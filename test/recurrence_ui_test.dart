import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/screens/widgets/recurrence_controls.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(
  id: 'recurrence-user',
  email: 'recurrence@example.com',
  displayName: '반복 사용자',
);

const _group = PlannerGroup(
  id: 'recurrence-group',
  name: '반복 그룹',
  timezone: 'UTC',
  ownerId: _userId,
);

const _groupOwner = PlannerUser(
  id: 'recurrence-group-owner',
  email: 'group-owner@example.com',
  displayName: '그룹 소유자',
);

const _ownerGroup = PlannerGroup(
  id: 'recurrence-owner-group',
  name: '소유자 그룹',
  timezone: 'UTC',
  ownerId: _groupOwnerId,
);

const _userId = 'recurrence-user';
const _groupOwnerId = 'recurrence-group-owner';

class _TestAuth extends AuthRepository {
  _TestAuth({this.currentUser = _user}) : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();

  @override
  final PlannerUser? currentUser;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

/// 레거시 단일 일정이 반복 시리즈로 변환될 때 편집기가 내보내는 반복 변경을
/// 캡처한다. 범위와 기본값 로직은 여전히 컨트롤러가 소유하며, 이 테스트 대역은
/// 위젯 테스트가 백엔드와 결합되는 것만 피한다.
class _SingletonConversionRepository extends LocalScheduleRepository {
  EventDraft? recurrenceDraft;
  PlannerEvent? recurrenceEvent;
  EventEditScope? recurrenceScope;
  EventEditScope? deletionScope;
  PlannerEvent? deletedEvent;
  PlannerEvent? replacementSource;
  String? replacedEventId;
  List<String>? replacedMemberIds;
  int? replacementExpectedVersion;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async =>
      userId == _user.id
      ? const <PlannerGroup>[_group]
      : const <PlannerGroup>[];

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      groupId == _group.id
      ? const <PlannerMember>[
          PlannerMember(
            id: _userId,
            name: '반복 사용자',
            email: 'recurrence@example.com',
            isOwner: true,
          ),
        ]
      : const <PlannerMember>[];

  @override
  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    recurrenceEvent = event;
    recurrenceDraft = draft;
    recurrenceScope = scope;
    final eventMembers = event.memberIds.toSet();
    final draftMembers = draft.memberIds.toSet();
    final changed =
        event.title != draft.title ||
        event.note != draft.note ||
        event.startAt != draft.startAt ||
        event.endAt != draft.endAt ||
        event.allDay != draft.allDay ||
        event.colorValue != draft.colorValue ||
        event.timezone != draft.timezone ||
        event.allDayStartDate != draft.allDayStartDate ||
        event.allDayEndDate != draft.allDayEndDate ||
        event.recurrenceRule != draft.recurrence ||
        eventMembers.length != draftMembers.length ||
        !eventMembers.containsAll(draftMembers);
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey,
      seriesVersion: expectedSeriesVersion + (changed ? 1 : 0),
      occurrenceVersion: scope == EventEditScope.thisOccurrence
          ? expectedOccurrenceVersion + (changed ? 1 : 0)
          : 0,
      scope: scope,
      changed: changed,
    );
  }

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    final source = replacementSource;
    if (source == null || source.id != eventId) {
      throw StateError('교체 원본이 없습니다');
    }
    replacedEventId = eventId;
    replacedMemberIds = memberIds.toList(growable: false);
    replacementExpectedVersion = expectedVersion;
    final sourceIds = source.memberIds.toSet();
    final replacementIds = replacedMemberIds!.toSet();
    final changed =
        sourceIds.length != replacementIds.length ||
        !sourceIds.containsAll(replacementIds);
    return source.copyWith(
      memberIds: replacedMemberIds,
      version: expectedVersion + (changed ? 1 : 0),
    );
  }

  @override
  Future<RecurrenceMutationReceipt> replaceRecurringEventMembers({
    required PlannerEvent event,
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    final source = replacementSource;
    if (source == null || source.id != event.id) {
      throw StateError('교체 원본이 없습니다');
    }
    replacedEventId = event.id;
    replacedMemberIds = memberIds.toList(growable: false);
    replacementExpectedVersion = expectedVersion;
    final sourceIds = source.memberIds.toSet();
    final replacementIds = replacedMemberIds!.toSet();
    final changed =
        sourceIds.length != replacementIds.length ||
        !sourceIds.containsAll(replacementIds);
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey == 'single'
          ? occurrenceKeyForIndex(0)
          : event.occurrenceKey,
      seriesVersion: expectedVersion + (changed ? 1 : 0),
      occurrenceVersion: 0,
      scope: EventEditScope.all,
      changed: changed,
    );
  }

  @override
  Future<RecurrenceMutationReceipt> deleteEventOccurrence({
    required PlannerEvent event,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    deletedEvent = event;
    deletionScope = scope;
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey,
      seriesVersion: expectedSeriesVersion + 1,
      occurrenceVersion: scope == EventEditScope.thisOccurrence
          ? expectedOccurrenceVersion + 1
          : 0,
      scope: scope,
      changed: true,
    );
  }
}

/// A 응답을 의도적으로 늦게 보내는 상세 저장소다. 라우트 식별자가 B로 바뀌는
/// 동안 GoRouter가 편집기 State를 유지하는 라우트 재사용 경로를 검사한다.
class _RouteReuseRepository extends LocalScheduleRepository {
  _RouteReuseRepository({required this.pendingA, required this.eventB});

  final Completer<PlannerEvent?> pendingA;
  final PlannerEvent eventB;
  PlannerEvent? updatedEvent;

  @override
  bool get useBoundedEventRangeReads => true;

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) {
    if (eventId == 'route-A') return pendingA.future;
    if (eventId == eventB.id) return Future<PlannerEvent?>.value(eventB);
    return Future<PlannerEvent?>.value(null);
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

PlannerController _controller({
  required _TestAuth auth,
  List<PlannerEvent> events = const <PlannerEvent>[],
  CalendarViewMode view = CalendarViewMode.day,
  ScheduleRepository? repository,
  PlannerUser user = _user,
  PlannerGroup group = _group,
  List<PlannerMember>? members,
}) {
  final controller = PlannerController(
    auth: auth,
    repository: repository ?? LocalScheduleRepository(),
  );
  controller.user = user;
  controller.groups = <PlannerGroup>[group];
  controller.selectedGroup = group;
  controller.members =
      members ??
      <PlannerMember>[
        PlannerMember(
          id: _userId,
          name: '반복 사용자',
          email: 'recurrence@example.com',
          isOwner: true,
        ),
      ];
  controller.events = events;
  controller.selectedDay = DateTime(2026, 8, 10);
  controller.calendarView = view;
  controller.isLoading = false;
  controller.isLoadingEvents = false;
  controller.authFlowState = AuthFlowState.signedIn;
  return controller;
}

Widget _app(PlannerController controller, Widget child) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
  ],
  child: MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: child,
  ),
);

RecurrenceRule _weeklyRule() => RecurrenceRule(
  frequency: RecurrenceFrequency.weekly,
  weekdays: const <int>[1, 3],
  end: RecurrenceEnd.count,
  count: 8,
);

PlannerEvent _occurrence({RecurrenceRule? rule}) => PlannerEvent(
  id: 'series-1',
  seriesId: 'series-1',
  occurrenceKey: 'o00000000000000000001',
  occurrenceIndex: 1,
  isOccurrence: true,
  recurrenceRule: rule ?? _weeklyRule(),
  groupId: _group.id,
  title: '반복 회의',
  note: '상속된 메모',
  startAt: DateTime.utc(2026, 8, 10, 9),
  endAt: DateTime.utc(2026, 8, 10, 10),
  ownerId: _user.id,
  memberIds: const <String>[_userId],
  colorValue: 0xff8266a5,
);

void main() {
  testWidgets('반복 편집기의 기본값이 없음이며 주간 규칙을 내보낸다', (tester) async {
    RecurrenceRule? emitted;
    final key = GlobalKey<RecurrenceEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              RecurrenceEditor(
                key: key,
                start: DateTime(2026, 8, 12), // Wednesday
                onChanged: (rule) => emitted = rule,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('반복'), findsOneWidget);
    expect(find.text('반복 안 함'), findsOneWidget);
    expect(emitted, isNull);

    await tester.tap(find.text('반복 안 함'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('매주').first);
    await tester.pumpAndSettle();

    expect(emitted?.frequency, RecurrenceFrequency.weekly);
    expect(emitted?.weekdays, <int>[3]);
    expect(find.bySemanticsLabel('수요일'), findsOneWidget);
    expect(find.textContaining('매주 수'), findsWidgets);
    expect(key.currentState?.validateRule(), emitted);
  });

  testWidgets('반복 편집기가 간격, 횟수, 월간 제한을 검증한다', (tester) async {
    final key = GlobalKey<RecurrenceEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              RecurrenceEditor(key: key, start: DateTime(2026, 1, 31)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('반복 안 함'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('매월').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('해당 월에 31일이 없으면'), findsOneWidget);

    await tester.tap(find.text('횟수'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    // 월간 날짜 필드 뒤에 횟수 필드가 오며, 좁은 너비에서도 모든 숫자 필드는
    // 키보드로 편집할 수 있다.
    expect(fields, findsNWidgets(3));
    final count = fields.at(2);
    await tester.enterText(count, '0');
    expect(key.currentState?.validateRule(), isNull);

    final interval = fields.first;
    await tester.enterText(interval, '1000');
    expect(key.currentState?.validateRule(), isNull);
  });

  testWidgets('단일 일정 편집이 전체 범위 반복 변환을 보낸다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final repository = _SingletonConversionRepository();
    final event = PlannerEvent(
      id: 'singleton-1',
      groupId: _group.id,
      title: '단일 일정',
      note: '변환 전 메모',
      startAt: DateTime.utc(2026, 8, 10, 9),
      endAt: DateTime.utc(2026, 8, 10, 10),
      ownerId: _user.id,
      memberIds: const <String>[_userId],
      timezone: 'UTC',
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/singleton-1',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) =>
              const EventEditorScreen(eventId: 'singleton-1'),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('반복 안 함'));
    await tester.pumpAndSettle();
    final daily = find.text('매일', skipOffstage: false).first;
    await tester.ensureVisible(daily);
    await tester.tap(daily);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(repository.recurrenceScope, EventEditScope.all);
    expect(
      repository.recurrenceDraft?.recurrence?.frequency,
      RecurrenceFrequency.daily,
    );
    expect(repository.recurrenceDraft?.recurrence?.interval, 1);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('전체 범위 편집이 반복 기준 일정을 단일 일정으로 되돌릴 수 있다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final repository = _SingletonConversionRepository();
    final event = PlannerEvent(
      id: 'recurring-anchor',
      groupId: _group.id,
      title: '반복에서 단일로',
      startAt: DateTime.utc(2026, 8, 10, 9),
      endAt: DateTime.utc(2026, 8, 10, 10),
      ownerId: _user.id,
      memberIds: const <String>[_userId],
      timezone: 'UTC',
      recurrenceRule: _weeklyRule(),
      occurrenceKey: 'single',
      isOccurrence: false,
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/recurring-anchor',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) =>
              const EventEditorScreen(eventId: 'recurring-anchor'),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('반복 안 함'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 일정'));
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    expect(repository.recurrenceScope, EventEditScope.all);
    expect(repository.recurrenceDraft?.recurrence, isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('재사용 편집기가 오래된 조회를 버리고 라우트 B만 저장한다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final pendingA = Completer<PlannerEvent?>();
    final eventB = PlannerEvent(
      id: 'route-B',
      groupId: _group.id,
      title: 'B 일정',
      note: 'B 메모',
      startAt: DateTime.utc(2026, 8, 12, 14),
      endAt: DateTime.utc(2026, 8, 12, 15),
      ownerId: _user.id,
      memberIds: const <String>[_userId],
      colorValue: 0xff8266a5,
      timezone: 'UTC',
    );
    final repository = _RouteReuseRepository(
      pendingA: pendingA,
      eventB: eventB,
    );
    final controller = _controller(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/route-A',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) => EventEditorScreen(
            eventId: state.pathParameters['id'],
            occurrenceKey: state.uri.queryParameters['occurrence'],
          ),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    // A의 상세 요청이 완료되기 전에 같은 편집기 State를 B에 재사용한다.
    router.go('/event/route-B');
    await tester.pumpAndSettle();
    final titleField = tester.widget<TextFormField>(
      find.byType(TextFormField).first,
    );
    final noteField = tester.widget<TextFormField>(
      find.byType(TextFormField).at(1),
    );
    expect(titleField.controller!.text, 'B 일정');
    expect(noteField.controller!.text, 'B 메모');

    pendingA.complete(
      PlannerEvent(
        id: 'route-A',
        groupId: _group.id,
        title: 'A stale 응답',
        note: 'A stale 메모',
        startAt: DateTime.utc(2026, 8, 10, 9),
        endAt: DateTime.utc(2026, 8, 10, 10),
        ownerId: _user.id,
        memberIds: const <String>[_userId],
        timezone: 'UTC',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      'B 일정',
    );

    await tester.enterText(find.byType(TextFormField).first, 'B 저장됨');
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();
    expect(repository.updatedEvent?.id, 'route-B');
    expect(repository.updatedEvent?.title, 'B 저장됨');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('재사용 편집기가 저장 전 다른 발생 일정으로 다시 시드한다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final first = _occurrence();
    const secondKey = 'o00000000000000000002';
    final second = first.copyWith(
      occurrenceKey: secondKey,
      occurrenceIndex: 2,
      title: '두 번째 반복',
      note: '두 번째 메모',
      startAt: DateTime.utc(2026, 8, 12, 9),
      endAt: DateTime.utc(2026, 8, 12, 10),
      memberIds: const <String>[_userId, 'member-two'],
    );
    final repository = _SingletonConversionRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[first, second],
      members: const <PlannerMember>[
        PlannerMember(
          id: _userId,
          name: '반복 사용자',
          email: 'recurrence@example.com',
          isOwner: true,
        ),
        PlannerMember(
          id: 'member-two',
          name: '두 번째 멤버',
          email: 'member-two@example.com',
        ),
      ],
    );
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/series-1?occurrence=${first.occurrenceKey}',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) => EventEditorScreen(
            eventId: state.pathParameters['id'],
            occurrenceKey: state.uri.queryParameters['occurrence'],
          ),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      '반복 회의',
    );

    router.go('/event/series-1?occurrence=$secondKey');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      '두 번째 반복',
    );
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(1))
          .controller!
          .text,
      '두 번째 메모',
    );
    final secondMember = find.widgetWithText(
      CheckboxListTile,
      '두 번째 멤버',
      skipOffstage: false,
    );
    expect(tester.widget<CheckboxListTile>(secondMember).value, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '참여자 변경 범위 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 일정'));
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();
    expect(repository.recurrenceEvent?.occurrenceKey, secondKey);
    expect(repository.recurrenceDraft?.title, '두 번째 반복');
    expect(repository.recurrenceScope, EventEditScope.all);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('범위 대화상자의 기본값이 이번 일정이며 취소는 무동작이다', (tester) async {
    EventEditScope? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showRecurrenceScopeDialog(
                  context,
                  deleting: false,
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('이번 일정만'), findsOneWidget);
    expect(find.text('이번 일정과 이후'), findsOneWidget);
    expect(find.text('전체 일정'), findsOneWidget);
    expect(find.textContaining('예외가 초기화될 수 있어요'), findsNWidgets(2));
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('편집 및 삭제 범위 대화상자가 모든 선택지를 제공한다', (tester) async {
    EventEditScope? result;
    var deleting = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showRecurrenceScopeDialog(
                  context,
                  deleting: deleting,
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );

    Future<void> choose({
      required String option,
      required bool isDeleting,
    }) async {
      deleting = isDeleting;
      result = null;
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option));
      await tester.tap(
        find.widgetWithText(FilledButton, isDeleting ? '삭제' : '저장'),
      );
      await tester.pumpAndSettle();
    }

    await choose(option: '이번 일정만', isDeleting: false);
    expect(result, EventEditScope.thisOccurrence);
    await choose(option: '이번 일정과 이후', isDeleting: false);
    expect(result, EventEditScope.future);
    await choose(option: '전체 일정', isDeleting: false);
    expect(result, EventEditScope.all);
    await choose(option: '이번 일정만', isDeleting: true);
    expect(result, EventEditScope.thisOccurrence);
    await choose(option: '이번 일정과 이후', isDeleting: true);
    expect(result, EventEditScope.future);
    await choose(option: '전체 시리즈', isDeleting: true);
    expect(result, EventEditScope.all);

    deleting = false;
    result = null;
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('반복 카드가 배지를 알리고 발생 일정 라우트를 보존한다', (tester) async {
    final auth = _TestAuth();
    final event = _occurrence();
    final controller = _controller(auth: auth, events: <PlannerEvent>[event]);
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
        GoRoute(
          path: '/event/:id',
          builder: (context, state) => Text(state.uri.toString()),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('반복 회의'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('매주')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('반복 일정')), findsWidgets);

    await tester.tap(find.text('반복 회의'));
    await tester.pumpAndSettle();
    expect(
      find.text('/event/series-1?occurrence=o00000000000000000001'),
      findsOneWidget,
    );
  });

  testWidgets('발생 일정 편집기가 상속 필드와 참여자 잠금을 표시한다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final event = _occurrence();
    final controller = _controller(auth: auth, events: <PlannerEvent>[event]);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      _app(
        controller,
        const EventEditorScreen(
          eventId: 'series-1',
          occurrenceKey: 'o00000000000000000001',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('상속된 메모', skipOffstage: false), findsOneWidget);
    expect(
      find.textContaining('제목·메모·색상·시간은 시리즈에서 상속돼요', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining('참여자는 전체 일정에 상속돼요', skipOffstage: false),
      findsOneWidget,
    );
    final memberTile = find.widgetWithText(
      CheckboxListTile,
      '반복 사용자',
      skipOffstage: false,
    );
    expect(memberTile, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(memberTile).onChanged, isNull);
    final scopeButton = find.widgetWithText(
      OutlinedButton,
      '참여자 변경 범위 선택',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(scopeButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 일정'));
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    // 전체 범위 참여자 편집을 포함해 반복 시리즈에는 일정 생성자가 항상 유지된다.
    expect(tester.widget<CheckboxListTile>(memberTile).onChanged, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('이번 일정 범위는 전체 범위 밖의 참여자 변경을 보낼 수 없다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final repository = _SingletonConversionRepository();
    final event = _occurrence();
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/series-1?occurrence=${event.occurrenceKey}',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) => EventEditorScreen(
            eventId: state.pathParameters['id'],
            occurrenceKey: state.uri.queryParameters['occurrence'],
          ),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final scopeButton = find.widgetWithText(
      OutlinedButton,
      '참여자 변경 범위 선택',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(scopeButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('이번 일정만'));
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    final memberTile = find.widgetWithText(
      CheckboxListTile,
      '반복 사용자',
      skipOffstage: false,
    );
    expect(tester.widget<CheckboxListTile>(memberTile).onChanged, isNull);
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(repository.recurrenceScope, EventEditScope.thisOccurrence);
    expect(repository.recurrenceDraft?.memberIds, event.memberIds);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('그룹 소유자가 작성자 본문 권한 없이 반복 일정 멤버를 바꿀 수 있다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final semantics = tester.ensureSemantics();
    final repository = _SingletonConversionRepository();
    final event = PlannerEvent(
      id: 'owner-series',
      seriesId: 'owner-series',
      occurrenceKey: 'o00000000000000000001',
      occurrenceIndex: 1,
      isOccurrence: true,
      recurrenceRule: _weeklyRule(),
      groupId: _ownerGroup.id,
      title: '소유자 관리 회의',
      startAt: DateTime.utc(2026, 8, 10, 9),
      endAt: DateTime.utc(2026, 8, 10, 10),
      ownerId: _user.id,
      memberIds: const <String>[_userId],
    );
    repository.replacementSource = event;
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _groupOwner,
      group: _ownerGroup,
      members: const <PlannerMember>[
        PlannerMember(
          id: _groupOwnerId,
          name: '그룹 소유자',
          email: 'group-owner@example.com',
          isOwner: true,
        ),
        PlannerMember(
          id: _userId,
          name: '반복 사용자',
          email: 'recurrence@example.com',
        ),
      ],
      events: <PlannerEvent>[event],
    );
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: '/event/owner-series?occurrence=${event.occurrenceKey}',
      routes: <RouteBase>[
        GoRoute(
          path: '/event/:id',
          builder: (context, state) => EventEditorScreen(
            eventId: state.pathParameters['id'],
            occurrenceKey: state.uri.queryParameters['occurrence'],
          ),
        ),
        GoRoute(path: '/home', builder: (context, state) => const Text('home')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final scopeButton = find.widgetWithText(
      OutlinedButton,
      '참여자 변경 범위 선택',
      skipOffstage: false,
    );
    expect(scopeButton, findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(scopeButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 일정'));
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    final creatorTile = find.widgetWithText(
      CheckboxListTile,
      '반복 사용자',
      skipOffstage: false,
    );
    expect(creatorTile, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(creatorTile).value, isTrue);
    expect(tester.widget<CheckboxListTile>(creatorTile).onChanged, isNull);
    expect(
      find.bySemanticsLabel(RegExp('작성자라서 항상 선택됨'), skipOffstage: false),
      findsOneWidget,
    );
    // 테스트나 키보드 동작이 전환을 시도해도 비활성화된 생성자 컨트롤은 선택
    // 상태를 유지해야 한다.
    await tester.ensureVisible(creatorTile);
    await tester.tap(creatorTile, warnIfMissed: false);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(creatorTile).value, isTrue);

    final ownerTile = find.widgetWithText(
      CheckboxListTile,
      '그룹 소유자',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(ownerTile);
    await tester.pumpAndSettle();
    final saveMembers = find.widgetWithText(
      FilledButton,
      '참여자 저장하기',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(saveMembers);
    await tester.pumpAndSettle();

    expect(repository.replacedEventId, event.id);
    expect(repository.replacedMemberIds, contains(_groupOwnerId));
    expect(repository.replacedMemberIds, contains(_userId));
    expect(repository.recurrenceDraft, isNull);
    expect(repository.recurrenceScope, isNull);
    expect(find.text('home'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('일반 참여자가 반복 일정 멤버를 관리할 수 없다', (tester) async {
    const ordinary = PlannerUser(
      id: 'ordinary-participant',
      email: 'ordinary@example.com',
      displayName: '일반 참여자',
    );
    final auth = _TestAuth(currentUser: null);
    final event = _occurrence();
    final controller = _controller(
      auth: auth,
      user: ordinary,
      group: _group,
      members: <PlannerMember>[
        PlannerMember(
          id: ordinary.id,
          name: '일반 참여자',
          email: 'ordinary@example.com',
        ),
        PlannerMember(
          id: _userId,
          name: '반복 사용자',
          email: 'recurrence@example.com',
          isOwner: true,
        ),
      ],
      events: <PlannerEvent>[event],
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      _app(
        controller,
        const EventEditorScreen(
          eventId: 'series-1',
          occurrenceKey: 'o00000000000000000001',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('참여자 변경 범위 선택', skipOffstage: false), findsNothing);
    expect(
      find.widgetWithText(FilledButton, '참여자 저장하기', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('외부 멤버 목록에 생성자가 없으면 반복 멤버 저장이 안전하게 실패한다', (tester) async {
    final auth = _TestAuth(currentUser: null);
    final semantics = tester.ensureSemantics();
    final repository = _SingletonConversionRepository();
    final event = _occurrence().copyWith(memberIds: const <String>[]);
    repository.replacementSource = event;
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _groupOwner,
      group: _ownerGroup,
      members: const <PlannerMember>[
        PlannerMember(
          id: _groupOwnerId,
          name: '그룹 소유자',
          email: 'group-owner@example.com',
          isOwner: true,
        ),
        PlannerMember(
          id: _userId,
          name: '반복 사용자',
          email: 'recurrence@example.com',
        ),
      ],
      events: <PlannerEvent>[event.copyWith(groupId: _ownerGroup.id)],
    );
    // 교체 원본을 컨트롤러가 투영한 일정과 일치시킨다. 누락된 생성자는 검사
    // 대상인 잘못된 외부 상태로 의도적으로 유지한다.
    repository.replacementSource = controller.events.single;
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      _app(
        controller,
        EventEditorScreen(
          eventId: controller.events.single.id,
          occurrenceKey: controller.events.single.occurrenceKey,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scopeButton = find.widgetWithText(
      OutlinedButton,
      '참여자 변경 범위 선택',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(scopeButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('전체 일정'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    final creatorTile = find.widgetWithText(
      CheckboxListTile,
      '반복 사용자',
      skipOffstage: false,
    );
    expect(tester.widget<CheckboxListTile>(creatorTile).value, isFalse);
    expect(tester.widget<CheckboxListTile>(creatorTile).onChanged, isNull);
    expect(
      find.bySemanticsLabel(
        RegExp('작성자 참여 정보가 없어 저장할 수 없음'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final groupOwnerTile = find.widgetWithText(
      CheckboxListTile,
      '그룹 소유자',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(groupOwnerTile, warnIfMissed: false);
    await tester.pumpAndSettle();
    final saveMembers = find.widgetWithText(
      FilledButton,
      '참여자 저장하기',
      skipOffstage: false,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(saveMembers, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(repository.replacedMemberIds, isNull);
    expect(find.text('home'), findsNothing);
    expect(find.text('작성자 참여 정보를 확인한 뒤 다시 저장해 주세요.'), findsOneWidget);
    semantics.dispose();
  });
}
