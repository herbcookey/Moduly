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

  test('알림 탭을 인증하고 멤버십을 검증한 뒤 라우팅한다', () {
    expect(bindings, contains('final user = planner.user;'));
    expect(bindings, contains('final selectedGroup = planner.selectedGroup;'));
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
    expect(bindings, contains('별도의 웜 스타트 탭'));
    expect(bindings, contains('_hasSyncedPlannerIdentity'));
    expect(bindings, contains('_plannerStateGeneration'));
  });

  test('콜드 실행은 한 번 소비하고 웜 전달은 독립적으로 제어한다', () {
    final scheduler = File(
      'lib/platform/notification_local_scheduler.dart',
    ).readAsStringSync();
    expect(scheduler, contains('_launchPayloadConsumed'));
    expect(scheduler, contains('웜 스타트 콜백은 [_handleResponse]를 계속 통과'));
  });

  test('딥 링크 페이로드 허용 목록이 비공개 일정 내용과 인증 정보를 제외한다', () {
    final start = payloadModel.indexOf('class NotificationPayload');
    final end = payloadModel.indexOf('/// 네이티브 스케줄러에 전달하는 데이터다', start);
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
  });
}
