import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_identity.dart';
import '../core/reminder_planner.dart';
import '../models/notification_models.dart';
import '../repositories/notification_repository.dart';
import '../repositories/schedule_repository.dart';

/// UI/플랫폼 계층에서 구현하는 플랫폼 경계다. 컨트롤러에서 전달한 토큰 없는
/// 제한 범위 예약 요청만 의도적으로 허용한다.
abstract interface class LocalNotificationScheduler {
  NotificationCapabilityState get capability;

  Future<NotificationPermissionState> permissionStatus();

  Future<NotificationPermissionState> requestPermission();

  Future<void> schedule(NotificationScheduleRequest request);

  Future<void> cancel(Iterable<int> notificationIds);

  Future<List<int>> pendingNotificationIds();
}

/// 푸시는 형식이 지정된 기능 접점일 뿐이다. 이 계층의 프로덕션 구현은
/// [UnconfiguredPushTokenSource]이므로 Firebase/APNs 토큰을 실수로 사용 가능한
/// 전달 경로로 취급할 수 없다.
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

/// PlannerController가 사용하는 좁은 무효화 접점이다. 이 인터페이스를 구체적인
/// 컨트롤러와 분리하면 기존 컨트롤러 테스트 대역에서 알림을 완전히 생략할 수 있다.
abstract interface class NotificationInvalidationSink {
  Future<void> onAuthenticated(String userId);

  Future<void> onSignedOut();

  Future<void> reconcile({DateTime? nowUtc});

  Future<void> cancelForGroup(String groupId);

  Future<void> onEventChanged({String? eventId, String? groupId});

  Future<void> onMembershipChanged({String? eventId, String? groupId});
}

/// 핵심 계층의 기본 동작은 실패 시 차단한다. 도메인 계층이 플랫폼 구현을 가져오지
/// 않아도 앱 셸에서 이 공급자를 Supabase/로컬 저장소와 네이티브 스케줄러로
/// 재정의할 수 있다.
final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => ConfigurationBlockedNotificationRepository('알림 저장소가 구성되지 않았습니다.'),
);

final localNotificationSchedulerProvider = Provider<LocalNotificationScheduler>(
  (ref) => const DisabledLocalNotificationScheduler(),
);

final pushTokenSourceProvider = Provider<PushTokenSource>(
  (ref) => const UnconfiguredPushTokenSource(),
);

/// 영구 플랫폼 연결에서는 이 공급자를 SharedPreferences 기반 레지스트리로 재정의할
/// 수 있다. 임베더/테스트가 실패 시 차단되고 영속성 플러그인이 필요하지 않도록 핵심
/// 계층의 기본값은 메모리 방식으로 유지한다.
final notificationIdAllocatorProvider = Provider<NotificationIdAllocator>(
  (ref) => NotificationIdAllocator(),
);

final notificationControllerProvider =
    ChangeNotifierProvider<NotificationController>(
      (ref) {
        final controller = NotificationController(
          repository: ref.watch(notificationRepositoryProvider),
          scheduler: ref.watch(localNotificationSchedulerProvider),
          pushTokenSource: ref.watch(pushTokenSourceProvider),
          idAllocator: ref.watch(notificationIdAllocatorProvider),
        );
        return controller;
      },
      dependencies: <ProviderOrFamily>[
        notificationRepositoryProvider,
        localNotificationSchedulerProvider,
        pushTokenSourceProvider,
        notificationIdAllocatorProvider,
      ],
    );

/// 설정, OS 권한 및 순차 처리되는 로컬 조정 루프를 위한 ChangeNotifier 상태다.
/// 플래너는 일정 행을 변경하지 않으며, 모든 비동기 후속 작업은 커밋 전에 활성
/// 사용자/세션 세대를 확인한다.
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
  // 빠른 인증 전환으로 여러 이전 네임스페이스가 네이티브 취소를 기다릴 수 있다
  // (예: 첫 취소가 실패하는 동안 A -> B -> C). 각 영구 할당기 스냅샷을 지울 때까지
  // 모두 유지한다. null 허용 슬롯 하나만 쓰면 B를 추가할 때 A를 잃는다.
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

  /// 인증된 신원이 커밋된 뒤 플래너 인증 수명 주기에서 호출한다. 반복된 ID는 새
  /// 사용자 세션이 아니라 새로 고침이다.
  @override
  Future<void> onAuthenticated(String authenticatedUserId) {
    final normalized = authenticatedUserId.trim();
    if (normalized.isEmpty) {
      return Future<void>.error(const FormatException('로그인 세션을 확인해 주세요.'));
    }
    // 순차 처리 본문이 저장소/네이티브 작업을 기다리기 전에 의도 발생 시점의 이전
    // 네임스페이스를 기록한다. 취소가 진행되는 동안 이 인증 요청이 로그아웃이나 이전
    // 인증 요청을 대체해도 후속 요청에는 재시도할 영구 사용자 네임스페이스가 남는다.
    // 오래된 후속 작업 자체는 표시 상태를 변경하지 못하도록 계속 차단한다.
    final previousUser = userId;
    if (previousUser != null && previousUser != normalized) {
      _pendingCleanupUsers.add(previousUser);
    }
    // 더 최신 인증 의도가 관찰되는 즉시 진행 중인 저장소 읽기를 차단한다. 실제
    // 신원/상태 변경은 아래에서 계속 순차 처리하지만, 이 요청이 이전 작업 뒤에서
    // 기다리는 동안 오래된 후속 작업은 더는 세대 검사를 통과할 수 없다.
    final requestedGeneration = ++_sessionGeneration;
    ++_reconcileGeneration;
    return _enqueue(() async {
      if (_disposed || requestedGeneration != _sessionGeneration) return;
      var cleanupReady = true;
      if (userId != normalized) {
        // 인증 스트림은 중간에 로그아웃 이벤트 없이 로그인 계정 사이를 직접 전환할 수
        // 있다. 메모리 세션을 교체하기 전에 이전 계정의 저장된 ID를 취소한다. 그렇지
        // 않으면 다음 네이티브 조정까지 이전 사용자 알림이 기기에 남을 수 있다.
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
      // 콜드 스타트 컨트롤러에는 이전 메모리 계정이 없지만 네이티브 요청은 프로세스
      // 종료 후에도 남을 수 있다. 새로 인증된 계정의 예약을 허용하기 전에 전체 대기
      // 집합을 제거한다. 제거에 실패하면 이 불러오기를 차단한다. 앱 재개/인증 때 다시
      // 시도하면 이전 계정 알림을 새 사용자 알림으로 잘못 판단하지 않는다.
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
        // 새 계정 인증은 커밋되었지만 이전 프로세스/계정의 모든 대기 요청을 제거하기
        // 전에는 후보 읽기/예약을 진행할 수 없다. 호출자가 이 실패 시 차단 상태를
        // 신뢰할 수 있는 빈 예약으로 착각하지 않도록 스냅샷을 불완전으로 표시한다.
        // onResume에서 정리를 다시 시도한다.
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

  /// 원하는 상태를 동기적으로 지운 뒤 이전 사용자가 소유한 ID만 가능한 범위에서 취소한다.
  /// 완전히 성공한 취소는 해당 사용자의 영구 소유권도 지우며 실패하면 나중에 재시도할
  /// 수 있도록 유지한다.
  @override
  Future<void> onSignedOut() {
    // 이전 네임스페이스를 동기적으로 보존한다. 대기열의 작업은 취소를 기다리기 전에
    // 표시 계정을 지운다. 따라서 네이티브 취소가 실패하거나 로그아웃 작업이 대체되어도
    // 즉각적인 인증 전환이 재시도용 참조를 잃지 않는다.
    final previousUser = userId;
    if (previousUser != null) _pendingCleanupUsers.add(previousUser);
    // 취소를 대기열에 넣기 전에 현재 세션을 무효화하여 대기 중인 일정별 불러오기/조정이
    // 이미 떠나는 계정의 행을 커밋하지 못하게 한다. 대기열 작업은 표시 상태 삭제와
    // 가능한 범위의 플랫폼 취소를 차례로 수행한다.
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
        // 새로 만든 컨트롤러에는 확인할 계정 네임스페이스가 없지만 네이티브 요청은
        // 이전 로그인 세션의 프로세스 종료 후에도 남을 수 있다. 알려진 계정
        // 네임스페이스부터 다시 시도한 뒤 다른 레지스트리를 건드리지 않고 앱이 소유한
        // 유효한 대기 ID를 정리한다.
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

  /// 설정 화면 또는 앱 재개에서 돌아온 뒤 OS 권한을 다시 확인하고 현재 원하는
  /// 설정을 적용한다.
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
      // 계정 전환/콜드 스타트 정리에 실패하면 새 신원을 실패 시 차단하는 셸에만
      // 커밋한다. 설정/환경설정은 의도적으로 초기화하고 후보를 읽지 않는다. 보존된
      // ID를 제거한 뒤 조정 전에 계정 스냅샷을 다시 불러온다. 그렇지 않으면 기본
      // `localDesired == false` 셸이 새 계정의 알림을 영구적으로 잘못 억제한다.
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

  /// 논리 일정 하나의 시리즈 전체 설정을 불러온다.
  ///
  /// 원격 알림 설정은 의도적으로 한 번에 일정 하나만 노출한다. 일정 편집기를 여는
  /// 호출자는 계정 전체 스냅샷에 이 일정이 이미 포함되었다고 가정하면 안 된다.
  /// 프로덕션 RPC는 모든 일정을 열거하지 않는다. 따라서 이 작업은 [eventId]의 행만
  /// 교체하고 다른 모든 일정의 캐시 설정을 유지한다. 부수 효과로 조정하거나 예약하지
  /// 않는다. 호출자는 저장된 희망 상태 행을 받고, 일반적인 변경/조정 경로만 플랫폼
  /// 스케줄러를 건드릴 수 있다.
  ///
  /// 저장소를 읽기 전에 세션 세대를 포착하고 상태를 변경하기 전에 확인한다. 읽기가
  /// 진행되는 동안 계정이 로그아웃/전환되거나 이 컨트롤러가 해제되면 오래된 결과를
  /// 무시하고 빈 목록을 반환한다. UI가 거짓 불러오기 성공을 표시하지 않도록 저장소
  /// 및 전송 형식 검증 실패는 [errorMessage]로 노출하고 다시 던진다.
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
        // 인증/세션 차단선을 넘은 뒤에는 데이터를 검증하거나 병합하지도 않는다. 오래된
        // 계정 결과는 외부에서 관찰되는 영향이 없어야 한다.
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

  /// 메모리 내 설정/계획 스냅샷에서 논리 일정 하나를 제거한다.
  ///
  /// 멤버십 제거 후 다음 계정 전체 후보 조정이 끝나기 전에 이전에 캐시된 일정 행의
  /// 권한이 사라질 수 있다. 이 메서드는 해당 일정의 로컬 캐시만 제거하며 저장소를
  /// 건드리거나 플랫폼 요청을 취소하지 않는다. 다음 신뢰 가능한 조정에서 스케줄러
  /// 정리를 담당하고 다른 모든 일정의 캐시는 그대로 유지한다.
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

  /// 캐시 제거 용어를 사용하는 호출자를 위한 이름 별칭이다.
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

  /// 계정 로컬 전환용 편의 메서드다. 서버 스키마는 로컬 계정 전환을 하나의 값으로
  /// 저장한다. [enabled]와 [localEnabled]는 함께 움직이고 푸시는 별도로
  /// 유지/비활성화한다.
  Future<void> setLocalEnabled(bool enabled) => saveSettings(
    settings.copyWith(enabled: enabled, localEnabled: enabled),
    expectedVersion: settings.version,
  );

  /// 새 호출자를 위해 계정 전체 범위를 명시한 이름이다. 이전 설정 UI와의 소스 호환
  /// 별칭으로 [setLocalEnabled]를 유지한다. 어느 메서드도 기기별 설정을 뜻하지 않는다.
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

  /// 그룹 나가기/보관 경로가 플래너 행을 지우기 전에 이를 호출한다.
  ///
  /// 그룹 ID는 소유권 키가 아니라 무효화 경계다. 프로세스를 다시 시작하면
  /// [_scheduled]은 비어 있고 영구 할당기에는 그룹 멤버십이 아닌 불투명한 신원만
  /// 저장된다. 제거된 그룹의 네이티브 요청을 남기지 않기 위해 먼저 활성 사용자의
  /// 전체 영구/네이티브 대기 집합을 취소하고, 같은 세션 세대에서 여전히 신뢰할 수
  /// 있는 전체 그룹 집합만 다시 만든다. 전체 취소 증명이나 대체 읽기 중 하나라도
  /// 실패하면 실패 시 차단 상태를 유지해 제거된 알림이 울리지 않게 한다. 이후 수명
  /// 주기 과정에서 여전히 접근 가능한 그룹의 알림을 복원할 수 있다.
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
      // 계정 전체 제거와 신뢰할 수 있는 대체 작업이 진행되는 동안 오래된 계획 프로젝션을
      // 표시 상태로 남기지 않는다.
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
      // 최종/그룹 무효화 또는 비활성 전환에서 플랫폼 호출에 실패한 뒤 네이티브 취소가
      // 대기 상태로 남을 수 있다. 오래된 요청이 살아 있는 동안 일반 일정/인증 조정이
      // 대체 알림을 예약하게 해서는 안 된다. 전체 정리 증명을 먼저 다시 시도하고 성공할
      // 때까지 실패 시 차단한다. 모든 호출자(앱 재개, 일정 변경, 실시간 무효화, 명시적
      // 조정)가 같은 개인정보 보호 경계를 공유하도록 이 가드를 여기서 중앙화한다.
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
      // 초기 권한 검사와 후보 RPC 사이에 저장소가 로컬 기능을 철회할 수 있다(예:
      // 서버 계정 전환이 아직 안정화 중일 때). 비활성/미지원 기능을 명시적으로
      // 보고하는 페이지는 예약하지 않고 실패 시 차단한다.
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
      // 잘못되었거나 사용할 수 없는 영구 할당기가 다른 면에서는 신뢰할 수 있는 예약을
      // 영구히 막아서는 안 된다. 복구는 의도적으로 완전한 후보 페이지 구분으로
      // 제한한다. 모든 네이티브 대기 요청을 열거해 전체 집합을 취소하고, 레지스트리를
      // 읽지 않고 덮어쓴 뒤 빈 맵에서 원하는 ID를 할당한다. 불완전한 페이지에서는
      // 실패 시 차단하며 취소 범위를 절대 넓히지 않는다.
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
        // 완전한 스냅샷을 성공적으로 취소한 뒤에만 영구 소유권을 정리한다. 네이티브
        // 취소나 대기 상태 검사가 실패하면 이후 조정에서 다시 시도하도록 오래된 행을
        // 유지한다.
        if (cancelled && known.complete) {
          try {
            await idAllocator.retainIds(active, desired);
            if (!_isCurrent(active, session) ||
                reconcile != _reconcileGeneration) {
              return;
            }
          } catch (error) {
            // 예약은 계속 진행할 수 있지만 영속화 실패를 노출하고 재시도를 위해 할당기의
            // 이전 스냅샷을 그대로 둔다.
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
          // 다른 유효한 알림은 유지하되 모든 후보를 성공적으로 예약했다고 주장하지 말고
          // 타입이 지정된 상태를 노출한다.
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
        // 영구 삭제가 실패하면 이후 수명 주기 과정에서 취소와 정리를 다시 시도할 수
        // 있도록 메모리/레지스트리에 소유권을 유지한다.
        complete = false;
      }
    }
    if (complete) {
      _pendingCleanupUsers.remove(active);
      // 네이티브 ID가 아직 영구 정리를 기다리는 다른 이전 네임스페이스에 속했을 수
      // 있다. 해당 네임스페이스도 지울 때까지 재시도 집합을 보존한다. 그렇지 않으면
      // 나중의 계정 전환에서 그 레지스트리를 다룰 유일한 참조를 잃을 수 있다.
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

  /// 실패한 로그아웃/계정 전환이나 이전 콜드 스타트 대기 ID 탐색이 남긴 개인정보
  /// 정리를 다시 시도한다. 호출자는 현재 세션 세대를 보유해야 하며 이 헬퍼 자체는 대체
  /// 알림을 예약하지 않는다.
  Future<bool> _retryPendingCleanup({
    required int session,
    bool forceNative = false,
  }) async {
    if (!_isGenerationCurrent(session)) return false;
    // 각 이전 계정이 자체 영구 삭제를 수행하도록 스냅샷을 기준으로 작업한다. await가
    // 진행되는 동안 새 인증 의도가 집합에 추가될 수 있다. 아래 세대 차단선이 이 시도를
    // 오래된 것으로 만들고 다음 수명 주기 호출에서 새 네임스페이스를 다시 시도한다.
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

  /// 후보 스냅샷을 신뢰할 수 있을 때만 읽을 수 없는 레지스트리를 복구한다. 대기 ID
  /// 열거는 광범위한 취소가 안전하다는 증명의 일부다. 읽기/취소/삭제가 실패하면 영구
  /// 소유권을 건드리지 않고 조정을 실패 시 차단 상태로 유지한다.
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
      // clearUser는 빈 맵을 직접 쓴다. 먼저 읽을 수 없는 스냅샷을 불러오거나
      // 검증하려고 시도하지 않는다.
      await idAllocator.clearUser(active);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 영구 할당기 소유권과 네이티브 대기 요청의 합집합을 반환한다. 네이티브 요청은
  /// 프로세스나 재시작 후 메모리 할당기보다 오래 남을 수 있으므로 신뢰할 수 있는 전체
  /// 조정, 로그아웃, 계정 전환, 비활성 전환에서는 대기에만 존재하는 ID도 정리해야
  /// 한다. 조회 실패 시 차단하고 영구 레지스트리를 건드리지 않는다. 이후 조정에서
  /// 가능한 범위의 취소를 다시 시도할 수 있다.
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
      // 손상되었거나 사용할 수 없는 레지스트리가 네이티브 정리를 막아서는 안 된다.
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
      // 네이티브 대기 상태 검사는 가능한 범위에서 수행한다. 할당기 ID를 유지하고 다음
      // 수명 주기/조정 과정에서 다시 시도한다.
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
      // 로그아웃/거부 전환 중 취소는 가능한 범위에서 수행한다. 이후 완전한 조정에서
      // 알려진 ID를 다시 시도한다. 상태가 권한/기능 상태를 유지하므로 거짓 성공은
      // 노출하지 않는다.
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
