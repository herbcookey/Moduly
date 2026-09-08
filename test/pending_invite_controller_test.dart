import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/demo_identity.dart';
import 'package:moduly/core/pending_invite_store.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/state/notification_state.dart';

const _token = '7K9MW3PXQ2RT';

class _InviteLocalRepository extends LocalScheduleRepository {
  int previewCalls = 0;
  int joinCalls = 0;
  Completer<InvitePreview>? previewGate;
  Completer<PlannerGroup>? joinGate;

  @override
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) async {
    previewCalls++;
    final gate = previewGate;
    if (gate != null) await gate.future;
    if (token != _token) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    return InvitePreview(
      groupId: 'demo-group',
      groupName: '우리 가족',
      groupDescription: '함께 정리하는 한 주',
      groupTimezone: 'Asia/Seoul',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      alreadyMember: false,
    );
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    joinCalls++;
    final gate = joinGate;
    if (gate != null) await gate.future;
    return (await groupsForUser(demoUserId)).single;
  }
}

class _TokenBearingRepository extends LocalScheduleRepository {
  static const group = PlannerGroup(
    id: 'token-bearing-group',
    name: 'Token group',
    timezone: 'UTC',
    ownerId: 'owner',
  );

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async =>
      userId == 'owner' ? <PlannerGroup>[group] : const <PlannerGroup>[];

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      const <PlannerMember>[
        PlannerMember(
          id: 'owner',
          name: 'Owner',
          email: 'owner@example.com',
          isOwner: true,
        ),
      ];

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(
    String userId,
    String groupId,
  ) => Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) =>
      const Stream<PlannerGroup?>.empty();

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async =>
      <InviteCode>[
        InviteCode(
          id: 'token-bearing-invite',
          groupId: groupId,
          expiresAt: DateTime.utc(2099),
          maxUses: 10,
          usesCount: 0,
          version: 1,
          token: 'SENSITIVE-PLAINTEXT-TOKEN',
        ),
      ];
}

class _DelayedCreateRepository extends LocalScheduleRepository {
  final Completer<InviteCode> createGate = Completer<InviteCode>();

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) => createGate.future;
}

class _CommittedFailureRepository extends _InviteLocalRepository {
  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    joinCalls++;
    throw const InviteJoinCommittedException();
  }
}

class _RevisionPreviewRepository extends LocalScheduleRepository {
  final List<Completer<InvitePreview>> previewGates =
      <Completer<InvitePreview>>[];
  int previewCalls = 0;

  @override
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) async {
    final call = previewCalls++;
    return previewGates[call].future;
  }
}

class _LateCommittedRepository extends _InviteLocalRepository {
  final Completer<void> committedGate = Completer<void>();

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    joinCalls++;
    await committedGate.future;
    throw const InviteJoinCommittedException();
  }
}

class _DelayedPendingInviteStore implements PendingInviteStore {
  final Completer<PendingInviteRecord?> readGate =
      Completer<PendingInviteRecord?>();
  PendingInviteRecord? current;
  int clearCalls = 0;

  @override
  Future<String?> read() async => (await readRecord())?.token;

  @override
  Future<PendingInviteRecord?> readRecord() => readGate.future;

  @override
  Future<void> write(String token, DateTime expiresAt) async {
    current = PendingInviteRecord(token: token, expiresAt: expiresAt);
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    current = null;
  }
}

class _InviteAuth extends AuthRepository {
  final StreamController<AuthRepositoryEvent> changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  PlannerUser? current;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => changes.stream;

  @override
  PlannerUser? get currentUser => current;

  void emit(AuthRepositoryEvent event) {
    if (event.type == AuthEventType.signedOut) {
      current = null;
    } else if (event.user != null) {
      current = event.user;
    }
    changes.add(event);
  }

  @override
  void dispose() {
    unawaited(changes.close());
    super.dispose();
  }
}

class _InviteNotificationSink implements NotificationInvalidationSink {
  final List<String> cancelledGroups = <String>[];
  final List<String> membershipGroups = <String>[];

  @override
  Future<void> cancelForGroup(String groupId) async {
    cancelledGroups.add(groupId);
  }

  @override
  Future<void> onAuthenticated(String userId) async {}

  @override
  Future<void> onEventChanged({String? eventId, String? groupId}) async {}

  @override
  Future<void> onMembershipChanged({String? eventId, String? groupId}) async {
    if (groupId != null) membershipGroups.add(groupId);
  }

  @override
  Future<void> onSignedOut() async {}

  @override
  Future<void> reconcile({DateTime? nowUtc}) async {}
}

class _RejoinAfterLeaveRepository extends _InviteLocalRepository {
  bool removed = false;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    if (removed) return const <PlannerGroup>[];
    return super.groupsForUser(userId);
  }

  @override
  Future<void> leaveGroup({
    required String actorId,
    required String groupId,
  }) async {
    removed = true;
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    removed = false;
    joinCalls++;
    return (await super.groupsForUser(userId)).single;
  }
}

void main() {
  test('메모리 대기 저장소가 TTL과 지우기를 적용한다', () async {
    final store = MemoryPendingInviteStore();
    final expiry = DateTime.now().toUtc().add(const Duration(minutes: 1));
    await store.write(_token, expiry);
    expect((await store.readRecord())?.token, _token);
    expect((await store.readRecord())?.expiresAt, expiry);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('대기 의도가 실시간으로 만료되고 폴링 없이 저장소를 지운다', () async {
    final store = MemoryPendingInviteStore();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: _InviteLocalRepository(),
      pendingInviteStore: store,
      pendingInviteTtl: const Duration(milliseconds: 30),
    );
    addTearDown(controller.dispose);

    expect(controller.captureInviteToken(_token), isTrue);
    expect(controller.hasPendingInvite, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(controller.hasPendingInvite, isFalse);
    expect(controller.pendingInvite?.expiresAt, isNull);
    expect(await store.readRecord(), isNull);
  });

  test('명시적 지우기가 늦은 복원 결과를 차단한다', () async {
    final store = _DelayedPendingInviteStore();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: _InviteLocalRepository(),
      pendingInviteStore: store,
    );
    addTearDown(controller.dispose);

    controller.clearPendingInvite();
    store.readGate.complete(
      PendingInviteRecord(
        token: _token,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.hasPendingInvite, isFalse);
    expect(store.clearCalls, greaterThanOrEqualTo(1));
  });

  test('초대 생성이 평문을 한 번 반환하지만 토큰 없는 행을 캐시한다', () async {
    final repository = LocalScheduleRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    await controller.loadGroups();
    controller.selectedGroup = controller.groups.single;

    final returned = await controller.createInviteCode();
    expect(returned.token, isNotNull);
    expect(controller.invites, hasLength(1));
    expect(controller.invites.single.token, isNull);
  });

  test('로그아웃 중 캡처하고 첫 로그인 후 미리보기를 표시한다', () async {
    final repository = _InviteLocalRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);

    expect(controller.captureInviteToken(_token), isTrue);
    expect(controller.hasPendingInvite, isTrue);
    await controller.signIn('demo@example.com', 'planner');
    await controller.previewPendingInvite();

    expect(repository.previewCalls, 1);
    expect(controller.pendingInvitePreview?.groupId, 'demo-group');
    expect(controller.pendingInvite?.preview?.groupTimezone, 'Asia/Seoul');
  });

  test('모든 초대 목록 할당이 토큰 포함 가짜 행을 제거한다', () async {
    final repository = _TokenBearingRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.user = const PlannerUser(
      id: 'owner',
      email: 'owner@example.com',
    );
    controller.groups = <PlannerGroup>[_TokenBearingRepository.group];
    await controller.selectGroup(_TokenBearingRepository.group.id);

    expect(controller.invites, hasLength(1));
    expect(controller.invites.single.token, isNull);
  });

  test('오래된 초대 생성이 평문 토큰을 반환하지 않는다', () async {
    final repository = _DelayedCreateRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    await controller.loadGroups();
    controller.selectedGroup = controller.groups.single;

    final creating = controller.createInviteCode();
    await Future<void>.delayed(Duration.zero);
    await controller.signOut();
    repository.createGate.complete(
      InviteCode(
        id: 'stale-invite',
        groupId: 'demo-group',
        expiresAt: DateTime.utc(2099),
        maxUses: 1,
        usesCount: 0,
        version: 1,
        token: _token,
      ),
    );

    await expectLater(creating, throwsA(isA<InviteOperationStaleException>()));
    expect(controller.invites, isEmpty);
    expect(controller.errorMessage, isNot(contains(_token)));
  });

  test('그룹 리비전 변경 후 오래된 초대 생성을 버린다', () async {
    final repository = _DelayedCreateRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    await controller.loadGroups();
    controller.selectedGroup = controller.groups.single;

    final creating = controller.createInviteCode();
    await Future<void>.delayed(Duration.zero);
    unawaited(controller.loadGroups());
    repository.createGate.complete(
      InviteCode(
        id: 'stale-revision-invite',
        groupId: 'demo-group',
        expiresAt: DateTime.utc(2099),
        maxUses: 1,
        usesCount: 0,
        version: 1,
        token: _token,
      ),
    );

    await expectLater(creating, throwsA(isA<InviteOperationStaleException>()));
    expect(controller.invites, isEmpty);
    expect(controller.errorMessage, isNot(contains(_token)));
  });

  test('주변 로그아웃 인증 이벤트가 로그아웃 상태의 의도를 지우지 않는다', () async {
    final auth = AuthRepository();
    final controller = PlannerController(
      auth: auth,
      repository: _InviteLocalRepository(),
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    controller.captureInviteToken(_token);
    await auth.signOut();
    expect(controller.hasPendingInvite, isTrue);
  });

  test('이후 사용자 전환이 대기 의도를 동기적으로 지운다', () async {
    final auth = _InviteAuth();
    final controller = PlannerController(
      auth: auth,
      repository: _InviteLocalRepository(),
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    addTearDown(auth.dispose);

    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.signedIn,
        user: PlannerUser(id: 'first-user', email: 'first@example.com'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    controller.captureInviteToken(_token);
    expect(controller.hasPendingInvite, isTrue);

    auth.emit(
      const AuthRepositoryEvent(
        type: AuthEventType.signedIn,
        user: PlannerUser(id: 'second-user', email: 'second@example.com'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.hasPendingInvite, isFalse);
  });

  test('중복 캡처가 멱등이고 최신 토큰이 오래된 작업을 대체한다', () async {
    final repository = _InviteLocalRepository()
      ..previewGate = Completer<InvitePreview>();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');

    expect(controller.captureInviteToken(_token), isTrue);
    expect(controller.captureInviteToken(_token), isTrue);
    final pending = controller.previewPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.previewCalls, 1);
    expect(controller.captureInviteToken('8K9MW3PXQ2RT'), isTrue);
    repository.previewGate!.complete(
      InvitePreview(
        groupId: 'demo-group',
        groupName: '우리 가족',
        groupDescription: '함께 정리하는 한 주',
        groupTimezone: 'Asia/Seoul',
        expiresAt: DateTime.utc(2099, 1, 1),
        alreadyMember: false,
      ),
    );
    expect(await pending, isNull);
    expect(controller.pendingInvitePreview, isNull);
    expect(controller.pendingInviteState, PendingInviteState.captured);
  });

  test('동시 미리보기가 한 세대에서 하나의 저장소 호출을 공유한다', () async {
    final repository = _InviteLocalRepository()
      ..previewGate = Completer<InvitePreview>();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);

    final first = controller.previewPendingInvite();
    final second = controller.previewPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.previewCalls, 1);
    repository.previewGate!.complete(
      InvitePreview(
        groupId: 'demo-group',
        groupName: '우리 가족',
        groupDescription: '함께 정리하는 한 주',
        groupTimezone: 'Asia/Seoul',
        expiresAt: DateTime.utc(2099),
        alreadyMember: false,
      ),
    );
    final results = await Future.wait(<Future<InvitePreview?>>[first, second]);
    expect(results[0], results[1]);
  });

  test('오래된 미리보기 종료가 최신 리비전 요청을 지울 수 없다', () async {
    final repository = _RevisionPreviewRepository()
      ..previewGates.add(Completer<InvitePreview>());
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);

    final first = controller.previewPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.previewCalls, 1);

    // loadGroups는 이 대기 토큰을 바꾸지 않고 플래너 리비전을 올리므로,
    // 두 번째 미리보기는 같은 세대/토큰에 대해 요청 식별자만 다른 새 요청이다.
    unawaited(controller.loadGroups());
    await Future<void>.delayed(Duration.zero);
    repository.previewGates.add(Completer<InvitePreview>());
    final second = controller.previewPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.previewCalls, 2);
    expect(controller.isPreviewingInvite, isTrue);
    expect(controller.pendingInviteState, PendingInviteState.loading);

    repository.previewGates[0].complete(
      InvitePreview(
        groupId: 'demo-group',
        groupName: '우리 가족',
        groupDescription: '함께 정리하는 한 주',
        groupTimezone: 'Asia/Seoul',
        expiresAt: DateTime.utc(2099),
        alreadyMember: false,
      ),
    );
    expect(await first, isNull);
    // F1의 finally가 F2를 끄거나 상태를 캡처 시점으로 되돌리면 안 된다.
    expect(controller.isPreviewingInvite, isTrue);
    expect(controller.pendingInviteState, PendingInviteState.loading);

    repository.previewGates[1].complete(
      InvitePreview(
        groupId: 'demo-group',
        groupName: '우리 가족',
        groupDescription: '함께 정리하는 한 주',
        groupTimezone: 'Asia/Seoul',
        expiresAt: DateTime.utc(2099),
        alreadyMember: false,
      ),
    );
    expect((await second)?.groupId, 'demo-group');
    expect(controller.isPreviewingInvite, isFalse);
  });

  test('명시적 수락을 멱등하게 보호하고 대기 상태를 지운다', () async {
    final repository = _InviteLocalRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);
    await controller.previewPendingInvite();
    final joined = await controller.acceptPendingInvite();
    expect(joined?.id, 'demo-group');
    expect(repository.joinCalls, 1);
    expect(controller.hasPendingInvite, isFalse);
    expect(controller.pendingInvite, isNull);
  });

  test('커밋된 참여의 투영 실패가 대기 상태를 지우고 재시도를 막는다', () async {
    final repository = _CommittedFailureRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);
    await controller.previewPendingInvite();

    await expectLater(
      controller.acceptPendingInvite(),
      throwsA(isA<InviteJoinCommittedException>()),
    );
    expect(controller.hasPendingInvite, isFalse);
    expect(controller.errorMessage, contains('완료되었지만'));
    expect(controller.errorMessage, isNot(contains(_token)));
    expect(await controller.acceptPendingInvite(), isNull);
    expect(repository.joinCalls, 1);
  });

  test('오래된 커밋 실패가 최신 토큰의 오류를 게시할 수 없다', () async {
    final repository = _LateCommittedRepository();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);
    await controller.previewPendingInvite();

    var notifications = 0;
    controller.addListener(() => notifications++);
    final acceptingA = controller.acceptPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.joinCalls, 1);

    const tokenB = '8K9MW3PXQ2RT';
    expect(controller.captureInviteToken(tokenB), isTrue);
    final notificationsAfterB = notifications;
    expect(controller.hasPendingInvite, isTrue);
    expect(controller.pendingInviteState, PendingInviteState.captured);

    repository.committedGate.complete();
    await expectLater(acceptingA, throwsA(isA<InviteJoinCommittedException>()));

    expect(controller.hasPendingInvite, isTrue);
    expect(controller.pendingInviteState, PendingInviteState.captured);
    expect(controller.pendingInviteError, isNull);
    expect(controller.errorMessage, isNull);
    expect(notifications, notificationsAfterB);
    expect(await controller.acceptPendingInvite(), isNull);
    expect(repository.joinCalls, 1);
  });

  test('그룹 리비전이 오래된 미리보기와 커밋된 수락을 한 번 무효화한다', () async {
    final repository = _InviteLocalRepository()
      ..previewGate = Completer<InvitePreview>()
      ..joinGate = Completer<PlannerGroup>();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);
    await controller.signIn('demo@example.com', 'planner');

    controller.captureInviteToken(_token);
    final previewing = controller.previewPendingInvite();
    await Future<void>.delayed(Duration.zero);
    // 플래너 새로 고침은 더 최신 그룹 컨텍스트지만 대기 중인 의도 자체를
    // 지우지는 않는다.
    unawaited(controller.loadGroups());
    repository.previewGate!.complete(
      InvitePreview(
        groupId: 'demo-group',
        groupName: '우리 가족',
        groupDescription: '함께 정리하는 한 주',
        groupTimezone: 'Asia/Seoul',
        expiresAt: DateTime.utc(2099, 1, 1),
        alreadyMember: false,
      ),
    );
    expect(await previewing, isNull);
    expect(controller.pendingInviteState, PendingInviteState.captured);

    // 현재 플래너 리비전을 기준으로 재시도한 뒤 수락이 진행되는 동안 해당
    // 리비전을 오래된 상태로 만든다. 커밋은 정확한 토큰을 지우므로 두 번째
    // 수락이 join을 다시 호출할 수 없다.
    await controller.previewPendingInvite();
    final accepting = controller.acceptPendingInvite();
    await Future<void>.delayed(Duration.zero);
    unawaited(controller.loadGroups());
    repository.joinGate!.complete(
      (await repository.groupsForUser(demoUserId)).single,
    );
    expect(await accepting, isNull);
    expect(controller.hasPendingInvite, isFalse);
    expect(repository.joinCalls, 1);
    expect(await controller.acceptPendingInvite(), isNull);
    expect(repository.joinCalls, 1);
  });

  test('초대 수락이 다시 불러오기 전에 탈퇴 차단 표식을 제거하고 알림을 무효화한다', () async {
    final repository = _RejoinAfterLeaveRepository();
    final notifications = _InviteNotificationSink();
    final controller = PlannerController(
      auth: AuthRepository(),
      repository: repository,
      notifications: notifications,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(controller.dispose);

    await controller.signIn('demo@example.com', 'planner');
    await controller.selectGroup('demo-group');
    await controller.leaveGroup();
    expect(repository.removed, isTrue);
    expect(controller.groups, isEmpty);

    controller.captureInviteToken(_token);
    await controller.previewPendingInvite();
    final joined = await controller.acceptPendingInvite();
    expect(joined?.id, 'demo-group');
    expect(notifications.membershipGroups, <String>['demo-group']);

    // 이제 저장소가 참여한 그룹을 다시 노출한다. 이후 권위 있는 로드에서
    // 이전 탈퇴 차단 표식으로 이 그룹을 걸러내면 안 된다.
    await controller.loadGroups();
    expect(controller.groups.map((group) => group.id), <String>['demo-group']);
  });

  test('계정 전환 후 오래된 초대 수락이 그룹을 복원하거나 알림을 보낼 수 없다', () async {
    final auth = _InviteAuth();
    final repository = _InviteLocalRepository()
      ..joinGate = Completer<PlannerGroup>();
    final notifications = _InviteNotificationSink();
    final controller = PlannerController(
      auth: auth,
      repository: repository,
      notifications: notifications,
      pendingInviteStore: MemoryPendingInviteStore(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });

    await controller.signIn('demo@example.com', 'planner');
    controller.captureInviteToken(_token);
    await controller.previewPendingInvite();
    final accepting = controller.acceptPendingInvite();
    await Future<void>.delayed(Duration.zero);
    expect(repository.joinCalls, 1);

    final userB = const PlannerUser(id: 'user-b', email: 'user-b@example.com');
    auth.emit(AuthRepositoryEvent(type: AuthEventType.signedIn, user: userB));
    await Future<void>.delayed(Duration.zero);
    repository.joinGate!.complete(
      const PlannerGroup(
        id: 'demo-group',
        name: '우리 가족',
        timezone: 'Asia/Seoul',
      ),
    );
    expect(await accepting, isNull);
    await Future<void>.delayed(Duration.zero);

    expect(controller.user?.id, 'user-b');
    expect(controller.groups, isEmpty);
    expect(notifications.membershipGroups, isEmpty);
  });
}
