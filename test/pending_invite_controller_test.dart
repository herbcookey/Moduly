import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/demo_identity.dart';
import 'package:moduly/core/pending_invite_store.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

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

void main() {
  test('memory pending store enforces TTL and clear', () async {
    final store = MemoryPendingInviteStore();
    final expiry = DateTime.now().toUtc().add(const Duration(minutes: 1));
    await store.write(_token, expiry);
    expect((await store.readRecord())?.token, _token);
    expect((await store.readRecord())?.expiresAt, expiry);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test(
    'pending intent expires live and clears its store without polling',
    () async {
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
    },
  );

  test('explicit clear fences a slow hydration result', () async {
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

  test(
    'invite creation returns plaintext once but caches a token-free row',
    () async {
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
    },
  );

  test('captures while signed out and previews after first login', () async {
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

  test('all invite list assignments strip token-bearing fake rows', () async {
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

  test('stale invite creation never returns its plaintext token', () async {
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

  test(
    'stale invite creation is discarded after a group revision changes',
    () async {
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

      await expectLater(
        creating,
        throwsA(isA<InviteOperationStaleException>()),
      );
      expect(controller.invites, isEmpty);
      expect(controller.errorMessage, isNot(contains(_token)));
    },
  );

  test(
    'ambient signed-out auth event does not erase a logged-out intent',
    () async {
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
    },
  );

  test(
    'a subsequent identity switch clears the pending intent synchronously',
    () async {
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
    },
  );

  test(
    'duplicate capture is idempotent and a newer token supersedes stale work',
    () async {
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
    },
  );

  test(
    'concurrent previews share one repository call for one generation',
    () async {
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
      final results = await Future.wait(<Future<InvitePreview?>>[
        first,
        second,
      ]);
      expect(results[0], results[1]);
    },
  );

  test(
    'stale preview finalization cannot clear a newer revision request',
    () async {
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

      // loadGroups advances the planner revision without replacing this
      // pending token, so the second preview is a new request for the same
      // generation/token with a distinct request identity.
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
      // F1's finally must not turn off F2 or roll its state back to captured.
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
    },
  );

  test('explicit accept is idempotently guarded and clears pending', () async {
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

  test(
    'committed join projection failure clears pending and forbids retry',
    () async {
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
    },
  );

  test(
    'a stale committed failure cannot publish an error for a newer token',
    () async {
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
      await expectLater(
        acceptingA,
        throwsA(isA<InviteJoinCommittedException>()),
      );

      expect(controller.hasPendingInvite, isTrue);
      expect(controller.pendingInviteState, PendingInviteState.captured);
      expect(controller.pendingInviteError, isNull);
      expect(controller.errorMessage, isNull);
      expect(notifications, notificationsAfterB);
      expect(await controller.acceptPendingInvite(), isNull);
      expect(repository.joinCalls, 1);
    },
  );

  test(
    'group revision invalidates stale preview and committed accept once',
    () async {
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
      // A planner refresh is a newer group context but does not clear the
      // pending intent itself.
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

      // Retry against the current planner revision, then make that revision
      // stale while acceptance is in flight. The commit clears the exact
      // token, so a second accept cannot call join again.
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
    },
  );
}
