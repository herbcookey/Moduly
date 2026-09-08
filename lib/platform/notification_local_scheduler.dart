import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/notification_models.dart';
import '../state/notification_state.dart';
import 'notification_id_registry.dart';

typedef NotificationScheduleOverride =
    Future<void> Function(
      NotificationScheduleRequest request,
      tz.Location location,
    );

/// 앱에 네이티브 스케줄러가 있는 플랫폼용 로컬 알림 어댑터다. 이 어댑터는
/// 의도적으로 계정이나 저장소를 알지 못한다. [NotificationScheduleRequest]가 이미
/// 알림 컨트롤러가 만든 신뢰할 수 있고 범위가 제한된 요청이기 때문이다.
///
/// 생성자에 의존성을 주입할 수 있어 위젯/단위 테스트가 네이티브 권한 요청을
/// 호출하지 않고 가짜 게이트웨이를 제공할 수 있다. 프로덕션 코드는 기본적으로
/// 플러그인 싱글턴을 사용한다.
class FlutterLocalNotificationScheduler implements LocalNotificationScheduler {
  FlutterLocalNotificationScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    this.onPayload,
    this.initializeOverride,
    this.supportedPlatformOverride,
    this.scheduleOverride,
    this.platformOverride,
    this.notificationsEnabledOverride,
    this.requestPermissionOverride,
    this.permissionStore,
  }) : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String channelId = 'moduly_reminders';
  static const String channelName = '일정 알림';
  static const String channelDescription = '일정 시작 전에 알려 드려요.';
  static const String androidIcon = 'ic_stat_moduly';
  static const String genericTitle = 'Moduly 일정 알림';
  static const String genericBody = '일정이 곧 시작돼요.';

  final FlutterLocalNotificationsPlugin plugin;

  /// 앱 라우터가 만들어진 뒤 [NotificationLifecycleBinding]이 할당한다. 콜백을
  /// 변경 가능하게 두면 위젯 트리를 다시 만들 때 두 번째 네이티브 플러그인 싱글턴을
  /// 만들지 않을 수 있다.
  void Function(NotificationPayload payload)? onPayload;

  /// 호스트 측 위젯 테스트로 실행할 수 없는 유일한 작업인 플러그인 싱글턴의 네이티브
  /// 초기화 호출을 위한 테스트 접점이다. 프로덕션 호출자는 `null`로 둔다. OS 권한을
  /// 요청해서는 안 되며, 권한 요청은 아래의 명시적인 [requestPermission] 동작으로 남는다.
  final Future<bool> Function()? initializeOverride;

  /// 호스트 측 테스트는 제품이 의도적으로 로컬 알림을 지원하지 않는다고 보고하는 Linux에서
  /// 실행된다. 이 선택적 접점을 사용하면 프로덕션 기능 결정을 바꾸지 않고 초기화
  /// 병합/재시도를 테스트할 수 있다.
  final bool? supportedPlatformOverride;

  /// 네이티브 메서드 채널을 호출하지 않고 검증된 시간대 변환을 받는 선택적 호스트
  /// 테스트 접점이다. 프로덕션에서는 `null`로 둔다.
  final NotificationScheduleOverride? scheduleOverride;

  /// Android 권한 호출을 위한 선택적 호스트 테스트 접점이다. 프로덕션에서는 플러그인
  /// 메서드를 직접 사용한다.
  final TargetPlatform? platformOverride;
  final Future<bool?> Function()? notificationsEnabledOverride;
  final Future<void> Function()? requestPermissionOverride;

  /// [areNotificationsEnabled]가 `false`일 때 Android 13 API는 첫 요청과 이전 거부를
  /// 구분하지 않는다. 불리언 표시만 저장하고 계정/일정 데이터는 절대 저장하지 않아,
  /// 프로세스를 다시 시작해도 거부 후 유용한 "시스템 설정 열기" 동작을 표시할 수 있게
  /// 한다. 호스트 테스트에서는 저장소를 주입하고 기본값은 비동기 플랫폼 환경설정 백엔드다.
  NotificationStringStore? permissionStore;

  static const String _permissionRequestedKey =
      'moduly_local_notification_permission_requested_v1';

  bool _initialized = false;
  bool _initializing = false;
  bool _permissionRequested = false;
  Future<bool>? _initialization;
  bool _launchPayloadConsumed = false;

  /// 이 제품의 플러그인에는 웹/Windows/Linux 구현이 없다. 이 결정을 하나의 어댑터에
  /// 두면 성공한 무동작으로 조용히 보고하지 않고 지원하지 않는 기능을 설정에 표시할 수 있다.
  @override
  NotificationCapabilityState get capability => _isSupportedPlatform
      ? (_initialized
            ? NotificationCapabilityState.available
            : NotificationCapabilityState.disabled)
      : NotificationCapabilityState.unsupported;

  bool get isInitialized => _initialized;

  TargetPlatform get _platform => platformOverride ?? defaultTargetPlatform;

  bool get _isSupportedPlatform =>
      supportedPlatformOverride ??
      (!kIsWeb &&
          (_platform == TargetPlatform.android ||
              _platform == TargetPlatform.iOS ||
              _platform == TargetPlatform.macOS));

  /// 권한을 요청하지 않고 네이티브 플러그인을 초기화한다. 권한 프롬프트는 알림 설정 UI의
  /// 명시적인 사용자 동작이 호출하는 [requestPermission]을 통해서만 표시된다.
  Future<bool> initialize() {
    if (!_isSupportedPlatform) {
      _initialized = false;
      return Future<bool>.value(false);
    }
    if (_initialized) return Future<bool>.value(true);
    final existing = _initialization;
    if (existing != null) {
      return existing;
    }
    _initializing = true;
    final future = initializeOverride == null
        ? _initializePlatform()
        : initializeOverride!();
    late final Future<bool> result;
    result = future.then<bool>(
      (success) {
        _initialized = success;
        _initializing = false;
        // 실패한 시도가 재시도 경로를 망치면 안 된다. 성공한 Future만 병합
        // 캐시로 유지하며 이후 설정 재시도에서는 새 네이티브 초기화 호출을 시작한다.
        if (!success && identical(_initialization, result)) {
          _initialization = null;
        }
        return success;
      },
      onError: (Object error, StackTrace stack) {
        _initialized = false;
        _initializing = false;
        if (identical(_initialization, result)) _initialization = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _initialization = result;
    return result;
  }

  Future<bool> _initializePlatform() async {
    try {
      final settings = InitializationSettings(
        android: const AndroidInitializationSettings(androidIcon),
        iOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          requestProvisionalPermission: false,
        ),
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          requestProvisionalPermission: false,
        ),
      );
      final result = await plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleResponse,
      );
      final initialized = result ?? false;
      if (initialized && _platform == TargetPlatform.android) {
        final android = plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            importance: Importance.defaultImportance,
            playSound: true,
            enableVibration: true,
            showBadge: true,
          ),
        );
      }
      return initialized;
    } catch (_) {
      // 기능은 실패 시 차단 상태로 유지한다. 호출자는 설정에서 다시 시도할 수 있으며
      // 네이티브/플러그인 예외 대신 일반적인 상태를 받는다.
      return false;
    }
  }

  Future<void> _ensureInitialized() async {
    if (!_isSupportedPlatform) return;
    if (!_initialized && !_initializing) await initialize();
    final initialization = _initialization;
    if (initialization != null) await initialization;
    if (!_initialized) throw StateError('로컬 알림을 초기화할 수 없습니다.');
  }

  /// OS 권한을 제품/계정 스위치와 별도로 보고한다. Android에서는 이 프로세스가 접근을
  /// 요청했는지를 의도적으로 추적한다. Android 13은 첫 요청과 이전 거부에 같은 `false`
  /// 결과를 내므로 거부를 성공한 권한 허용으로 잘못 판단하지 않게 한다.
  @override
  Future<NotificationPermissionState> permissionStatus() async {
    if (!_isSupportedPlatform) return NotificationPermissionState.unsupported;
    try {
      await _ensureInitialized();
      if (_platform == TargetPlatform.android) {
        final enabled = notificationsEnabledOverride != null
            ? await notificationsEnabledOverride!()
            : await plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.areNotificationsEnabled();
        if (enabled == true) return NotificationPermissionState.authorized;
        final marker = await _permissionWasRequested();
        return _permissionRequested || marker
            ? NotificationPermissionState.denied
            : NotificationPermissionState.notDetermined;
      }
      final NotificationsEnabledOptions? options;
      if (_platform == TargetPlatform.iOS) {
        options = await plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions();
      } else {
        options = await plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions();
      }
      if (options == null) {
        return _permissionRequested
            ? NotificationPermissionState.denied
            : NotificationPermissionState.notDetermined;
      }
      if (options.isProvisionalEnabled) {
        return NotificationPermissionState.provisional;
      }
      if (options.isEnabled) return NotificationPermissionState.authorized;
      return _permissionRequested
          ? NotificationPermissionState.denied
          : NotificationPermissionState.notDetermined;
    } catch (_) {
      return NotificationPermissionState.disabled;
    }
  }

  /// 사용자의 명시적인 동작 후 OS 권한을 요청한다. [initialize]나 위젯 수명 주기
  /// 콜백에서는 절대 호출하지 않는다.
  @override
  Future<NotificationPermissionState> requestPermission() async {
    if (!_isSupportedPlatform) return NotificationPermissionState.unsupported;
    try {
      await _ensureInitialized();
      _permissionRequested = true;
      // 초기화 후이며 명시적인 설정 동작을 통해 이 메서드에 도달했을 때만 저장한다.
      // 초기화 자체가 권한을 요청한 것으로 표시해서는 안 된다.
      try {
        final store = permissionStore ??= SharedPreferencesAsyncStringStore();
        await store.write(_permissionRequestedKey, '1');
      } catch (_) {
        // 프로세스 내 표시는 유지한다. 저장소 실패 때문에 명시적인 요청을 거짓
        // 성공으로 바꾸거나 백엔드 세부 정보를 노출해서는 안 된다.
      }
      if (_platform == TargetPlatform.android) {
        if (requestPermissionOverride != null) {
          await requestPermissionOverride!();
        } else {
          await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission();
        }
      } else if (_platform == TargetPlatform.iOS) {
        final implementation = plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        await implementation?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
      } else {
        final implementation = plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        await implementation?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
      }
      return permissionStatus();
    } catch (_) {
      return NotificationPermissionState.disabled;
    }
  }

  /// OS 설정 앱에서 돌아온 뒤 다시 확인한다. 어댑터가 설정을 자동으로 열지는 않으며,
  /// 거부 상태에 `openAppNotificationSettings` 동작을 제공할지는 UI가 결정한다.
  Future<NotificationPermissionState> refreshPermission() => permissionStatus();

  Future<bool> _permissionWasRequested() async {
    try {
      final store = permissionStore ??= SharedPreferencesAsyncStringStore();
      return (await store.read(_permissionRequestedKey)) == '1';
    } catch (_) {
      // 알 수 없는 표시 상태는 의도적으로 미결정으로 처리한다. 권한 허용 여부는
      // 위의 네이티브 활성 검사를 계속 기준으로 삼는다.
      return false;
    }
  }

  Future<bool> openAppNotificationSettings() async {
    if (!_isSupportedPlatform) return false;
    try {
      await _ensureInitialized();
      final result = await plugin.openAppNotificationSettings();
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> schedule(NotificationScheduleRequest request) async {
    await _ensureInitialized();
    if (request.notificationId < 1 ||
        request.notificationId > 0x7fffffff ||
        !request.fireAt.isUtc ||
        !request.fireAt.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('알림 예약 정보를 확인해 주세요.');
    }
    final location = _location(request.timezone);
    final scheduledDate = tz.TZDateTime.from(request.fireAt.toUtc(), location);
    if (scheduleOverride != null) {
      await scheduleOverride!(request, location);
      return;
    }
    final payload = request.payload.encode();
    final details = NotificationDetails(
      android: const AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        icon: androidIcon,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        playSound: true,
        enableVibration: true,
        channelShowBadge: true,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    // 요청 제목은 의도적으로 버린다. 일정 제목에 비공개 멤버 정보가 있을 수 있으므로
    // 일반적인 잠금 화면 문구를 사용해 페이로드와 알림 표시에 민감한 내용이 없게 한다.
    await plugin.zonedSchedule(
      id: request.notificationId,
      title: genericTitle,
      body: genericBody,
      scheduledDate: scheduledDate,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(Iterable<int> notificationIds) async {
    if (!_isSupportedPlatform) return;
    await _ensureInitialized();
    for (final id in notificationIds) {
      if (id < 1 || id > 0x7fffffff) continue;
      await plugin.cancel(id: id);
    }
  }

  @override
  Future<List<int>> pendingNotificationIds() async {
    if (!_isSupportedPlatform) return const <int>[];
    await _ensureInitialized();
    final pending = await plugin.pendingNotificationRequests();
    return List<int>.unmodifiable(
      pending.map((request) => request.id).where((id) => id > 0),
    );
  }

  /// 콜드 스타트 탭은 앱 부트스트랩이 한 번만 소비한다. 플러그인이 지우기 메서드를
  /// 노출하지 않으므로 이 어댑터의 세션 플래그가 다시 빌드하거나 재개된 콜백에서 같은
  /// 실행 의도를 다시 처리하지 않게 한다.
  /// 웜 스타트 콜백은 [_handleResponse]를 계속 통과하며 여기서 제한하지 않는다.
  Future<NotificationPayload?> consumeLaunchPayload() async {
    if (!_isSupportedPlatform) return null;
    if (_launchPayloadConsumed) return null;
    _launchPayloadConsumed = true;
    await _ensureInitialized();
    final details = await plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true ||
        details?.notificationResponse?.payload == null) {
      return null;
    }
    final encoded = details!.notificationResponse!.payload!;
    return _decodePayload(encoded);
  }

  void _handleResponse(NotificationResponse response) {
    final encoded = response.payload;
    if (encoded == null || encoded.isEmpty) return;
    final payload = _decodePayload(encoded);
    if (payload != null) onPayload?.call(payload);
  }

  NotificationPayload? _decodePayload(String encoded) {
    try {
      return NotificationPayload.decode(encoded);
    } catch (_) {
      // 알 수 없는 페이로드는 무시한다. 신뢰할 수 없는 내용을 기록하거나 표시하지 않는다.
      return null;
    }
  }

  tz.Location _location(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) throw const FormatException('시간대를 확인해 주세요.');
    if (normalized == 'UTC' || normalized == 'Etc/UTC') return tz.UTC;
    try {
      return tz.getLocation(normalized);
    } catch (_) {
      throw const FormatException('시간대를 확인해 주세요.');
    }
  }
}
