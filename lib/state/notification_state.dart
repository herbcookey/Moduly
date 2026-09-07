import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_identity.dart';
import '../core/reminder_planner.dart';
import '../models/notification_models.dart';
import '../repositories/notification_repository.dart';
import '../repositories/schedule_repository.dart';

/// Platform boundary implemented by the UI/platform slice. It deliberately
/// accepts only token-free, bounded schedule requests from the controller.
abstract interface class LocalNotificationScheduler {
  NotificationCapabilityState get capability;

  Future<NotificationPermissionState> permissionStatus();

  Future<NotificationPermissionState> requestPermission();

  Future<void> schedule(NotificationScheduleRequest request);

  Future<void> cancel(Iterable<int> notificationIds);

  Future<List<int>> pendingNotificationIds();
}

/// Push is a typed capability seam only. The production implementation for
/// this slice is [UnconfiguredPushTokenSource], so no Firebase/APNs token can
/// accidentally be treated as an available delivery path.
abstract interface class PushTokenSource {
  NotificationCapabilityState get capability;

  Future<String?> tokenForUser(String userId);

  Future<void> revokeForUser(String userId);
}

class UnconfiguredPushTokenSource implements PushTokenSource {
  const UnconfiguredPushTokenSource();

  @override
  NotificationCapabilityState get capability =>
      NotificationCapabilityState.unconfigured;

  @override
  Future<String?> tokenForUser(String userId) async => null;

  @override
  Future<void> revokeForUser(String userId) async {}
}

class DisabledLocalNotificationScheduler implements LocalNotificationScheduler {
  const DisabledLocalNotificationScheduler({
    this.state = NotificationCapabilityState.unsupported,
  });

  final NotificationCapabilityState state;

  @override
  NotificationCapabilityState get capability => state;

  @override
  Future<NotificationPermissionState> permissionStatus() async =>
      switch (state) {
        NotificationCapabilityState.unsupported =>
          NotificationPermissionState.unsupported,
        NotificationCapabilityState.unconfigured =>
          NotificationPermissionState.unconfigured,
        NotificationCapabilityState.disabled =>
          NotificationPermissionState.disabled,
        NotificationCapabilityState.available =>
          NotificationPermissionState.disabled,
      };

  @override
  Future<NotificationPermissionState> requestPermission() => permissionStatus();

  @override
  Future<void> schedule(NotificationScheduleRequest request) async {
    throw StateError('로컬 알림을 사용할 수 없습니다.');
  }

  @override
  Future<void> cancel(Iterable<int> notificationIds) async {}

  @override
  Future<List<int>> pendingNotificationIds() async => const <int>[];
}

/// Narrow invalidation seam consumed by PlannerController. Keeping this
/// interface separate from the concrete controller means existing controller
/// fakes can omit notifications entirely.
abstract interface class NotificationInvalidationSink {
  Future<void> onAuthenticated(String userId);

  Future<void> onSignedOut();

  Future<void> reconcile({DateTime? nowUtc});

  Future<void> cancelForGroup(String groupId);

  Future<void> onEventChanged({String? eventId, String? groupId});

  Future<void> onMembershipChanged({String? eventId, String? groupId});
}

/// Core defaults are fail-closed. The app shell may override these providers
/// with the Supabase/local repository and native scheduler without making the
/// domain layer import platform implementations.
final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => ConfigurationBlockedNotificationRepository('알림 저장소가 구성되지 않았습니다.'),
);

final localNotificationSchedulerProvider = Provider<LocalNotificationScheduler>(
  (ref) => const DisabledLocalNotificationScheduler(),
);

final pushTokenSourceProvider = Provider<PushTokenSource>(
  (ref) => const UnconfiguredPushTokenSource(),
);

/// Durable platform wiring may override this provider with a
/// SharedPreferences-backed registry.  The core default remains in-memory so
/// embedders/tests are fail-closed and do not require a persistence plugin.
final notificationIdAllocatorProvider = Provider<NotificationIdAllocator>(
  (ref) => NotificationIdAllocator(),
);

final notificationControllerProvider =
    ChangeNotifierProvider<NotificationController>((ref) {
      final controller = NotificationController(
        repository: ref.watch(notificationRepositoryProvider),
        scheduler: ref.watch(localNotificationSchedulerProvider),
        pushTokenSource: ref.watch(pushTokenSourceProvider),
        idAllocator: ref.watch(notificationIdAllocatorProvider),
      );
      return controller;
    });

/// ChangeNotifier state for settings, OS permission and the serialized local
/// reconciliation loop. The planner never mutates event rows and every async
/// continuation checks the active user/session generation before committing.
class NotificationController extends ChangeNotifier
    implements NotificationInvalidationSink {
  NotificationController({
    required this.repository,
    this.scheduler,
    PushTokenSource? pushTokenSource,
    NotificationIdAllocator? idAllocator,
    DateTime Function()? clock,
    this.horizon = reminderPlanningHorizon,
    this.maxReminders = reminderPlanningLimit,
  }) : pushTokenSource = pushTokenSource ?? const UnconfiguredPushTokenSource(),
       idAllocator = idAllocator ?? NotificationIdAllocator(),
       clock = clock ?? DateTime.now {
    if (horizon <= Duration.zero || horizon > const Duration(days: 366)) {
      throw ArgumentError.value(horizon, 'horizon');
    }
    if (maxReminders < 1 || maxReminders > reminderPlanningLimit) {
      throw ArgumentError.value(maxReminders, 'maxReminders');
    }
  }

  final NotificationRepository repository;
  final LocalNotificationScheduler? scheduler;
  final PushTokenSource pushTokenSource;
  final NotificationIdAllocator idAllocator;
  final DateTime Function() clock;
  final Duration horizon;
  final int maxReminders;

  String? userId;
  UserNotificationSettings settings = const UserNotificationSettings(
    userId: '',
  );
  List<EventNotificationPreference> eventPreferences =
      const <EventNotificationPreference>[];
  NotificationPermissionState permission =
      NotificationPermissionState.unconfigured;
  NotificationCapabilityState capability =
      NotificationCapabilityState.unconfigured;
  NotificationCapabilityState pushCapability =
      NotificationCapabilityState.unconfigured;
  bool isLoading = false;
  bool isReconciling = false;
  bool candidatesIncomplete = false;
  String? errorMessage;
  List<PlannedReminder> plannedReminders = const <PlannedReminder>[];

  final Map<int, NotificationScheduleRequest> _scheduled =
      <int, NotificationScheduleRequest>{};
  Future<void> _serial = Future<void>.value();
  int _sessionGeneration = 0;
  int _reconcileGeneration = 0;
  // A rapid auth sequence can leave more than one old namespace waiting for
  // native cancellation (for example A -> B -> C while the first cancel is
  // failing). Keep all of them until their durable allocator snapshots have
  // been cleared; a single nullable slot would lose A when B is added.
  final Set<String> _pendingCleanupUsers = <String>{};
  final Set<int> _pendingNativeCleanupIds = <int>{};
  bool _pendingNativeCleanupRequired = false;
  bool _disposed = false;

  bool get isAuthenticated => userId != null;
  bool get localEnabled => settings.localDesired;
  bool get pushEnabled => settings.pushDesired;
  bool get canScheduleLocal =>
      capability == NotificationCapabilityState.available &&
      (permission == NotificationPermissionState.authorized ||
          permission == NotificationPermissionState.provisional);

  /// Called by the planner auth lifecycle after an authenticated identity is
  /// committed. A repeated id is a refresh, not a new user session.
  @override
  Future<void> onAuthenticated(String authenticatedUserId) {
    final normalized = authenticatedUserId.trim();
    if (normalized.isEmpty) {
      return Future<void>.error(const FormatException('로그인 세션을 확인해 주세요.'));
    }
    // Record the old namespace at intent time, before the serialized body
    // awaits any repository/native operation.  If this auth request supersedes
    // a sign-out (or an older auth request) while its cancellation is in
    // flight, the successor still has a durable user namespace to retry; the
    // stale continuation itself remains fenced from mutating visible state.
    final previousUser = userId;
    if (previousUser != null && previousUser != normalized) {
      _pendingCleanupUsers.add(previousUser);
    }
    // Fence any in-flight repository read as soon as a newer auth intent is
    // observed.  The actual identity/state mutation remains serialized below,
    // but stale continuations can no longer pass their generation checks while
    // this request is waiting behind an earlier operation.
    final requestedGeneration = ++_sessionGeneration;
    ++_reconcileGeneration;
    return _enqueue(() async {
      if (_disposed || requestedGeneration != _sessionGeneration) return;
      var cleanupReady = true;
      if (userId != normalized) {
        // Auth streams can switch directly from one signed-in account to
        // another without emitting a signed-out event in between.  Cancel
        // the old account's persisted IDs before replacing the in-memory
        // session, otherwise an old user's reminders could remain pending on
        // the device until the next native reconciliation.
        final previousUser = userId;
        if (previousUser != null) {
          _scheduled.clear();
          cleanupReady = await _cancelKnown(
            previousUser,
            session: requestedGeneration,
          );
          if (_disposed || requestedGeneration != _sessionGeneration) return;
        }
      }
      // A cold-start controller has no old in-memory account, but native
      // requests can survive process death. Purge the complete pending set
      // before allowing the newly authenticated account to schedule. A failed
      // purge blocks this load; retrying on resume/auth keeps the old account's
      // reminders from being mistaken for the new user's.
      if (cleanupReady &&
          (userId == null ||
              _pendingCleanupUsers.isNotEmpty ||
              _pendingNativeCleanupRequired ||
              _pendingNativeCleanupIds.isNotEmpty)) {
        cleanupReady = await _retryPendingCleanup(
          session: requestedGeneration,
          forceNative: userId == null,
        );
      }
      if (_disposed || requestedGeneration != _sessionGeneration) return;
      userId = normalized;
      settings = UserNotificationSettings(userId: normalized);
      eventPreferences = const <EventNotificationPreference>[];
      plannedReminders = const <PlannedReminder>[];
      _scheduled.clear();
      if (!cleanupReady) {
        // Authentication is committed for the new account, but no candidate
        // read/schedule may proceed until every pending request from the
        // previous process/account has been purged.  Mark the snapshot
        // incomplete so callers cannot mistake this fail-closed state for an
        // authoritative empty schedule; onResume retries the cleanup.
        candidatesIncomplete = true;
        errorMessage = _friendlyError(
          const ScheduleCapabilityException(
            '이전 알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
          ),
        );
        notifyListeners();
        return;
      }
      await _loadAndReconcile(
        normalized,
        nowUtc: clock().toUtc(),
        session: requestedGeneration,
      );
    });
  }

  /// Clears desired state synchronously, then best-effort cancels only IDs
  /// owned by the old user. A complete successful cancellation also clears
  /// that user's durable ownership; failures retain it for a later retry.
  @override
  Future<void> onSignedOut() {
    // Preserve the old namespace synchronously.  The queued operation clears
    // the visible account before awaiting cancellation, so an immediate auth
    // switch cannot lose the retry handle if native cancellation fails or the
    // sign-out operation is superseded.
    final previousUser = userId;
    if (previousUser != null) _pendingCleanupUsers.add(previousUser);
    // Invalidate the current session before queuing cancellation so a pending
    // per-event load/reconcile cannot commit rows for the account that is
    // already leaving.  The queued operation performs the visible clear and
    // best-effort platform cancellation in order.
    final requestedGeneration = ++_sessionGeneration;
    ++_reconcileGeneration;
    return _enqueue(() async {
      if (_disposed || requestedGeneration != _sessionGeneration) return;
      final oldUser = userId;
      userId = null;
      settings = const UserNotificationSettings(userId: '');
      eventPreferences = const <EventNotificationPreference>[];
      plannedReminders = const <PlannedReminder>[];
      candidatesIncomplete = false;
      errorMessage = null;
      isLoading = false;
      isReconciling = false;
      _scheduled.clear();
      notifyListeners();
      var cleanupReady = true;
      if (oldUser != null) {
        cleanupReady = await _cancelKnown(
          oldUser,
          session: requestedGeneration,
          allowSignedOut: true,
        );
      } else {
        // A freshly created controller has no account namespace to consult,
        // but native requests can survive process death from an earlier
        // signed-in session. Retry any known account namespace first, then
        // clean valid app-owned pending IDs without touching other registries.
        cleanupReady = await _retryPendingCleanup(
          session: requestedGeneration,
          forceNative: true,
        );
      }
      if (!cleanupReady && _isGenerationCurrent(requestedGeneration)) {
        errorMessage = _friendlyError(
          const ScheduleCapabilityException(
            '이전 알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
          ),
        );
        notifyListeners();
      }
    });
  }

  @override
  Future<void> reconcile({DateTime? nowUtc}) {
    final active = userId;
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (active == null || !_isCurrent(active, session)) return;
      await _reconcileInternal(
        active,
        nowUtc: (nowUtc ?? clock()).toUtc(),
        session: session,
      );
    });
  }

  /// Rechecks OS authorization after a settings/app-resume return and then
  /// applies the current desired settings.
  Future<void> onResume() {
    final active = userId;
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (!_isGenerationCurrent(session)) return;
      if (active == null) {
        final cleanupReady = await _retryPendingCleanup(
          session: session,
          forceNative: true,
        );
        if (!_isGenerationCurrent(session)) return;
        if (!cleanupReady) {
          errorMessage = _friendlyError(
            const ScheduleCapabilityException(
              '이전 알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
            ),
          );
          notifyListeners();
        }
        return;
      }
      if (!_isCurrent(active, session)) return;
      // A failed account switch/cold-start cleanup commits the new identity
      // only as a fail-closed shell (settings/preferences are intentionally
      // reset and no candidates are read).  Once the retained IDs have been
      // purged, reload the account snapshot before reconciling; otherwise the
      // default `localDesired == false` shell would incorrectly suppress the
      // new account's reminders forever.
      final hadPendingCleanup =
          _pendingCleanupUsers.isNotEmpty ||
          _pendingNativeCleanupRequired ||
          _pendingNativeCleanupIds.isNotEmpty ||
          settings.userId != active;
      if (!await _retryPendingCleanup(session: session)) {
        if (_isCurrent(active, session)) {
          errorMessage = _friendlyError(
            const ScheduleCapabilityException(
              '이전 알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
            ),
          );
          notifyListeners();
        }
        return;
      }
      if (!_isCurrent(active, session)) return;
      if (hadPendingCleanup) {
        await _loadAndReconcile(
          active,
          nowUtc: clock().toUtc(),
          session: session,
        );
        return;
      }
      if (!await _refreshPermissionInternal(active: active, session: session)) {
        return;
      }
      if (!_isCurrent(active, session)) return;
      await _reconcileInternal(
        active,
        nowUtc: clock().toUtc(),
        session: session,
      );
    });
  }

  Future<NotificationPermissionState> requestPermission() {
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (!_isGenerationCurrent(session)) return permission;
      if (scheduler == null) {
        permission = NotificationPermissionState.unconfigured;
        notifyListeners();
        return permission;
      }
      final requested = await scheduler!.requestPermission();
      final nextCapability = scheduler!.capability;
      final active = userId;
      if (active == null || !_isCurrent(active, session)) return permission;
      permission = requested;
      capability = nextCapability;
      notifyListeners();
      await _reconcileInternal(
        active,
        nowUtc: clock().toUtc(),
        session: session,
      );
      return permission;
    });
  }

  Future<NotificationPermissionState> refreshPermission() {
    final active = userId;
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (active == null || !_isCurrent(active, session)) return permission;
      await _refreshPermissionInternal(active: active, session: session);
      return permission;
    });
  }

  /// Loads the series-wide settings for one logical event.
  ///
  /// Remote notification settings are intentionally exposed one event at a
  /// time.  A caller opening an event editor must not assume that the
  /// account-wide snapshot has already included this event (the production
  /// RPC does not enumerate every event).  This operation therefore replaces
  /// only rows for [eventId], preserving settings cached for every other
  /// event.  It never reconciles or schedules as a side effect: the caller
  /// receives the persisted desired rows and the normal mutation/reconcile
  /// path remains the only place that can touch the platform scheduler.
  ///
  /// A session generation is captured before the repository read and checked
  /// before any state mutation.  If the account is signed out/switched (or
  /// this controller is disposed) while the read is in flight, the stale
  /// result is ignored and an empty list is returned.  Repository and wire
  /// validation failures are surfaced through [errorMessage] and rethrown so
  /// the UI cannot display a false successful load.
  Future<List<EventNotificationPreference>> loadEventPreferences(
    String eventId,
  ) {
    final active = userId;
    final normalizedEventId = eventId.trim();
    if (active == null) {
      return Future<List<EventNotificationPreference>>.error(
        const ScheduleAuthorizationException('로그인 세션을 확인해 주세요.'),
      );
    }
    if (normalizedEventId.isEmpty || normalizedEventId != eventId) {
      return Future<List<EventNotificationPreference>>.error(
        const ScheduleValidationException('일정 알림 설정을 확인해 주세요.'),
      );
    }
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (!_isCurrent(active, session)) {
        return const <EventNotificationPreference>[];
      }
      errorMessage = null;
      notifyListeners();
      try {
        final loaded = await repository.preferencesForEvent(
          userId: active,
          eventId: normalizedEventId,
        );
        // Do not even validate or merge data after the auth/session fence has
        // been crossed.  A stale account result must be observationally inert.
        if (!_isCurrent(active, session)) {
          return const <EventNotificationPreference>[];
        }

        final replacement = <EventNotificationPreference>[];
        final channels = <NotificationChannel>{};
        for (final value in loaded) {
          if (value.userId != active || value.eventId != normalizedEventId) {
            throw const ScheduleConflictException(
              '일정 알림 설정 응답의 사용자 또는 일정을 확인할 수 없습니다.',
            );
          }
          if (!channels.add(value.channel)) {
            throw const ScheduleConflictException('일정 알림 설정 응답에 중복 채널이 있습니다.');
          }
          replacement.add(value);
        }
        final merged =
            <EventNotificationPreference>[
              ...eventPreferences.where(
                (value) => value.eventId != normalizedEventId,
              ),
              ...replacement,
            ]..sort((left, right) {
              final event = left.eventId.compareTo(right.eventId);
              if (event != 0) return event;
              final channel = left.channel.wireName.compareTo(
                right.channel.wireName,
              );
              if (channel != 0) return channel;
              return left.id.compareTo(right.id);
            });
        eventPreferences = List<EventNotificationPreference>.unmodifiable(
          merged,
        );
        final output = List<EventNotificationPreference>.unmodifiable(
          replacement,
        );
        notifyListeners();
        return output;
      } catch (error) {
        if (_isCurrent(active, session)) {
          errorMessage = _friendlyError(error);
          notifyListeners();
        }
        rethrow;
      }
    });
  }

  /// Evicts one logical event from the in-memory preference/planned snapshot.
  ///
  /// Membership removal can make a previously cached event row unauthorized
  /// before the next account-wide candidate reconcile completes. This method
  /// only removes that event's local cache; it does not touch the repository
  /// or cancel platform requests. The next authoritative reconcile owns
  /// scheduler cleanup, and every other event's cache remains intact.
  Future<void> forgetEventPreferences(String eventId) {
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (!_isGenerationCurrent(session)) return;
      final normalizedEventId = eventId.trim();
      if (normalizedEventId.isEmpty || normalizedEventId != eventId) {
        throw const ScheduleValidationException('일정 알림 설정을 확인해 주세요.');
      }
      eventPreferences = List<EventNotificationPreference>.unmodifiable(
        eventPreferences.where((value) => value.eventId != normalizedEventId),
      );
      plannedReminders = List<PlannedReminder>.unmodifiable(
        plannedReminders.where(
          (value) =>
              value.eventId != normalizedEventId &&
              value.identity.eventId != normalizedEventId,
        ),
      );
      notifyListeners();
    });
  }

  /// Naming alias for callers that use cache-eviction terminology.
  Future<void> evictEventPreferences(String eventId) =>
      forgetEventPreferences(eventId);

  Future<void> saveSettings(
    UserNotificationSettings desired, {
    int? expectedVersion,
  }) {
    final active = userId;
    final session = _sessionGeneration;
    if (active == null || desired.userId != active) {
      return Future<void>.error(
        const ScheduleAuthorizationException('로그인 세션을 확인해 주세요.'),
      );
    }
    return _enqueue(() async {
      if (!_isCurrent(active, session)) return;
      isLoading = true;
      errorMessage = null;
      notifyListeners();
      try {
        final saved = await repository.saveSettings(
          desired,
          expectedVersion: expectedVersion ?? settings.version,
        );
        if (!_isCurrent(active, session)) return;
        settings = saved;
        await _reconcileInternal(
          active,
          nowUtc: clock().toUtc(),
          session: session,
        );
      } catch (error) {
        if (_isCurrent(active, session)) {
          errorMessage = _friendlyError(error);
        }
        rethrow;
      } finally {
        if (_isCurrent(active, session)) {
          isLoading = false;
          notifyListeners();
        }
      }
    });
  }

  /// Convenience for the account local switch. The server schema stores the
  /// local account switch as one value; [enabled] and [localEnabled] remain in
  /// lock-step while push is separately retained/disabled.
  Future<void> setLocalEnabled(bool enabled) => saveSettings(
    settings.copyWith(enabled: enabled, localEnabled: enabled),
    expectedVersion: settings.version,
  );

  /// Explicit account-wide spelling for new callers. Keep
  /// [setLocalEnabled] as a source-compatible alias for older settings UI;
  /// neither method represents a per-device preference.
  Future<void> setAccountEnabled(bool enabled) => setLocalEnabled(enabled);

  Future<void> saveEventPreference(
    EventNotificationPreference desired, {
    int? expectedVersion,
  }) {
    final active = userId;
    final session = _sessionGeneration;
    if (active == null || desired.userId != active) {
      return Future<void>.error(
        const ScheduleAuthorizationException('로그인 세션을 확인해 주세요.'),
      );
    }
    return _enqueue(() async {
      if (!_isCurrent(active, session)) return;
      isLoading = true;
      errorMessage = null;
      notifyListeners();
      try {
        final saved = await repository.saveEventPreference(
          desired,
          expectedVersion: expectedVersion ?? desired.version,
        );
        if (!_isCurrent(active, session)) return;
        final next = <EventNotificationPreference>[
          ...eventPreferences.where(
            (value) =>
                !(value.eventId == saved.eventId &&
                    value.channel == saved.channel),
          ),
          saved,
        ]..sort((left, right) => left.eventId.compareTo(right.eventId));
        eventPreferences = List<EventNotificationPreference>.unmodifiable(next);
        await _reconcileInternal(
          active,
          nowUtc: clock().toUtc(),
          session: session,
        );
      } catch (error) {
        if (_isCurrent(active, session)) {
          errorMessage = _friendlyError(error);
        }
        rethrow;
      } finally {
        if (_isCurrent(active, session)) {
          isLoading = false;
          notifyListeners();
        }
      }
    });
  }

  Future<void> deleteEventPreference({
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  }) {
    final active = userId;
    final session = _sessionGeneration;
    if (active == null) {
      return Future<void>.error(
        const ScheduleAuthorizationException('로그인 세션을 확인해 주세요.'),
      );
    }
    return _enqueue(() async {
      if (!_isCurrent(active, session)) return;
      await repository.deleteEventPreference(
        userId: active,
        eventId: eventId,
        channel: channel,
        expectedVersion: expectedVersion,
      );
      if (!_isCurrent(active, session)) return;
      eventPreferences = List<EventNotificationPreference>.unmodifiable(
        eventPreferences.where(
          (value) => !(value.eventId == eventId && value.channel == channel),
        ),
      );
      await _reconcileInternal(
        active,
        nowUtc: clock().toUtc(),
        session: session,
      );
      if (!_isCurrent(active, session)) return;
      notifyListeners();
    });
  }

  /// A group leave/archive path calls this before clearing its planner rows.
  ///
  /// The group id is an invalidation boundary, not an ownership key: after a
  /// process restart [_scheduled] is empty and the durable allocator stores
  /// only opaque identities (not group membership).  To avoid leaving a
  /// removed group's native request behind, first cancel the active user's
  /// complete durable/native pending set, then rebuild only the still
  /// authoritative all-group set in the same session generation.  If either
  /// the full cancellation proof or the replacement read fails, we remain
  /// fail-closed (the removed reminder cannot fire); a later lifecycle pass
  /// can restore reminders for groups that are still accessible.
  @override
  Future<void> cancelForGroup(String groupId) {
    final normalized = groupId.trim();
    final active = userId;
    final session = _sessionGeneration;
    return _enqueue(() async {
      if (normalized.isEmpty ||
          active == null ||
          !_isCurrent(active, session)) {
        return;
      }
      // Do not leave a stale planned projection visible while the account-wide
      // purge and authoritative replacement are in flight.
      plannedReminders = const <PlannedReminder>[];
      final cancelled = await _cancelKnown(active, session: session);
      if (!_isCurrent(active, session)) {
        return;
      }
      if (!cancelled) {
        candidatesIncomplete = true;
        errorMessage = _friendlyError(
          const ScheduleCapabilityException('알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.'),
        );
        notifyListeners();
        return;
      }
      await _reconcileInternal(
        active,
        nowUtc: clock().toUtc(),
        session: session,
      );
    });
  }

  @override
  Future<void> onEventChanged({String? eventId, String? groupId}) =>
      reconcile();

  @override
  Future<void> onMembershipChanged({String? eventId, String? groupId}) =>
      reconcile();

  Future<void> _loadAndReconcile(
    String active, {
    required DateTime nowUtc,
    required int session,
  }) async {
    if (!_isCurrent(active, session)) return;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final loadedSettings = await repository.settingsForUser(active);
      if (!_isCurrent(active, session)) return;
      final loadedPreferences = await repository.preferencesForUser(active);
      if (!_isCurrent(active, session)) return;
      settings = loadedSettings;
      eventPreferences = loadedPreferences;
      pushCapability = pushTokenSource.capability;
      if (!_isCurrent(active, session)) return;
      if (!await _refreshPermissionInternal(active: active, session: session)) {
        return;
      }
      if (!_isCurrent(active, session)) return;
      await _reconcileInternal(active, nowUtc: nowUtc, session: session);
    } catch (error) {
      if (_isCurrent(active, session)) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      if (_isCurrent(active, session)) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _refreshPermissionInternal({
    String? active,
    int? session,
  }) async {
    final nextCapability =
        scheduler?.capability ?? NotificationCapabilityState.unconfigured;
    final nextPermission = scheduler == null
        ? NotificationPermissionState.unconfigured
        : await scheduler!.permissionStatus();
    if (active != null && (session == null || !_isCurrent(active, session))) {
      return false;
    }
    if (session != null &&
        (active == null || _disposed || _sessionGeneration != session)) {
      return false;
    }
    capability = nextCapability;
    permission = nextPermission;
    notifyListeners();
    return true;
  }

  Future<void> _reconcileInternal(
    String active, {
    required DateTime nowUtc,
    required int session,
  }) async {
    final reconcile = ++_reconcileGeneration;
    if (!_isCurrent(active, session)) return;
    isReconciling = true;
    candidatesIncomplete = false;
    notifyListeners();
    try {
      // A terminal/group invalidation or disabled transition may have left a
      // native cancellation pending after a failed platform call.  Never let
      // an ordinary event/auth reconcile schedule a replacement while those
      // stale requests are still live: retry the complete cleanup proof first,
      // and remain fail-closed until it succeeds.  This guard is centralized
      // here so every caller (resume, event mutation, realtime invalidation,
      // and an explicit reconcile) shares the same privacy boundary.
      final hasPendingCleanup =
          _pendingCleanupUsers.isNotEmpty ||
          _pendingNativeCleanupRequired ||
          _pendingNativeCleanupIds.isNotEmpty;
      if (hasPendingCleanup) {
        final cleanupReady = await _retryPendingCleanup(session: session);
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        if (!cleanupReady) {
          plannedReminders = const <PlannedReminder>[];
          candidatesIncomplete = true;
          errorMessage = _friendlyError(
            const ScheduleCapabilityException(
              '이전 알림을 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
            ),
          );
          return;
        }
      }
      if (scheduler == null ||
          capability != NotificationCapabilityState.available ||
          (permission != NotificationPermissionState.authorized &&
              permission != NotificationPermissionState.provisional) ||
          !settings.localDesired) {
        plannedReminders = const <PlannedReminder>[];
        await _cancelKnown(active, session: session, reconcile: reconcile);
        return;
      }
      final candidates = <ReminderCandidate>[];
      ReminderCandidateCursor? cursor;
      var pages = 0;
      while (true) {
        if (++pages > reminderPageCap) {
          candidatesIncomplete = true;
          break;
        }
        final page = await repository.reminderCandidatesForUser(
          userId: active,
          fireAtStart: nowUtc,
          fireAtEnd: nowUtc.add(horizon),
          cursor: cursor,
          limit: reminderPageLimit,
        );
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        capability = page.capability;
        candidates.addAll(page.candidates);
        if (!page.complete) candidatesIncomplete = true;
        if (!page.hasMore) break;
        cursor = page.nextCursor;
        if (cursor == null) {
          candidatesIncomplete = true;
          break;
        }
      }
      // A repository can revoke its local capability between the initial
      // permission check and the candidate RPC (for example when the server
      // account switch is still settling). Fail closed instead of scheduling
      // a page that explicitly reports disabled/unsupported capability.
      if (capability != NotificationCapabilityState.available) {
        plannedReminders = const <PlannedReminder>[];
        await _cancelKnown(active, session: session, reconcile: reconcile);
        return;
      }
      final planned = ReminderPlanner.fromCandidates(
        userId: active,
        candidates: candidates,
        nowUtc: nowUtc,
        horizon: horizon,
        maxReminders: maxReminders,
      );
      if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
        return;
      }
      plannedReminders = planned;
      // A malformed or unavailable durable allocator must not permanently
      // block an otherwise authoritative schedule. Recovery is deliberately
      // restricted to complete candidate pagination: enumerate every native
      // pending request, cancel that complete set, overwrite the registry
      // without reading it, then allocate the desired IDs from an empty map.
      // On incomplete pages we fail closed and never broaden cancellation.
      if (!candidatesIncomplete) {
        try {
          await idAllocator.entriesFor(active);
          if (!_isCurrent(active, session) ||
              reconcile != _reconcileGeneration) {
            return;
          }
        } catch (error) {
          final recovered = await _recoverUnreadableRegistry(
            active,
            session: session,
            reconcile: reconcile,
          );
          if (!_isCurrent(active, session) ||
              reconcile != _reconcileGeneration) {
            return;
          }
          if (!recovered) {
            plannedReminders = const <PlannedReminder>[];
            candidatesIncomplete = true;
            errorMessage = _friendlyError(
              const ScheduleCapabilityException(
                '알림 식별자 저장소를 복구할 수 없습니다. 잠시 후 다시 시도해 주세요.',
              ),
            );
            return;
          }
          _scheduled.clear();
        }
      }
      final desired = <int>{};
      final requests = <int, NotificationScheduleRequest>{};
      for (final reminder in planned) {
        final id = await idAllocator.idFor(reminder.identity);
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        desired.add(id);
        requests[id] = reminder.withId(id);
      }
      if (!candidatesIncomplete) {
        final known = await _knownIds(active);
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        final stale = known.ids.where((id) => !desired.contains(id));
        final cancelled = await _cancelIds(stale);
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        // Prune durable ownership only after a complete, successfully
        // cancelled snapshot. If native cancellation or pending inspection
        // fails, retain stale rows so a future reconcile can retry them.
        if (cancelled && known.complete) {
          try {
            await idAllocator.retainIds(active, desired);
            if (!_isCurrent(active, session) ||
                reconcile != _reconcileGeneration) {
              return;
            }
          } catch (error) {
            // Scheduling can still proceed, but surface persistence failure
            // and leave the allocator's prior snapshot intact for retry.
            if (_isCurrent(active, session) &&
                reconcile == _reconcileGeneration) {
              errorMessage = _friendlyError(error);
            }
          }
        }
      }
      for (final entry in requests.entries) {
        if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
          return;
        }
        try {
          await scheduler!.schedule(entry.value);
          if (!_isCurrent(active, session) ||
              reconcile != _reconcileGeneration) {
            return;
          }
          _scheduled[entry.key] = entry.value;
        } catch (error) {
          // Keep other valid reminders, but surface a typed state rather than
          // claiming every candidate was successfully scheduled.
          if (_isCurrent(active, session) &&
              reconcile == _reconcileGeneration) {
            errorMessage = _friendlyError(error);
          }
        }
      }
    } catch (error) {
      if (_isCurrent(active, session) && reconcile == _reconcileGeneration) {
        candidatesIncomplete = true;
        errorMessage = _friendlyError(error);
      }
    } finally {
      if (_isCurrent(active, session) && reconcile == _reconcileGeneration) {
        isReconciling = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _cancelKnown(
    String active, {
    int? session,
    int? reconcile,
    bool allowSignedOut = false,
  }) async {
    bool isCurrentCancellation() => session == null
        ? true
        : (allowSignedOut
              ? _isGenerationCurrent(session)
              : _isCurrent(active, session));

    final known = await _knownIds(active);
    if (!isCurrentCancellation() ||
        (reconcile != null && reconcile != _reconcileGeneration)) {
      return false;
    }
    final cancelled = await _cancelIds(known.ids);
    if (!isCurrentCancellation() ||
        (reconcile != null && reconcile != _reconcileGeneration)) {
      return false;
    }
    var complete = cancelled && known.complete;
    if (complete) {
      try {
        await idAllocator.clearUser(active);
        if (!isCurrentCancellation() ||
            (reconcile != null && reconcile != _reconcileGeneration)) {
          return false;
        }
      } catch (_) {
        // Keep ownership in memory/registry when the durable clear fails so a
        // later lifecycle pass can retry cancellation and pruning.
        complete = false;
      }
    }
    if (complete) {
      _pendingCleanupUsers.remove(active);
      // Native IDs may have belonged to another old namespace that is still
      // awaiting durable cleanup. Preserve their retry set until that
      // namespace is cleared as well; otherwise a later account switch could
      // lose the only handle to its registry.
      if (_pendingCleanupUsers.isEmpty) {
        _pendingNativeCleanupIds.clear();
        _pendingNativeCleanupRequired = false;
      }
    } else {
      _pendingCleanupUsers.add(active);
      _pendingNativeCleanupIds.addAll(known.ids);
      _pendingNativeCleanupRequired = true;
    }
    if (session == null ||
        (_isGenerationCurrent(session) &&
            (reconcile == null || reconcile == _reconcileGeneration))) {
      _scheduled.clear();
    }
    return complete;
  }

  Future<bool> _cancelPendingOnly({int? session}) async {
    final scheduler = this.scheduler;
    if (scheduler == null) {
      return !_pendingNativeCleanupRequired && _pendingNativeCleanupIds.isEmpty;
    }
    if (session != null && !_isGenerationCurrent(session)) return false;
    final pending = <int>{..._pendingNativeCleanupIds};
    try {
      pending.addAll(
        (await scheduler.pendingNotificationIds()).where(
          _isValidNotificationId,
        ),
      );
    } catch (_) {
      _pendingNativeCleanupIds
        ..clear()
        ..addAll(pending.where(_isValidNotificationId));
      _pendingNativeCleanupRequired = true;
      return false;
    }
    if (session != null && !_isGenerationCurrent(session)) return false;
    final cancelled = await _cancelIds(pending);
    if (session != null && !_isGenerationCurrent(session)) return false;
    if (cancelled) {
      _pendingNativeCleanupIds.clear();
      _pendingNativeCleanupRequired = false;
      return true;
    }
    _pendingNativeCleanupIds
      ..clear()
      ..addAll(pending);
    _pendingNativeCleanupRequired = true;
    return false;
  }

  /// Retries privacy cleanup left behind by a failed sign-out/account switch
  /// or a prior cold-start pending-ID probe.  A caller must hold the current
  /// session generation; this helper never schedules a replacement itself.
  Future<bool> _retryPendingCleanup({
    required int session,
    bool forceNative = false,
  }) async {
    if (!_isGenerationCurrent(session)) return false;
    // Work through a snapshot so each old account gets its own durable clear.
    // New auth intents can append to the set while an await is in flight; the
    // generation fence below makes this attempt stale and the next lifecycle
    // call retries the newly-added namespace.
    final pendingUsers = List<String>.from(_pendingCleanupUsers);
    for (final pendingUser in pendingUsers) {
      final cleaned = await _cancelKnown(
        pendingUser,
        session: session,
        allowSignedOut: true,
      );
      if (!_isGenerationCurrent(session) || !cleaned) return false;
    }
    if (forceNative ||
        _pendingNativeCleanupRequired ||
        _pendingNativeCleanupIds.isNotEmpty) {
      final cleaned = await _cancelPendingOnly(session: session);
      if (!_isGenerationCurrent(session) || !cleaned) return false;
    }
    return _pendingCleanupUsers.isEmpty &&
        !_pendingNativeCleanupRequired &&
        _pendingNativeCleanupIds.isEmpty;
  }

  /// Repairs a registry that cannot be read, but only while the candidate
  /// snapshot is authoritative. The pending-ID enumeration is part of the
  /// proof that broad cancellation is safe; any read/cancel/clear failure
  /// leaves durable ownership untouched and keeps reconciliation fail-closed.
  Future<bool> _recoverUnreadableRegistry(
    String active, {
    required int session,
    required int reconcile,
  }) async {
    final scheduler = this.scheduler;
    if (scheduler == null) return false;
    final pending = <int>[];
    try {
      final nativeIds = await scheduler.pendingNotificationIds();
      if (nativeIds.any((id) => !_isValidNotificationId(id))) return false;
      pending.addAll(nativeIds);
    } catch (_) {
      return false;
    }
    if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
      return false;
    }
    if (!await _cancelIds(pending)) return false;
    if (!_isCurrent(active, session) || reconcile != _reconcileGeneration) {
      return false;
    }
    try {
      // clearUser writes an empty map directly; it does not attempt to load
      // or validate the unreadable snapshot first.
      await idAllocator.clearUser(active);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the union of durable allocator ownership and native pending
  /// requests. Native requests can outlive a process (or an in-memory
  /// allocator after restart), so an authoritative full reconcile, sign-out,
  /// account switch, or disabled transition must also clean pending-only IDs.
  /// Query failures are fail-closed and leave the durable registry untouched;
  /// a later reconcile can retry the best-effort cancellation.
  Future<_KnownNotificationIds> _knownIds(String active) async {
    final ids = <int>{..._pendingNativeCleanupIds};
    var complete = true;
    try {
      ids.addAll(
        (await idAllocator.entriesFor(
          active,
        )).map((entry) => entry.id).where(_isValidNotificationId),
      );
    } catch (_) {
      // A corrupt/unavailable registry must not prevent native cleanup.
      complete = false;
    }
    final scheduler = this.scheduler;
    if (scheduler == null) {
      return _KnownNotificationIds(ids: ids, complete: complete);
    }
    try {
      ids.addAll(
        (await scheduler.pendingNotificationIds()).where(
          _isValidNotificationId,
        ),
      );
    } catch (_) {
      // Native pending inspection is best effort. Keep allocator IDs and
      // retry on the next lifecycle/reconcile pass.
      complete = false;
    }
    return _KnownNotificationIds(ids: ids, complete: complete);
  }

  static bool _isValidNotificationId(int id) =>
      id >= 1 && id <= NotificationIdAllocator.maxPositive31Bit;

  Future<bool> _cancelIds(Iterable<int> ids) async {
    final values = ids.toSet();
    if (values.isEmpty) return true;
    final scheduler = this.scheduler;
    if (scheduler == null) return false;
    try {
      await scheduler.cancel(values);
      return true;
    } catch (_) {
      // Cancellation is best effort during sign-out/denied transitions. A
      // future complete reconcile retries known IDs; no fake success is
      // exposed because state retains the permission/capability status.
      return false;
    }
  }

  bool _isGenerationCurrent(int session) =>
      !_disposed && _sessionGeneration == session;

  bool _isCurrent(String active, int session) =>
      _isGenerationCurrent(session) && userId == active;

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _serial.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _serial = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  String _friendlyError(Object error) {
    if (error is ScheduleConflictException) return error.message;
    if (error is ScheduleValidationException) return error.message;
    if (error is ScheduleAuthorizationException) return error.message;
    if (error is ScheduleCapabilityException) return error.message;
    if (error is FormatException) return error.message;
    return '알림을 업데이트하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _reconcileGeneration++;
    super.dispose();
  }
}

class _KnownNotificationIds {
  const _KnownNotificationIds({required this.ids, required this.complete});

  final Set<int> ids;
  final bool complete;
}
