import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String pubspec;
  late String androidManifest;
  late String iosPlist;
  late String macosReleaseEntitlements;
  late String macosDebugEntitlements;
  late String iosAppDelegate;
  late String macosAppDelegate;
  late String webIndex;
  late String readme;
  late String notificationBindings;
  late String mainSource;

  setUpAll(() {
    pubspec = File('pubspec.yaml').readAsStringSync();
    androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    iosPlist = File('ios/Runner/Info.plist').readAsStringSync();
    macosReleaseEntitlements = File(
      'macos/Runner/Release.entitlements',
    ).readAsStringSync();
    macosDebugEntitlements = File(
      'macos/Runner/DebugProfile.entitlements',
    ).readAsStringSync();
    iosAppDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    macosAppDelegate = File(
      'macos/Runner/AppDelegate.swift',
    ).readAsStringSync();
    webIndex = File('web/index.html').readAsStringSync();
    readme = File('README.md').readAsStringSync();
    notificationBindings = File(
      'lib/platform/notification_bindings.dart',
    ).readAsStringSync();
    mainSource = File('lib/main.dart').readAsStringSync();
  });

  test('의존성이 로컬 전용이며 정확한 버전으로 고정된다', () {
    expect(
      pubspec,
      matches(
        RegExp(
          r'^\s*flutter_local_notifications:\s*22\.3\.0\s*$',
          multiLine: true,
        ),
      ),
    );
    expect(
      pubspec,
      matches(RegExp(r'^\s*crypto:\s*3\.0\.7\s*$', multiLine: true)),
    );
    expect(
      pubspec,
      matches(RegExp(r'^\s*timezone:\s*0\.11\.1\s*$', multiLine: true)),
    );
    expect(
      pubspec,
      matches(
        RegExp(r'^\s*shared_preferences:\s*2\.5\.5\s*$', multiLine: true),
      ),
    );
    expect(pubspec, isNot(contains('firebase_core:')));
    expect(pubspec, isNot(contains('firebase_messaging:')));
  });

  test('Android 매니페스트에 로컬 예약 권한과 receiver만 있다', () {
    expect(
      androidManifest,
      contains(
        '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"',
      ),
    );
    expect(
      androidManifest,
      contains(
        '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"',
      ),
    );
    expect(
      androidManifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
      ),
    );
    expect(
      androidManifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver',
      ),
    );
    for (final action in <String>[
      'android.intent.action.BOOT_COMPLETED',
      'android.intent.action.MY_PACKAGE_REPLACED',
      'android.intent.action.QUICKBOOT_POWERON',
      'com.htc.intent.action.QUICKBOOT_POWERON',
    ]) {
      expect(androidManifest, contains(action));
    }
    expect(androidManifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
    expect(androidManifest, isNot(contains('USE_EXACT_ALARM')));
    expect(androidManifest, isNot(contains('FirebaseMessagingService')));
    expect(androidManifest, isNot(contains('google-services')));

    final icon = File(
      'android/app/src/main/res/drawable/ic_stat_moduly.xml',
    ).readAsStringSync();
    expect(icon, contains('@android:color/white'));
    final strings = File(
      'android/app/src/main/res/values/notification_strings.xml',
    ).readAsStringSync();
    expect(strings, contains('moduly_reminders_channel_id'));
    expect(strings, contains('moduly_reminders'));
  });

  test('Apple 로컬 알림이 원격 푸시 기능을 추가하지 않는다', () {
    expect(iosAppDelegate, contains('import UserNotifications'));
    expect(
      iosAppDelegate,
      contains('UNUserNotificationCenter.current().delegate'),
    );
    expect(macosAppDelegate, contains('import UserNotifications'));
    expect(
      macosAppDelegate,
      contains('UNUserNotificationCenter.current().delegate'),
    );
    expect(iosPlist, isNot(contains('UIBackgroundModes')));
    expect(iosPlist, isNot(contains('aps-environment')));
    expect(iosPlist, isNot(contains('FirebaseMessaging')));
    for (final entitlements in <String>[
      macosReleaseEntitlements,
      macosDebugEntitlements,
    ]) {
      expect(
        entitlements,
        contains('<key>com.apple.security.network.client</key>'),
      );
      expect(entitlements, contains('<true/>'));
      expect(entitlements, isNot(contains('aps-environment')));
    }
  });

  test('릴리스 빌드가 로컬 알림 아이콘 리소스를 유지한다', () {
    final keep = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    expect(keep, contains('tools:keep="@drawable/ic_stat_moduly"'));
  });

  test('웹은 서버 푸시 미설정 상태이며 Firebase 작업자가 없다', () {
    expect(webIndex, isNot(contains('firebase-messaging-sw.js')));
    expect(webIndex, isNot(contains('firebase.initializeApp')));
    expect(File('web/firebase-messaging-sw.js').existsSync(), isFalse);
  });

  test('로컬 데모가 네이티브 전달 기능을 지원한다고 표시하지 않는다', () {
    expect(notificationBindings, contains('else if (client == null)'));
    expect(
      notificationBindings,
      contains('state: NotificationCapabilityState.unconfigured'),
    );
    expect(notificationBindings, contains('UUID 기반 인증 경계'));
  });

  test('부트스트랩이 완전한 시간대 별칭 데이터셋을 불러온다', () {
    expect(
      mainSource,
      contains("package:timezone/data/latest_all.dart' as tzdata"),
    );
  });

  test('README가 로컬 제한과 향후 공급자 차단 요인을 설명한다', () {
    expect(readme, contains('로컬 알림(기능 3)'));
    expect(readme, contains('inexactAllowWhileIdle'));
    expect(readme, contains('60 days'));
    expect(readme, contains('48'));
    expect(readme, contains('unconfigured'));
    expect(readme, contains('최소 한 번'));
    expect(readme, contains('APNs'));
    expect(readme, contains('VAPID'));
    expect(readme, contains('cron'));
    expect(readme, contains('verify_jwt = false'));
    expect(readme, contains('REMINDER_WORKER_SECRET'));
    expect(readme, contains('x-reminder-worker-secret'));
  });
}
