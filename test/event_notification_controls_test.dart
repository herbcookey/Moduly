import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/notification_models.dart';
import 'package:moduly/widgets/event_notification_controls.dart';

void main() {
  testWidgets('시간 일정은 timed 오프셋과 반복 전체 적용을 제공한다', (WidgetTester tester) async {
    var lead = 900;
    var wholeSeries = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventNotificationControls(
            allDay: false,
            recurring: true,
            enabled: true,
            channel: NotificationChannel.local,
            timedLeadSeconds: lead,
            allDayDaysBefore: 0,
            localCapability: NotificationCapabilityState.available,
            pushCapability: NotificationCapabilityState.unconfigured,
            onTimedLeadChanged: (value) async => lead = value,
            onApplyToWholeSeriesChanged: (value) async => wholeSeries = value,
          ),
        ),
      ),
    );
    expect(find.text('미리 알림'), findsOneWidget);
    expect(find.text('15분 전'), findsOneWidget);
    expect(find.text('반복 일정 전체에 적용'), findsOneWidget);
    expect(find.text('서버 푸시는 아직 설정되지 않았어요.'), findsOneWidget);

    await tester.tap(find.text('반복 일정 전체에 적용'));
    await tester.pump();
    expect(wholeSeries, isFalse);
  });

  testWidgets('종일 일정은 시간대 오전 9시와 calendar-day 간격을 표시한다', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EventNotificationControls(
            allDay: true,
            recurring: false,
            enabled: true,
            channel: NotificationChannel.local,
            timedLeadSeconds: 900,
            allDayDaysBefore: 1,
            localCapability: NotificationCapabilityState.available,
            pushCapability: NotificationCapabilityState.unconfigured,
          ),
        ),
      ),
    );
    expect(find.text('일정 시간대의 오전 9시에 알려 드려요.'), findsOneWidget);
    expect(find.text('1일 전'), findsOneWidget);
    expect(find.byIcon(Icons.today_outlined), findsOneWidget);
  });

  testWidgets('비동기 저장 실패 시 알림 초안 값이 되돌아간다', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventNotificationControls(
            allDay: false,
            recurring: false,
            enabled: true,
            channel: NotificationChannel.local,
            timedLeadSeconds: 900,
            allDayDaysBefore: 0,
            localCapability: NotificationCapabilityState.available,
            pushCapability: NotificationCapabilityState.unconfigured,
            onEnabledChanged: (value) async => throw StateError('temporary'),
            onTimedLeadChanged: (value) async => throw StateError('temporary'),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pump();
    await tester.tap(find.text('30분 전').last);
    await tester.pumpAndSettle();
    expect(find.text('15분 전'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
