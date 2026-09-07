import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/state/notification_state.dart';

class _NoAuth extends AuthRepository {
  _NoAuth() : super();

  @override
  PlannerUser? get currentUser => null;
}

class _NoSchedule implements ScheduleRepository {
  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async =>
      const <PlannerGroup>[];

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      const <PlannerMember>[];

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) =>
      const Stream<List<PlannerEvent>>.empty();

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description, {
    String timezone = 'Asia/Seoul',
  }) => Future<PlannerGroup>.error(
    const ScheduleCapabilityException('테스트 저장소에서 그룹 만들기를 지원하지 않습니다.'),
  );

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) => Future<PlannerGroup>.error(
    const ScheduleCapabilityException('테스트 저장소에서 그룹 편집을 지원하지 않습니다.'),
  );

  @override
  Future<void> leaveGroup({required String actorId, required String groupId}) =>
      Future<void>.error(
        const ScheduleCapabilityException('테스트 저장소에서 그룹 나가기를 지원하지 않습니다.'),
      );

  @override
  Future<PlannerGroup> transferGroupOwnership({
    required String actorId,
    required String groupId,
    required String newOwnerId,
    required int expectedVersion,
  }) => Future<PlannerGroup>.error(
    const ScheduleCapabilityException('테스트 저장소에서 소유권 이전을 지원하지 않습니다.'),
  );

  @override
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) => Future<int>.error(
    const ScheduleCapabilityException('테스트 저장소에서 그룹 보관을 지원하지 않습니다.'),
  );

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) =>
      Future<PlannerGroup>.error(
        const ScheduleCapabilityException('테스트 저장소에서 그룹 참여를 지원하지 않습니다.'),
      );

  @override
  Future<String> createInviteCode(String groupId) => Future<String>.error(
    const ScheduleCapabilityException('테스트 저장소에서 초대 코드 생성을 지원하지 않습니다.'),
  );

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) => Future<InviteCode>.error(
    const ScheduleCapabilityException('테스트 저장소에서 초대 옵션을 지원하지 않습니다.'),
  );

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async =>
      const <InviteCode>[];

  @override
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<InviteCode>.error(
    const ScheduleCapabilityException('테스트 저장소에서 초대 취소를 지원하지 않습니다.'),
  );

  @override
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) => Future<PlannerMember>.error(
    const ScheduleCapabilityException('테스트 저장소에서 멤버 변경을 지원하지 않습니다.'),
  );

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) => Future<PlannerEvent>.error(
    const ScheduleCapabilityException('테스트 저장소에서 일정 생성을 지원하지 않습니다.'),
  );

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) => Future<PlannerEvent>.error(
    const ScheduleCapabilityException('테스트 저장소에서 일정 편집을 지원하지 않습니다.'),
  );

  @override
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<void>.error(
    const ScheduleCapabilityException('테스트 저장소에서 일정 삭제를 지원하지 않습니다.'),
  );
}

class _MutationSchedule extends _NoSchedule {
  Future<void>? leaveGate;
  Future<void>? archiveGate;
  bool leaveCalled = false;
  bool archiveCalled = false;

  @override
  Future<void> leaveGroup({
    required String actorId,
    required String groupId,
  }) async {
    leaveCalled = true;
    final gate = leaveGate;
    if (gate != null) {
      leaveGate = null;
      await gate;
    }
  }

  @override
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) async {
    archiveCalled = true;
    final gate = archiveGate;
    if (gate != null) {
      archiveGate = null;
      await gate;
    }
    return expectedVersion + 1;
  }
}

class _RecordingNotifications implements NotificationInvalidationSink {
  final List<String> cancelledGroups = <String>[];

  @override
  Future<void> cancelForGroup(String groupId) async {
    cancelledGroups.add(groupId);
  }

  @override
  Future<void> onAuthenticated(String userId) async {}

  @override
  Future<void> onEventChanged({String? eventId, String? groupId}) async {}

  @override
  Future<void> onMembershipChanged({String? eventId, String? groupId}) async {}

  @override
  Future<void> onSignedOut() async {}

  @override
  Future<void> reconcile({DateTime? nowUtc}) async {}
}

class _EventAuth extends AuthRepository {
  _EventAuth() : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();
  PlannerUser? value;

  @override
  PlannerUser? get currentUser => value;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  void emit(AuthRepositoryEvent event) => _events.add(event);

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

Future<void> _settlePlannerCallbacks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

PlannerUser _plannerUser(String id) =>
    PlannerUser(id: id, email: '$id@example.com');

PlannerGroup _plannerGroup(String id) => PlannerGroup(id: id, name: id);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test(
    'PlannerController filters events by local calendar day and member',
    () async {
      final controller = PlannerController(
        auth: _NoAuth(),
        repository: _NoSchedule(),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      final start = DateTime.utc(2026, 5, 1, 23);
      final end = DateTime.utc(2026, 5, 2, 1);
      final event = PlannerEvent(
        id: 'cross-midnight',
        groupId: 'g',
        title: 'Cross midnight',
        startAt: start,
        endAt: end,
        ownerId: 'owner',
        memberIds: const <String>['member'],
      );
      controller.events = <PlannerEvent>[event];

      controller.setSelectedDay(start.toLocal());
      expect(
        controller.visibleEvents.map((value) => value.id),
        contains('cross-midnight'),
      );
      controller.setSelectedDay(end.toLocal());
      expect(
        controller.visibleEvents.map((value) => value.id),
        contains('cross-midnight'),
      );

      controller.setMemberFilter('other-member');
      expect(controller.visibleEvents, isEmpty);
      controller.setMemberFilter('member');
      expect(
        controller.visibleEvents.map((value) => value.id),
        contains('cross-midnight'),
      );
      controller.setMemberFilter('owner');
      expect(controller.visibleEvents, isEmpty);
    },
  );

  test(
    'filters events by the event IANA timezone, not the device timezone',
    () async {
      final controller = PlannerController(
        auth: _NoAuth(),
        repository: _NoSchedule(),
      );
      addTearDown(controller.dispose);
      final event = PlannerEvent(
        id: 'la-midnight',
        groupId: 'g',
        title: 'LA midnight',
        startAt: DateTime.utc(2026, 3, 8, 8),
        endAt: DateTime.utc(2026, 3, 9, 7),
        ownerId: 'owner',
        allDay: true,
        timezone: 'America/Los_Angeles',
        allDayStartDate: DateTime(2026, 3, 8),
        allDayEndDate: DateTime(2026, 3, 9),
      );
      controller.events = <PlannerEvent>[event];
      controller.selectedDay = DateTime(2026, 3, 8);
      expect(
        controller.visibleEvents.map((item) => item.id),
        contains('la-midnight'),
      );
      controller.selectedDay = DateTime(2026, 3, 9);
      expect(controller.visibleEvents, isEmpty);
    },
  );

  test(
    'stale leave completion does not purge a newly authenticated account',
    () async {
      final auth = _EventAuth();
      final schedule = _MutationSchedule();
      final notifications = _RecordingNotifications();
      final leaveGate = Completer<void>();
      schedule.leaveGate = leaveGate.future;
      final controller = PlannerController(
        auth: auth,
        repository: schedule,
        notifications: notifications,
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settlePlannerCallbacks();

      controller.user = _plannerUser('user-a');
      controller.selectedGroup = _plannerGroup('group-a');
      final leave = controller.leaveGroup();
      await _settlePlannerCallbacks();
      expect(schedule.leaveCalled, isTrue);

      final userB = _plannerUser('user-b');
      auth.value = userB;
      auth.emit(AuthRepositoryEvent(type: AuthEventType.signedIn, user: userB));
      await _settlePlannerCallbacks();
      leaveGate.complete();
      await leave;
      await _settlePlannerCallbacks();

      expect(controller.user?.id, 'user-b');
      expect(notifications.cancelledGroups, isEmpty);
    },
  );

  test(
    'stale archive completion does not purge a newly authenticated account',
    () async {
      final auth = _EventAuth();
      final schedule = _MutationSchedule();
      final notifications = _RecordingNotifications();
      final archiveGate = Completer<void>();
      schedule.archiveGate = archiveGate.future;
      final controller = PlannerController(
        auth: auth,
        repository: schedule,
        notifications: notifications,
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settlePlannerCallbacks();

      controller.user = _plannerUser('user-a');
      controller.selectedGroup = _plannerGroup('group-a');
      final archive = controller.archiveGroup();
      await _settlePlannerCallbacks();
      expect(schedule.archiveCalled, isTrue);

      final userB = _plannerUser('user-b');
      auth.value = userB;
      auth.emit(AuthRepositoryEvent(type: AuthEventType.signedIn, user: userB));
      await _settlePlannerCallbacks();
      archiveGate.complete();
      await archive;
      await _settlePlannerCallbacks();

      expect(controller.user?.id, 'user-b');
      expect(notifications.cancelledGroups, isEmpty);
    },
  );

  test(
    'same-account group switch still cancels the completed leave group',
    () async {
      final auth = _EventAuth();
      final schedule = _MutationSchedule();
      final notifications = _RecordingNotifications();
      final leaveGate = Completer<void>();
      schedule.leaveGate = leaveGate.future;
      final controller = PlannerController(
        auth: auth,
        repository: schedule,
        notifications: notifications,
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await _settlePlannerCallbacks();

      controller.user = _plannerUser('user-a');
      controller.selectedGroup = _plannerGroup('group-a');
      final leave = controller.leaveGroup();
      await _settlePlannerCallbacks();
      controller.selectedGroup = _plannerGroup('group-b');
      leaveGate.complete();
      await leave;
      await _settlePlannerCallbacks();

      expect(notifications.cancelledGroups, <String>['group-a']);
    },
  );
}
