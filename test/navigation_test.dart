import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/app.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/state/app_state.dart';

class _RouterAuth extends AuthRepository {
  _RouterAuth() : super();

  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  PlannerUser? _currentUser;
  Object? signOutError;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _changes.stream;

  @override
  PlannerUser? get currentUser => _currentUser;

  void emit(AuthRepositoryEvent event) {
    if (event.type == AuthEventType.signedOut) {
      _currentUser = null;
    } else if (event.user != null) {
      _currentUser = event.user;
    }
    _changes.add(event);
  }

  @override
  Future<void> signOut() async {
    final error = signOutError;
    if (error != null) throw error;
    await super.signOut();
  }

  @override
  Future<PlannerUser> updateRecoveredPassword(String password) async {
    final user = _currentUser ?? _routeUser;
    _currentUser = user;
    _changes.add(
      AuthRepositoryEvent(type: AuthEventType.userUpdated, user: user),
    );
    return user;
  }

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

const _routeUser = PlannerUser(
  id: 'route-user',
  email: 'route@example.com',
  displayName: 'Route User',
);

Future<GoRouter> _pumpRoutedApp(WidgetTester tester, _RouterAuth auth) async {
  final schedule = LocalScheduleRepository(
    seedMembers: <PlannerMember>[
      PlannerMember(
        id: _routeUser.id,
        name: _routeUser.displayName ?? 'Route User',
        email: _routeUser.email,
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(auth),
        scheduleRepositoryProvider.overrideWithValue(schedule),
      ],
      child: const ModulyApp(),
    ),
  );
  await tester.pumpAndSettle();
  return GoRouter.of(tester.element(find.byType(LoginScreen)));
}

void main() {
  testWidgets(
    'auth callback waits for the typed event before choosing a flow',
    (tester) async {
      final auth = _RouterAuth();
      addTearDown(auth.dispose);
      final router = await _pumpRoutedApp(tester, auth);

      router.go('/auth-callback');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('인증 링크를 확인하는 중이에요'), findsOneWidget);

      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.signedIn,
          user: _routeUser,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('어디서 함께할까요?'), findsOneWidget);

      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await tester.pumpAndSettle();
      router.go('/auth-callback');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.passwordRecovery,
          user: _routeUser,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('새 비밀번호 만들기'), findsOneWidget);
    },
  );

  testWidgets('OAuth callback maps cancellation to safe Korean copy', (
    tester,
  ) async {
    final auth = _RouterAuth();
    addTearDown(auth.dispose);
    final router = await _pumpRoutedApp(tester, auth);

    router.go(
      '/auth-callback?error=access_denied&error_description='
      'User%20cancelled%20the%20login%20provider_secret',
    );
    await tester.pumpAndSettle();

    expect(find.text('인증 링크를 확인하지 못했어요'), findsOneWidget);
    expect(find.text(socialAuthCancelledMessage), findsOneWidget);
    expect(find.textContaining('access_denied'), findsNothing);
    expect(find.textContaining('User cancelled'), findsNothing);
    expect(find.textContaining('provider_secret'), findsNothing);
  });

  testWidgets('OAuth callback maps unknown errors without exposing details', (
    tester,
  ) async {
    final auth = _RouterAuth();
    addTearDown(auth.dispose);
    final router = await _pumpRoutedApp(tester, auth);

    router.go(
      '/auth-callback?error=server_error&error_description='
      'provider%20secret%20details',
    );
    await tester.pumpAndSettle();

    expect(find.text('인증 링크를 확인하지 못했어요'), findsOneWidget);
    expect(find.text(socialAuthUnknownErrorMessage), findsOneWidget);
    expect(find.textContaining('server_error'), findsNothing);
    expect(find.textContaining('provider secret'), findsNothing);
    expect(find.textContaining('details'), findsNothing);
  });

  testWidgets('OAuth callback hides a description even without an error code', (
    tester,
  ) async {
    final auth = _RouterAuth();
    addTearDown(auth.dispose);
    final router = await _pumpRoutedApp(tester, auth);

    router.go('/auth-callback?error_description=account%20secret');
    await tester.pumpAndSettle();

    expect(find.text(socialAuthUnknownErrorMessage), findsOneWidget);
    expect(find.textContaining('account secret'), findsNothing);
  });

  testWidgets('custom-scheme callback keeps its query while routing', (
    tester,
  ) async {
    final auth = _RouterAuth();
    addTearDown(auth.dispose);
    final router = await _pumpRoutedApp(tester, auth);

    router.go(
      'moduly://auth-callback?error=access_denied&error_description=cancelled',
    );
    await tester.pumpAndSettle();

    expect(find.text(socialAuthCancelledMessage), findsOneWidget);
  });

  testWidgets('signed-in confirmation and stale reset routes go to groups', (
    tester,
  ) async {
    final auth = _RouterAuth();
    addTearDown(auth.dispose);
    final router = await _pumpRoutedApp(tester, auth);

    router.go('/verify-email');
    await tester.pumpAndSettle();
    expect(find.text('메일함을 확인해 주세요'), findsOneWidget);

    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _routeUser),
    );
    await tester.pumpAndSettle();
    expect(find.text('어디서 함께할까요?'), findsOneWidget);

    router.go('/reset-password');
    await tester.pumpAndSettle();
    expect(find.text('어디서 함께할까요?'), findsOneWidget);
  });

  testWidgets('group logout keeps a safe login route when sign-out fails', (
    tester,
  ) async {
    final auth = _RouterAuth()..signOutError = StateError('provider secret');
    addTearDown(auth.dispose);
    await _pumpRoutedApp(tester, auth);

    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _routeUser),
    );
    await tester.pumpAndSettle();
    expect(find.text('어디서 함께할까요?'), findsOneWidget);

    await tester.tap(find.byTooltip('로그아웃'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('provider secret'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings logout keeps a safe login route when sign-out fails', (
    tester,
  ) async {
    final auth = _RouterAuth()..signOutError = StateError('provider secret');
    addTearDown(auth.dispose);
    await _pumpRoutedApp(tester, auth);

    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _routeUser),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('로그아웃'),
      400,
      scrollable: find.byType(Scrollable).last,
    );

    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('provider secret'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'password reset remains visible long enough to show successful update',
    (tester) async {
      final auth = _RouterAuth();
      addTearDown(auth.dispose);
      final router = await _pumpRoutedApp(tester, auth);

      router.go('/auth-callback');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.passwordRecovery,
          user: _routeUser,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('새 비밀번호 만들기'), findsOneWidget);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'new-password');
      await tester.enterText(fields.at(1), 'new-password');
      await tester.tap(find.text('비밀번호 변경하기'));
      await tester.pumpAndSettle();

      expect(find.text('비밀번호를 변경했어요. 새 비밀번호로 로그인해 주세요.'), findsOneWidget);
      expect(find.text('로그인하러 가기'), findsOneWidget);
      expect(find.text('어디서 함께할까요?'), findsNothing);
    },
  );

  testWidgets(
    'demo login navigates through group and bottom-navigation routes',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
      await tester.pumpAndSettle();
      expect(find.text('로그인'), findsOneWidget);

      await tester.tap(find.text('데모 값 채우기'));
      await tester.tap(find.text('로그인'));
      await tester.pumpAndSettle();
      expect(find.text('어디서 함께할까요?'), findsOneWidget);
      expect(find.text('우리 가족'), findsOneWidget);

      await tester.tap(find.text('우리 가족'));
      await tester.pumpAndSettle();
      expect(find.text('캘린더'), findsWidgets);

      await tester.tap(find.text('멤버').last);
      await tester.pumpAndSettle();
      expect(find.text('동현'), findsOneWidget);
      expect(find.text('진우'), findsOneWidget);

      await tester.tap(find.text('설정').last);
      await tester.pumpAndSettle();
      expect(find.text('어두운 화면'), findsOneWidget);
    },
  );

  testWidgets('cancelling invite dialogs disposes their fields safely', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('초대 코드로 참여'));
    await tester.pumpAndSettle();
    expect(find.text('예: 7K9M-W3PX-Q2RT'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('멤버').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 코드'));
    await tester.pumpAndSettle();
    expect(find.text('초대 코드 만들기'), findsOneWidget);
    final maxUsesField = find.byType(TextFormField);
    await tester.enterText(maxUsesField, '0');
    await tester.tap(find.text('만들기'));
    await tester.pump();
    expect(find.text('사용 횟수는 1~100,000회로 입력해 주세요.'), findsOneWidget);
    await tester.enterText(maxUsesField, '100001');
    await tester.tap(find.text('만들기'));
    await tester.pump();
    expect(find.text('사용 횟수는 1~100,000회로 입력해 주세요.'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('group dialogs validate blank and malformed input inline', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('새 그룹 만들기'));
    await tester.pumpAndSettle();
    final groupFields = find.byType(TextField);
    expect(tester.widget<TextField>(groupFields.at(1)).maxLength, 10000);
    await tester.tap(find.text('만들기'));
    await tester.pump();
    expect(find.text('그룹 이름을 입력해 주세요.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('초대 코드로 참여'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('참여'));
    await tester.pump();
    expect(find.text('초대 코드를 입력해 주세요.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'not-a-code');
    await tester.tap(find.text('참여'));
    await tester.pump();
    expect(find.text('초대 코드를 확인해 주세요.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('horizontal swipes move the selected schedule day', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    final controller = container.read(plannerControllerProvider);
    final initialDay = controller.selectedDay;

    await tester.drag(find.byType(CustomScrollView), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(
      controller.selectedDay,
      DateTime(initialDay.year, initialDay.month, initialDay.day + 1),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(controller.selectedDay, initialDay);
  });

  testWidgets('settings lets the signed-in user change their display name', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('이름 변경'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '표시 이름'), '새 표시 이름');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('새 표시 이름'), findsOneWidget);
    expect(find.text('이름을 변경했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saving an event returns home after controller notifications in the same turn',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('데모 값 채우기'));
      await tester.tap(find.text('로그인'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('우리 가족'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('일정 추가'));
      await tester.pumpAndSettle();
      expect(find.byType(EventEditorScreen), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '회귀 테스트 일정');
      // LocalScheduleRepository는 이벤트를 내보내고, _save가 이동하기 전에
      // 같은 저장 작업의 시작과 끝에서 saveEvent를 알린다.
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();

      expect(find.byType(EventEditorScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('회귀 테스트 일정'), findsOneWidget);
    },
  );
}
