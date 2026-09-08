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
      throw StateError('참여자 교체 원본이 없습니다');
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

class _AmbiguousCreateSchedule extends _Schedule {
  PlannerController? planner;
  PlannerEvent? created;

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    final memberIds = draft.hasExplicitMemberIds
        ? draft.memberIds
        : <String>[userId];
    final shadow = PlannerEvent(
      id: 'same-content-existing-event',
      groupId: groupId,
      title: draft.title,
      note: draft.note,
      startAt: draft.startAt,
      endAt: draft.endAt,
      ownerId: userId,
      memberIds: memberIds,
      allDay: draft.allDay,
      timezone: draft.timezone,
      updatedAt: DateTime.utc(9998),
    );
    planner!.events = <PlannerEvent>[...planner!.events, shadow];
    created = PlannerEvent(
      id: 'authoritative-created-event',
      groupId: groupId,
      title: draft.title,
      note: draft.note,
      startAt: draft.startAt,
      endAt: draft.endAt,
      ownerId: userId,
      memberIds: memberIds,
      allDay: draft.allDay,
      timezone: draft.timezone,
    );
    return created!;
  }
}

class _StaleReceiptSchedule extends _Schedule {
  late PlannerEvent staleProjection;
  EventEditScope? receivedScope;

  @override
  bool get useBoundedEventRangeReads => true;

  @override
  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    receivedScope = scope;
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey,
      seriesVersion: expectedSeriesVersion + 1,
      occurrenceVersion: scope == EventEditScope.thisOccurrence
          ? expectedOccurrenceVersion + 1
          : 0,
      scope: scope,
    );
  }

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async => EventRangePage(
    events: <PlannerEvent>[staleProjection],
    nextCursor: null,
    hasMore: false,
  );
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
  PlannerEvent? event,
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
  controller.events = event == null
      ? const <PlannerEvent>[]
      : <PlannerEvent>[event];
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
  fail('편집기 뷰포트에 대상이 표시되지 않았다');
}

Widget _app(
  PlannerController planner,
  NotificationController notifications, {
  String? eventId = 'notification-event',
}) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => planner),
    notificationControllerProvider.overrideWith((ref) => notifications),
  ],
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: EventEditorScreen(eventId: eventId),
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
  testWidgets('새 일정 알림은 내용이 같은 기존 일정이 아닌 저장 결과 ID를 사용한다', (tester) async {
    final auth = _Auth();
    final schedule = _AmbiguousCreateSchedule();
    final repository = _NotificationRepository(schedule: schedule);
    final planner = _planner(auth: auth, schedule: schedule);
    schedule.planner = planner;
    final notifications = _notifications(repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, notifications, eventId: null));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, '같은 내용의 일정');
    await _scrollTo(tester, find.text('내 알림', skipOffstage: false));
    await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(schedule.created, isNotNull);
    expect(repository.preferenceWrites, 1);
    expect(repository.lastSaved?.eventId, schedule.created!.id);
    expect(repository.lastSaved?.eventVersion, schedule.created!.version);
    expect(tester.takeException(), isNull);
  });

  testWidgets('반복 저장 receipt보다 오래된 projection으로 알림을 저장하지 않는다', (tester) async {
    final auth = _Auth();
    final schedule = _StaleReceiptSchedule();
    final rule = RecurrenceRule(
      frequency: RecurrenceFrequency.daily,
      end: RecurrenceEnd.count,
      count: 2,
    );
    final event = PlannerEvent(
      id: 'notification-event',
      seriesId: 'notification-event',
      groupId: _group.id,
      title: '기존 반복 알림 일정',
      startAt: DateTime.utc(2026, 9, 10, 9),
      endAt: DateTime.utc(2026, 9, 10, 10),
      ownerId: _user.id,
      memberIds: const <String>['notification-editor-user'],
      timezone: _group.timezone,
      version: 3,
      occurrenceKey: occurrenceKeyForIndex(0),
      occurrenceIndex: 0,
      occurrenceVersion: 2,
      isOccurrence: true,
      recurrenceRule: rule,
    );
    schedule.staleProjection = event;
    final repository = _NotificationRepository(schedule: schedule);
    final planner = _planner(auth: auth, schedule: schedule, event: event)
      ..selectedEventRange = EventRange(
        startUtc: DateTime.utc(2026, 9, 1),
        endUtc: DateTime.utc(2026, 10, 1),
        viewTimezone: 'UTC',
      );
    final notifications = _notifications(repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, notifications));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await _scrollTo(tester, find.text('내 알림', skipOffstage: false));
    await tester.tap(find.widgetWithText(SwitchListTile, '내 알림'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    expect(schedule.receivedScope, EventEditScope.thisOccurrence);
    expect(repository.preferenceWrites, 0);
    expect(
      find.text('일정은 저장했지만 알림 설정을 저장하지 못했어요. 최신 일정을 불러온 뒤 다시 시도해 주세요.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('기존 일정 미리 알림을 한 번 불러오고 저장 시 버전을 보존한다', (tester) async {
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
    // 편집기는 프레임 뒤에 원격 읽기를 예약한다. 이 로컬 테스트 어댑터에서는
    // 저장소와 컨트롤러가 모두 동기적으로 완료된다.
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
  });

  testWidgets('일정 미리 알림 읽기 실패가 일반 오류이며 초안/캐시를 건드리지 않는다', (tester) async {
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
  });

  testWidgets('미리 알림 읽기 실패는 동작할 때만 재시도하고 원격 버전을 보존한다', (tester) async {
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

    // 다시 빌드하는 것만으로 다른 요청을 시작하면 안 된다. 명시적 동작만
    // 재시도를 일으킨다.
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
  });

  testWidgets('참여자 변경이 미리 알림 저장 전에 일정 버전을 새로 고친다', (tester) async {
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

    // 참여자와 미리 알림 초안을 모두 변경 상태로 만든다. 할당 응답은 일정
    // 버전을 3에서 4로 올린다.
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
  });

  testWidgets('참여자 전용 미리 알림 저장이 멱등 멤버십 쓰기에서 버전을 유지한다', (tester) async {
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

    // 참여자는 바꾸지 않고 미리 알림만 켠다. 멱등 교체는 버전 4를 새로
    // 만들지 않고 버전 3을 유지해야 한다.
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
  });

  testWidgets('자기 자신 제거가 멤버십을 커밋하고 미리 알림 쓰기를 건너뛴다', (tester) async {
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

  testWidgets('본문 저장 중 자기 자신 제거도 미리 알림 쓰기를 건너뛴다', (tester) async {
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

  testWidgets('참여자가 아닌 일정 조회자는 미리 알림 설정을 조회하지 않는다', (tester) async {
    final auth = _Auth();
    final schedule = _Schedule();
    final event = _event(
      ownerId: 'event-owner',
      memberIds: const <String>['event-owner'],
    );
    // 다른 사용자가 권위 있는 멤버십 투영에서 현재 사용자를 제거한 뒤에도
    // 컨트롤러 캐시에 남아 있는 설정을 재현한다. 편집기는 이를 표시하거나
    // 기록하면 안 된다.
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
      initialPreferences: <String, EventNotificationPreference>{'stale': stale},
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
  });
}
