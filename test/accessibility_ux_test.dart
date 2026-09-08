import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/app.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/models/app_models.dart';

void main() {
  testWidgets('앱 내 텍스트 설정이 플랫폼의 큰 텍스트를 줄이지 않는다', (tester) async {
    final auth = AuthRepository();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    )..textScale = 0.9;
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const ModulyApp(),
        ),
      ),
    );
    await tester.pump();

    final loginContext = tester.element(find.byType(LoginScreen));
    final effectiveScaler = MediaQuery.of(loginContext).textScaler;
    expect(effectiveScaler.scale(14), greaterThanOrEqualTo(28));
  });

  testWidgets('긴 그룹 이름이 홈 앱 바 안에 표시된다', (tester) async {
    final auth = AuthRepository();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      auth.dispose();
    });
    const user = PlannerUser(id: 'user', email: 'user@example.com');
    final group = PlannerGroup(
      id: 'long-group',
      name: '가' * 160,
      timezone: 'UTC',
    );
    controller.user = user;
    controller.groups = <PlannerGroup>[group];
    controller.selectedGroup = group;
    controller.isLoading = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    final title = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == group.name,
      ),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
  });
}
