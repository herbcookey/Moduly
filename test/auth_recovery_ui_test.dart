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
  testWidgets('데모 로그인이 명확한 자동 입력 동작을 표시한다', (tester) async {
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

  testWidgets('원격 로그인이 데모 인증 정보나 문구를 노출하지 않는다', (tester) async {
    await _pumpLogin(tester, remote: true, demoAllowed: true);

    expect(find.text('데모 값 채우기'), findsNothing);
    expect(find.textContaining('데모 모드'), findsNothing);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);
  });

  testWidgets('설정으로 차단된 로그인이 데모 인증 정보를 노출하지 않는다', (tester) async {
    await _pumpLogin(tester, remote: false, demoAllowed: false);

    expect(find.text('데모 값 채우기'), findsNothing);
    expect(find.textContaining('데모 모드'), findsNothing);
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);
  });

  testWidgets('로그인이 백엔드 비밀번호 최소 길이 6자를 적용한다', (tester) async {
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

  testWidgets('로그인 진행 상태가 음성 진행 라벨을 제공한다', (tester) async {
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

  testWidgets('가입이 백엔드 비밀번호 및 표시 이름 제한을 적용한다', (tester) async {
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

  testWidgets('비밀번호 찾기 화면이 이메일 요청 후 성공을 알린다', (tester) async {
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

  testWidgets('비밀번호 찾기 오류가 계정 존재 여부를 드러내지 않는다', (tester) async {
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

  testWidgets('비밀번호 재설정 화면이 확인값을 검증하고 비밀번호를 갱신한다', (tester) async {
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
  });

  testWidgets('확인 화면에서 재전송하고 로그인으로 돌아갈 수 있다', (tester) async {
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

  testWidgets('확인 화면이 공급자의 원본 오류 세부 정보를 숨긴다', (tester) async {
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

  testWidgets('비밀번호 재설정 화면이 공급자의 원본 오류 세부 정보를 숨긴다', (tester) async {
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
