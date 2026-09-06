import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _alice = PlannerUser(id: 'alice', email: 'alice@example.com');
const _bob = PlannerUser(id: 'bob', email: 'bob@example.com');
const _groupA = PlannerGroup(id: 'group-a', name: 'A', timezone: 'UTC');
const _groupB = PlannerGroup(id: 'group-b', name: 'B', timezone: 'UTC');

class _ControlledAuth extends AuthRepository {
  _ControlledAuth() : super();

  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  PlannerUser? _currentUser;
  Object? signOutError;
  Completer<PlannerUser>? displayNameLoad;
  Completer<PlannerUser>? recoveredPasswordLoad;

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
  Future<PlannerUser> updateDisplayName(String displayName) {
    final load = displayNameLoad;
    if (load != null) return load.future;
    return Future<PlannerUser>.value(
      _currentUser ?? const PlannerUser(id: 'unknown', email: 'unknown'),
    );
  }

  @override
  Future<PlannerUser> updateRecoveredPassword(String password) {
    final load = recoveredPasswordLoad;
    if (load != null) return load.future;
    return Future<PlannerUser>.value(
      _currentUser ?? const PlannerUser(id: 'unknown', email: 'unknown'),
    );
  }

  @override
  Future<void> signOut() async {
    final error = signOutError;
    if (error != null) throw error;
  }

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

class _ControlledScheduleRepository extends LocalScheduleRepository {
  final List<Completer<List<PlannerGroup>>> groupLoads =
      <Completer<List<PlannerGroup>>>[];
  final Map<String, Completer<List<PlannerMember>>> memberLoads =
      <String, Completer<List<PlannerMember>>>{};
  final Map<String, List<PlannerMember>> immediateMembers =
      <String, List<PlannerMember>>{};
  Completer<InviteCode>? inviteLoad;
  InviteCode? inviteResult;
  final List<Completer<PlannerGroup>> createGroupLoads =
      <Completer<PlannerGroup>>[];
  PlannerEvent? updatedEvent;
  Completer<PlannerGroup>? createGroupLoad;
  PlannerGroup? createGroupResult;
  int createGroupCalls = 0;
  final List<Completer<PlannerGroup>> joinGroupLoads =
      <Completer<PlannerGroup>>[];
  Completer<PlannerGroup>? joinGroupLoad;
  PlannerGroup? joinGroupResult;
  int joinGroupCalls = 0;
  Completer<PlannerEvent>? createEventLoad;
  final List<Completer<PlannerEvent>> createEventLoads =
      <Completer<PlannerEvent>>[];
  PlannerEvent? createEventResult;

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  ) {
    createGroupCalls++;
    if (createGroupLoads.isNotEmpty) {
      return createGroupLoads.removeAt(0).future;
    }
    final load = createGroupLoad;
    if (load != null) return load.future;
    return Future<PlannerGroup>.value(
      createGroupResult ??
          const PlannerGroup(id: 'created-group', name: 'Created'),
    );
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) {
    joinGroupCalls++;
    if (joinGroupLoads.isNotEmpty) {
      return joinGroupLoads.removeAt(0).future;
    }
    final load = joinGroupLoad;
    if (load != null) return load.future;
    return Future<PlannerGroup>.value(
      joinGroupResult ?? const PlannerGroup(id: 'joined-group', name: 'Joined'),
    );
  }

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) {
    final load = Completer<List<PlannerGroup>>();
    groupLoads.add(load);
    return load.future;
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) {
    final load = memberLoads[groupId];
    if (load != null) return load.future;
    return Future<List<PlannerMember>>.value(
      immediateMembers[groupId] ?? const <PlannerMember>[],
    );
  }

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) {
    final load = inviteLoad;
    if (load != null) return load.future;
    final now = DateTime.now().toUtc();
    return Future<InviteCode>.value(
      inviteResult ??
          InviteCode(
            id: 'invite-1',
            groupId: groupId,
            expiresAt: now.add(ttl),
            maxUses: maxUses,
            usesCount: 0,
            version: 1,
            token: 'invite-token',
            createdAt: now,
            updatedAt: now,
          ),
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) =>
      Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) {
    if (createEventLoads.isNotEmpty) {
      return createEventLoads.removeAt(0).future;
    }
    final load = createEventLoad;
    if (load != null) return load.future;
    return Future<PlannerEvent>.value(
      createEventResult ??
          PlannerEvent(
            id: 'created-event',
            groupId: groupId,
            title: draft.title,
            startAt: draft.startAt,
            endAt: draft.endAt,
            ownerId: userId,
            timezone: draft.timezone,
          ),
    );
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    updatedEvent = event.copyWith(version: expectedVersion + 1);
    return updatedEvent!;
  }
}

Future<void> _settleControllerBootstrap() async {
  await Future<void>.delayed(Duration.zero);
}

PlannerMember _owner(String id) =>
    PlannerMember(id: id, name: id, email: '$id@example.com', isOwner: true);

void main() {
  test('loadGroups ignores a result that completes after sign-out', () async {
    final auth = _ControlledAuth();
    final repository = _ControlledScheduleRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();

    controller.user = _alice;
    controller.groups = const <PlannerGroup>[_groupA];
    controller.selectedGroup = _groupA;
    controller.events = <PlannerEvent>[
      PlannerEvent(
        id: 'private-event',
        groupId: _groupA.id,
        title: 'Private',
        startAt: DateTime.utc(2026, 1, 1, 9),
        endAt: DateTime.utc(2026, 1, 1, 10),
        ownerId: _alice.id,
      ),
    ];

    final loading = controller.loadGroups();
    expect(repository.groupLoads, hasLength(1));

    auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    await Future<void>.delayed(Duration.zero);
    repository.groupLoads.single.complete(const <PlannerGroup>[_groupA]);
    await loading;

    expect(controller.user, isNull);
    expect(controller.groups, isEmpty);
    expect(controller.selectedGroup, isNull);
    expect(controller.events, isEmpty);
  });

  test('only the newest overlapping loadGroups call may commit', () async {
    final auth = _ControlledAuth();
    final repository = _ControlledScheduleRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();
    controller.user = _alice;

    final first = controller.loadGroups();
    final second = controller.loadGroups();
    expect(repository.groupLoads, hasLength(2));

    repository.groupLoads[1].complete(const <PlannerGroup>[_groupB]);
    await second;
    repository.groupLoads[0].complete(const <PlannerGroup>[_groupA]);
    await first;

    expect(controller.groups.map((group) => group.id), <String>[_groupB.id]);
    expect(controller.isLoading, isFalse);
  });

  test(
    'a removed selection clears all group-scoped caches on refresh',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_groupA];
      controller.selectedGroup = _groupA;
      controller.members = <PlannerMember>[_owner(_alice.id)];
      controller.invites = <InviteCode>[
        InviteCode(
          id: 'invite-1',
          groupId: _groupA.id,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          maxUses: 1,
          usesCount: 0,
          version: 1,
        ),
      ];
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'event-1',
          groupId: _groupA.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      ];

      final refresh = controller.loadGroups();
      repository.groupLoads.single.complete(const <PlannerGroup>[]);
      await refresh;

      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.members, isEmpty);
      expect(controller.invites, isEmpty);
      expect(controller.events, isEmpty);
      expect(controller.isLoading, isFalse);
    },
  );

  test(
    'selectGroup commits only the latest overlapping group switch',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_groupA, _groupB];
      repository.memberLoads[_groupA.id] = Completer<List<PlannerMember>>();
      repository.immediateMembers[_groupB.id] = <PlannerMember>[
        _owner(_alice.id),
      ];

      final first = controller.selectGroup(_groupA.id);
      await Future<void>.delayed(Duration.zero);
      final second = controller.selectGroup(_groupB.id);
      await second;

      repository.memberLoads[_groupA.id]!.complete(<PlannerMember>[
        _owner(_alice.id),
        const PlannerMember(
          id: 'member-a',
          name: 'A member',
          email: 'a@example.com',
        ),
      ]);
      await first;

      expect(controller.selectedGroup?.id, _groupB.id);
      expect(controller.members.map((member) => member.id), <String>[
        _alice.id,
      ]);
      expect(controller.events, isEmpty);
    },
  );

  test('auth user changes invalidate an in-flight group load', () async {
    final auth = _ControlledAuth();
    final repository = _ControlledScheduleRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();
    controller.user = _alice;

    final oldLoad = controller.loadGroups();
    auth.emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _bob),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(repository.groupLoads, hasLength(2));

    repository.groupLoads[0].complete(const <PlannerGroup>[_groupA]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.groups, isEmpty);

    repository.groupLoads[1].complete(const <PlannerGroup>[_groupB]);
    await oldLoad;
    await Future<void>.delayed(Duration.zero);

    expect(controller.user?.id, _bob.id);
    expect(controller.groups.map((group) => group.id), <String>[_groupB.id]);
  });

  test(
    'stale createGroup completion cannot restore data after sign-out',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository()
        ..createGroupLoad = Completer<PlannerGroup>()
        ..createGroupResult = _groupB;
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;

      final creating = controller.createGroup('B', 'description');
      await Future<void>.delayed(Duration.zero);
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await Future<void>.delayed(Duration.zero);
      repository.createGroupLoad!.complete(_groupB);
      await creating;

      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'stale joinGroup completion cannot restore data after sign-out',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository()
        ..joinGroupLoad = Completer<PlannerGroup>()
        ..joinGroupResult = _groupB;
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;

      final joining = controller.joinGroup('invite-token');
      await Future<void>.delayed(Duration.zero);
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await Future<void>.delayed(Duration.zero);
      repository.joinGroupLoad!.complete(_groupB);
      await joining;

      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'createGroup rejects duplicate submits and preserves a new session guard',
    () async {
      final auth = _ControlledAuth();
      final firstLoad = Completer<PlannerGroup>();
      final secondLoad = Completer<PlannerGroup>();
      final repository = _ControlledScheduleRepository()
        ..createGroupLoads.addAll(<Completer<PlannerGroup>>[
          firstLoad,
          secondLoad,
        ]);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;

      final first = controller.createGroup('First', '');
      await Future<void>.delayed(Duration.zero);
      expect(controller.isSaving, isTrue);
      await expectLater(
        controller.createGroup('Duplicate', ''),
        throwsA(isA<ScheduleConflictException>()),
      );
      expect(repository.createGroupCalls, 1);

      // A sign-out clears the ownership token. A new session may start its
      // own group operation while the stale first request is still pending.
      await controller.signOut();
      controller.user = _bob;
      final next = controller.createGroup('Second', '');
      await Future<void>.delayed(Duration.zero);
      expect(repository.createGroupCalls, 2);

      firstLoad.complete(_groupA);
      await first;
      // The stale first finally block must not clear the second operation's
      // saving state or ownership token.
      expect(controller.isSaving, isTrue);

      secondLoad.complete(_groupB);
      await next;
      expect(controller.selectedGroup?.id, _groupB.id);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'joinGroup rejects duplicate submits while the first is pending',
    () async {
      final auth = _ControlledAuth();
      final load = Completer<PlannerGroup>();
      final repository = _ControlledScheduleRepository()
        ..joinGroupLoads.add(load);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;

      final first = controller.joinGroup('invite-token');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        controller.joinGroup('invite-token'),
        throwsA(isA<ScheduleConflictException>()),
      );
      expect(repository.joinGroupCalls, 1);

      load.complete(_groupB);
      await first;
      expect(controller.selectedGroup?.id, _groupB.id);
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'stale saveEvent completion cannot restore data after sign-out',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository()
        ..createEventLoad = Completer<PlannerEvent>();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;
      controller.selectedGroup = _groupA;

      final saving = controller.saveEvent(
        draft: EventDraft(
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      await Future<void>.delayed(Duration.zero);
      repository.createEventLoad!.complete(
        PlannerEvent(
          id: 'private-event',
          groupId: _groupA.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      );
      await saving;

      expect(controller.user, isNull);
      expect(controller.events, isEmpty);
      expect(controller.isSaving, isFalse);
    },
  );

  test('stale profile update cannot restore data after sign-out', () async {
    final auth = _ControlledAuth()..displayNameLoad = Completer<PlannerUser>();
    final controller = PlannerController(
      auth: auth,
      repository: _ControlledScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();
    controller.user = _alice;

    final updating = controller.updateDisplayName('Alice updated');
    await Future<void>.delayed(Duration.zero);
    auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    await Future<void>.delayed(Duration.zero);
    auth.displayNameLoad!.complete(
      const PlannerUser(
        id: 'alice',
        email: 'alice@example.com',
        displayName: 'Alice updated',
      ),
    );
    await updating;

    expect(controller.user, isNull);
    expect(controller.isSaving, isFalse);
  });

  test(
    'signedIn followed by signedOut leaves the controller signed out',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();

      auth.emit(
        const AuthRepositoryEvent(type: AuthEventType.signedIn, user: _alice),
      );
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      for (final load in repository.groupLoads) {
        if (!load.isCompleted) load.complete(const <PlannerGroup>[]);
      }

      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.authFlowState, AuthFlowState.signedOut);
    },
  );

  test(
    'signOut clears private state and keeps an actionable failure',
    () async {
      final auth = _ControlledAuth()
        ..signOutError = const AuthException('network');
      final repository = _ControlledScheduleRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_groupA];
      controller.selectedGroup = _groupA;
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'private-event',
          groupId: _groupA.id,
          title: 'Private',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          ownerId: _alice.id,
        ),
      ];

      await expectLater(controller.signOut(), throwsA(isA<AuthException>()));
      expect(controller.user, isNull);
      expect(controller.groups, isEmpty);
      expect(controller.selectedGroup, isNull);
      expect(controller.events, isEmpty);
      expect(controller.authFlowState, AuthFlowState.signedOut);
      expect(controller.errorMessage, authSessionErrorMessage);
    },
  );

  test('isOffline resets after a later successful group refresh', () async {
    final auth = _ControlledAuth();
    final repository = _ControlledScheduleRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();
    controller.user = _alice;

    final failed = controller.loadGroups();
    repository.groupLoads.single.completeError(StateError('offline'));
    await failed;
    expect(controller.isOffline, isTrue);

    final succeeded = controller.loadGroups();
    repository.groupLoads[1].complete(const <PlannerGroup>[_groupA]);
    await succeeded;
    expect(controller.isOffline, isFalse);
  });

  test('duplicate createInviteCode calls are rejected while busy', () async {
    final auth = _ControlledAuth();
    final repository = _ControlledScheduleRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await _settleControllerBootstrap();
    controller.user = _alice;
    controller.groups = const <PlannerGroup>[_groupA];
    controller.selectedGroup = _groupA;
    controller.members = <PlannerMember>[_owner(_alice.id)];
    final invite = InviteCode(
      id: 'invite-1',
      groupId: _groupA.id,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      maxUses: 1,
      usesCount: 0,
      version: 1,
      token: 'token-1',
    );
    repository.inviteLoad = Completer<InviteCode>();
    repository.inviteResult = invite;

    final first = controller.createInviteCode();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isSaving, isTrue);
    await expectLater(
      controller.createInviteCode(),
      throwsA(isA<ScheduleConflictException>()),
    );

    repository.inviteLoad!.complete(invite);
    await first;
    expect(controller.invites, hasLength(1));
    expect(controller.isSaving, isFalse);
  });

  test('PlannerEvent.copyWith can clear all-day date metadata', () {
    final event = PlannerEvent(
      id: 'event-1',
      groupId: _groupA.id,
      title: 'All day',
      startAt: DateTime.utc(2026, 1, 1),
      endAt: DateTime.utc(2026, 1, 2),
      ownerId: _alice.id,
      allDay: true,
      allDayStartDate: DateTime(2026, 1, 1),
      allDayEndDate: DateTime(2026, 1, 2),
    );

    final cleared = event.copyWith(allDay: false, clearAllDayDates: true);
    expect(cleared.allDay, isFalse);
    expect(cleared.allDayStartDate, isNull);
    expect(cleared.allDayEndDate, isNull);
  });

  test(
    'saveEvent clears local all-day metadata when switching to timed',
    () async {
      final auth = _ControlledAuth();
      final repository = _ControlledScheduleRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settleControllerBootstrap();
      controller.user = _alice;
      controller.groups = const <PlannerGroup>[_groupA];
      controller.selectedGroup = _groupA;
      final existing = PlannerEvent(
        id: 'event-1',
        groupId: _groupA.id,
        title: 'All day',
        startAt: DateTime.utc(2026, 1, 1),
        endAt: DateTime.utc(2026, 1, 2),
        ownerId: _alice.id,
        allDay: true,
        allDayStartDate: DateTime(2026, 1, 1),
        allDayEndDate: DateTime(2026, 1, 2),
      );
      controller.events = <PlannerEvent>[existing];

      await controller.saveEvent(
        existing: existing,
        draft: EventDraft(
          title: 'Timed',
          startAt: DateTime.utc(2026, 1, 1, 9),
          endAt: DateTime.utc(2026, 1, 1, 10),
          timezone: 'UTC',
        ),
      );

      expect(repository.updatedEvent?.allDay, isFalse);
      expect(repository.updatedEvent?.allDayStartDate, isNull);
      expect(repository.updatedEvent?.allDayEndDate, isNull);
      expect(controller.events.single.allDayStartDate, isNull);
      expect(controller.events.single.allDayEndDate, isNull);
    },
  );
}
