import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/models/notification_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/notification_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/state/notification_state.dart';

const _user = PlannerUser(
  id: 'notification-editor-user',
  email: 'notifications@example.com',
);
const _group = PlannerGroup(
  id: 'notification-editor-group',
  name: '알림 테스트 그룹',
  timezone: 'UTC',
  ownerId: 'notification-editor-user',
);

class _Auth extends AuthRepository {
  _Auth() : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();

  @override
  PlannerUser? get currentUser => null;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _Schedule extends LocalScheduleRepository {
  PlannerEvent? updated;
  List<String>? updateMemberIds;
  PlannerEvent? participantReplacementSource;
  int participantReplacementCalls = 0;
  int? lastParticipantExpectedVersion;

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    updated = event.copyWith(
      version: expectedVersion + 1,
      memberIds: updateMemberIds ?? event.memberIds,
    );
    return updated!;
  }

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    participantReplacementCalls += 1;
    lastParticipantExpectedVersion = expectedVersion;
    final source = participantReplacementSource;
    if (source == null || source.id != eventId) {
      throw StateError('participant replacement source is missing');
    }
    final nextMembers = memberIds.toList(growable: false);
    final changed =
        source.memberIds.toSet().length != nextMembers.toSet().length ||
        !source.memberIds.toSet().containsAll(nextMembers);
    return source.copyWith(
      memberIds: nextMembers,
      version: changed ? expectedVersion + 1 : expectedVersion,
    );
  }
}

class _NotificationRepository extends LocalNotificationRepository {
  _NotificationRepository({
    required ScheduleRepository schedule,
    Map<String, EventNotificationPreference>? initialPreferences,
    this.readError,
  }) : super(schedule, initialPreferences: initialPreferences);

  Object? readError;
  int preferenceReads = 0;
  int preferenceWrites = 0;
  int? lastExpectedVersion;
  EventNotificationPreference? lastSaved;

  @override
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async {
    preferenceReads += 1;
    final error = readError;
    if (error != null) throw error;
    return super.preferencesForEvent(userId: userId, eventId: eventId);
  }

  @override
  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference preference, {
    int? expectedVersion,
  }) async {
    preferenceWrites += 1;
    lastExpectedVersion = expectedVersion;
    lastSaved = preference;
    return super.saveEventPreference(
      preference,
      expectedVersion: expectedVersion,
    );
  }
}

PlannerEvent _event({
  int version = 3,
  String ownerId = 'notification-editor-user',
  List<String> memberIds = const <String>['notification-editor-user'],
}) => PlannerEvent(
  id: 'notification-event',
  groupId: _group.id,
  title: '기존 알림 일정',
  startAt: DateTime.utc(2026, 9, 10, 9),
  endAt: DateTime.utc(2026, 9, 10, 10),
  ownerId: ownerId,
  memberIds: memberIds,
  timezone: _group.timezone,
  version: version,
);

PlannerController _planner({
  required _Auth auth,
  required ScheduleRepository schedule,
  required PlannerEvent event,
  List<PlannerMember>? members,
}) {
  final controller = PlannerController(auth: auth, repository: schedule);
  controller.user = _user;
  controller.groups = <PlannerGroup>[_group];
  controller.selectedGroup = _group;
  controller.members =
      members ??
      <PlannerMember>[
        PlannerMember(
          id: _user.id,
          name: '알림 사용자',
          email: _user.email,
          isOwner: true,
          isActive: true,
        ),
      ];
  controller.events = <PlannerEvent>[event];
  controller.isLoading = false;
  controller.authFlowState = AuthFlowState.signedIn;
  return controller;
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  final list = find.byType(ListView).first;
  final viewport = tester.getRect(list);
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (target.evaluate().isNotEmpty) {
      final rect = tester.getRect(target.first);
      if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) return;
    }
    await tester.drag(list, const Offset(0, -180));
    await tester.pump();
  }
  fail('target did not become visible in editor viewport');
}

Widget _app(PlannerController planner, NotificationController notifications) =>
    ProviderScope(
      overrides: <Override>[
        plannerControllerProvider.overrideWith((ref) => planner),
        notificationControllerProvider.overrideWith((ref) => notifications),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const EventEditorScreen(eventId: 'notification-event'),
      ),
    );

NotificationController _notifications(_NotificationRepository repository) {
  final controller = NotificationController(repository: repository);
  controller.userId = _user.id;
  controller.settings = const UserNotificationSettings(
    userId: 'notification-editor-user',
    enabled: true,
    localEnabled: true,
    version: 1,
  );
  controller.capability = NotificationCapabilityState.available;
  controller.permission = NotificationPermissionState.authorized;
  controller.pushCapability = NotificationCapabilityState.unconfigured;
  return controller;
}

void main() {
  testWidgets(
    'existing event reminder loads once and preserves its version on save',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final event = _event();
      final existing = EventNotificationPreference(
        id: 'reminder-setting-id',
        userId: _user.id,
        eventId: event.seriesId,
        channel: NotificationChannel.local,
        enabled: true,
        timedLeadSeconds: 900,
        version: 7,
        eventVersion: event.version,
      );
      final repository = _NotificationRepository(
        schedule: schedule,
        initialPreferences: <String, EventNotificationPreference>{
          'stable-key': existing,
        },
      );
      final planner = _planner(auth: auth, schedule: schedule, event: event);
      final notifications = _notifications(repository);
      addTearDown(() {
        auth.dispose();
      });

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      // The editor schedules the remote read post-frame; the repository and
      // controller both complete synchronously in this local test adapter.
      await tester.pump();
      await tester.pump();

      expect(repository.preferenceReads, 1);
      await _scrollTo(tester, find.text('15분 전', skipOffstage: false));
      expect(find.text('15분 전'), findsOneWidget);

      final dropdown = find.byType(DropdownButton<int>);
      expect(dropdown, findsOneWidget);
      await tester.tap(dropdown);
      await tester.pump();
      await tester.tap(find.text('30분 전').last);
      await tester.pump();
      expect(find.text('30분 전'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pumpAndSettle();

      expect(repository.preferenceWrites, 1);
      expect(repository.lastExpectedVersion, 7);
      expect(repository.lastSaved?.timedLeadSeconds, 1800);
      expect(repository.lastSaved?.version, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed event reminder read is generic and leaves draft/cache untouched',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final planner = _planner(auth: auth, schedule: schedule, event: _event());
      final repository = _NotificationRepository(
        schedule: schedule,
        readError: StateError('private backend detail'),
      );
      final notifications = _notifications(repository);
      addTearDown(() {
        auth.dispose();
      });

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(repository.preferenceReads, 1);
      expect(notifications.eventPreferences, isEmpty);
      expect(notifications.errorMessage, '알림을 업데이트하지 못했습니다. 잠시 후 다시 시도해 주세요.');
      expect(
        find.text('알림을 업데이트하지 못했습니다. 잠시 후 다시 시도해 주세요.', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('private backend detail'), findsNothing);
      expect(repository.preferenceWrites, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed reminder read retries only on action and then preserves remote version',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final event = _event();
      final existing = EventNotificationPreference(
        id: 'retry-reminder-setting',
        userId: _user.id,
        eventId: event.seriesId,
        channel: NotificationChannel.local,
        enabled: true,
        timedLeadSeconds: 900,
        version: 7,
        eventVersion: event.version,
      );
      final repository = _NotificationRepository(
        schedule: schedule,
        initialPreferences: <String, EventNotificationPreference>{
          'retry-key': existing,
        },
        readError: StateError('temporary transport detail'),
      );
      final planner = _planner(auth: auth, schedule: schedule, event: event);
      final notifications = _notifications(repository);
      addTearDown(auth.dispose);

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(repository.preferenceReads, 1);
      expect(
        find.text('알림을 업데이트하지 못했습니다. 잠시 후 다시 시도해 주세요.', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('알림 설정 다시 불러오기', skipOffstage: false), findsOneWidget);

      // A rebuild alone must not spin another request. The explicit action is
      // the only retry trigger.
      notifications.notifyListeners();
      await tester.pump();
      expect(repository.preferenceReads, 1);

      repository.readError = null;
      await _scrollTo(tester, find.text('알림 설정 다시 불러오기', skipOffstage: false));
      await tester.tap(find.text('알림 설정 다시 불러오기'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(repository.preferenceReads, 2);
      expect(find.text('알림 설정 다시 불러오기', skipOffstage: false), findsNothing);
      await _scrollTo(tester, find.text('15분 전', skipOffstage: false));
      final dropdown = find.byType(DropdownButton<int>);
      await tester.tap(dropdown);
      await tester.pump();
      await tester.tap(find.text('30분 전').last);
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pumpAndSettle();

      expect(repository.preferenceWrites, 1);
      expect(repository.lastExpectedVersion, 7);
      expect(repository.lastSaved?.timedLeadSeconds, 1800);
      expect(repository.lastSaved?.version, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'participant mutation refreshes event version before saving reminder',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final event = _event(
        ownerId: 'event-owner',
        memberIds: const <String>['notification-editor-user'],
      );
      schedule.participantReplacementSource = event;
      final repository = _NotificationRepository(schedule: schedule);
      final planner = _planner(
        auth: auth,
        schedule: schedule,
        event: event,
        members: <PlannerMember>[
          PlannerMember(
            id: _user.id,
            name: '알림 사용자',
            email: _user.email,
            isOwner: true,
            isActive: true,
          ),
          const PlannerMember(
            id: 'member-b',
            name: '멤버 B',
            email: 'member-b@example.com',
            isActive: true,
          ),
        ],
      );
      final notifications = _notifications(repository);
      addTearDown(auth.dispose);

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Make both participant and reminder drafts dirty. The assignment
      // response bumps the event from version 3 to 4.
      await _scrollTo(tester, find.text('멤버 B', skipOffstage: false));
      await tester.tap(find.widgetWithText(CheckboxListTile, '멤버 B'));
      await _scrollTo(tester, find.text('내 알림', skipOffstage: false));
      await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
      await tester.pump();
      await _scrollTo(tester, find.widgetWithText(FilledButton, '참여자 저장하기'));
      await tester.tap(find.widgetWithText(FilledButton, '참여자 저장하기'));
      await tester.pumpAndSettle();

      expect(schedule.participantReplacementCalls, 1);
      expect(schedule.lastParticipantExpectedVersion, 3);
      expect(repository.preferenceWrites, 1);
      expect(repository.lastSaved?.eventVersion, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'participant-only reminder save keeps version on idempotent membership write',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final event = _event(
        ownerId: 'event-owner',
        memberIds: const <String>['notification-editor-user'],
      );
      schedule.participantReplacementSource = event;
      final repository = _NotificationRepository(schedule: schedule);
      final planner = _planner(auth: auth, schedule: schedule, event: event);
      final notifications = _notifications(repository);
      addTearDown(auth.dispose);

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Leave participants unchanged and only enable the reminder. The
      // idempotent replacement must keep version 3, not manufacture version 4.
      await _scrollTo(tester, find.text('내 알림', skipOffstage: false));
      await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
      await tester.pump();
      await _scrollTo(tester, find.widgetWithText(FilledButton, '참여자 저장하기'));
      await tester.tap(find.widgetWithText(FilledButton, '참여자 저장하기'));
      await tester.pumpAndSettle();

      expect(schedule.lastParticipantExpectedVersion, 3);
      expect(repository.preferenceWrites, 1);
      expect(repository.lastSaved?.eventVersion, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('self-removal commits membership and skips the reminder write', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule();
    final event = _event(
      ownerId: 'event-owner',
      memberIds: const <String>['notification-editor-user'],
    );
    schedule.participantReplacementSource = event;
    final repository = _NotificationRepository(schedule: schedule);
    final planner = _planner(auth: auth, schedule: schedule, event: event);
    final notifications = _notifications(repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, notifications));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repository.preferenceReads, 1);

    await _scrollTo(tester, find.text('알림 사용자', skipOffstage: false));
    await tester.tap(find.widgetWithText(CheckboxListTile, '알림 사용자'));
    await _scrollTo(tester, find.text('내 알림', skipOffstage: false));
    await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
    await tester.pump();
    await _scrollTo(tester, find.widgetWithText(FilledButton, '참여자 저장하기'));
    await tester.tap(find.widgetWithText(FilledButton, '참여자 저장하기'));
    await tester.pumpAndSettle();

    expect(schedule.participantReplacementCalls, 1);
    expect(repository.preferenceWrites, 0);
    expect(find.text('참여에서 제외되어 알림도 해제됐어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('body save self-removal also skips the reminder write', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule()..updateMemberIds = const <String>[];
    final event = _event();
    final repository = _NotificationRepository(schedule: schedule);
    final planner = _planner(auth: auth, schedule: schedule, event: event);
    final notifications = _notifications(repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, notifications));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repository.preferenceReads, 1);

    await _scrollTo(tester, find.text('알림 사용자', skipOffstage: false));
    await tester.tap(find.widgetWithText(CheckboxListTile, '알림 사용자'));
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(schedule.updated, isNotNull);
    expect(repository.preferenceWrites, 0);
    expect(find.text('참여에서 제외되어 알림도 해제됐어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nonparticipant event viewer does not probe reminder preferences',
    (tester) async {
      final auth = _Auth();
      final schedule = _Schedule();
      final event = _event(
        ownerId: 'event-owner',
        memberIds: const <String>['event-owner'],
      );
      // Simulate a preference that remains in the controller's cache after a
      // different actor removed the current user from the authoritative
      // membership projection.  The editor must not surface or write it.
      final stale = EventNotificationPreference(
        id: 'stale-reminder-setting',
        userId: _user.id,
        eventId: event.seriesId,
        channel: NotificationChannel.local,
        enabled: true,
        version: 4,
        eventVersion: event.version,
      );
      final repository = _NotificationRepository(
        schedule: schedule,
        initialPreferences: <String, EventNotificationPreference>{
          'stale': stale,
        },
      );
      final planner = _planner(auth: auth, schedule: schedule, event: event);
      final notifications = _notifications(repository);
      addTearDown(auth.dispose);

      await tester.pumpWidget(_app(planner, notifications));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(repository.preferenceReads, 0);
      final reminderSwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '내 알림', skipOffstage: false),
      );
      expect(reminderSwitch.value, isFalse);
      expect(reminderSwitch.onChanged, isNull);
      expect(notifications.errorMessage, isNull);
      expect(find.text('일정 제목'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
