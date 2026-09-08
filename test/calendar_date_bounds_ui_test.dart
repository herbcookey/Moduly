import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/screens/event_search_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/screens/widgets/recurrence_controls.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(
  id: 'date-bounds-user',
  email: 'date-bounds@example.com',
  displayName: '날짜 범위 사용자',
);

const _group = PlannerGroup(
  id: 'date-bounds-group',
  name: '날짜 범위 그룹',
  timezone: 'UTC',
  ownerId: 'date-bounds-user',
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

class _TestRepository extends LocalScheduleRepository {
  @override
  Future<EventRangePage> searchEvents({
    required String userId,
    required String groupId,
    required EventRange range,
    required String query,
    EventRangeCursor? cursor,
    int limit = eventSearchDefaultPageSize,
    String? creatorId,
    String? participantId,
  }) async => EventRangePage.empty();

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      const Stream<void>.empty();
}

PlannerController _controller(
  _TestAuth auth,
  _TestRepository repository, {
  DateTime? selectedDay,
}) {
  return PlannerController(
      auth: auth,
      repository: repository,
      searchDebounce: Duration.zero,
    )
    ..user = _user
    ..groups = const <PlannerGroup>[_group]
    ..selectedGroup = _group
    ..members = const <PlannerMember>[
      PlannerMember(
        id: 'date-bounds-user',
        name: '날짜 범위 사용자',
        email: 'date-bounds@example.com',
        isOwner: true,
      ),
    ]
    ..selectedDay = selectedDay ?? DateTime(2042, 6, 15)
    ..events = const <PlannerEvent>[]
    ..isLoading = false
    ..isLoadingEvents = false
    ..authFlowState = AuthFlowState.signedIn;
}

Widget _app(PlannerController controller, Widget child) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
  ],
  child: MaterialApp(theme: ThemeData(useMaterial3: true), home: child),
);

void _expectCommonBounds(DatePickerDialog picker) {
  expect(picker.firstDate, CalendarDateBounds.firstDate);
  expect(picker.lastDate, CalendarDateBounds.lastDate);
}

void _expectCommonRangeBounds(DateRangePickerDialog picker) {
  expect(picker.firstDate, CalendarDateBounds.firstDate);
  expect(picker.lastDate, CalendarDateBounds.lastDate);
}

Future<void> _cancelPicker(WidgetTester tester) async {
  await tester.tap(find.text('취소').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('홈 날짜 선택기가 공통 범위와 컨트롤러 클램프를 사용한다', (tester) async {
    final auth = _TestAuth();
    final repository = _TestRepository();
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    controller.setSelectedDay(DateTime(1999, 12, 31));
    expect(controller.selectedDay, CalendarDateBounds.firstDate);
    controller.setSelectedDay(DateTime(2101, 1, 1));
    expect(controller.selectedDay, CalendarDateBounds.lastDate);

    await tester.pumpWidget(_app(controller, const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('날짜 선택'));
    await tester.pumpAndSettle();

    final picker = tester.widget<DatePickerDialog>(
      find.byType(DatePickerDialog),
    );
    _expectCommonBounds(picker);
    expect(picker.initialDate, CalendarDateBounds.lastDate);
    await _cancelPicker(tester);
  });

  testWidgets('검색 날짜 범위 선택기가 공통 범위와 366일 제한을 유지한다', (tester) async {
    final auth = _TestAuth();
    final repository = _TestRepository();
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller, const EventSearchScreen()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithIcon(OutlinedButton, Icons.date_range_outlined),
    );
    await tester.pumpAndSettle();

    final rangePicker = tester.widget<DateRangePickerDialog>(
      find.byType(DateRangePickerDialog),
    );
    _expectCommonRangeBounds(rangePicker);
    expect(rangePicker.initialDateRange, isNotNull);

    Navigator.of(
      tester.element(find.byType(DateRangePickerDialog)),
    ).pop<DateTimeRange>(
      DateTimeRange(start: DateTime(2025, 1, 1), end: DateTime(2026, 1, 2)),
    );
    await tester.pumpAndSettle();

    expect(find.text('검색 범위는 366일 이내로 선택해 주세요.'), findsOneWidget);
  });

  testWidgets('일정 편집기 종일 종료일 선택기가 공통 범위와 시작일 하한을 유지한다', (tester) async {
    final auth = _TestAuth();
    final repository = _TestRepository();
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller, const EventEditorScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('종일 일정'));
    await tester.pumpAndSettle();

    final dateButtons = find.widgetWithIcon(
      OutlinedButton,
      Icons.event_outlined,
      skipOffstage: false,
    );
    expect(dateButtons, findsNWidgets(2));
    await tester.ensureVisible(dateButtons.at(1));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithIcon(OutlinedButton, Icons.event_outlined).last,
    );
    await tester.pumpAndSettle();

    final picker = tester.widget<DatePickerDialog>(
      find.byType(DatePickerDialog),
    );
    _expectCommonBounds(picker);
    expect(picker.helpText, '종료 날짜');
    final minimumEndDate = picker.initialDate!;
    final predicate = picker.selectableDayPredicate;
    expect(predicate, isNotNull);
    expect(
      predicate!(minimumEndDate.subtract(const Duration(days: 1))),
      isFalse,
    );
    expect(predicate(minimumEndDate), isTrue);
    await _cancelPicker(tester);
  });

  testWidgets('반복 종료일 선택기가 공통 범위와 반복 시작일 하한을 유지한다', (tester) async {
    final start = DateTime(2042, 6, 15, 9);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(child: RecurrenceEditor(start: start)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('반복 안 함'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('매일').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('종료일').first);
    await tester.pumpAndSettle();
    final untilButton = find.text('종료일을 선택해 주세요');
    await tester.ensureVisible(untilButton);
    await tester.tap(untilButton);
    await tester.pumpAndSettle();

    final picker = tester.widget<DatePickerDialog>(
      find.byType(DatePickerDialog),
    );
    _expectCommonBounds(picker);
    expect(picker.helpText, '반복 종료일');
    expect(picker.initialDate, dateOnly(start));
    final predicate = picker.selectableDayPredicate;
    expect(predicate, isNotNull);
    expect(predicate!(DateTime(2042, 6, 14)), isFalse);
    expect(predicate(DateTime(2042, 6, 15)), isTrue);
    await _cancelPicker(tester);
  });

  testWidgets('월간 반복 종료일 하한은 정규화된 순번 0 날짜다', (tester) async {
    final start = DateTime(2030, 1, 20, 9);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecurrenceEditor(
              start: start,
              initialRule: RecurrenceRule(
                frequency: RecurrenceFrequency.monthly,
                interval: 2,
                monthlyDay: 15,
                end: RecurrenceEnd.until,
                untilDate: DateTime(2030, 2, 15),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final untilButton = find.text('2030년 2월 15일');
    await tester.ensureVisible(untilButton);
    await tester.tap(untilButton);
    await tester.pumpAndSettle();

    final picker = tester.widget<DatePickerDialog>(
      find.byType(DatePickerDialog),
    );
    _expectCommonBounds(picker);
    expect(picker.initialDate, DateTime(2030, 2, 15));
    final predicate = picker.selectableDayPredicate;
    expect(predicate, isNotNull);
    expect(predicate!(DateTime(2030, 2, 14)), isFalse);
    expect(predicate(DateTime(2030, 2, 15)), isTrue);
    await _cancelPicker(tester);
  });
}
