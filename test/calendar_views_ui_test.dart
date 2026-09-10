import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(
  id: 'calendar-user',
  email: 'calendar@example.com',
  displayName: '캘린더 사용자',
);

const _group = PlannerGroup(
  id: 'calendar-group',
  name: '캘린더 테스트 그룹',
  timezone: 'UTC',
  ownerId: 'calendar-user',
);

class _TestAuth extends AuthRepository {
  _TestAuth() : super();

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

class _RangeRepository extends LocalScheduleRepository {
  _RangeRepository({this.rangeEvents = const <PlannerEvent>[]});

  @override
  bool get useBoundedEventRangeReads => true;

  List<PlannerEvent> rangeEvents;
  bool failReads = false;
  int pageSize = 100;
  int rangeCalls = 0;

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async {
    rangeCalls += 1;
    if (failReads) {
      throw const ScheduleCapabilityException('일정 범위를 불러오지 못했어요.');
    }
    final sorted = rangeEvents.toList(growable: false)
      ..sort((a, b) {
        final byStart = a.startAt.compareTo(b.startAt);
        return byStart == 0 ? a.id.compareTo(b.id) : byStart;
      });
    var offset = 0;
    if (cursor != null) {
      final index = sorted.indexWhere((event) => event.id == cursor.eventId);
      offset = index < 0 ? sorted.length : index + 1;
    }
    final take = pageSize.clamp(1, 100);
    final page = sorted.skip(offset).take(take).toList(growable: false);
    final hasMore = offset + page.length < sorted.length;
    final nextCursor = hasMore
        ? EventRangeCursor(
            startsAtUtc: page.last.startAt,
            eventId: page.last.id,
          )
        : null;
    return EventRangePage(
      events: page,
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      Stream<void>.empty();
}

/// 달력 범위 기능 도입 전의 어댑터 형태다. 상속받은 범위 제한 기능은 런타임
/// 타입 호환성 스위치에서 의도적으로 비활성화한다.
class _LegacyRepository extends LocalScheduleRepository {}

PlannerEvent _event({
  required String id,
  required String title,
  DateTime? startAt,
  DateTime? endAt,
  bool allDay = false,
  List<String> memberIds = const <String>['calendar-user'],
  String timezone = 'UTC',
  DateTime? allDayStartDate,
  DateTime? allDayEndDate,
}) => PlannerEvent(
  id: id,
  groupId: _group.id,
  title: title,
  startAt: (startAt ?? DateTime.utc(2026, 8, 10, 9)).toUtc(),
  endAt: (endAt ?? DateTime.utc(2026, 8, 10, 10)).toUtc(),
  ownerId: _user.id,
  memberIds: memberIds,
  timezone: timezone,
  allDay: allDay,
  allDayStartDate: allDayStartDate,
  allDayEndDate: allDayEndDate,
);

PlannerController _controller({
  required _TestAuth auth,
  required _RangeRepository repository,
  required List<PlannerEvent> events,
  DateTime? selectedDay,
  String timezone = 'UTC',
  List<PlannerMember> members = const <PlannerMember>[],
}) {
  final controller = PlannerController(auth: auth, repository: repository);
  controller.user = _user;
  controller.groups = <PlannerGroup>[_group.copyWith(timezone: timezone)];
  controller.selectedGroup = _group.copyWith(timezone: timezone);
  controller.members = members;
  controller.selectedDay = selectedDay ?? DateTime(2026, 8, 10);
  controller.events = events;
  controller.isLoading = false;
  controller.isLoadingEvents = false;
  controller.authFlowState = AuthFlowState.signedIn;
  repository.rangeEvents = events;
  return controller;
}

Widget _app(PlannerController controller, {Widget? child}) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
  ],
  child: MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: child ?? const HomeScreen(),
  ),
);

Widget _largeConstrained(Widget child) => MediaQuery(
  data: const MediaQueryData(
    textScaler: TextScaler.linear(2),
    viewInsets: EdgeInsets.only(bottom: 300),
  ),
  child: child,
);

void _useSmallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _cell(int year, int month, int day) =>
    find.byKey(ValueKey<String>('calendar-cell-$year-$month-$day'));

Finder _calendarCells() => find.byWidgetPredicate((widget) {
  if (widget is! Semantics) return false;
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('calendar-cell-');
});

Finder _monthGrid() => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == '월간 일정 그리드',
);

void _expectMonthGridFitsViewport(WidgetTester tester) {
  final grid = _monthGrid();
  expect(grid, findsOneWidget);
  // The view-mode toolbar and period controls intentionally remain
  // horizontally scrollable. The month grid itself must not introduce a
  // horizontal scroll view.
  expect(
    find.descendant(of: grid, matching: find.byType(SingleChildScrollView)),
    findsNothing,
  );

  final viewportWidth =
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final gridRect = tester.getRect(grid);
  expect(gridRect.left, greaterThanOrEqualTo(-0.01));
  expect(gridRect.right, lessThanOrEqualTo(viewportWidth + 0.01));

  // August 2026 starts on Monday, so these seven cells form the first row.
  final firstRow = <Finder>[
    _cell(2026, 7, 27),
    _cell(2026, 7, 28),
    _cell(2026, 7, 29),
    _cell(2026, 7, 30),
    _cell(2026, 7, 31),
    _cell(2026, 8, 1),
    _cell(2026, 8, 2),
  ];
  final rects = firstRow.map(tester.getRect).toList(growable: false);
  expect(rects.map((rect) => rect.top).toSet(), hasLength(1));
  expect(rects.first.left, greaterThanOrEqualTo(gridRect.left - 0.01));
  expect(rects.last.right, lessThanOrEqualTo(gridRect.right + 0.01));
}

void _showMonth(PlannerController controller) {
  controller.calendarView = CalendarViewMode.month;
  controller.notifyListeners();
}

void _showAgenda(PlannerController controller) {
  controller.calendarView = CalendarViewMode.agenda;
  controller.notifyListeners();
}

void main() {
  testWidgets('일간 보기가 기본값으로 유지되고 기존 일정 카드가 표시된다', (tester) async {
    final auth = _TestAuth();
    final event = _event(id: 'day-event', title: '기존 일간 일정');
    final repository = _RangeRepository(rangeEvents: <PlannerEvent>[event]);
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();

    expect(controller.calendarView, CalendarViewMode.day);
    expect(find.text('기존 일간 일정'), findsOneWidget);
    expect(find.text('일간'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('이전 기간')).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('그룹 선택에 일정 스냅샷이 없을 때 기존 어댑터가 로딩을 표시한다', (tester) async {
    final auth = _TestAuth();
    final repository = _LegacyRepository();
    final controller = PlannerController(auth: auth, repository: repository)
      ..user = _user
      ..groups = <PlannerGroup>[_group]
      ..selectedGroup = _group
      ..selectedDay = DateTime(2026, 8, 10)
      ..events = const <PlannerEvent>[]
      ..isLoadingEvents = false
      ..isLoading = false
      ..authFlowState = AuthFlowState.signedIn;
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.pump();

    // 레거시 스트림이 일정을 지운 뒤 보조 읽기를 마치기 전의 짧은
    // selectGroup 상태를 재현한다.
    controller.isLoading = true;
    controller.notifyListeners();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('비어 있는 하루예요'), findsNothing);
    expect(tester.takeException(), isNull);

    controller.isLoading = false;
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('비어 있는 하루예요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('월간 모드가 7열 그리드와 셀 선택을 제공한다', (tester) async {
    final auth = _TestAuth();
    final event = _event(id: 'month-event', title: '월간 일정');
    final repository = _RangeRepository(rangeEvents: <PlannerEvent>[event]);
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.tap(find.text('월간'));
    await tester.pumpAndSettle();

    expect(controller.calendarView, CalendarViewMode.month);
    expect(_calendarCells(), findsNWidgets(42));
    final selectedCell = _cell(2026, 8, 10);
    expect(selectedCell, findsOneWidget);
    expect(tester.getSize(selectedCell).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(selectedCell).height, greaterThanOrEqualTo(48));
    final weekdayHeader = find.byKey(
      const ValueKey<String>('calendar-weekday-0'),
    );
    final weekdayRect = tester.getRect(weekdayHeader);
    final firstColumnRect = tester.getRect(_cell(2026, 7, 27));
    expect(weekdayRect.left, closeTo(firstColumnRect.left, 0.001));
    expect(weekdayRect.width, closeTo(firstColumnRect.width, 0.001));
    _expectMonthGridFitsViewport(tester);

    final target = _cell(2026, 8, 12);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    expect(controller.selectedDay, DateTime(2026, 8, 12));
    expect(controller.calendarView, CalendarViewMode.month);
    expect(tester.takeException(), isNull);
  });

  testWidgets('윤년 2월과 6행인 달이 보이는 그리드를 제공한다', (tester) async {
    final auth = _TestAuth();
    final event = _event(
      id: 'leap-event',
      title: '윤년 일정',
      startAt: DateTime.utc(2024, 2, 29, 9),
      endAt: DateTime.utc(2024, 2, 29, 10),
    );
    final repository = _RangeRepository(rangeEvents: <PlannerEvent>[event]);
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
      selectedDay: DateTime(2024, 2, 29),
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    _showMonth(controller);
    await tester.pump();

    expect(_calendarCells(), findsNWidgets(35));
    expect(_cell(2024, 2, 29), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('2024년 2월 29일')), findsOneWidget);

    controller.selectedDay = DateTime(2025, 3, 1);
    controller.notifyListeners();
    await tester.pump();
    expect(_calendarCells(), findsNWidgets(42));
    expect(tester.takeException(), isNull);
  });

  testWidgets('일정 목록이 종일 일정을 먼저 정렬하고 자정 통과 일정을 한 번 표시한다', (tester) async {
    final auth = _TestAuth();
    final allDay = _event(
      id: 'agenda-all-day',
      title: '종일 모임',
      allDay: true,
      startAt: DateTime.utc(2026, 8, 10),
      endAt: DateTime.utc(2026, 8, 12),
      allDayStartDate: DateTime(2026, 8, 10),
      allDayEndDate: DateTime(2026, 8, 12),
    );
    final timed = _event(
      id: 'agenda-timed',
      title: '아침 회의',
      startAt: DateTime.utc(2026, 8, 10, 8),
      endAt: DateTime.utc(2026, 8, 10, 9),
    );
    final overnight = _event(
      id: 'agenda-overnight',
      title: '자정 넘김',
      startAt: DateTime.utc(2026, 8, 10, 23, 30),
      endAt: DateTime.utc(2026, 8, 11, 1, 30),
    );
    final repository = _RangeRepository(
      rangeEvents: <PlannerEvent>[overnight, timed, allDay],
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[overnight, timed, allDay],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    _showAgenda(controller);
    await tester.pump();

    expect(find.text('종일 모임'), findsOneWidget);
    expect(find.text('아침 회의'), findsOneWidget);
    expect(find.text('자정 넘김'), findsOneWidget);
    expect(find.text('종일 · 8월 10일–8월 11일'), findsOneWidget);
    expect(find.textContaining('다음 날까지'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('종일 모임')).dy,
      lessThan(tester.getTopLeft(find.text('아침 회의')).dy),
    );
    expect(find.text('자정 넘김'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('참여자 필터가 월간 및 일정 목록 카드에 적용된다', (tester) async {
    final auth = _TestAuth();
    final first = _event(
      id: 'member-one-event',
      title: '첫 멤버 일정',
      memberIds: const <String>['member-one'],
    );
    final second = _event(
      id: 'member-two-event',
      title: '둘째 멤버 일정',
      memberIds: const <String>['member-two'],
    );
    final repository = _RangeRepository(
      rangeEvents: <PlannerEvent>[first, second],
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[first, second],
      members: <PlannerMember>[
        PlannerMember(id: 'member-one', name: '첫 멤버', email: 'one@example.com'),
        PlannerMember(
          id: 'member-two',
          name: '둘째 멤버',
          email: 'two@example.com',
        ),
      ],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    _showAgenda(controller);
    await tester.pump();
    expect(find.text('첫 멤버 일정'), findsOneWidget);
    expect(find.text('둘째 멤버 일정'), findsOneWidget);

    await tester.tap(find.text('모든 참여자'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('첫 멤버').last);
    await tester.pump();

    expect(controller.selectedMemberId, 'member-one');
    expect(find.text('첫 멤버 일정'), findsOneWidget);
    expect(find.text('둘째 멤버 일정'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('오늘이 선택한 그룹의 시간대를 사용한다', (tester) async {
    final auth = _TestAuth();
    final repository = _RangeRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: const <PlannerEvent>[],
      timezone: 'America/Los_Angeles',
      selectedDay: DateTime(2000, 1, 1),
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.tap(find.text('오늘'));
    await tester.pump();

    final expected = dateOnly(
      utcToWallTime(DateTime.now().toUtc(), 'America/Los_Angeles'),
    );
    expect(controller.selectedDay, expected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('날짜 선택기 취소는 선택을 유지하고 선택 완료는 날짜를 갱신한다', (tester) async {
    final auth = _TestAuth();
    final repository = _RangeRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: const <PlannerEvent>[],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    final initial = controller.selectedDay;
    await tester.tap(find.byTooltip('날짜 선택'));
    await tester.pumpAndSettle();
    expect(find.text('날짜 선택'), findsWidgets);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(controller.selectedDay, initial);

    await tester.tap(find.byTooltip('날짜 선택'));
    await tester.pumpAndSettle();
    final day15 = find.text('15').last;
    expect(day15, findsOneWidget);
    await tester.tap(day15);
    await tester.tap(find.text('선택'));
    await tester.pumpAndSettle();
    expect(controller.selectedDay.day, 15);
    expect(tester.takeException(), isNull);
  });

  testWidgets('범위 오류가 재시도를 제공하고 더 불러오기를 사용할 수 있다', (tester) async {
    final auth = _TestAuth();
    final first = _event(id: 'range-first', title: '첫 페이지 일정');
    final second = _event(
      id: 'range-second',
      title: '다음 페이지 일정',
      startAt: DateTime.utc(2026, 8, 11, 9),
      endAt: DateTime.utc(2026, 8, 11, 10),
    );
    final repository = _RangeRepository(
      rangeEvents: <PlannerEvent>[first, second],
    )..pageSize = 1;
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[first, second],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    repository.failReads = true;
    controller.setCalendarView(CalendarViewMode.month);
    await tester.pumpAndSettle();
    expect(find.text('다시 시도'), findsOneWidget);
    expect(controller.rangeError, isNotNull);

    repository.failReads = false;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('첫 페이지 일정'), findsWidgets);
    final loadMore = find.byKey(
      const ValueKey<String>('calendar-load-more'),
      skipOffstage: false,
    );
    expect(loadMore, findsOneWidget);
    await tester.scrollUntilVisible(
      loadMore,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final renderObject = tester.renderObject(loadMore);
    final reveal = RenderAbstractViewport.of(
      renderObject,
    ).getOffsetToReveal(renderObject, 1).offset;
    position.jumpTo(reveal);
    await tester.pump();
    await tester.tap(loadMore);
    await tester.pumpAndSettle();
    expect(find.text('다음 페이지 일정'), findsWidgets);
    expect(repository.rangeCalls, greaterThanOrEqualTo(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('2배 텍스트와 키보드가 있는 320x568에서도 월 셀, 컨트롤, 의미 정보가 유지된다', (
    tester,
  ) async {
    _useSmallViewport(tester);
    final semantics = tester.ensureSemantics();
    final auth = _TestAuth();
    final event = _event(id: 'a11y-event', title: '접근성 일정');
    final repository = _RangeRepository(rangeEvents: <PlannerEvent>[event]);
    final controller = _controller(
      auth: auth,
      repository: repository,
      events: <PlannerEvent>[event],
    );
    addTearDown(() {
      auth.dispose();
    });

    await tester.pumpWidget(_largeConstrained(_app(controller)));
    await tester.pump();
    final homeContext = tester.element(find.byType(HomeScreen));
    expect(MediaQuery.textScalerOf(homeContext).scale(12), 24);
    expect(MediaQuery.viewInsetsOf(homeContext).bottom, 300);
    _showMonth(controller);
    await tester.pump();

    for (final tooltip in <String>['이전 기간', '다음 기간', '날짜 선택']) {
      expect(
        tester.getSize(find.byTooltip(tooltip)).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '오늘')).height,
      greaterThanOrEqualTo(48),
    );
    final cell = _cell(2026, 8, 10);
    await tester.scrollUntilVisible(
      cell,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final cellRect = tester.getRect(cell);
    expect(cellRect.width, greaterThan(0));
    expect(cellRect.height, greaterThanOrEqualTo(48));
    _expectMonthGridFitsViewport(tester);
    expect(find.bySemanticsLabel(RegExp('2026년 8월 10일')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selectedDay, DateTime(2026, 8, 11));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selectedDay, DateTime(2026, 8, 12));
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
}
