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

/// 앱 경계에서 구체적인 알림 공급자를 만든다. 핵심 공급자는 의도적으로 실패 시
/// 차단하여 테스트와 다른 임베더가 네이티브 플러그인을 가져오지 않고 도메인
/// 컨트롤러를 사용할 수 있게 한다.
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
      // 로컬 데모 행은 사람이 읽을 수 있는 ID를 사용하며 의도적으로 네이티브 딥 링크
      // 전달 대상에서 제외한다. 데모 설정은 표시하되 OS 알림이 예약되었거나 알림 탭이
      // UUID 기반 인증 경계를 통과할 수 있다고 주장하지 말고 실패 시 차단한다.
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
      // 앱 셸을 만드는 동안 네이티브 설정을 시작한다. 수명 주기 연결은 인증 동기화
      // 전에 같은 멱등 초기화를 기다린다.
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

/// [NotificationController]를 미리 활성 상태로 유지하고 플래너의 인증/그룹 수명
/// 주기를 연결하며 로컬 알림 탭을 처리한다. 콜드 스타트 세부 정보는 네이티브
/// 어댑터가 한 번만 소비하고 웜 스타트 콜백은 전달 이벤트로 처리한다. 컨트롤러가
/// 신뢰할 수 있는 발생 항목을 가져와 멤버십을 검증한 뒤에만 경로 탐색을 수행한다.
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
    // 설정 경로를 방문하기 전에도 컨트롤러와 어댑터를 미리 만든다. 첫 인증
    // 동기화는 네이티브 설정을 기다린다.
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
      // 잘못되었거나 지원되지 않는 네이티브 실행 페이로드는 무시한다. 앱은 토큰을 담은
      // UI 없이 정상적인 인증 경로에 머문다.
    }
  }

  void _receivePayload(NotificationPayload payload) {
    if (_disposed) return;
    final fingerprint = payload.encode();
    // 지점 조회가 대기 중일 때 네이티브 플러그인이 같은 웜 응답을 여러 번 전달할 수
    // 있다. 중복 응답은 합치되, 이후의 서로 다른 알림은 현재 요청 후 검증할 수 있도록
    // 유지한다.
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
    // 다른 신원 동기화가 시작되는 순간 이전 완료 표시는 더 이상 현재 상태를
    // 증명하지 않는다. 플랫폼 준비와 알림 컨트롤러 호출이 모두 성공한 뒤에만
    // 아래에서 새 완료 상태를 게시한다.
    _hasSyncedPlannerIdentity = false;
    _runDetachedNotificationOperation(() async {
      try {
        // 호출 자체가 동기적으로 실패할 수 있으므로 detached 경계 안에서 실행한다.
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
        // 플랫폼 준비 또는 컨트롤러 오류는 설정 상태에서 표시한다. 완료로 표시하지
        // 않으므로 같은 신원의 다음 플래너 알림에서 안전하게 재시도할 수 있다.
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
    // 비동기 조회를 시작하기 전에 이 전달 건을 진행 중 슬롯으로 옮긴다. 이후 같은
    // 페이로드의 두 번째 콜백은 무시하고, 서로 다른 콜백은 [_pendingPayload]에 넣는다.
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
            // 조회 중 받은 별도의 웜 스타트 탭은 최신 플래너 상태에서 인증/그룹/발생 항목을
            // 새로 검증한다.
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
    // 미리 관찰한다. 공급자 해제는 설정 경로가 아니라 앱 루트에 연결되며,
    // 인증/일정 수명 주기 신호는 계속 활성 상태로 남는다.
    ref.watch(notificationControllerProvider);
    return widget.child;
  }
}
