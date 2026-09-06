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
  test('social auth display name supports Google metadata keys', () {
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

  test('explicit display name has priority over provider fallbacks', () {
    expect(
      displayNameFromAuthMetadata(<String, dynamic>{
        'display_name': 'Chosen Name',
        'full_name': 'Google Name',
      }, fallback: 'Sign-up Name'),
      'Chosen Name',
    );
  });

  test('local user can update a validated display name', () async {
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

  test(
    'local auth keeps demo flows deterministic and emits typed events',
    () async {
      final auth = AuthRepository();
      addTearDown(auth.dispose);

      final signInEvent = auth.events.first;
      final user = await auth.signIn('demo@example.com', 'planner');
      expect(user.id, isNotEmpty);
      expect((await signInEvent).type, AuthEventType.signedIn);

      final result = await auth.signUp(
        'new@example.com',
        'planner',
        'New User',
      );
      expect(result, isA<AuthenticatedSignUp>());
      expect(result.isAuthenticated, isTrue);

      await auth.resendSignupConfirmation('new@example.com');
      expect(auth.pendingLocalConfirmationEmail, 'new@example.com');
      await auth.requestPasswordReset('new@example.com');
      expect(await auth.updateRecoveredPassword('new-password'), isNotNull);

      final signOutEvent = auth.events.first;
      await auth.signOut();
      expect((await signOutEvent).type, AuthEventType.signedOut);
    },
  );

  test(
    'controller exposes pending confirmation as state, not an error',
    () async {
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
    },
  );

  test(
    'recovery password validation matches the eight-character UI rule',
    () async {
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
    },
  );

  test('controller enforces the same recovery password minimum', () async {
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

  test(
    'controller applies auth state events without trusting metadata for access',
    () async {
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
    },
  );

  test('password reset errors stay neutral about account existence', () async {
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
