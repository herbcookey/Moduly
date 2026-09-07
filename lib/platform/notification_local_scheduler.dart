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

/// Local notification adapter for the platforms where the app has a native
/// scheduler.  This adapter intentionally does not know about accounts or
/// repositories: [NotificationScheduleRequest] is already the authoritative,
/// bounded request produced by the notification controller.
///
/// The constructor is dependency-injectable so widget/unit tests can provide
/// a fake gateway without invoking a native permission prompt.  Production
/// code uses the plugin singleton by default.
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

  /// Assigned by [NotificationLifecycleBinding] after the app router exists.
  /// Keeping the callback mutable avoids constructing a second native plugin
  /// singleton when a widget tree is rebuilt.
  void Function(NotificationPayload payload)? onPayload;

  /// Test seam for the one operation that cannot be exercised by a host-side
  /// widget test (the plugin singleton's native initialize call). Production
  /// callers leave this null. It must not request OS permission; that remains
  /// the explicit [requestPermission] action below.
  final Future<bool> Function()? initializeOverride;

  /// Host-side tests run on Linux, where the product intentionally reports
  /// local notifications as unsupported. This opt-in seam lets those tests
  /// exercise initialization coalescing/retry without changing production
  /// capability decisions.
  final bool? supportedPlatformOverride;

  /// Optional host-test seam that receives the validated timezone conversion
  /// without invoking a native method channel. Production leaves this null.
  final NotificationScheduleOverride? scheduleOverride;

  /// Optional host-test seams for Android authorization calls. Production
  /// uses the plugin methods directly.
  final TargetPlatform? platformOverride;
  final Future<bool?> Function()? notificationsEnabledOverride;
  final Future<void> Function()? requestPermissionOverride;

  /// The Android 13 API does not distinguish a first request from a prior
  /// denial when [areNotificationsEnabled] is false. Persist only a boolean
  /// marker (never account/event data) so a process restart can still expose a
  /// useful "open system settings" action after denial. The store is injected
  /// in host tests and defaults to the async platform preferences backend.
  NotificationStringStore? permissionStore;

  static const String _permissionRequestedKey =
      'moduly_local_notification_permission_requested_v1';

  bool _initialized = false;
  bool _initializing = false;
  bool _permissionRequested = false;
  Future<bool>? _initialization;
  bool _launchPayloadConsumed = false;

  /// The plugin has no web/Windows/Linux implementation in this product.
  /// Keeping this decision in one adapter makes unsupported capability visible
  /// to settings instead of silently reporting a successful no-op.
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

  /// Initializes the native plugin without asking for permission.  Permission
  /// prompts are only reached through [requestPermission], which is called by
  /// an explicit user action in the notification settings UI.
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
        // A failed attempt must not poison the retry path. Keep only a
        // successful future as the coalescing cache; a subsequent settings
        // retry starts a fresh native initialize call.
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
      // Keep capability fail-closed. The caller can retry from settings and
      // receives a generic status rather than a native/plugin exception.
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

  /// Reports OS authorization separately from product/account switches.
  /// Android intentionally tracks whether this process has requested access:
  /// Android 13 exposes the same false result for a first request and a prior
  /// denial, so a denial cannot be mistaken for a successful authorization.
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

  /// Requests OS permission after an explicit user action. Never call this
  /// from [initialize] or a widget lifecycle callback.
  @override
  Future<NotificationPermissionState> requestPermission() async {
    if (!_isSupportedPlatform) return NotificationPermissionState.unsupported;
    try {
      await _ensureInitialized();
      _permissionRequested = true;
      // Persist only after initialization and only because this method was
      // reached through an explicit settings action. Initialization itself
      // must never mark a permission as requested.
      try {
        final store = permissionStore ??= SharedPreferencesAsyncStringStore();
        await store.write(_permissionRequestedKey, '1');
      } catch (_) {
        // Keep the in-process marker; a storage failure must not turn an
        // explicit request into a false success or expose backend details.
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

  /// Re-check after returning from the OS settings app. The adapter does not
  /// open settings automatically; the UI decides whether a denied state gets
  /// an `openAppNotificationSettings` affordance.
  Future<NotificationPermissionState> refreshPermission() => permissionStatus();

  Future<bool> _permissionWasRequested() async {
    try {
      final store = permissionStore ??= SharedPreferencesAsyncStringStore();
      return (await store.read(_permissionRequestedKey)) == '1';
    } catch (_) {
      // Unknown marker state is deliberately treated as not determined. The
      // native enabled check above still remains authoritative for grants.
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
    // Deliberately discard the request title. Event titles may contain
    // private member information; generic lock-screen copy keeps payload and
    // notification presentation free of sensitive content.
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

  /// A cold-start tap is consumed once by the app bootstrap. The plugin does
  /// not expose a clear method, so this adapter's session flag prevents a
  /// rebuild or resumed callback from replaying the same launch intent. Warm
  /// callbacks continue through [_handleResponse] and are not gated here.
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
      // Unknown payloads are ignored. Never log or display untrusted content.
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
