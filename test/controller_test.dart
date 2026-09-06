import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

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
}
