import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/notification_identity.dart';
import '../models/notification_models.dart';
import '../repositories/notification_repository.dart';
import '../state/app_state.dart';
import '../state/notification_state.dart';
import 'notification_id_registry.dart';
import 'notification_local_scheduler.dart';

void _runDetachedNotificationOperation(Future<void> Function() operation) {
  Future<void>.sync(operation).ignore();
}

/// Creates the concrete notification providers at the app boundary. The core
/// providers intentionally remain fail-closed so tests and other embedders can
/// use the domain controller without importing a native plugin.
class NotificationPlatformScope extends ConsumerStatefulWidget {
  const NotificationPlatformScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<NotificationPlatformScope> createState() =>
      _NotificationPlatformScopeState();
}

class _NotificationPlatformScopeState
    extends ConsumerState<NotificationPlatformScope> {
  late final NotificationRepository _repository;
  late final LocalNotificationScheduler _scheduler;
  late final PushTokenSource _pushTokenSource;
  late final NotificationIdAllocator _idAllocator;

  @override
  void initState() {
    super.initState();
    final client = ref.read(supabaseClientProvider);
    final schedule = ref.read(scheduleRepositoryProvider);
    final releaseError = ref.read(releaseConfigurationErrorProvider);
    final allowDemo = ref.read(localDemoAllowedProvider);
    _repository = client != null
        ? SupabaseNotificationRepository(client)
        : allowDemo
        ? LocalNotificationRepository(schedule)
        : ConfigurationBlockedNotificationRepository(
            releaseError ?? '알림 저장소가 구성되지 않았습니다.',
          );
    final nativeLocalSupported =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (!nativeLocalSupported) {
      _scheduler = const DisabledLocalNotificationScheduler();
      _idAllocator = NotificationIdAllocator();
    } else if (client == null) {
      // Local demo rows use human-readable IDs and are intentionally not
      // eligible for native deep-link delivery. Keep demo settings visible,
      // but fail closed instead of claiming that an OS notification was
      // scheduled or that its tap could pass the UUID-backed auth fence.
      _scheduler = const DisabledLocalNotificationScheduler(
        state: NotificationCapabilityState.unconfigured,
      );
      _idAllocator = NotificationIdAllocator();
    } else {
      final concrete = FlutterLocalNotificationScheduler();
      _scheduler = concrete;
      _idAllocator = NotificationIdAllocator(
        registry: SharedPreferencesAsyncNotificationIdRegistry(),
      );
      // Start native setup while the app shell is being built. The lifecycle
      // binding awaits the same idempotent initialization before auth sync.
      _runDetachedNotificationOperation(concrete.initialize);
    }
    _pushTokenSource = const UnconfiguredPushTokenSource();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: <Override>[
        notificationRepositoryProvider.overrideWithValue(_repository),
        localNotificationSchedulerProvider.overrideWithValue(_scheduler),
        pushTokenSourceProvider.overrideWithValue(_pushTokenSource),
        notificationIdAllocatorProvider.overrideWithValue(_idAllocator),
      ],
      child: widget.child,
    );
  }
}

/// Eagerly keeps [NotificationController] alive, binds planner auth/group
/// lifecycle, and handles local notification taps. Cold-start details are
/// consumed once by the native adapter; warm callbacks are delivery events.
/// Route navigation occurs only after the controller has fetched and
/// membership-validated the authoritative occurrence.
class NotificationLifecycleBinding extends ConsumerStatefulWidget {
  const NotificationLifecycleBinding({
    required this.child,
    this.router,
    this.schedulerReady,
    super.key,
  });

  final Widget child;
  final GoRouter? router;
  final Future<void>? schedulerReady;

  @override
  ConsumerState<NotificationLifecycleBinding> createState() =>
      _NotificationLifecycleBindingState();
}

class _NotificationLifecycleBindingState
    extends ConsumerState<NotificationLifecycleBinding>
    with WidgetsBindingObserver {
  String? _lastUserId;
  bool _hasSyncedPlannerIdentity = false;
  String? _inFlightUserId;
  bool _identitySyncInFlight = false;
  int _identitySyncGeneration = 0;
  int _plannerStateGeneration = 0;
  NotificationPayload? _pendingPayload;
  String? _pendingPayloadFingerprint;
  bool _payloadInFlight = false;
  String? _inFlightPayloadFingerprint;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final planner = ref.read(plannerControllerProvider);
    ref.listenManual<PlannerController>(plannerControllerProvider, (_, next) {
      _plannerStateGeneration += 1;
      _syncPlanner(next);
      _tryOpenPending(next);
    });
    // Ensure the controller and adapter are created eagerly even before a
    // settings route is visited. The first auth sync waits for native setup.
    ref.read(notificationControllerProvider);
    final scheduler = ref.read(localNotificationSchedulerProvider);
    if (scheduler is FlutterLocalNotificationScheduler) {
      scheduler.onPayload = _receivePayload;
      _runDetachedNotificationOperation(() => _consumeColdStart(scheduler));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _syncPlanner(planner);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _identitySyncGeneration += 1;
    _identitySyncInFlight = false;
    _inFlightUserId = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _disposed) return;
    final controller = ref.read(notificationControllerProvider);
    _runDetachedNotificationOperation(controller.onResume);
  }

  Future<void> _consumeColdStart(
    FlutterLocalNotificationScheduler scheduler,
  ) async {
    try {
      await _platformReady();
      final payload = await scheduler.consumeLaunchPayload();
      if (payload != null) _receivePayload(payload);
    } catch (_) {
      // A malformed/unsupported native launch payload is ignored. The app
      // remains on its normal authenticated route with no token-bearing UI.
    }
  }

  void _receivePayload(NotificationPayload payload) {
    if (_disposed) return;
    final fingerprint = payload.encode();
    // Native plugins may deliver the same warm response more than once while
    // a point lookup is pending. Coalesce that duplicate, but retain a later
    // distinct reminder so it can be validated after the current request.
    if (_payloadInFlight &&
        (fingerprint == _inFlightPayloadFingerprint ||
            fingerprint == _pendingPayloadFingerprint)) {
      return;
    }
    _pendingPayload = payload;
    _pendingPayloadFingerprint = fingerprint;
    _tryOpenPending(ref.read(plannerControllerProvider));
  }

  void _syncPlanner(PlannerController planner) {
    if (_disposed) return;
    final active = planner.user?.id;
    if (_identitySyncInFlight) {
      if (active == _inFlightUserId) return;
    } else if (_hasSyncedPlannerIdentity && active == _lastUserId) {
      return;
    }
    final syncGeneration = ++_identitySyncGeneration;
    _identitySyncInFlight = true;
    _inFlightUserId = active;
    _hasSyncedPlannerIdentity = false;
    _runDetachedNotificationOperation(() async {
      try {
        await _platformReady();
        if (_disposed || syncGeneration != _identitySyncGeneration) return;
        var latest = ref.read(plannerControllerProvider);
        if (latest.user?.id != active) return;
        final notifications = ref.read(notificationControllerProvider);
        if (active == null) {
          await notifications.onSignedOut();
        } else {
          await notifications.onAuthenticated(active);
        }
        if (_disposed || syncGeneration != _identitySyncGeneration) return;
        latest = ref.read(plannerControllerProvider);
        if (latest.user?.id != active) return;
        _lastUserId = active;
        _hasSyncedPlannerIdentity = true;
        _tryOpenPending(latest);
      } catch (_) {
        // Notification setup/controller errors are exposed by notification
        // state. Keep this identity unsynced so a later planner signal retries.
      } finally {
        if (syncGeneration == _identitySyncGeneration) {
          _identitySyncInFlight = false;
          _inFlightUserId = null;
        }
      }
    });
  }

  Future<void> _platformReady() {
    final supplied = widget.schedulerReady;
    if (supplied != null) return supplied;
    final scheduler = ref.read(localNotificationSchedulerProvider);
    if (scheduler is FlutterLocalNotificationScheduler) {
      return scheduler.initialize().then((_) {});
    }
    return Future<void>.value();
  }

  void _tryOpenPending(PlannerController planner) {
    final payload = _pendingPayload;
    final fingerprint = _pendingPayloadFingerprint;
    if (payload == null ||
        fingerprint == null ||
        _payloadInFlight ||
        _disposed) {
      return;
    }
    final user = planner.user;
    final selectedGroup = planner.selectedGroup;
    if (user == null || selectedGroup == null || planner.isLoading) return;
    if (payload.groupId != null && payload.groupId != selectedGroup.id) {
      _rejectPending();
      return;
    }
    final supports = payload.occurrenceKey == 'single'
        ? planner.supportsEventById
        : planner.supportsEventOccurrenceByKey;
    if (!supports) {
      _rejectPending();
      return;
    }
    // Move this delivery into the in-flight slot before starting the async
    // lookup. A second callback for the same payload is then ignored, while a
    // distinct callback is queued in [_pendingPayload].
    _pendingPayload = null;
    _pendingPayloadFingerprint = null;
    _payloadInFlight = true;
    _inFlightPayloadFingerprint = fingerprint;
    final eventId = payload.eventId;
    final occurrenceKey = payload.occurrenceKey;
    final requestGeneration = _plannerStateGeneration;
    _runDetachedNotificationOperation(
      () => planner
          .loadEventById(eventId, occurrenceKey: occurrenceKey)
          .then((event) {
            if (_disposed) return;
            final latest = ref.read(plannerControllerProvider);
            final latestUser = latest.user;
            final latestGroup = latest.selectedGroup;
            final valid =
                event != null &&
                _plannerStateGeneration == requestGeneration &&
                latestUser?.id == user.id &&
                latestGroup?.id == selectedGroup.id &&
                event.id.trim() == eventId &&
                event.occurrenceKey == occurrenceKey &&
                !event.isDeleted &&
                event.groupId == selectedGroup.id &&
                event.memberIds.contains(user.id);
            if (valid) {
              final query = occurrenceKey == 'single'
                  ? ''
                  : '?occurrence=${Uri.encodeQueryComponent(occurrenceKey)}';
              if (mounted) {
                final router = widget.router ?? GoRouter.maybeOf(context);
                if (router == null) {
                  throw StateError('알림 일정을 열 수 있는 경로가 없습니다.');
                }
                router.go('/event/$eventId$query');
              }
            } else {
              _showPayloadRejected();
            }
          })
          .catchError((Object _) {
            if (!_disposed) _showPayloadRejected();
          })
          .whenComplete(() {
            if (_disposed) return;
            _payloadInFlight = false;
            _inFlightPayloadFingerprint = null;
            // A distinct warm tap received during the lookup gets a fresh
            // auth/group/occurrence validation under the latest planner state.
            final next = ref.read(plannerControllerProvider);
            if (_pendingPayload != null) _tryOpenPending(next);
          }),
    );
  }

  void _rejectPending() {
    _pendingPayload = null;
    _pendingPayloadFingerprint = null;
    _payloadInFlight = false;
    _inFlightPayloadFingerprint = null;
    _showPayloadRejected();
  }

  void _showPayloadRejected() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text('알림에서 요청한 일정을 열 수 없어요.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Eager watch: provider disposal is tied to the app root rather than a
    // settings route, and auth/event lifecycle signals remain live.
    ref.watch(notificationControllerProvider);
    return widget.child;
  }
}
