// 추가형 일정 검색 기능에 집중한 비 UI 검사다.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(id: 'demo-user', email: 'demo@example.com');

PlannerEvent _event({
  required String id,
  required String title,
  required DateTime startAt,
  String? ownerId,
  String note = '',
  List<String> memberIds = const <String>['demo-user'],
}) => PlannerEvent(
  id: id,
  groupId: 'demo-group',
  title: title,
  note: note,
  startAt: startAt,
  endAt: startAt.add(const Duration(minutes: 20)),
  ownerId: ownerId ?? 'demo-user',
  memberIds: memberIds,
  timezone: 'UTC',
);

Map<String, dynamic> _eventRow({
  String id = 'event-1',
  String title = '회의 💙',
  String description = '메모',
  String groupId = 'group-1',
  String createdBy = 'demo-user',
  String startsAt = '2030-01-02T09:00:00.000Z',
  String endsAt = '2030-01-02T10:00:00.000Z',
  Object? memberIds = const <String>['demo-user'],
}) => <String, dynamic>{
  'id': id,
  'group_id': groupId,
  'created_by': createdBy,
  'title': title,
  'description': description,
  'starts_at': startsAt,
  'ends_at': endsAt,
  'timezone': 'UTC',
  'is_all_day': false,
  'all_day_start': null,
  'all_day_end': null,
  'version': 1,
  'deleted_at': null,
  'created_at': '2030-01-01T00:00:00.000Z',
  'updated_at': '2030-01-01T00:00:00.000Z',
  'color_value': 0xff476a6f,
  'member_ids': memberIds,
  // 검색 RPC 행에는 항상 완전한 발생 일정 투영값이 들어 있다. 단일 일정 행은
  // v2 키셋 페이지네이션에 필요한 명시적 `single` 튜플 요소를 사용한다.
  'event_id': id,
  'series_id': id,
  'occurrence_key': 'single',
  'occurrence_index': 0,
  'occurrence_version': 1,
  'is_occurrence': false,
  'scheduled_starts_at': startsAt,
  'scheduled_ends_at': endsAt,
  'recurrence_rule': null,
};

class _RpcTransport extends http.BaseClient {
  _RpcTransport(this.payload);

  Object? payload;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
      request: request,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

SupabaseClient _client(http.BaseClient transport) => SupabaseClient(
  'https://example.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
  httpClient: transport,
);

class _AuthenticatedRepository extends SupabaseScheduleRepository {
  _AuthenticatedRepository(super.client, this.sessionUserId);

  final String? sessionUserId;

  @override
  String? get currentSessionUserId => sessionUserId;
}

class _SearchRepository extends LocalScheduleRepository {
  final List<String> queries = <String>[];
  final Map<String, Completer<EventRangePage>> pending =
      <String, Completer<EventRangePage>>{};
  final Map<String, List<Completer<EventRangePage>>> pendingByQuery =
      <String, List<Completer<EventRangePage>>>{};
  final StreamController<void> invalidations =
      StreamController<void>.broadcast();

  @override
  bool get useBoundedEventRangeReads => true;

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
  }) {
    queries.add(query);
    final completer = Completer<EventRangePage>();
    pending[query] = completer;
    pendingByQuery
        .putIfAbsent(query, () => <Completer<EventRangePage>>[])
        .add(completer);
    return completer.future;
  }

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) => Future<EventRangePage>.value(EventRangePage.empty());

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      invalidations.stream;

  Future<void> close() => invalidations.close();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('일정 검색 모델', () {
    test('Unicode 스칼라 길이와 UTF-8 경계를 정규화한다', () {
      expect(normalizeEventSearchQuery('  회의  '), '회의');
      expect(normalizeEventSearchQuery('💙_'), '💙_');
      expect(normalizeEventSearchQuery(''), isEmpty);
      expect(() => normalizeEventSearchQuery('a'), throwsFormatException);
      expect(
        () => normalizeEventSearchQuery('💙' * 101),
        throwsFormatException,
      );
      expect(() => normalizeEventSearchQuery('가' * 201), throwsFormatException);
      expect(isValidEventSearchQuery('회의'), isTrue);
      expect(isValidEventSearchQuery('x'), isFalse);
    });
  });

  group('LocalScheduleRepository 일정 검색', () {
    test('리터럴 Unicode/특수 텍스트와 생성자/참여자 필터가 일치한다', () async {
      final repository = LocalScheduleRepository();
      final day = calendarDayBounds(DateTime(2030, 1, 2), 'UTC').toEventRange();
      final literal = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: '회의 💙 100%_완료',
          note: r'메모 [literal] \',
          startAt: DateTime.utc(2030, 1, 2, 9),
          endAt: DateTime.utc(2030, 1, 2, 10),
          memberIds: const <String>['demo-user', 'member-jin'],
        ),
      );
      final participantPage = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: day,
        query: '%_',
        participantId: 'member-jin',
      );
      expect(participantPage.events.single.id, literal.id);
      final creatorPage = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: day,
        query: '회의',
        creatorId: 'demo-user',
      );
      expect(creatorPage.events.single.title, contains('100%_'));
      final notePage = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: day,
        query: '메모',
      );
      expect(notePage.events.single.note, contains(r'\'));
    });

    test('반복 행을 구체화하고 범위가 제한된 v2 키셋 페이지를 사용한다', () async {
      final repository = LocalScheduleRepository();
      final range = EventRange(
        startUtc: DateTime.utc(2030, 1, 1),
        endUtc: DateTime.utc(2030, 1, 4),
        viewTimezone: 'UTC',
      );
      final recurring = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: '반복 회의',
          startAt: DateTime.utc(2030, 1, 1, 9),
          endAt: DateTime.utc(2030, 1, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.count,
            count: 3,
          ),
        ),
      );
      final first = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        query: '반복',
        limit: 2,
      );
      expect(first.events, hasLength(2));
      expect(first.hasMore, isTrue);
      expect(first.nextCursor, isNotNull);
      expect(first.nextCursor!.occurrenceKey, isNotEmpty);
      final second = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        query: '반복',
        cursor: first.nextCursor,
        limit: 2,
      );
      expect(second.events, hasLength(1));
      expect(second.events.first.seriesId, recurring.id);
      expect(second.events.first.occurrenceKey, isNot('single'));

      final bulkRange = EventRange(
        startUtc: DateTime.utc(2030, 2, 1),
        endUtc: DateTime.utc(2030, 2, 2),
        viewTimezone: 'UTC',
      );
      for (var index = 0; index < 1001; index++) {
        final start = bulkRange.startUtc.add(Duration(minutes: index));
        await repository.createEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: 'Hit $index',
            startAt: start,
            endAt: start.add(const Duration(minutes: 1)),
          ),
        );
      }
      final seen = <String>{};
      EventRangeCursor? cursor;
      var hasMore = true;
      while (hasMore) {
        final page = await repository.searchEvents(
          userId: 'demo-user',
          groupId: 'demo-group',
          range: bulkRange,
          query: 'hit',
          cursor: cursor,
          limit: 100,
        );
        expect(page.events.length, lessThanOrEqualTo(100));
        for (final event in page.events) {
          expect(seen.add(event.identityKey), isTrue);
        }
        cursor = page.nextCursor;
        hasMore = page.hasMore;
      }
      expect(seen, hasLength(1001));
    });

    test('비활성 필터 사용자와 v2가 아닌 연속 조회 커서를 거부한다', () async {
      final repository = LocalScheduleRepository(
        seedMembers: const <PlannerMember>[
          PlannerMember(
            id: 'inactive',
            name: 'Inactive',
            email: 'inactive@example.com',
            isActive: false,
          ),
        ],
      );
      final range = calendarDayBounds(
        DateTime(2030, 1, 2),
        'UTC',
      ).toEventRange();
      await expectLater(
        repository.searchEvents(
          userId: 'demo-user',
          groupId: 'demo-group',
          range: range,
          query: '',
          creatorId: 'inactive',
        ),
        throwsA(isA<ScheduleAuthorizationException>()),
      );
      await expectLater(
        repository.searchEvents(
          userId: 'demo-user',
          groupId: 'demo-group',
          range: range,
          query: '',
          cursor: EventRangeCursor(
            startsAtUtc: range.startUtc,
            eventId: 'event-1',
          ),
        ),
        throwsA(isA<ScheduleValidationException>()),
      );
    });
  });

  group('Supabase 일정 검색 경계', () {
    test('현재 세션을 요구하고 정확한 RPC 매개변수를 보낸다', () async {
      final noSessionTransport = _RpcTransport(<String, dynamic>{});
      final noSessionClient = _client(noSessionTransport);
      final noSession = _AuthenticatedRepository(noSessionClient, null);
      final range = calendarDayBounds(
        DateTime(2030, 1, 2),
        'UTC',
      ).toEventRange();
      await expectLater(
        noSession.searchEvents(
          userId: 'demo-user',
          groupId: 'group-1',
          range: range,
          query: '회의',
        ),
        throwsA(isA<ScheduleAuthorizationException>()),
      );
      expect(noSessionTransport.requests, isEmpty);
      await noSessionClient.dispose();

      final transport = _RpcTransport(<String, dynamic>{
        'events': <Map<String, dynamic>>[_eventRow()],
        'next_cursor': null,
        'has_more': false,
      });
      final client = _client(transport);
      final repository = _AuthenticatedRepository(client, 'demo-user');
      addTearDown(client.dispose);
      final page = await repository.searchEvents(
        userId: 'demo-user',
        groupId: 'group-1',
        range: range,
        query: ' 회의 💙 ',
        creatorId: 'demo-user',
        participantId: 'demo-user',
      );
      expect(page.events.single.title, '회의 💙');
      final request = transport.requests.single as http.Request;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['p_query'], '회의 💙');
      expect(body['p_group_id'], 'group-1');
      expect(body['p_creator_id'], 'demo-user');
      expect(body['p_participant_id'], 'demo-user');
      expect(body.containsKey('p_user_id'), isFalse);
      expect(request.url.path, contains('search_events_v1'));
      await expectLater(
        repository.searchEvents(
          userId: 'demo-user',
          groupId: 'group-1',
          range: range,
          query: 'x',
        ),
        throwsFormatException,
      );
      expect(transport.requests, hasLength(1));
    });

    test('잘못된 엄격 검색 커서와 응답 행을 거부한다', () async {
      final range = calendarDayBounds(
        DateTime(2030, 1, 2),
        'UTC',
      ).toEventRange();
      final malformed = _RpcTransport(<String, dynamic>{
        'events': <Map<String, dynamic>>[
          _eventRow(startsAt: '2030-02-30T09:00:00Z'),
        ],
        'next_cursor': null,
        'has_more': false,
      });
      final client = _client(malformed);
      final repository = _AuthenticatedRepository(client, 'demo-user');
      addTearDown(client.dispose);
      await expectLater(
        repository.searchEvents(
          userId: 'demo-user',
          groupId: 'group-1',
          range: range,
          query: '회의',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );

      final baseOnlyRow = _eventRow()
        ..removeWhere(
          (key, _) => <String>{
            'event_id',
            'series_id',
            'occurrence_key',
            'occurrence_index',
            'occurrence_version',
            'is_occurrence',
            'scheduled_starts_at',
            'scheduled_ends_at',
            'recurrence_rule',
          }.contains(key),
        );
      final baseOnlyTransport = _RpcTransport(<String, dynamic>{
        'events': <Map<String, dynamic>>[baseOnlyRow],
        'next_cursor': null,
        'has_more': false,
      });
      final baseOnlyClient = _client(baseOnlyTransport);
      final baseOnlyRepository = _AuthenticatedRepository(
        baseOnlyClient,
        'demo-user',
      );
      addTearDown(baseOnlyClient.dispose);
      await expectLater(
        baseOnlyRepository.searchEvents(
          userId: 'demo-user',
          groupId: 'group-1',
          range: range,
          query: '회의',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });
  });

  test('설정으로 차단된 저장소가 검색을 명시적으로 실패 처리한다', () async {
    final repository = ConfigurationBlockedScheduleRepository('blocked');
    final range = calendarDayBounds(DateTime(2030, 1, 2), 'UTC').toEventRange();
    await expectLater(
      repository.searchEvents(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        query: '',
      ),
      throwsA(isA<RuntimeConfigurationException>()),
    );
  });

  group('PlannerController 일정 검색 상태', () {
    PlannerController controllerFor(_SearchRepository repository) {
      final controller = PlannerController(
        auth: AuthRepository(),
        repository: repository,
        searchDebounce: const Duration(milliseconds: 20),
      );
      controller.user = _user;
      controller.selectedGroup = const PlannerGroup(
        id: 'demo-group',
        name: 'Demo',
        timezone: 'UTC',
      );
      controller.selectedEventRange = EventRange(
        startUtc: DateTime.utc(2030, 1, 2),
        endUtc: DateTime.utc(2030, 1, 3),
        viewTimezone: 'UTC',
      );
      return controller;
    }

    test('마지막 검색어로 디바운스하고 달력 범위를 변경하지 않는다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final calendarRange = controller.selectedEventRange;
      controller.setSearchQuery('first');
      controller.setSearchQuery('second');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repository.queries, <String>['second']);
      repository.pending['second']!.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'second',
              title: 'second',
              startAt: DateTime.utc(2030, 1, 2, 9),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.searchResults.single.id, 'second');
      expect(controller.selectedEventRange, calendarRange);
    });

    test('취소가 늦은 성공과 오래된 필터 오류를 차단한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final first = controller.searchEvents(query: 'alpha', immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(repository.pending, contains('alpha'));
      controller.cancelSearch();
      repository.pending['alpha']!.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'late',
              title: 'alpha',
              startAt: DateTime.utc(2030, 1, 2, 9),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await first;
      expect(controller.searchResults, isEmpty);
      expect(controller.hasActiveSearch, isFalse);

      final stale = controller.searchEvents(query: 'creator', immediate: true);
      await Future<void>.delayed(Duration.zero);
      controller.setSearchFilters(creatorId: 'member-jin');
      repository.pending['creator']!.completeError(
        const ScheduleAuthorizationException('stale'),
      );
      await stale;
      expect(controller.searchError, isNull);
    });

    test('강제 SQLSTATE 28000 거부가 마지막 정상 검색 결과를 지운다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final request = controller.searchEvents(
        query: 'sqlstate',
        immediate: true,
      );
      await Future<void>.delayed(Duration.zero);
      final events = List<PlannerEvent>.generate(
        eventSearchDefaultPageSize,
        (index) => _event(
          id: 'sqlstate-$index',
          title: 'sqlstate',
          startAt: DateTime.utc(2030, 1, 2, 9).add(Duration(minutes: index)),
        ),
      );
      final cursor = EventRangeCursor(
        startsAtUtc: events.last.startAt,
        eventId: events.last.id,
        occurrenceKey: 'single',
      );
      repository.pending['sqlstate']!.complete(
        EventRangePage(events: events, nextCursor: cursor, hasMore: true),
      );
      await request;
      expect(controller.searchResults, hasLength(eventSearchDefaultPageSize));
      expect(controller.searchCursor, cursor);
      expect(controller.hasMoreSearchResults, isTrue);

      final refresh = controller.refreshSearch(force: true);
      await Future<void>.delayed(Duration.zero);
      repository.pendingByQuery['sqlstate']![1].completeError(
        const PostgrestException(message: 'permission denied', code: '28000'),
      );
      await refresh;
      expect(controller.searchResults, isEmpty);
      expect(controller.searchCursor, isNull);
      expect(controller.hasMoreSearchResults, isFalse);
    });

    test('강제 일시적 새로 고침이 커서를 복원하고 더 불러오기를 유지한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final first = controller.searchEvents(query: 'restore', immediate: true);
      await Future<void>.delayed(Duration.zero);
      final firstEvents = List<PlannerEvent>.generate(
        eventSearchDefaultPageSize,
        (index) => _event(
          id: 'restore-$index',
          title: 'restore',
          startAt: DateTime.utc(2030, 1, 2, 9).add(Duration(minutes: index)),
        ),
      );
      final cursor = EventRangeCursor(
        startsAtUtc: firstEvents.last.startAt,
        eventId: firstEvents.last.id,
        occurrenceKey: 'single',
      );
      repository.pending['restore']!.complete(
        EventRangePage(events: firstEvents, nextCursor: cursor, hasMore: true),
      );
      await first;

      final refresh = controller.refreshSearch(force: true);
      await Future<void>.delayed(Duration.zero);
      repository.pendingByQuery['restore']![1].completeError(
        StateError('temporary'),
      );
      await refresh;
      expect(controller.searchResults, hasLength(firstEvents.length));
      expect(controller.searchCursor, cursor);
      expect(controller.hasMoreSearchResults, isTrue);

      final loadMore = controller.loadMoreSearchResults();
      await Future<void>.delayed(Duration.zero);
      final nextEvents = List<PlannerEvent>.generate(
        eventSearchDefaultPageSize,
        (index) => _event(
          id: 'restore-next-$index',
          title: 'restore',
          startAt: DateTime.utc(2030, 1, 2, 10).add(Duration(minutes: index)),
        ),
      );
      repository.pendingByQuery['restore']![2].complete(
        EventRangePage(events: nextEvents, nextCursor: null, hasMore: false),
      );
      await loadMore;
      expect(controller.searchResults, hasLength(firstEvents.length * 2));
      expect(controller.searchCursor, isNull);
      expect(controller.hasMoreSearchResults, isFalse);
    });

    test('그룹 및 사용자 변경 후 늦은 첫 페이지를 차단한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final groupRequest = controller.searchEvents(
        query: 'group',
        immediate: true,
      );
      await Future<void>.delayed(Duration.zero);
      controller.selectedGroup = const PlannerGroup(
        id: 'other-group',
        name: 'Other',
        timezone: 'UTC',
      );
      repository.pending['group']!.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'late-group',
              title: 'group',
              startAt: DateTime.utc(2030, 1, 2, 9),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await groupRequest;
      expect(controller.searchResults, isEmpty);

      controller.selectedGroup = const PlannerGroup(
        id: 'demo-group',
        name: 'Demo',
        timezone: 'UTC',
      );
      final userRequest = controller.searchEvents(
        query: 'user',
        immediate: true,
      );
      await Future<void>.delayed(Duration.zero);
      controller.user = const PlannerUser(
        id: 'member-jin',
        email: 'jin@example.com',
      );
      repository.pending['user']!.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'late-user',
              title: 'user',
              startAt: DateTime.utc(2030, 1, 2, 9),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await userRequest;
      expect(controller.searchResults, isEmpty);
    });

    test('범위/필터 변경이 커서를 초기화하고 늦은 페이지를 차단한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final request = controller.searchEvents(
        query: 'criteria',
        immediate: true,
      );
      await Future<void>.delayed(Duration.zero);
      final nextRange = EventRange(
        startUtc: DateTime.utc(2030, 1, 3),
        endUtc: DateTime.utc(2030, 1, 4),
        viewTimezone: 'UTC',
      );
      controller.setSearchFilters(range: nextRange, creatorId: 'member-jin');
      expect(controller.searchCursor, isNull);
      expect(controller.searchRange, nextRange);
      repository.pending['criteria']!.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'late-criteria',
              title: 'criteria',
              startAt: DateTime.utc(2030, 1, 2, 9),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await request;
      expect(controller.searchResults, isEmpty);
      expect(controller.searchCursor, isNull);
    });

    test('잘못된 초안을 비활성 상태로 두고 RPC를 보내지 않는다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      controller.setSearchQuery('x');
      await Future<void>.delayed(Duration.zero);
      expect(controller.searchError, isNotNull);
      expect(controller.hasActiveSearch, isFalse);
      expect(repository.queries, isEmpty);
      await controller.refreshSearch(force: true);
      expect(repository.queries, isEmpty);
    });

    test('부모 무효화가 활성 검색 새로 고침으로 병합된다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      controller.groups = const <PlannerGroup>[
        PlannerGroup(id: 'demo-group', name: 'Demo', timezone: 'UTC'),
      ];
      await controller.selectGroup('demo-group');
      final searchRange = controller.selectedEventRange!;
      final request = controller.searchEvents(
        query: 'invalidate',
        range: searchRange,
        immediate: true,
      );
      await Future<void>.delayed(Duration.zero);
      repository.invalidations.add(null);
      repository.invalidations.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(repository.queries, <String>['invalidate']);
      final result = EventRangePage(
        events: <PlannerEvent>[
          _event(
            id: 'invalidate',
            title: 'invalidate',
            startAt: searchRange.startUtc.add(const Duration(hours: 1)),
          ),
        ],
        nextCursor: null,
        hasMore: false,
      );
      repository.pending['invalidate']!.complete(result);
      await request;
      await Future<void>.delayed(Duration.zero);
      expect(repository.queries, <String>['invalidate', 'invalidate']);
      repository.pending['invalidate']!.complete(result);
      await Future<void>.delayed(Duration.zero);
      expect(controller.searchResults.single.id, 'invalidate');
    });

    test('권한 거부는 결과를 지우고 일시적 검색 실패는 결과를 보존한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final request = controller.searchEvents(query: 'error', immediate: true);
      await Future<void>.delayed(Duration.zero);
      final event = _event(
        id: 'good',
        title: 'error',
        startAt: DateTime.utc(2030, 1, 2, 9),
      );
      repository.pending['error']!.complete(
        EventRangePage(
          events: <PlannerEvent>[event],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await request;
      final transient = controller.refreshSearch(force: true);
      await Future<void>.delayed(Duration.zero);
      repository.pending['error']!.completeError(StateError('temporary'));
      await transient;
      expect(controller.searchResults.single.id, 'good');
      expect(controller.searchError, isNotNull);

      final denied = controller.refreshSearch(force: true);
      await Future<void>.delayed(Duration.zero);
      repository.pending['error']!.completeError(
        const ScheduleAuthorizationException('denied'),
      );
      await denied;
      expect(controller.searchResults, isEmpty);
      expect(controller.searchCursor, isNull);
    });

    test('취소가 연속 조회 커서를 지운다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final request = controller.searchEvents(query: 'cursor', immediate: true);
      await Future<void>.delayed(Duration.zero);
      final events = List<PlannerEvent>.generate(
        eventSearchDefaultPageSize,
        (index) => _event(
          id: 'cursor-$index',
          title: 'cursor',
          startAt: DateTime.utc(2030, 1, 2, 9).add(Duration(minutes: index)),
        ),
      );
      repository.pending['cursor']!.complete(
        EventRangePage(
          events: events,
          nextCursor: EventRangeCursor(
            startsAtUtc: events.last.startAt,
            eventId: events.last.id,
            occurrenceKey: 'single',
          ),
          hasMore: true,
        ),
      );
      await request;
      expect(controller.searchCursor, isNotNull);
      controller.cancelSearch();
      expect(controller.searchCursor, isNull);
    });

    test('검색 페이지 처리를 직렬화하고 일시적 실패 때 마지막 정상 결과를 보존한다', () async {
      final repository = _SearchRepository();
      final controller = controllerFor(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final first = controller.searchEvents(query: 'page', immediate: true);
      await Future<void>.delayed(Duration.zero);
      final firstEvents = List<PlannerEvent>.generate(
        eventSearchDefaultPageSize,
        (index) => _event(
          id: 'page-$index',
          title: 'page',
          startAt: DateTime.utc(2030, 1, 2, 9).add(Duration(minutes: index)),
        ),
      );
      repository.pending['page']!.complete(
        EventRangePage(
          events: firstEvents,
          nextCursor: EventRangeCursor(
            startsAtUtc: firstEvents.last.startAt,
            eventId: firstEvents.last.id,
            occurrenceKey: 'single',
          ),
          hasMore: true,
        ),
      );
      await first;
      expect(controller.hasMoreSearchResults, isTrue);

      final more = controller.loadMoreSearchResults();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isLoadingMoreSearch, isTrue);
      final duplicate = controller.loadMoreSearchResults();
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.queries.where((query) => query == 'page'),
        hasLength(2),
      );
      // 가짜 구현은 검색어별로 대기 요청을 색인하므로 직렬화된 더 불러오기
      // Future 하나를 마지막 페이지로 완료한다.
      repository.pending['page']!.completeError(StateError('transient'));
      await more;
      await duplicate;
      expect(controller.searchResults, hasLength(eventSearchDefaultPageSize));
      expect(controller.searchError, isNotNull);
    });
  });
}
