import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/state/app_state.dart';

class _UiAuthRepository extends AuthRepository {
  _UiAuthRepository({required this.remote}) : super();

  final bool remote;

  @override
  bool get isRemote => remote;
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  required bool remote,
  required bool demoAllowed,
}) async {
  final auth = _UiAuthRepository(remote: remote);
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(auth),
        localDemoAllowedProvider.overrideWithValue(demoAllowed),
        scheduleRepositoryProvider.overrideWithValue(LocalScheduleRepository()),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('demo login shows an explicit fill affordance', (tester) async {
    await _pumpLogin(tester, remote: false, demoAllowed: true);

    expect(find.text('데모 값 채우기'), findsOneWidget);
    expect(find.text('데모 모드에서는 예시 값으로 바로 시작할 수 있어요.'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);

    await tester.tap(find.text('데모 값 채우기'));
    await tester.pump();
    expect(
      tester.widget<TextField>(fields.at(0)).controller?.text,
      'me@example.com',
    );
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, 'planner');
  });

  testWidgets('remote login does not expose demo credentials or copy', (
    tester,
  ) async {
    await _pumpLogin(tester, remote: true, demoAllowed: true);

    expect(find.text('데모 값 채우기'), findsNothing);
    expect(find.textContaining('데모 모드'), findsNothing);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);
  });

  testWidgets('configuration-blocked login does not expose demo credentials', (
    tester,
  ) async {
    await _pumpLogin(tester, remote: false, demoAllowed: false);

    expect(find.text('데모 값 채우기'), findsNothing);
    expect(find.textContaining('데모 모드'), findsNothing);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);
  });

  testWidgets('login enforces the six-character backend password minimum', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), '12345');
    await tester.tap(find.text('로그인'));
    await tester.pump();

    expect(find.text('6자 이상 입력해 주세요.'), findsOneWidget);
  });

  testWidgets('login busy state exposes a spoken progress label', (
    tester,
  ) async {
    final auth = _UiAuthRepository(remote: false);
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    )..isSaving = true;
    addTearDown(() {
      auth.dispose();
    });
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
          authRepositoryProvider.overrideWithValue(auth),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('로그인 중'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('sign-up enforces backend password and display-name limits', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SignUpScreen())),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    final passwordField = tester.widget<EditableText>(
      find.byType(EditableText).at(2),
    );
    expect(passwordField.textInputAction, TextInputAction.done);
    expect(passwordField.onSubmitted, isNotNull);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).maxLength,
      120,
    );
    await tester.enterText(fields.at(0), 'New User');
    await tester.enterText(fields.at(1), 'person@example.com');
    await tester.enterText(fields.at(2), '12345');
    await tester.tap(find.text('가입하고 시작하기'));
    await tester.pump();

    expect(find.text('6자 이상 입력해 주세요.'), findsOneWidget);
  });

  testWidgets('forgot-password screen reports success after requesting email', (
    tester,
  ) async {
    String? requestedEmail;
    await tester.pumpWidget(
      MaterialApp(
        home: ForgotPasswordScreen(
          onRequest: (email) async {
            requestedEmail = email;
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'person@example.com');
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pumpAndSettle();

    expect(requestedEmail, 'person@example.com');
    expect(find.textContaining('재설정 메일을 보냈어요'), findsOneWidget);
  });

  testWidgets('forgot-password errors do not reveal account existence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ForgotPasswordScreen(
          onRequest: (email) async {
            throw const AuthException('User not found');
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'unknown@example.com');
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pumpAndSettle();

    expect(find.textContaining('User not found'), findsNothing);
    expect(find.textContaining('등록되어 있다면 잠시 후 다시 시도해 주세요'), findsOneWidget);
  });

  testWidgets(
    'reset-password screen validates confirmation and updates password',
    (tester) async {
      String? updatedPassword;
      await tester.pumpWidget(
        MaterialApp(
          home: ResetPasswordScreen(
            onUpdate: (password) async {
              updatedPassword = password;
            },
          ),
        ),
      );

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'new-password');
      await tester.enterText(fields.at(1), 'different-password');
      await tester.tap(find.text('비밀번호 변경하기'));
      await tester.pump();
      expect(find.text('비밀번호가 일치하지 않아요.'), findsOneWidget);
      expect(updatedPassword, isNull);

      await tester.enterText(fields.at(1), 'new-password');
      await tester.tap(find.text('비밀번호 변경하기'));
      await tester.pumpAndSettle();
      expect(updatedPassword, 'new-password');
      expect(find.textContaining('비밀번호를 변경했어요'), findsOneWidget);
    },
  );

  testWidgets('confirmation screen can resend and return to login', (
    tester,
  ) async {
    String? resentEmail;
    await tester.pumpWidget(
      MaterialApp(
        home: VerifyEmailScreen(
          initialEmail: 'person@example.com',
          onResend: (email) async {
            resentEmail = email;
          },
        ),
      ),
    );

    await tester.tap(find.text('인증 메일 다시 보내기'));
    await tester.pumpAndSettle();
    expect(resentEmail, 'person@example.com');
    expect(find.textContaining('인증 메일을 다시 보냈어요'), findsOneWidget);
  });

  testWidgets('confirmation screen hides raw provider error details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VerifyEmailScreen(
          initialEmail: 'person@example.com',
          onResend: (email) async {
            throw const AuthException(
              'provider_secret account=person@example.com status=500',
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('인증 메일 다시 보내기'));
    await tester.pumpAndSettle();

    expect(find.textContaining('provider_secret'), findsNothing);
    expect(find.textContaining('person@example.com status=500'), findsNothing);
    expect(find.text(authResendSignupErrorMessage), findsOneWidget);
  });

  testWidgets('reset-password screen hides raw provider error details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResetPasswordScreen(
          onUpdate: (password) async {
            throw const AuthException(
              'internal_session_secret account=person@example.com',
            );
          },
        ),
      ),
    );

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'new-password');
    await tester.enterText(fields.at(1), 'new-password');
    await tester.tap(find.text('비밀번호 변경하기'));
    await tester.pumpAndSettle();

    expect(find.textContaining('internal_session_secret'), findsNothing);
    expect(find.textContaining('account=person@example.com'), findsNothing);
    expect(find.text(authRecoveredPasswordErrorMessage), findsOneWidget);
  });
}
