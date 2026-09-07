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

/// A pre-calendar-range adapter shape. Its inherited bounded capability is
/// intentionally disabled by the runtime-type compatibility switch.
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

void _showMonth(PlannerController controller) {
  controller.calendarView = CalendarViewMode.month;
  controller.notifyListeners();
}

void _showAgenda(PlannerController controller) {
  controller.calendarView = CalendarViewMode.agenda;
  controller.notifyListeners();
}

void main() {
  testWidgets(
    'daily view remains the default and existing event cards render',
    (tester) async {
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
    },
  );

  testWidgets(
    'legacy adapter shows loading while group selection has no event snapshot',
    (tester) async {
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

      // Reproduce the brief selectGroup state after the legacy stream has
      // cleared events but before its auxiliary reads have completed.
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
    },
  );

  testWidgets('month mode exposes a 7-column grid and cell selection', (
    tester,
  ) async {
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

    final target = _cell(2026, 8, 12);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    expect(controller.selectedDay, DateTime(2026, 8, 12));
    expect(controller.calendarView, CalendarViewMode.month);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leap February and a six-row month expose visible grids', (
    tester,
  ) async {
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

  testWidgets(
    'agenda orders all-day before timed and shows cross-midnight once',
    (tester) async {
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
    },
  );

  testWidgets('participant filter applies to month and agenda event cards', (
    tester,
  ) async {
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

  testWidgets('today uses the selected group timezone', (tester) async {
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

  testWidgets(
    'date picker cancel leaves selection unchanged and select updates it',
    (tester) async {
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
    },
  );

  testWidgets('range error offers retry and load-more remains reachable', (
    tester,
  ) async {
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

  testWidgets(
    'month cells, controls and semantics survive 320x568 at 2x with keyboard',
    (tester) async {
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
      expect(cellRect.width, greaterThanOrEqualTo(48));
      expect(cellRect.height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel(RegExp('2026년 8월 10일')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controller.selectedDay, DateTime(2026, 8, 11));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controller.selectedDay, DateTime(2026, 8, 12));
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
