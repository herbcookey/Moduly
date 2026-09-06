import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/group_picker_screen.dart';
import 'package:moduly/screens/members_screen.dart';
import 'package:moduly/screens/settings_screen.dart';
import 'package:moduly/state/app_state.dart';

class _DialogAuth extends AuthRepository {
  _DialogAuth() : super();

  @override
  PlannerUser? get currentUser => null;
}

ThemeData _dialogTheme() => ThemeData(
  useMaterial3: true,
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
);

Widget _largeTextApp(Widget child, ValueNotifier<EdgeInsets> insets) =>
    MaterialApp(
      theme: _dialogTheme(),
      builder: (context, built) => ValueListenableBuilder<EdgeInsets>(
        valueListenable: insets,
        builder: (context, viewInsets, _) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2), viewInsets: viewInsets),
          child: built ?? child,
        ),
      ),
      home: child,
    );

void _useConstrainedViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

PlannerController _controllerWith({
  required _DialogAuth auth,
  PlannerUser? user,
  PlannerGroup? group,
}) {
  final controller = PlannerController(
    auth: auth,
    repository: LocalScheduleRepository(),
  );
  controller.user = user;
  controller.groups = group == null
      ? const <PlannerGroup>[]
      : <PlannerGroup>[group];
  controller.selectedGroup = group;
  controller.isLoading = false;
  controller.authFlowState = user == null
      ? AuthFlowState.signedOut
      : AuthFlowState.signedIn;
  return controller;
}

void _expectVisible(WidgetTester tester, Finder finder) {
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
  expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
}

Future<void> _scrollIntoBodyViewport(WidgetTester tester, Finder target) async {
  final list = find.byType(ListView).first;
  final viewport = tester.getRect(list);
  for (var index = 0; index < 20; index += 1) {
    if (target.evaluate().isNotEmpty) {
      final rect = tester.getRect(target);
      if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) {
        return;
      }
    }
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  fail('Target did not become visible in the constrained body viewport.');
}

void main() {
  testWidgets(
    'create-invite dialog keeps actions reachable with large text and keyboard',
    (tester) async {
      _useConstrainedViewport(tester);
      final insets = ValueNotifier<EdgeInsets>(
        const EdgeInsets.only(bottom: 300),
      );
      addTearDown(insets.dispose);
      final auth = _DialogAuth();
      addTearDown(auth.dispose);
      final user = const PlannerUser(
        id: 'owner-dialog',
        email: 'owner@example.com',
        displayName: '소유자',
      );
      final group = const PlannerGroup(
        id: 'dialog-group',
        name: '그룹',
        description: '',
        timezone: 'Asia/Seoul',
        ownerId: 'owner-dialog',
      );
      final controller = _controllerWith(auth: auth, user: user, group: group);
      controller.members = <PlannerMember>[
        PlannerMember(
          id: user.id,
          name: user.displayName!,
          email: user.email,
          isOwner: true,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: _largeTextApp(const MembersScreen(), insets),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('새 코드'));
      await tester.pumpAndSettle();

      expect(find.text('초대 코드 만들기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final create = find.widgetWithText(FilledButton, '만들기');
      _expectVisible(tester, create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'join-group dialog keeps validation action reachable with large text and keyboard',
    (tester) async {
      _useConstrainedViewport(tester);
      final insets = ValueNotifier<EdgeInsets>(
        const EdgeInsets.only(bottom: 300),
      );
      addTearDown(insets.dispose);
      final auth = _DialogAuth();
      addTearDown(auth.dispose);
      final controller = _controllerWith(auth: auth);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: _largeTextApp(const GroupPickerScreen(), insets),
        ),
      );
      await tester.pumpAndSettle();
      final joinEntry = find.widgetWithText(OutlinedButton, '초대 코드로 참여');
      await _scrollIntoBodyViewport(tester, joinEntry);
      await tester.tap(joinEntry);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      final join = find.widgetWithText(FilledButton, '참여');
      _expectVisible(tester, join);
      await tester.tap(join);
      await tester.pump();
      expect(find.text('초대 코드를 입력해 주세요.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      _expectVisible(tester, join);
    },
  );

  testWidgets(
    'edit-display-name dialog keeps max-length counter and actions reachable',
    (tester) async {
      _useConstrainedViewport(tester);
      final insets = ValueNotifier<EdgeInsets>(
        const EdgeInsets.only(bottom: 300),
      );
      addTearDown(insets.dispose);
      final auth = _DialogAuth();
      addTearDown(auth.dispose);
      final user = const PlannerUser(
        id: 'settings-dialog',
        email: 'settings@example.com',
        displayName: '기존 이름',
      );
      final controller = _controllerWith(auth: auth, user: user);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: _largeTextApp(const SettingsScreen(), insets),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollIntoBodyViewport(tester, find.byIcon(Icons.edit_outlined));
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.text('이름 변경'), findsOneWidget);
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).maxLength, 120);
      expect(find.textContaining('/120'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final save = find.widgetWithText(FilledButton, '저장');
      _expectVisible(tester, save);

      await tester.enterText(field, '');
      await tester.tap(save);
      await tester.pump();
      expect(find.text('1자 이상 120자 이하로 입력해 주세요.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      _expectVisible(tester, save);
    },
  );
}
