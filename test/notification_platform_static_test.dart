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

  test('dependencies stay local-only and exactly pinned', () {
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

  test('Android manifest has only local scheduling permissions and receivers', () {
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

  test('Apple local notifications do not add remote-push capabilities', () {
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

  test('release builds retain the local notification icon resource', () {
    final keep = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    expect(keep, contains('tools:keep="@drawable/ic_stat_moduly"'));
  });

  test('web remains server-push unconfigured and has no Firebase worker', () {
    expect(webIndex, isNot(contains('firebase-messaging-sw.js')));
    expect(webIndex, isNot(contains('firebase.initializeApp')));
    expect(File('web/firebase-messaging-sw.js').existsSync(), isFalse);
  });

  test('local demo never claims native delivery capability', () {
    expect(notificationBindings, contains('else if (client == null)'));
    expect(
      notificationBindings,
      contains('state: NotificationCapabilityState.unconfigured'),
    );
    expect(notificationBindings, contains('UUID-backed auth fence'));
  });

  test('bootstrap loads the complete timezone alias dataset', () {
    expect(
      mainSource,
      contains("package:timezone/data/latest_all.dart' as tzdata"),
    );
  });

  test('README documents local limits and future provider blockers', () {
    expect(readme, contains('Local reminders (Feature 3)'));
    expect(readme, contains('inexactAllowWhileIdle'));
    expect(readme, contains('60 days'));
    expect(readme, contains('48'));
    expect(readme, contains('unconfigured'));
    expect(readme, contains('at-least-once'));
    expect(readme, contains('APNs'));
    expect(readme, contains('VAPID'));
    expect(readme, contains('cron'));
    expect(readme, contains('verify_jwt = false'));
    expect(readme, contains('REMINDER_WORKER_SECRET'));
    expect(readme, contains('x-reminder-worker-secret'));
  });
}
