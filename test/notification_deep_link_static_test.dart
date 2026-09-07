import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String bindings;
  late String payloadModel;

  setUpAll(() {
    bindings = File(
      'lib/platform/notification_bindings.dart',
    ).readAsStringSync();
    payloadModel = File(
      'lib/models/notification_models.dart',
    ).readAsStringSync();
  });

  test(
    'notification taps are authenticated and membership validated before routing',
    () {
      expect(bindings, contains('final user = planner.user;'));
      expect(
        bindings,
        contains('final selectedGroup = planner.selectedGroup;'),
      );
      expect(
        bindings,
        contains('.loadEventById(eventId, occurrenceKey: occurrenceKey)'),
      );
      expect(bindings, contains('event.memberIds.contains(user.id)'));
      expect(bindings, contains('!event.isDeleted'));
      expect(bindings, contains("router.go('/event/\$eventId\$query')"));
      expect(bindings, isNot(contains('_payloadConsumed')));
      expect(bindings, contains('_inFlightPayloadFingerprint'));
      expect(bindings, contains('_pendingPayloadFingerprint'));
      expect(bindings, contains('distinct warm tap'));
      expect(bindings, contains('_hasSyncedPlannerIdentity'));
      expect(bindings, contains('_plannerStateGeneration'));
    },
  );

  test(
    'cold launch is consumed once but warm deliveries are independently gated',
    () {
      final scheduler = File(
        'lib/platform/notification_local_scheduler.dart',
      ).readAsStringSync();
      expect(scheduler, contains('_launchPayloadConsumed'));
      expect(scheduler, contains('Warm\n  /// callbacks continue'));
    },
  );

  test(
    'deep-link payload allowlist excludes private event content and credentials',
    () {
      final start = payloadModel.indexOf('class NotificationPayload');
      final end = payloadModel.indexOf(
        '/// Data passed to the native scheduler',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final payloadSection = payloadModel.substring(start, end);
      expect(payloadSection, contains("'schema_version'"));
      expect(payloadSection, contains("'type'"));
      expect(payloadSection, contains("'event_id'"));
      expect(payloadSection, contains("'occurrence_key'"));
      expect(payloadSection, isNot(contains("'title'")));
      expect(payloadSection, isNot(contains("'note'")));
      expect(payloadSection, isNot(contains("'email'")));
      expect(payloadSection, isNot(contains("'token'")));
    },
  );
}
