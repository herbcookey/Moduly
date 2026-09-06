import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _plannerUser = PlannerUser(id: 'viewer', email: 'viewer@example.com');
const _groupA = PlannerGroup(
  id: 'roster-group-a',
  name: 'Group A',
  timezone: 'UTC',
  ownerId: 'viewer',
);
const _groupB = PlannerGroup(
  id: 'roster-group-b',
  name: 'Group B',
  timezone: 'UTC',
  ownerId: 'viewer',
);

final _viewerMember = PlannerMember(
  id: _plannerUser.id,
  name: 'Viewer',
  email: _plannerUser.email,
  isOwner: true,
);
final _memberM = const PlannerMember(
  id: 'member-m',
  name: 'Member M',
  email: 'm@example.com',
);

class _RosterAuth extends AuthRepository {
  _RosterAuth() : super();

  @override
  PlannerUser? get currentUser => null;
}

/// Lifecycle signals are deliberately separate from the member read so tests
/// can model another client changing M while a roster request is in flight.
class _RosterRepository extends LocalScheduleRepository {
  _RosterRepository({required Map<String, List<PlannerMember>> snapshots})
    : _snapshots = <String, List<PlannerMember>>{
        for (final entry in snapshots.entries)
          entry.key: List<PlannerMember>.unmodifiable(entry.value),
      };

  final Map<String, List<PlannerMember>> _snapshots;
  final Map<String, StreamController<PlannerGroup?>> _lifecycle =
      <String, StreamController<PlannerGroup?>>{};
  final Map<String, List<Future<List<PlannerMember>>>> _queuedReads =
      <String, List<Future<List<PlannerMember>>>>{};
  final Map<String, int> memberReads = <String, int>{};

  void setSnapshot(String groupId, Iterable<PlannerMember> members) {
    _snapshots[groupId] = List<PlannerMember>.unmodifiable(members);
  }

  void queueMemberRead(String groupId, Future<List<PlannerMember>> read) {
    _queuedReads.putIfAbsent(groupId, () => <Future<List<PlannerMember>>>[]);
    _queuedReads[groupId]!.add(read);
  }

  void emitGroupLifecycle(String groupId, PlannerGroup? group) {
    _lifecycle[groupId]?.add(group);
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) {
    memberReads[groupId] = (memberReads[groupId] ?? 0) + 1;
    final queued = _queuedReads[groupId];
    if (queued != null && queued.isNotEmpty) return queued.removeAt(0);
    return Future<List<PlannerMember>>.value(
      _snapshots[groupId] ?? const <PlannerMember>[],
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId) {
    return Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);
  }

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) {
    return _lifecycle
        .putIfAbsent(groupId, () => StreamController<PlannerGroup?>.broadcast())
        .stream;
  }

  Future<void> close() async {
    for (final controller in _lifecycle.values) {
      await controller.close();
    }
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitForMemberRead(
  _RosterRepository repository,
  String groupId, {
  int atLeast = 2,
}) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    if ((repository.memberReads[groupId] ?? 0) >= atLeast) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('member roster refresh did not start');
}

PlannerEvent _eventForMember(String groupId) => PlannerEvent(
  id: 'event-$groupId',
  groupId: groupId,
  title: 'Shared event',
  startAt: DateTime.utc(2026, 9, 7, 9),
  endAt: DateTime.utc(2026, 9, 7, 10),
  ownerId: _plannerUser.id,
  memberIds: const <String>['member-m'],
);

void main() {
  test(
    'external member deactivation refreshes roster and clears stale filter',
    () async {
      final auth = _RosterAuth();
      final repository = _RosterRepository(
        snapshots: <String, List<PlannerMember>>{
          _groupA.id: <PlannerMember>[_viewerMember, _memberM],
        },
      );
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
        auth.dispose();
      });
      await _settle();

      controller.user = _plannerUser;
      controller.groups = const <PlannerGroup>[_groupA];
      await controller.selectGroup(_groupA.id);
      controller.events = <PlannerEvent>[_eventForMember(_groupA.id)];
      controller.setMemberFilter(_memberM.id);
      expect(controller.selectedMemberId, _memberM.id);
      expect(
        controller.members.any((member) => member.id == _memberM.id),
        isTrue,
      );

      repository.setSnapshot(_groupA.id, <PlannerMember>[_viewerMember]);
      repository.emitGroupLifecycle(_groupA.id, _groupA);
      await _waitForMemberRead(repository, _groupA.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        controller.members.any((member) => member.id == _memberM.id),
        isFalse,
      );
      expect(controller.selectedMemberId, isNull);
      expect(controller.showAllMembers, isTrue);
      // The event may retain a historical member id, but no stale display
      // identity remains in the active roster or member-filter semantics.
      expect(controller.events.single.memberIds, <String>[_memberM.id]);
    },
  );

  test('stale roster response after switching groups is ignored', () async {
    final auth = _RosterAuth();
    final repository = _RosterRepository(
      snapshots: <String, List<PlannerMember>>{
        _groupA.id: <PlannerMember>[_viewerMember, _memberM],
        _groupB.id: <PlannerMember>[_viewerMember],
      },
    );
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() async {
      controller.dispose();
      await repository.close();
      auth.dispose();
    });
    await _settle();

    controller.user = _plannerUser;
    controller.groups = const <PlannerGroup>[_groupA, _groupB];
    await controller.selectGroup(_groupA.id);
    final staleRead = Completer<List<PlannerMember>>();
    repository.queueMemberRead(_groupA.id, staleRead.future);
    repository.emitGroupLifecycle(_groupA.id, _groupA);
    await _waitForMemberRead(repository, _groupA.id);

    await controller.selectGroup(_groupB.id);
    staleRead.complete(<PlannerMember>[_viewerMember, _memberM]);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(controller.selectedGroup?.id, _groupB.id);
    expect(controller.members.map((member) => member.id), <String>[
      _plannerUser.id,
    ]);
    expect(
      controller.members.any((member) => member.id == _memberM.id),
      isFalse,
    );
  });

  test(
    'stale roster response after sign-out cannot restore private data',
    () async {
      final auth = _RosterAuth();
      final repository = _RosterRepository(
        snapshots: <String, List<PlannerMember>>{
          _groupA.id: <PlannerMember>[_viewerMember, _memberM],
        },
      );
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
        auth.dispose();
      });
      await _settle();

      controller.user = _plannerUser;
      controller.groups = const <PlannerGroup>[_groupA];
      await controller.selectGroup(_groupA.id);
      final staleRead = Completer<List<PlannerMember>>();
      repository.queueMemberRead(_groupA.id, staleRead.future);
      repository.emitGroupLifecycle(_groupA.id, _groupA);
      await _waitForMemberRead(repository, _groupA.id);

      final signOut = controller.signOut();
      staleRead.complete(<PlannerMember>[_viewerMember, _memberM]);
      await signOut;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(controller.user, isNull);
      expect(controller.selectedGroup, isNull);
      expect(controller.members, isEmpty);
      expect(controller.events, isEmpty);
    },
  );

  test(
    'roster read errors preserve last-known members until retry succeeds',
    () async {
      final auth = _RosterAuth();
      final repository = _RosterRepository(
        snapshots: <String, List<PlannerMember>>{
          _groupA.id: <PlannerMember>[_viewerMember, _memberM],
        },
      );
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
        auth.dispose();
      });
      await _settle();

      controller.user = _plannerUser;
      controller.groups = const <PlannerGroup>[_groupA];
      await controller.selectGroup(_groupA.id);
      controller.setMemberFilter(_memberM.id);

      repository.setSnapshot(_groupA.id, <PlannerMember>[_viewerMember]);
      final errorRead = Completer<List<PlannerMember>>();
      repository.queueMemberRead(_groupA.id, errorRead.future);
      repository.emitGroupLifecycle(_groupA.id, _groupA);
      await _waitForMemberRead(repository, _groupA.id);
      errorRead.completeError(StateError('temporary roster error'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        controller.members.any((member) => member.id == _memberM.id),
        isTrue,
      );
      expect(controller.selectedMemberId, _memberM.id);

      repository.emitGroupLifecycle(_groupA.id, _groupA);
      await _waitForMemberRead(repository, _groupA.id, atLeast: 3);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        controller.members.any((member) => member.id == _memberM.id),
        isFalse,
      );
      expect(controller.selectedMemberId, isNull);
    },
  );
}
