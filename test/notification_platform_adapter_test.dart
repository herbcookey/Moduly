import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moduly/core/notification_identity.dart';
import 'package:moduly/models/notification_models.dart';
import 'package:moduly/platform/notification_id_registry.dart';
import 'package:moduly/platform/notification_local_scheduler.dart';
import 'package:timezone/timezone.dart' as tz;

class _Store implements NotificationStringStore {
  final Map<String, String> values = <String, String>{};
  int activeWrites = 0;
  int maxConcurrentWrites = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    activeWrites += 1;
    if (activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = activeWrites;
    }
    await Future<void>.delayed(Duration.zero);
    values[key] = value;
    activeWrites -= 1;
  }
}

ReminderIdentity _identity({
  String userId = 'user-a',
  String eventId = 'event-a',
}) => ReminderIdentity(
  userId: userId,
  eventId: eventId,
  occurrenceKey: 'single',
  offsetValue: 900,
  offsetUnit: NotificationOffsetUnit.seconds,
  channel: NotificationChannel.local,
);

void main() {
  test(
    'SharedPreferences registry persists, isolates users, and validates data',
    () async {
      final store = _Store();
      final first = SharedPreferencesAsyncNotificationIdRegistry(store: store);
      final identity = _identity();
      final id = 123;
      await first.save('user-a', <int, String>{id: identity.stableKey});

      final reloaded = SharedPreferencesAsyncNotificationIdRegistry(
        store: store,
      );
      expect(await reloaded.load('user-a'), <int, String>{
        id: identity.stableKey,
      });
      expect(await reloaded.load('user-b'), isEmpty);
      final userKey = first.storageKeyForUser('user-a');
      expect(userKey, isNot(contains('user-a')));
      expect(store.values[userKey], contains('"id":123'));
      expect(store.values[userKey], contains(identity.stableKey));
      expect(store.maxConcurrentWrites, 1);

      store.values[userKey] = jsonEncode(<String, Object>{
        'v': 1,
        'entries': <Object>[
          <String, Object>{'id': 0, 'key': identity.stableKey},
        ],
      });
      final malformedEntry = SharedPreferencesAsyncNotificationIdRegistry(
        store: store,
      );
      expect(
        () => malformedEntry.load('user-a'),
        throwsA(isA<FormatException>()),
      );
      store.values[userKey] = '{malformed';
      final malformedJson = SharedPreferencesAsyncNotificationIdRegistry(
        store: store,
      );
      expect(
        () => malformedJson.load('user-a'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'native initialize retries after false/error and coalesces in-flight calls',
    () async {
      var calls = 0;
      final outcomes = <Object>[false, true];
      final scheduler = FlutterLocalNotificationScheduler(
        supportedPlatformOverride: true,
        initializeOverride: () async {
          calls += 1;
          final outcome = outcomes.removeAt(0);
          if (outcome is bool) return outcome;
          throw outcome;
        },
      );

      final first = scheduler.initialize();
      final coalesced = scheduler.initialize();
      expect(await first, isFalse);
      expect(await coalesced, isFalse);
      expect(scheduler.isInitialized, isFalse);
      expect(scheduler.capability, NotificationCapabilityState.disabled);

      expect(await scheduler.initialize(), isTrue);
      expect(calls, 2);
      expect(scheduler.isInitialized, isTrue);
      expect(scheduler.capability, NotificationCapabilityState.available);
    },
  );

  test(
    'native initialize clears a throwing future so a later retry can recover',
    () async {
      var calls = 0;
      final scheduler = FlutterLocalNotificationScheduler(
        supportedPlatformOverride: true,
        initializeOverride: () async {
          calls += 1;
          if (calls == 1) throw StateError('temporary');
          return true;
        },
      );

      await expectLater(scheduler.initialize(), throwsA(isA<StateError>()));
      expect(await scheduler.initialize(), isTrue);
      expect(calls, 2);
    },
  );

  test('initialize override never requests permission', () async {
    var initializeCalls = 0;
    final scheduler = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      initializeOverride: () async {
        initializeCalls += 1;
        return true;
      },
    );
    expect(await scheduler.initialize(), isTrue);
    expect(initializeCalls, 1);
  });

  test('Android denial marker survives a scheduler restart', () async {
    final store = _Store();
    final first = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      platformOverride: TargetPlatform.android,
      initializeOverride: () async => true,
      permissionStore: store,
      notificationsEnabledOverride: () async => false,
      requestPermissionOverride: () async {},
    );
    expect(
      await first.permissionStatus(),
      NotificationPermissionState.notDetermined,
    );
    await first.requestPermission();
    expect(await first.permissionStatus(), NotificationPermissionState.denied);

    final restarted = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      platformOverride: TargetPlatform.android,
      initializeOverride: () async => true,
      permissionStore: store,
      notificationsEnabledOverride: () async => false,
    );
    expect(
      await restarted.permissionStatus(),
      NotificationPermissionState.denied,
    );

    final authorized = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      platformOverride: TargetPlatform.android,
      initializeOverride: () async => true,
      permissionStore: store,
      notificationsEnabledOverride: () async => true,
    );
    expect(
      await authorized.permissionStatus(),
      NotificationPermissionState.authorized,
    );
  });

  test(
    'scheduler accepts UTC and rejects unknown timezones before native call',
    () async {
      tz.Location? receivedLocation;
      final scheduler = FlutterLocalNotificationScheduler(
        supportedPlatformOverride: true,
        initializeOverride: () async => true,
        scheduleOverride: (request, location) async {
          receivedLocation = location;
        },
      );
      final request = NotificationScheduleRequest(
        notificationId: 1,
        fireAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        title: 'private title must not reach native presentation',
        payload: const NotificationPayload(
          eventId: '123e4567-e89b-12d3-a456-426614174000',
          occurrenceKey: 'single',
        ),
        timezone: 'UTC',
      );
      await scheduler.schedule(request);
      expect(receivedLocation, same(tz.UTC));

      final invalid = NotificationScheduleRequest(
        notificationId: request.notificationId,
        fireAt: request.fireAt,
        title: request.title,
        payload: request.payload,
        timezone: 'Mars/Olympus',
      );
      await expectLater(
        scheduler.schedule(invalid),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
