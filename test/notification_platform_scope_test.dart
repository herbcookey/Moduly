import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:moduly/app.dart';
import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/models/notification_models.dart';
import 'package:moduly/platform/notification_bindings.dart';
import 'package:moduly/repositories/notification_repository.dart';
import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/state/notification_state.dart';

void main() {
  testWidgets('실제 앱 셸이 중첩 알림 플랫폼 범위에서 로컬 데모 로그인 화면을 렌더링한다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appConfigProvider.overrideWithValue(
            const AppConfig(supabaseUrl: '', supabasePublishableKey: ''),
          ),
          supabaseReadyProvider.overrideWithValue(false),
          releaseConfigurationErrorProvider.overrideWithValue(null),
        ],
        child: const NotificationPlatformScope(child: ModulyApp()),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('데모 모드에서는 예시 값으로 바로 시작할 수 있어요.'), findsOneWidget);

    final appElement = tester.element(find.byType(ModulyApp));
    final innerContainer = ProviderScope.containerOf(appElement, listen: false);
    final controller = innerContainer.read(notificationControllerProvider);

    expect(
      innerContainer.read(notificationRepositoryProvider),
      same(controller.repository),
    );
    expect(controller.repository, isA<LocalNotificationRepository>());
    expect(
      innerContainer.read(localNotificationSchedulerProvider),
      same(controller.scheduler),
    );
    expect(controller.scheduler, isA<DisabledLocalNotificationScheduler>());
    expect(
      controller.scheduler!.capability,
      NotificationCapabilityState.unconfigured,
    );
    expect(
      innerContainer.read(pushTokenSourceProvider),
      same(controller.pushTokenSource),
    );
    expect(controller.pushTokenSource, isA<UnconfiguredPushTokenSource>());
    expect(
      innerContainer.read(notificationIdAllocatorProvider),
      same(controller.idAllocator),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
