import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

class _PendingAuth extends AuthRepository {
  _PendingAuth() : super();

  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  PlannerUser? _user;
  String? resentEmail;
  String? resetEmail;
  Object? resetError;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _changes.stream;

  @override
  PlannerUser? get currentUser => _user;

  @override
  Future<AuthSignUpResult> signUp(
    String email,
    String password,
    String name,
  ) async => PendingEmailConfirmation(email: email.trim());

  @override
  Future<void> resendSignupConfirmation(String email) async {
    resentEmail = email;
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    final error = resetError;
    if (error != null) throw error;
    resetEmail = email;
  }

  void emit(AuthRepositoryEvent event) => _changes.add(event);

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

void main() {
  test('소셜 인증 표시 이름이 Google 메타데이터 키를 지원한다', () {
    expect(
      displayNameFromAuthMetadata(<String, dynamic>{
        'full_name': '  Google User  ',
        'name': 'Fallback Name',
      }),
      'Google User',
    );
    expect(
      displayNameFromAuthMetadata(<String, dynamic>{'name': 'Provider Name'}),
      'Provider Name',
    );
  });

  test('명시적 표시 이름이 공급자 대체값보다 우선한다', () {
    expect(
      displayNameFromAuthMetadata(<String, dynamic>{
        'display_name': 'Chosen Name',
        'full_name': 'Google Name',
      }, fallback: 'Sign-up Name'),
      'Chosen Name',
    );
  });

  test('로컬 사용자가 검증된 표시 이름을 갱신할 수 있다', () async {
    final auth = AuthRepository();
    addTearDown(auth.dispose);
    await auth.signIn('demo@example.com', 'planner');

    final updated = await auth.updateDisplayName('  새 이름  ');
    expect(updated.displayName, '새 이름');
    expect(auth.currentUser?.displayName, '새 이름');

    await expectLater(
      auth.updateDisplayName('   '),
      throwsA(isA<AuthException>()),
    );
  });

  test('로컬 인증이 데모 흐름을 결정적으로 유지하고 타입이 있는 이벤트를 내보낸다', () async {
    final auth = AuthRepository();
    addTearDown(auth.dispose);

    final signInEvent = auth.events.first;
    final user = await auth.signIn('demo@example.com', 'planner');
    expect(user.id, isNotEmpty);
    expect((await signInEvent).type, AuthEventType.signedIn);

    final result = await auth.signUp('new@example.com', 'planner', 'New User');
    expect(result, isA<AuthenticatedSignUp>());
    expect(result.isAuthenticated, isTrue);

    await auth.resendSignupConfirmation('new@example.com');
    expect(auth.pendingLocalConfirmationEmail, 'new@example.com');
    await auth.requestPasswordReset('new@example.com');
    expect(await auth.updateRecoveredPassword('new-password'), isNotNull);

    final signOutEvent = auth.events.first;
    await auth.signOut();
    expect((await signOutEvent).type, AuthEventType.signedOut);
  });

  test('컨트롤러가 대기 중 확인을 오류가 아닌 상태로 제공한다', () async {
    final auth = _PendingAuth();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    final result = await controller.signUp(
      'pending@example.com',
      'planner',
      'Pending User',
    );
    expect(result, isA<PendingEmailConfirmation>());
    expect(controller.authFlowState, AuthFlowState.pendingEmailConfirmation);
    expect(controller.pendingConfirmationEmail, 'pending@example.com');
    expect(controller.user, isNull);
    expect(controller.errorMessage, isNull);

    await controller.resendSignupConfirmation();
    expect(auth.resentEmail, 'pending@example.com');
  });

  test('복구 비밀번호 검증이 UI의 8자 규칙과 일치한다', () async {
    final auth = AuthRepository();
    addTearDown(auth.dispose);

    await expectLater(
      auth.updateRecoveredPassword('1234567'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          '8자 이상 입력해 주세요.',
        ),
      ),
    );
  });

  test('컨트롤러가 같은 복구 비밀번호 최소 길이를 적용한다', () async {
    final auth = _PendingAuth();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      controller.updateRecoveredPassword('1234567'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          '8자 이상 입력해 주세요.',
        ),
      ),
    );
  });

  test('컨트롤러가 접근 권한에 메타데이터를 신뢰하지 않고 인증 상태 이벤트를 적용한다', () async {
    final auth = _PendingAuth();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    const signedInUser = PlannerUser(
      id: 'remote-user',
      email: 'remote@example.com',
      displayName: 'Remote',
    );
    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.signedIn,
        user: signedInUser,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.user?.id, 'remote-user');
    expect(controller.authFlowState, AuthFlowState.signedIn);

    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.passwordRecovery,
        user: signedInUser,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.isInPasswordRecovery, isTrue);

    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.userUpdated,
        user: PlannerUser(
          id: 'remote-user',
          email: 'remote@example.com',
          displayName: 'Updated',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.user?.displayName, 'Updated');

    auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    await Future<void>.delayed(Duration.zero);
    expect(controller.user, isNull);
    expect(controller.authFlowState, AuthFlowState.signedOut);
  });

  test('비밀번호 재설정 오류가 계정 존재 여부를 중립적으로 처리한다', () async {
    final auth = _PendingAuth()
      ..resetError = const AuthException('User not found');
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      controller.requestPasswordReset('person@example.com'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          passwordResetRequestErrorMessage,
        ),
      ),
    );
    expect(controller.errorMessage, passwordResetRequestErrorMessage);
    expect(controller.errorMessage, isNot(contains('User not found')));
  });
}
