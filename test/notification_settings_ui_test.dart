import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/notification_models.dart';
import 'package:moduly/screens/notification_settings_screen.dart';

void main() {
  testWidgets('알림 설정은 계정 스위치와 기기 권한을 분리한다', (WidgetTester tester) async {
    var account = false;
    var requested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationSettingsScreen(
          accountEnabled: account,
          pushEnabled: false,
          permissionState: NotificationPermissionState.notDetermined,
          localCapability: NotificationCapabilityState.available,
          pushCapability: NotificationCapabilityState.unconfigured,
          onAccountChanged: (value) async => account = value,
          onRequestPermission: () async => requested = true,
        ),
      ),
    );

    expect(find.text('로컬 알림 사용'), findsOneWidget);
    expect(find.text('이 기기에서 받기'), findsOneWidget);
    expect(find.text('서버 푸시는 아직 설정되지 않았어요.'), findsOneWidget);
    expect(find.text('권한 요청'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));

    await tester.tap(find.text('권한 요청'));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
    expect(account, isFalse);
  });

  testWidgets('거부 상태는 설정 열기만 제공하고 320px에서도 접근 가능하다', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationSettingsScreen(
          accountEnabled: true,
          pushEnabled: false,
          permissionState: NotificationPermissionState.denied,
          localCapability: NotificationCapabilityState.available,
          pushCapability: NotificationCapabilityState.unconfigured,
          onOpenSystemSettings: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('기기 설정에서 알림 권한을 허용해 주세요.'), findsOneWidget);
    expect(find.text('설정 열기'), findsOneWidget);
    expect(find.text('권한 요청'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('기기 알림 상태: 권한이 거부됨', skipOffstage: false),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('지원하지 않는 플랫폼 상태는 토글과 권한 요청을 차단한다', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationSettingsScreen(
          accountEnabled: true,
          pushEnabled: false,
          permissionState: NotificationPermissionState.unsupported,
          localCapability: NotificationCapabilityState.unsupported,
          pushCapability: NotificationCapabilityState.unsupported,
          onRequestPermission: () async {
            fail('지원하지 않는 상태에서는 OS 권한을 요청하면 안 된다');
          },
        ),
      ),
    );
    expect(find.text('이 플랫폼에서는 기기 알림을 지원하지 않아요.'), findsWidgets);
    expect(find.text('권한 요청'), findsNothing);
  });

  testWidgets('계정 스위치는 저장 실패 시 이전 상태로 되돌아간다', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationSettingsScreen(
          accountEnabled: false,
          pushEnabled: false,
          permissionState: NotificationPermissionState.authorized,
          localCapability: NotificationCapabilityState.available,
          pushCapability: NotificationCapabilityState.unconfigured,
          onAccountChanged: (value) async => throw StateError('temporary'),
        ),
      ),
    );

    final accountSwitch = find.byType(SwitchListTile).first;
    expect(tester.widget<SwitchListTile>(accountSwitch).value, isFalse);
    await tester.tap(find.text('로컬 알림 사용'));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(accountSwitch).value, isFalse);
    expect(find.text('변경하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });

  testWidgets('서버 푸시 스위치는 저장 실패 시 이전 상태로 되돌아간다', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationSettingsScreen(
          accountEnabled: true,
          pushEnabled: false,
          permissionState: NotificationPermissionState.authorized,
          localCapability: NotificationCapabilityState.available,
          pushCapability: NotificationCapabilityState.available,
          onPushChanged: (value) async => throw StateError('temporary'),
        ),
      ),
    );

    final pushSwitch = find.byType(SwitchListTile).last;
    expect(tester.widget<SwitchListTile>(pushSwitch).value, isFalse);
    await tester.tap(find.text('다른 기기에서도 받기'));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(pushSwitch).value, isFalse);
    expect(find.text('변경하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });
}
