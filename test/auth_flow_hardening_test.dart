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
  test('오래된 로그인 완료가 로그아웃 후 상태를 복원할 수 없다', () async {
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
  });

  test('로그아웃 후 오래된 로그인 이벤트를 새 로그인까지 차단한다', () async {
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
  });

  test('SDK가 로그아웃 이벤트를 먼저 내보내도 로그아웃 실패를 보존한다', () async {
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
  });

  test('새 직접 로그인이 진행 중인 로그아웃 완료를 기다린다', () async {
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

    // 로그아웃으로 비공개 UI는 이미 지워졌지만 원격 세션 취소는 아직
    // 진행 중이다. 이 로그인과 이전 세션이 경합하지 않게 한다.
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

  test('일반 로그아웃이 결과 전에 새 직접 로그인 이벤트를 허용한다', () async {
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
  });

  test('일반 로그아웃이 새 가입과 일치하는 이메일 확인을 허용한다', () async {
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
  });

  test('현재 사용자가 없어도 로그아웃 이벤트가 대기 로그인을 차단한다', () async {
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
  });

  test('오래된 가입 완료가 최신 인증 진행 표시를 덮어쓸 수 없다', () async {
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
  });

  test('오래된 재전송 및 재설정 finally 블록이 최신 상태를 보존한다', () async {
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

  test('OAuth가 종료 이벤트까지 진행 상태를 유지한 뒤 안전하게 해제된다', () async {
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

  test('OAuth 시간 초과가 안전한 한국어 문구와 함께 진행 상태를 해제한다', () async {
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

  test('시간 초과 후 늦은 OAuth 콜백이 직접 로그인을 앞설 수 없다', () async {
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
  });

  test('차단된 콜백 후 직접 로그인 실패가 SDK 세션을 취소한다', () async {
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

    // 명시적 로그인이 대기 중 작업을 소유하는 동안 공급자 콜백을 차단하고,
    // 실패 정리에 사용할 수 있도록 콜백이 관찰되었다는 사실은 기억한다.
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
  });

  test('새 로그인이 실행 전에 안전 실패형 SDK 세션 취소를 기다린다', () async {
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
  });

  test('직접 커밋 후 늦은 OAuth 콜백이 사용자를 교체할 수 없다', () async {
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

    // 시간 초과된 공급자 콜백은 신뢰할 수 없고 일치하지 않는 사용자다.
    // SDK 세션과 플래너 상태가 어긋나지 않도록 안전하게 실패 처리한다.
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
    );
    await _settle();
    expect(controller.user, isNull);
    expect(controller.authFlowState, AuthFlowState.signedOut);
    expect(auth.currentUser, isNull);
    expect(auth.signOutCalls, 1);
  });

  test('로그아웃이 차단된 사용자를 지우고 이후 직접 로그인이 소유권을 되찾는다', () async {
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

    // 시간 초과 시 소셜 로그인 차단 표식을 영구적으로 만든다. 이후 직접
    // 로그인은 Alice를 확정된 사용자로 명시적으로 설정할 수 있다.
    await controller.signInWithOAuth(SocialAuthProvider.google);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final aliceLogin = controller.signIn('alice@example.com', 'password');
    await _settle();
    auth.signInLoads.single.complete(_alice);
    await aliceLogin;
    expect(controller.user?.id, _alice.id);

    // 명시적 로그아웃은 이전에 예상한 사용자를 잊는다. 그 사용자에 대한
    // 지연 콜백은 계속 차단되어야 하며 사용자를 되살릴 수 없다.
    await controller.signOut();
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
    );
    await _settle();
    expect(controller.user, isNull);
    expect(controller.authFlowState, AuthFlowState.signedOut);

    // 이후 직접 로그인은 다른 계정을 설정할 수 있다. 새 소유자가 현재
    // 사용자로 유지되는 동안 그 계정 자체의 갱신은 허용한다.
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

    // 더 늦게 도착한 이전 Alice 계정의 콜백은 신뢰할 수 없다. 컨트롤러와
    // SDK의 계정 불일치를 유지하는 대신 SDK 세션을 취소하고 Bob도 지운다.
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
    );
    await _settle();
    expect(controller.user, isNull);
    expect(controller.authFlowState, AuthFlowState.signedOut);
    expect(auth.currentUser, isNull);
  });

  test('외부 로그아웃이 지연 콜백 전에 차단된 사용자를 지운다', () async {
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

    // 이 이벤트는 다른 탭이나 세션에서 올 수 있으므로 이전 OAuth 실행에
    // 기록된 사용자를 동기적으로 차단해야 한다.
    auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
    );
    await _settle();

    expect(controller.user, isNull);
    expect(controller.authFlowState, AuthFlowState.signedOut);
    expect(auth.currentUser, isNull);
    expect(auth.signOutCalls, greaterThanOrEqualTo(1));
  });

  test('시간 초과 후 새 OAuth 실행이 새 사용자를 소유할 수 있다', () async {
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

  test('OAuth 시간 초과 차단 후에도 비밀번호 복구를 사용할 수 있다', () async {
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
  });

  test('OAuth 시간 초과 차단 후 이메일 확인을 완료할 수 있다', () async {
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
  });

  test('OAuth 실행 자체에 시간 제한이 있고 늦은 실행이 진행 상태를 되살리지 못한다', () async {
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
  });

  test('빠른 로그인 및 사용자 갱신 이벤트 뒤에도 그룹을 불러온다', () async {
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

  test('빠른 비밀번호 복구 후 사용자 갱신이 복구 상태를 유지한다', () async {
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
  });

  test('빠른 비밀번호 복구 후 로그아웃이 비공개 상태를 지운다', () async {
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
  });

  test('로그아웃 인증 이벤트가 큐 실행 전에 비공개 상태를 지운다', () async {
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
  });
}
