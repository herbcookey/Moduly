import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_search_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(
  id: 'search-user',
  email: 'search@example.com',
  displayName: '검색 사용자',
);

const _group = PlannerGroup(
  id: 'search-group',
  name: '검색 테스트 그룹',
  timezone: 'Asia/Seoul',
  ownerId: 'search-user',
);

class _TestAuth extends AuthRepository {
  _TestAuth() : super();

  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();

  @override
  PlannerUser? get currentUser => null;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _changes.stream;

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

class _SearchCall {
  const _SearchCall({
    required this.query,
    required this.range,
    required this.creatorId,
    required this.participantId,
    required this.cursor,
  });

  final String query;
  final EventRange range;
  final String? creatorId;
  final String? participantId;
  final EventRangeCursor? cursor;
}

class _SearchRepository extends LocalScheduleRepository {
  _SearchRepository({Iterable<EventRangePage> pages = const <EventRangePage>[]})
    : pages = pages.toList(growable: true);

  final List<EventRangePage> pages;
  final List<_SearchCall> calls = <_SearchCall>[];
  bool failNext = false;

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      const Stream<void>.empty();

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
  }) async {
    calls.add(
      _SearchCall(
        query: query,
        range: range,
        creatorId: creatorId,
        participantId: participantId,
        cursor: cursor,
      ),
    );
    if (failNext) {
      failNext = false;
      throw const ScheduleCapabilityException('검색을 불러오지 못했어요.');
    }
    if (pages.isEmpty) return EventRangePage.empty();
    return pages.removeAt(0);
  }
}

PlannerEvent _event({
  required String id,
  required String title,
  DateTime? startAt,
  String ownerId = 'search-user',
  List<String> memberIds = const <String>['search-user'],
  String note = '',
  String seriesId = '',
  String occurrenceKey = 'single',
  bool isOccurrence = false,
  bool allDay = false,
}) {
  final start = (startAt ?? DateTime.utc(2026, 8, 10, 9)).toUtc();
  final end = start.add(const Duration(hours: 1));
  return PlannerEvent(
    id: id,
    groupId: _group.id,
    title: title,
    note: note,
    startAt: start,
    endAt: end,
    ownerId: ownerId,
    memberIds: memberIds,
    timezone: _group.timezone,
    allDay: allDay,
    allDayStartDate: allDay ? DateTime(2026, 8, 10) : null,
    allDayEndDate: allDay ? DateTime(2026, 8, 11) : null,
    seriesId: seriesId.isEmpty ? null : seriesId,
    occurrenceKey: occurrenceKey,
    isOccurrence: isOccurrence,
  );
}

PlannerController _controller(
  _TestAuth auth,
  _SearchRepository repository, {
  Duration debounce = const Duration(milliseconds: 20),
}) {
  final controller =
      PlannerController(
          auth: auth,
          repository: repository,
          searchDebounce: debounce,
        )
        ..user = _user
        ..groups = <PlannerGroup>[_group]
        ..selectedGroup = _group
        ..members = const <PlannerMember>[
          PlannerMember(
            id: 'search-user',
            name: '검색 사용자',
            email: 'search@example.com',
            isOwner: true,
          ),
          PlannerMember(
            id: 'member-hana',
            name: '하나',
            email: 'hana@example.com',
          ),
          PlannerMember(
            id: 'member-inactive',
            name: '비활성 멤버',
            email: 'inactive@example.com',
            isActive: false,
          ),
        ]
        ..selectedDay = DateTime(2026, 8, 10)
        ..isLoading = false
        ..isLoadingEvents = false
        ..authFlowState = AuthFlowState.signedIn;
  return controller;
}

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
);

Widget _screenApp(PlannerController controller) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
  ],
  child: MaterialApp(theme: _theme(), home: const EventSearchScreen()),
);

Widget _routedApp(PlannerController controller, {String initial = '/home'}) {
  final router = GoRouter(
    initialLocation: initial,
    routes: <RouteBase>[
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
      GoRoute(
        path: '/search',
        builder: (context, state) => const EventSearchScreen(),
      ),
      GoRoute(
        path: '/event/:id',
        builder: (context, state) =>
            Text('event route ${state.uri.toString()}'),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      plannerControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp.router(theme: _theme(), routerConfig: router),
  );
}

EventRange _range(DateTime start, DateTime end) => EventRange(
  // EventRange 경계는 선택한 그룹의 IANA 시간대에서 현지 자정을 나타내는
  // UTC 시각이다.
  startUtc: wallTimeToUtc(dateOnly(start), _group.timezone),
  endUtc: wallTimeToUtc(dateOnly(end), _group.timezone),
  viewTimezone: _group.timezone,
);

EventRangePage _page(Iterable<PlannerEvent> events) {
  final values = events.toList(growable: false);
  return EventRangePage(events: values, nextCursor: null, hasMore: false);
}

EventRangePage _pageWithMore(List<PlannerEvent> events) {
  final last = events.last;
  return EventRangePage(
    events: events,
    nextCursor: EventRangeCursor(
      startsAtUtc: last.startAt,
      eventId: last.id,
      occurrenceKey: last.occurrenceKey,
    ),
    hasMore: true,
  );
}

Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 30));
  await tester.pump();
}

void main() {
  testWidgets('홈이 48px 크기의 접근 가능한 검색 동작을 제공한다', (tester) async {
    final auth = _TestAuth();
    final repository = _SearchRepository();
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_routedApp(controller));
    await tester.pump();

    final search = find.byTooltip('일정 검색');
    expect(search, findsOneWidget);
    expect(tester.getSize(search).width, greaterThanOrEqualTo(48));
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.byType(EventSearchScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('빈 검색어가 선택한 달을 기준으로 검색하고 Unicode를 표시한다', (tester) async {
    final auth = _TestAuth();
    final event = _event(
      id: 'unicode-event',
      title: '회의 · 한글 😀 100%',
      note: r'특수문자 _% [] ( )',
    );
    final repository = _SearchRepository(
      pages: <EventRangePage>[
        _page([event]),
      ],
    );
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_screenApp(controller));
    await _settleSearch(tester);

    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.query, isEmpty);
    expect(find.text('회의 · 한글 😀 100%'), findsOneWidget);
    expect(find.textContaining('작성자'), findsWidgets);
    expect(find.bySemanticsLabel('일정 검색어'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('문자 하나인 검색어는 유효성 오류로 알리고 조회하지 않는다', (tester) async {
    final auth = _TestAuth();
    final repository = _SearchRepository(
      pages: <EventRangePage>[_page(const <PlannerEvent>[])],
    );
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_screenApp(controller));
    await _settleSearch(tester);
    final callsBefore = repository.calls.length;
    await tester.enterText(find.byType(TextField), '가');
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();

    expect(find.text('검색어는 두 글자 이상 입력하거나 비워 두세요.'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
    expect(repository.calls.length, callsBefore);

    // 공백만 있는 입력은 지원되는 빈 검색어 모드로 정규화되므로,
    // 유효성 검사 상태를 지우고 범위가 제한된 요청을 한 번 보내야 한다.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repository.calls.length, callsBefore + 1);
    expect(repository.calls.last.query, isEmpty);
    expect(find.text('검색어는 두 글자 이상 입력하거나 비워 두세요.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('생성자, 참여자, 날짜 필터를 함께 전송한다', (tester) async {
    final auth = _TestAuth();
    final event = _event(
      id: 'filtered-event',
      title: '필터 결과',
      ownerId: 'member-hana',
      memberIds: const <String>['member-hana'],
    );
    final repository = _SearchRepository(
      pages: <EventRangePage>[
        _page([event]),
        _page([event]),
      ],
    );
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_screenApp(controller));
    await _settleSearch(tester);
    final selectedRange = _range(
      DateTime.utc(2026, 8, 1),
      DateTime.utc(2026, 8, 20),
    );
    controller.setSearchFilters(
      range: selectedRange,
      creatorId: 'member-hana',
      participantId: 'member-hana',
    );
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();

    expect(repository.calls.last.range, selectedRange);
    expect(repository.calls.last.creatorId, 'member-hana');
    expect(repository.calls.last.participantId, 'member-hana');
    expect(find.text('필터 결과'), findsOneWidget);
    expect(
      find.bySemanticsLabel('검색 날짜 범위 2026.8.1 – 2026.8.19'),
      findsOneWidget,
    );
    expect(find.text('작성자 필터'), findsOneWidget);
    expect(find.text('참여자 필터'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('재시도가 복구되고 범위 제한 더 불러오기가 다음 페이지를 추가한다', (tester) async {
    final auth = _TestAuth();
    final firstPageEvents = List<PlannerEvent>.generate(
      eventSearchDefaultPageSize,
      (index) => _event(
        id: 'page-one-$index',
        title: '페이지 1-$index',
        startAt: DateTime.utc(2026, 8, 1, 0, index),
      ),
    );
    final secondEvent = _event(
      id: 'page-two',
      title: '페이지 2',
      startAt: DateTime.utc(2026, 8, 4),
    );
    final repository = _SearchRepository(
      pages: <EventRangePage>[
        _pageWithMore(firstPageEvents),
        _page([secondEvent]),
      ],
    )..failNext = true;
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_screenApp(controller));
    await _settleSearch(tester);
    expect(find.text('다시 시도'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await _settleSearch(tester);
    expect(find.text('페이지 1-0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('더 불러오기'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('더 불러오기'), findsOneWidget);
    await tester.tap(find.text('더 불러오기'));
    await _settleSearch(tester);
    expect(find.text('페이지 2'), findsOneWidget);
    expect(repository.calls.last.cursor, isNotNull);
    expect(repository.calls.last.cursor!.occurrenceKey, 'single');
    expect(tester.takeException(), isNull);
  });

  testWidgets('발생 일정 결과가 선택 날짜를 갱신하고 불투명한 발생 라우트를 사용한다', (tester) async {
    final auth = _TestAuth();
    const occurrenceKey = 'o00000000000000000001';
    final occurrence = _event(
      id: 'occurrence-row',
      title: '반복 일정 결과',
      startAt: DateTime.utc(2026, 8, 11, 1),
      seriesId: 'series-anchor',
      occurrenceKey: occurrenceKey,
      isOccurrence: true,
    );
    final repository = _SearchRepository(
      pages: <EventRangePage>[
        _page([occurrence]),
      ],
    );
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_routedApp(controller, initial: '/search'));
    await _settleSearch(tester);
    await tester.tap(find.text('반복 일정 결과'));
    await tester.pumpAndSettle();

    expect(controller.selectedDay, DateTime(2026, 8, 11));
    expect(
      find.textContaining('/event/series-anchor?occurrence=$occurrenceKey'),
      findsOneWidget,
    );
    expect(find.textContaining('반복 일정 결과'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('큰 텍스트, 키보드 인셋, 작은 뷰포트에서도 의미 정보를 유지한다', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _TestAuth();
    final repository = _SearchRepository(
      pages: <EventRangePage>[_page(const <PlannerEvent>[])],
    );
    final controller = _controller(auth, repository);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          textScaler: TextScaler.linear(2),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
        child: _screenApp(controller),
      ),
    );
    await _settleSearch(tester);

    expect(find.bySemanticsLabel('일정 검색어'), findsOneWidget);
    expect(find.text('일정 검색'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
