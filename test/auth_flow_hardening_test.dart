import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _alice = PlannerUser(id: 'alice', email: 'alice@example.com');
const _bob = PlannerUser(id: 'bob', email: 'bob@example.com');
const _group = PlannerGroup(id: 'group-a', name: 'A', timezone: 'UTC');

class _AuthDouble extends AuthRepository {
  _AuthDouble() : super();

  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  final List<Completer<PlannerUser>> signInLoads = <Completer<PlannerUser>>[];
  final List<Completer<AuthSignUpResult>> signUpLoads =
      <Completer<AuthSignUpResult>>[];
  final List<Completer<void>> resendLoads = <Completer<void>>[];
  final List<Completer<void>> resetLoads = <Completer<void>>[];
  PlannerUser? _currentUser;
  int oauthCalls = 0;
  int signOutCalls = 0;
  bool oauthLaunchResult = true;
  Completer<bool>? oauthGate;
  Completer<void>? signOutGate;
  bool emitSignedOutBeforeSignOutGate = false;
  bool emitSignedOutBeforeSignOutError = false;
  Object? signOutError;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _changes.stream;

  @override
  PlannerUser? get currentUser => _currentUser;

  @override
  Future<PlannerUser> signIn(String email, String password) {
    final load = Completer<PlannerUser>();
    signInLoads.add(load);
    return load.future.then((authenticated) {
      _currentUser = authenticated;
      return authenticated;
    });
  }

  @override
  Future<AuthSignUpResult> signUp(String email, String password, String name) {
    final load = Completer<AuthSignUpResult>();
    signUpLoads.add(load);
    return load.future;
  }

  @override
  Future<void> resendSignupConfirmation(String email) {
    final load = Completer<void>();
    resendLoads.add(load);
    return load.future;
  }

  @override
  Future<void> requestPasswordReset(String email) {
    final load = Completer<void>();
    resetLoads.add(load);
    return load.future;
  }

  @override
  Future<bool> signInWithOAuth(
    SocialAuthProvider provider, {
    String? redirectTo,
  }) async {
    oauthCalls++;
    final gate = oauthGate;
    if (gate != null) return gate.future;
    return oauthLaunchResult;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _currentUser = null;
    if (emitSignedOutBeforeSignOutGate) {
      emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    }
    final gate = signOutGate;
    if (gate != null) await gate.future;
    if (emitSignedOutBeforeSignOutError) {
      emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    }
    final error = signOutError;
    if (error != null) throw error;
    await super.signOut();
  }

  void emit(AuthRepositoryEvent event) {
    if (event.type == AuthEventType.signedOut) {
      _currentUser = null;
    } else if (event.user != null) {
      _currentUser = event.user;
    }
    _changes.add(event);
  }

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

class _GroupDouble extends LocalScheduleRepository {
  final List<Completer<List<PlannerGroup>>> groupLoads =
      <Completer<List<PlannerGroup>>>[];

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) {
    final load = Completer<List<PlannerGroup>>();
    groupLoads.add(load);
    return load.future;
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) =>
      Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'stale sign-in completion cannot restore state after sign-out',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      final signingIn = controller.signIn('alice@example.com', 'password');
      await _settle();
      expect(controller.isSaving, isTrue);

      await controller.signOut();
      auth.signInLoads.single.complete(_alice);
      await signingIn;

      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(controller.isSaving, isFalse);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, greaterThanOrEqualTo(1));
    },
  );

  test(
    'stale signed-in event after sign-out is fenced until a new login',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      final signingIn = controller.signIn('alice@example.com', 'password');
      await _settle();
      await controller.signOut();
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, greaterThanOrEqualTo(1));

      auth.signInLoads.single.complete(_alice);
      await signingIn;
      expect(controller.user, isNull);
      expect(controller.isSaving, isFalse);
      expect(auth.currentUser, isNull);
    },
  );

  test(
    'sign-out preserves its failure when SDK emits signed-out first',
    () async {
      final auth = _AuthDouble()
        ..emitSignedOutBeforeSignOutError = true
        ..signOutError = const AuthException('network');
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_group];
      controller.selectedGroup = _group;
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'private-signout-failure',
          groupId: _group.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      ];

      await expectLater(
        controller.signOut(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            authSessionErrorMessage,
          ),
        ),
      );
      await _settle();

      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.events, isEmpty);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(controller.errorMessage, authSessionErrorMessage);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, 1);
    },
  );

  test('new direct login waits for a pending sign-out settlement', () async {
    final auth = _AuthDouble()
      ..signOutGate = Completer<void>()
      ..emitSignedOutBeforeSignOutGate = true;
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();

    final signingOut = controller.signOut();
    await _settle();
    expect(auth.signOutCalls, 1);

    // The sign-out has already cleared the private UI, but its remote
    // revoke is still pending. Do not let this login race that old session.
    final signingIn = controller.signIn('alice@example.com', 'password');
    await _settle();
    expect(auth.signInLoads, isEmpty);

    auth.signOutGate!.complete();
    await signingOut;
    await _settle();
    expect(auth.signInLoads, hasLength(1));

    auth.signInLoads.single.complete(_alice);
    await signingIn;
    expect(controller.user?.id, _alice.id);
    expect(controller.authFlowState, AuthFlowState.signedIn);
    expect(auth.currentUser?.id, _alice.id);
  });

  test(
    'ordinary sign-out permits a new direct login event before its result',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signOut();
      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      await _settle();
      expect(controller.isSaving, isTrue);

      auth.signInLoads.single.complete(_alice);
      await direct;
      expect(controller.user?.id, _alice.id);
      expect(auth.currentUser?.id, _alice.id);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'ordinary sign-out permits matching email confirmation for a new signup',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signOut();
      final signingUp = controller.signUp(
        'pending@example.com',
        'password',
        'Pending',
      );
      await _settle();
      auth.signUpLoads.single.complete(
        const PendingEmailConfirmation(email: 'pending@example.com'),
      );
      await signingUp;
      expect(controller.authFlowState, AuthFlowState.pendingEmailConfirmation);

      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.signedIn,
          user: PlannerUser(id: 'pending-user', email: 'pending@example.com'),
        ),
      );
      await _settle();
      expect(controller.user?.id, 'pending-user');
      expect(controller.authFlowState, AuthFlowState.signedIn);
    },
  );

  test(
    'signed-out event fences a pending sign-in even with no current identity',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      final signingIn = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      auth.signInLoads.single.complete(_alice);
      await signingIn;
      await _settle();

      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'stale sign-up completion cannot overwrite a newer auth spinner',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      final first = controller.signUp('first@example.com', 'password', 'First');
      await _settle();
      final second = controller.signUp(
        'second@example.com',
        'password',
        'Second',
      );
      await _settle();
      auth.signUpLoads[0].complete(AuthenticatedSignUp(user: _alice));
      await first;
      expect(controller.isSaving, isTrue);
      auth.signUpLoads[1].complete(AuthenticatedSignUp(user: _bob));
      await second;
      expect(controller.user?.id, _bob.id);
      expect(controller.isSaving, isFalse);
    },
  );

  test('stale resend and reset finally blocks preserve newer state', () async {
    final auth = _AuthDouble();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();
    controller.pendingConfirmationEmail = 'pending@example.com';

    final resend = controller.resendSignupConfirmation();
    await _settle();
    final reset = controller.requestPasswordReset('reset@example.com');
    await _settle();
    auth.resendLoads.single.complete();
    await resend;
    expect(controller.isSaving, isTrue);
    auth.resetLoads.single.complete();
    await reset;

    expect(controller.pendingConfirmationEmail, 'pending@example.com');
    expect(controller.passwordResetRequestedEmail, 'reset@example.com');
    expect(controller.isSaving, isFalse);
  });

  test('OAuth remains busy until terminal event, then clears safely', () async {
    final auth = _AuthDouble();
    final repository = _GroupDouble();
    final controller = PlannerController(
      auth: auth,
      repository: repository,
      oauthTimeout: const Duration(seconds: 1),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();

    await controller.signInWithOAuth(SocialAuthProvider.google);
    expect(auth.oauthCalls, 1);
    expect(controller.isSocialAuthInFlight, isTrue);
    expect(controller.isSaving, isTrue);

    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
    );
    await _settle();
    expect(controller.isSocialAuthInFlight, isFalse);
    expect(controller.isSaving, isFalse);
    expect(controller.user?.id, _alice.id);
  });

  test('OAuth timeout clears busy state with safe Korean copy', () async {
    final auth = _AuthDouble();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
      oauthTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();

    await controller.signInWithOAuth(SocialAuthProvider.google);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.isSocialAuthInFlight, isFalse);
    expect(controller.isSaving, isFalse);
    expect(controller.errorMessage, socialAuthTimeoutMessage);
  });

  test(
    'late OAuth callback after timeout cannot beat a direct sign-in',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.errorMessage, socialAuthTimeoutMessage);
      expect(controller.user, isNull);

      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(controller.isSaving, isTrue);

      auth.signInLoads.single.complete(_alice);
      await direct;
      expect(controller.user?.id, _alice.id);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'a failed direct login after a fenced callback revokes the SDK session',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();

      // The provider callback is fenced while the explicit login owns the
      // pending operation; its observation is remembered for failure cleanup.
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(auth.signOutCalls, 0);

      auth.signInLoads.single.completeError(
        const AuthException(authSignInErrorMessage),
      );
      await expectLater(direct, throwsA(isA<AuthException>()));
      await _settle();

      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(controller.isSaving, isFalse);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, 1);
    },
  );

  test(
    'new login waits for fail-closed SDK revocation before launching',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.signInLoads.single.complete(_alice);
      await direct;

      auth.signOutGate = Completer<void>();
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
      );
      await _settle();
      expect(auth.signOutCalls, 1);

      final retry = controller.signIn('bob@example.com', 'password');
      await _settle();
      expect(auth.signInLoads, hasLength(1));

      auth.signOutGate!.complete();
      await _settle();
      expect(auth.signInLoads, hasLength(2));
      auth.signInLoads.last.complete(_bob);
      await retry;
      expect(controller.user?.id, _bob.id);
    },
  );

  test(
    'a late OAuth callback cannot replace an identity after direct commit',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.signInLoads.single.complete(_alice);
      await direct;
      expect(controller.user?.id, _alice.id);

      // The timed-out provider callback is an untrusted, mismatched
      // identity. Fail closed so the SDK session and planner cannot diverge.
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, 1);
    },
  );

  test(
    'sign-out clears fenced identity and later direct login reclaims ownership',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      // Timeout creates the persistent social tombstone. A direct login may
      // then explicitly claim Alice as the committed identity.
      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final aliceLogin = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.signInLoads.single.complete(_alice);
      await aliceLogin;
      expect(controller.user?.id, _alice.id);

      // Explicit sign-out forgets the prior expected identity. A delayed
      // callback for that identity must remain fenced and cannot resurrect it.
      await controller.signOut();
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);

      // A subsequent direct login can claim a different account. Its own
      // update is accepted while the new owner is current.
      final bobLogin = controller.signIn('bob@example.com', 'password');
      await _settle();
      auth.signInLoads.last.complete(_bob);
      await bobLogin;
      expect(controller.user?.id, _bob.id);
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.userUpdated,
          user: PlannerUser(
            id: 'bob',
            email: 'bob@example.com',
            displayName: 'Bob Updated',
          ),
        ),
      );
      await _settle();
      expect(controller.user?.displayName, 'Bob Updated');

      // A still-later callback for the old Alice account is untrusted. It
      // revokes the SDK session and clears Bob too, rather than preserving a
      // controller/SDK account mismatch.
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      await _settle();
      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(auth.currentUser, isNull);
    },
  );

  test(
    'external signed-out clears fenced identity before a delayed callback',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final direct = controller.signIn('alice@example.com', 'password');
      await _settle();
      auth.signInLoads.single.complete(_alice);
      await direct;
      expect(controller.user?.id, _alice.id);

      // This event may come from another tab/session and must synchronously
      // fence the identity recorded for the old OAuth launch.
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      await _settle();

      expect(controller.user, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(auth.currentUser, isNull);
      expect(auth.signOutCalls, greaterThanOrEqualTo(1));
    },
  );

  test('a fresh OAuth launch after timeout can own a new identity', () async {
    final auth = _AuthDouble();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
      oauthTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();

    await controller.signInWithOAuth(SocialAuthProvider.google);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.errorMessage, socialAuthTimeoutMessage);

    await controller.signInWithOAuth(SocialAuthProvider.apple);
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
    );
    await _settle();
    expect(controller.user?.id, _bob.id);
    expect(controller.isSocialAuthInFlight, isFalse);
  });

  test(
    'password recovery remains available after an OAuth timeout fence',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.passwordRecovery,
          user: _bob,
        ),
      );
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.userUpdated,
          user: PlannerUser(
            id: 'bob',
            email: 'bob@example.com',
            displayName: 'Recovered',
          ),
        ),
      );
      await _settle();

      expect(controller.authFlowState, AuthFlowState.passwordRecovery);
      expect(controller.user?.displayName, 'Recovered');
    },
  );

  test(
    'email confirmation can complete after an OAuth timeout fence',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      await controller.signInWithOAuth(SocialAuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final signingUp = controller.signUp(
        'pending@example.com',
        'password',
        'Pending',
      );
      await _settle();
      auth.signUpLoads.single.complete(
        const PendingEmailConfirmation(email: 'pending@example.com'),
      );
      await signingUp;

      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.signedIn,
          user: PlannerUser(
            id: 'pending-user',
            email: 'pending@example.com',
            displayName: 'Pending',
          ),
        ),
      );
      await _settle();
      expect(controller.user?.id, 'pending-user');
      expect(controller.authFlowState, AuthFlowState.signedIn);
    },
  );

  test(
    'OAuth launch itself is bounded and late launch cannot resurrect busy state',
    () async {
      final auth = _AuthDouble()..oauthGate = Completer<bool>();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
        oauthTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      final launch = controller.signInWithOAuth(SocialAuthProvider.google);
      await expectLater(
        launch,
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            socialAuthTimeoutMessage,
          ),
        ),
      );
      expect(controller.isSocialAuthInFlight, isFalse);
      expect(controller.isSaving, isFalse);
      expect(controller.errorMessage, socialAuthTimeoutMessage);

      auth.oauthGate!.complete(true);
      await _settle();
      expect(controller.user, isNull);
      expect(controller.isSaving, isFalse);
    },
  );

  test('rapid signed-in then user-updated events still load groups', () async {
    final auth = _AuthDouble();
    final repository = _GroupDouble();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settle();

    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
    );
    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.userUpdated,
        user: PlannerUser(
          id: 'alice',
          email: 'alice@example.com',
          displayName: 'Updated',
        ),
      ),
    );
    await _settle();
    expect(repository.groupLoads, hasLength(1));
    repository.groupLoads.single.complete(const <PlannerGroup>[_group]);
    await _settle();

    expect(controller.user?.displayName, 'Updated');
    expect(controller.groups.map((group) => group.id), <String>[_group.id]);
  });

  test(
    'rapid password-recovery then user-updated keeps recovery state',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();

      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.passwordRecovery,
          user: _alice,
        ),
      );
      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.userUpdated,
          user: PlannerUser(
            id: 'alice',
            email: 'alice@example.com',
            displayName: 'Recovery User',
          ),
        ),
      );
      await _settle();

      expect(controller.authFlowState, AuthFlowState.passwordRecovery);
      expect(controller.user?.displayName, 'Recovery User');
    },
  );

  test(
    'rapid password-recovery then signed-out clears private state',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_group];
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'recovery-private',
          groupId: _group.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      ];

      auth.emit(
        const AuthRepositoryEvent(
          type: AuthEventType.passwordRecovery,
          user: _alice,
        ),
      );
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await _settle();

      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.events, isEmpty);
    },
  );

  test(
    'signed-out auth event clears private state before its queue runs',
    () async {
      final auth = _AuthDouble();
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settle();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_group];
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'private',
          groupId: _group.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      ];
      var notifications = 0;
      controller.addListener(() => notifications++);

      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await _settle();
      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.events, isEmpty);
      expect(notifications, greaterThan(0));
    },
  );
}
