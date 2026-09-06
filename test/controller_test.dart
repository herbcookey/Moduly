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
    String description,
  ) => Future<PlannerGroup>.error(UnimplementedError());

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) =>
      Future<PlannerGroup>.error(UnimplementedError());

  @override
  Future<String> createInviteCode(String groupId) =>
      Future<String>.error(UnimplementedError());

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) => Future<InviteCode>.error(UnimplementedError());

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async =>
      const <InviteCode>[];

  @override
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<InviteCode>.error(UnimplementedError());

  @override
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) => Future<PlannerMember>.error(UnimplementedError());

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) => Future<PlannerEvent>.error(UnimplementedError());

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) => Future<PlannerEvent>.error(UnimplementedError());

  @override
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<void>.error(UnimplementedError());
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
      controller.setMemberFilter('owner');
      expect(
        controller.visibleEvents.map((value) => value.id),
        contains('cross-midnight'),
      );
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
