// Focused non-UI coverage for bounded calendar reads and the local calendar
// projection.  The Supabase migration has independent SQL tests; the remote
// adapter cases below only exercise the request/parser boundary.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _rangeUser = PlannerUser(id: 'demo-user', email: 'demo@example.com');

PlannerEvent _event({
  required String id,
  required String groupId,
  required DateTime startAt,
  required DateTime endAt,
  bool allDay = false,
  List<String> memberIds = const <String>['demo-user'],
  DateTime? allDayStartDate,
  DateTime? allDayEndDate,
}) => PlannerEvent(
  id: id,
  groupId: groupId,
  title: id,
  startAt: startAt,
  endAt: endAt,
  allDay: allDay,
  ownerId: 'demo-user',
  memberIds: memberIds,
  timezone: 'UTC',
  allDayStartDate: allDayStartDate,
  allDayEndDate: allDayEndDate,
);

Map<String, dynamic> _eventRow({
  String id = 'event-1',
  String groupId = 'group-1',
  Object? memberIds = const <String>['demo-user'],
  Object? version = 1,
  String startsAt = '2030-01-02T09:00:00.000Z',
  String endsAt = '2030-01-02T10:00:00.000Z',
  String timezone = 'UTC',
  bool isAllDay = false,
  Object? allDayStart,
  Object? allDayEnd,
}) => <String, dynamic>{
  'id': id,
  'group_id': groupId,
  'created_by': 'demo-user',
  'title': id,
  'description': '',
  'starts_at': startsAt,
  'ends_at': endsAt,
  'timezone': timezone,
  'is_all_day': isAllDay,
  'all_day_start': allDayStart,
  'all_day_end': allDayEnd,
  'version': version,
  'deleted_at': null,
  'created_at': '2030-01-01T00:00:00.000Z',
  'updated_at': '2030-01-01T00:00:00.000Z',
  'color_value': 0xff476a6f,
  'member_ids': memberIds,
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

class _LegacyRealtimeRepository extends SupabaseScheduleRepository {
  factory _LegacyRealtimeRepository() {
    final client = _client(_RpcTransport(<String, dynamic>{}));
    return _LegacyRealtimeRepository._(client);
  }

  _LegacyRealtimeRepository._(this.client) : super(client);

  final SupabaseClient client;
  final StreamController<List<Map<String, dynamic>>> parentRows =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final Map<String, List<String>> assignments = <String, List<String>>{};

  @override
  Stream<List<Map<String, dynamic>>> eventRowsStream(String groupId) =>
      parentRows.stream;

  @override
  Future<Map<String, List<String>>> eventMemberRows(
    Iterable<String> eventIds,
  ) async {
    return <String, List<String>>{
      for (final id in eventIds)
        id: List<String>.unmodifiable(
          assignments[id] ?? const <String>['demo-user'],
        ),
    };
  }
}

class _RangeRepository extends LocalScheduleRepository {
  _RangeRepository(this.pages);

  final List<EventRangePage> pages;
  final List<EventRange> ranges = <EventRange>[];
  Future<EventRangePage> Function(EventRange range)? responseForRange;
  Future<EventRangePage> Function(EventRange range, String? participantId)?
  responseForRangeWithParticipant;
  PlannerEvent? eventByIdResult;
  Object? eventByIdError;
  Future<PlannerEvent?> Function(String userId, String groupId, String eventId)?
  eventByIdCallback;
  int eventByIdCalls = 0;
  final StreamController<void> invalidations =
      StreamController<void>.broadcast();

  @override
  bool get useBoundedEventRangeReads => true;

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async {
    ranges.add(range);
    final participantCallback = responseForRangeWithParticipant;
    if (participantCallback != null) {
      return participantCallback(range, participantId);
    }
    final callback = responseForRange;
    if (callback != null) return callback(range);
    if (pages.isEmpty) return EventRangePage.empty();
    return pages.removeAt(0);
  }

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      invalidations.stream;

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) async {
    eventByIdCalls++;
    final error = eventByIdError;
    if (error != null) throw error;
    final callback = eventByIdCallback;
    if (callback != null) return callback(userId, groupId, eventId);
    return eventByIdResult;
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) =>
      Future<List<PlannerMember>>.value(const <PlannerMember>[
        PlannerMember(
          id: 'demo-user',
          name: 'Demo',
          email: 'demo@example.com',
          isOwner: true,
        ),
      ]);

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) =>
      Future<List<InviteCode>>.value(const <InviteCode>[]);

  Future<void> close() => invalidations.close();
}

class _LegacyEmptyCreateRepository extends LocalScheduleRepository {
  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async => PlannerEvent(
    id: 'legacy-created',
    groupId: groupId,
    title: draft.title,
    startAt: draft.startAt,
    endAt: draft.endAt,
    ownerId: userId,
    timezone: draft.timezone,
  );
}

class _StrictEmptyCreateRepository extends _LegacyEmptyCreateRepository {
  @override
  bool get requireExactEventMutationResults => true;
}

class _LegacyRefreshRepository extends LocalScheduleRepository {
  int groupsReads = 0;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    groupsReads++;
    return const <PlannerGroup>[
      PlannerGroup(id: 'demo-group', name: 'Demo', timezone: 'UTC'),
    ];
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('bounded calendar models and timezone policy', () {
    test(
      'cursor is strict v1 URL-safe base64 and page snapshots are immutable',
      () {
        final cursor = EventRangeCursor(
          startsAtUtc: DateTime.utc(2030, 1, 2, 9),
          eventId: 'event-1',
        );
        final token = cursor.toToken();
        expect(token, isNot(contains('=')));
        expect(EventRangeCursor.fromToken(token), cursor);

        final timezoneLess = base64Url
            .encode(
              utf8.encode(
                jsonEncode(<String, Object>{
                  'v': 1,
                  'starts_at': '2030-01-02T09:00:00',
                  'event_id': 'event-1',
                }),
              ),
            )
            .replaceAll('=', '');
        expect(
          () => EventRangeCursor.decode(timezoneLess),
          throwsFormatException,
        );
        String cursorToken(String startsAt) => base64Url
            .encode(
              utf8.encode(
                jsonEncode(<String, Object>{
                  'v': 1,
                  'starts_at': startsAt,
                  'event_id': 'event-1',
                }),
              ),
            )
            .replaceAll('=', '');
        const malformedStarts = <String>[
          '2030-02-30T09:00:00Z',
          '2031-02-29T09:00:00Z',
          '2030-01-02T24:00:00Z',
          '2030-01-02T09:60:00Z',
          '2030-01-02T09:00:00+99:99',
          '2030-01-02T09:00:00.1234567Z',
          '2030-1-02T09:00:00Z',
          '2030-01-02 09:00:00Z',
          '2030-01-02T09:00Z',
          '2030-01-02T09:00:00z',
          '2030-01-02T09:00:00+0900',
        ];
        for (final startsAt in malformedStarts) {
          expect(
            () => EventRangeCursor.decode(cursorToken(startsAt)),
            throwsFormatException,
            reason: startsAt,
          );
        }
        final offsetCursor = EventRangeCursor.decode(
          cursorToken('2030-01-02T09:00:00.123456+09:30'),
        );
        expect(
          offsetCursor.startsAtUtc,
          DateTime.utc(2030, 1, 1, 23, 30, 0, 123, 456),
        );
        expect(() => EventRangeCursor.decode('$token='), throwsFormatException);
        expect(
          () => EventRangeCursor(
            startsAtUtc: DateTime.utc(2030),
            eventId: 'event-1',
            occurrenceKey: 'future-v2',
          ).encode(),
          throwsFormatException,
        );

        final source = <PlannerEvent>[
          _event(
            id: 'event-1',
            groupId: 'group-1',
            startAt: DateTime.utc(2030, 1, 2, 9),
            endAt: DateTime.utc(2030, 1, 2, 10),
          ),
        ];
        final page = EventRangePage(
          events: source,
          nextCursor: null,
          hasMore: false,
        );
        source.clear();
        expect(page.events, hasLength(1));
        expect(() => page.events.clear(), throwsUnsupportedError);
        expect(
          () => EventRangePage(
            events: const <PlannerEvent>[],
            nextCursor: cursor,
            hasMore: true,
          ),
          returnsNormally,
        );
        expect(
          () => EventRangePage(
            events: const <PlannerEvent>[],
            nextCursor: cursor,
            hasMore: false,
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'day/month/agenda bounds use local midnight and DST-safe date counts',
      () {
        final dst = calendarDayBounds(
          DateTime(2030, 3, 10),
          'America/Los_Angeles',
        );
        expect(dst.startUtc, DateTime.utc(2030, 3, 10, 8));
        expect(dst.endUtc, DateTime.utc(2030, 3, 11, 7));
        expect(calendarDateSpan(dst.startUtc, dst.endUtc, dst.timezone), 1);

        final february = calendarMonthBounds(2030, 2, 'America/New_York');
        expect(february.startDate.weekday, DateTime.monday);
        expect(
          calendarDateSpan(
            february.startUtc,
            february.endUtc,
            february.timezone,
          ),
          35,
        );
        final agenda = calendarAgendaBounds(2030, 2, 'America/New_York');
        expect(agenda.startDate, DateTime(2030, 2, 1));
        expect(agenda.endDate, DateTime(2030, 3, 1));
        expect(
          calendarDateSpan(agenda.startUtc, agenda.endUtc, agenda.timezone),
          28,
        );
      },
    );

    test(
      'timed overlap is instant half-open and all-day overlap is date half-open',
      () {
        final range = calendarDayBounds(
          DateTime(2030, 3, 10),
          'America/Los_Angeles',
        ).toEventRange();
        final atStart = _event(
          id: 'at-start',
          groupId: 'group-1',
          startAt: range.startUtc,
          endAt: range.startUtc.add(const Duration(minutes: 5)),
        );
        final atEnd = _event(
          id: 'at-end',
          groupId: 'group-1',
          startAt: range.endUtc,
          endAt: range.endUtc.add(const Duration(minutes: 5)),
        );
        final endingAtStart = _event(
          id: 'ending-at-start',
          groupId: 'group-1',
          startAt: range.startUtc.subtract(const Duration(minutes: 5)),
          endAt: range.startUtc,
        );
        expect(eventOverlapsCalendarRange(atStart, range), isTrue);
        expect(eventOverlapsCalendarRange(atEnd, range), isFalse);
        expect(eventOverlapsCalendarRange(endingAtStart, range), isFalse);

        final allDayInside = _event(
          id: 'all-day-inside',
          groupId: 'group-1',
          startAt: DateTime.utc(2030, 3, 10),
          endAt: DateTime.utc(2030, 3, 11),
          allDay: true,
          allDayStartDate: DateTime(2030, 3, 10),
          allDayEndDate: DateTime(2030, 3, 11),
        );
        final allDayBefore = allDayInside.copyWith(
          id: 'all-day-before',
          startAt: DateTime.utc(2030, 3, 9),
          endAt: DateTime.utc(2030, 3, 10),
          allDayStartDate: DateTime(2030, 3, 9),
          allDayEndDate: DateTime(2030, 3, 10),
        );
        expect(eventOverlapsCalendarRange(allDayInside, range), isTrue);
        expect(eventOverlapsCalendarRange(allDayBefore, range), isFalse);
        expect(
          eventOverlapsCalendarDate(
            allDayInside,
            DateTime(2030, 3, 9),
            'America/Los_Angeles',
          ),
          isFalse,
        );
      },
    );
  });

  group('LocalScheduleRepository bounded reads', () {
    test(
      'uses exact overlap, participant membership, and keyset pages over 1000 rows',
      () async {
        final repository = LocalScheduleRepository();
        final range = calendarDayBounds(
          DateTime(2031, 1, 2),
          'UTC',
        ).toEventRange();
        final endingAtStart = await repository.createEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: 'ending',
            startAt: range.startUtc.subtract(const Duration(hours: 1)),
            endAt: range.startUtc,
          ),
        );
        final startingAtEnd = await repository.createEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: 'after',
            startAt: range.endUtc,
            endAt: range.endUtc.add(const Duration(hours: 1)),
          ),
        );
        final assigned = await repository.createEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: 'assigned',
            startAt: range.startUtc.add(const Duration(hours: 1)),
            endAt: range.startUtc.add(const Duration(hours: 2)),
            memberIds: const <String>['member-jin'],
          ),
        );
        final eventIds = <String>[];
        for (var index = 0; index < 1001; index++) {
          final event = await repository.createEvent(
            'demo-user',
            'demo-group',
            EventDraft(
              title: 'page-$index',
              startAt: range.startUtc.add(const Duration(hours: 3)),
              endAt: range.startUtc.add(const Duration(hours: 4)),
            ),
          );
          eventIds.add(event.id);
        }

        final first = await repository.eventsForRange(
          userId: 'demo-user',
          groupId: 'demo-group',
          range: range,
          limit: 200,
        );
        expect(
          first.events.any((event) => event.id == endingAtStart.id),
          isFalse,
        );
        expect(
          first.events.any((event) => event.id == startingAtEnd.id),
          isFalse,
        );
        expect(first.events.any((event) => event.id == assigned.id), isTrue);

        final loaded = <PlannerEvent>[...first.events];
        var page = first;
        while (page.hasMore) {
          page = await repository.eventsForRange(
            userId: 'demo-user',
            groupId: 'demo-group',
            range: range,
            cursor: page.nextCursor,
            limit: 200,
          );
          loaded.addAll(page.events);
        }
        final loadedIds = loaded.map((event) => event.id).toSet();
        expect(loadedIds.length, loaded.length);
        expect(loadedIds.containsAll(eventIds), isTrue);
        expect(loaded.length, 1002); // assigned + 1001 page rows
        for (var index = 1; index < loaded.length; index++) {
          final previous = loaded[index - 1];
          final current = loaded[index];
          expect(
            previous.startAt.toUtc().compareTo(current.startAt.toUtc()) < 0 ||
                (previous.startAt == current.startAt &&
                    previous.id.compareTo(current.id) < 0),
            isTrue,
          );
        }

        await expectLater(
          repository.eventsForRange(
            userId: 'outsider',
            groupId: 'demo-group',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );

        await expectLater(
          repository.eventsForRange(
            userId: 'demo-user',
            groupId: 'demo-group',
            range: range,
            limit: 201,
          ),
          throwsA(isA<ScheduleValidationException>()),
        );
        await expectLater(
          repository.eventsForRange(
            userId: 'demo-user',
            groupId: 'demo-group',
            range: EventRange(
              startUtc: range.startUtc,
              endUtc: range.startUtc.add(const Duration(days: 367)),
              viewTimezone: 'UTC',
            ),
          ),
          throwsA(isA<ScheduleValidationException>()),
        );
        await repository.setMemberActive(
          'demo-group',
          'member-jin',
          false,
          actorId: 'demo-user',
        );
        await expectLater(
          repository.eventsForRange(
            userId: 'demo-user',
            groupId: 'demo-group',
            range: range,
            participantId: 'member-jin',
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        await expectLater(
          repository.eventsForRange(
            userId: 'demo-user',
            groupId: 'demo-group',
            range: EventRange(
              startUtc: range.startUtc.add(const Duration(microseconds: 1)),
              endUtc: range.endUtc,
              viewTimezone: 'UTC',
            ),
          ),
          throwsA(isA<ScheduleValidationException>()),
        );
      },
    );
  });

  group('Supabase bounded RPC boundary', () {
    test(
      'serializes exact range parameters and strictly parses the envelope',
      () async {
        final payload = <String, dynamic>{
          'events': <Object>[_eventRow()],
          'next_cursor': null,
          'has_more': false,
        };
        final transport = _RpcTransport(payload);
        final client = _client(transport);
        final repository = SupabaseScheduleRepository(client);
        addTearDown(client.dispose);
        final range = calendarDayBounds(
          DateTime(2030, 1, 2),
          'UTC',
        ).toEventRange();

        final page = await repository.eventsForRange(
          userId: 'ignored-local-hint',
          groupId: 'group-1',
          range: range,
          limit: 17,
          participantId: 'demo-user',
        );
        expect(page.events.single.memberIds, <String>['demo-user']);
        final request = transport.requests.single as http.Request;
        expect(request.url.path, contains('/rpc/events_for_range'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys, <String>{
          'p_group_id',
          'p_range_start',
          'p_range_end',
          'p_view_timezone',
          'p_limit',
          'p_cursor',
          'p_participant_id',
        });
        expect(body['p_group_id'], 'group-1');
        expect(body['p_range_start'], range.startUtc.toIso8601String());
        expect(body['p_range_end'], range.endUtc.toIso8601String());
        expect(body['p_view_timezone'], 'UTC');
        expect(body['p_limit'], 17);
        expect(body['p_cursor'], isNull);
        expect(body['p_participant_id'], 'demo-user');
        expect(body.keys, isNot(contains('userId')));
        expect(body.keys, isNot(contains('actor')));

        payload['events'] = <Object>[_eventRow(memberIds: null)];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[_eventRow(groupId: 'other-group')];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[
          <String, dynamic>{..._eventRow(), 'deleted_at': 'not-a-timestamp'},
        ];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[
          <String, dynamic>{..._eventRow(), 'timezone': 'Not/IANA'},
        ];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[
          _eventRow(
            startsAt: '2030-01-02T10:00:00.000Z',
            endsAt: '2030-01-02T09:00:00.000Z',
          ),
        ];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[
          _eventRow(
            startsAt: '2030-01-01T15:00:00.000Z',
            endsAt: '2030-01-02T15:00:00.000Z',
            timezone: 'Asia/Seoul',
            isAllDay: true,
            allDayStart: '2030-01-02',
            allDayEnd: '2030-01-03',
          ),
        ];
        final validAllDayPage = await repository.eventsForRange(
          userId: 'ignored-local-hint',
          groupId: 'group-1',
          range: range,
        );
        expect(validAllDayPage.events.single.allDay, isTrue);
        payload['events'] = <Object>[
          _eventRow(
            startsAt: '2030-01-01T16:00:00.000Z',
            endsAt: '2030-01-02T15:00:00.000Z',
            timezone: 'Asia/Seoul',
            isAllDay: true,
            allDayStart: '2030-01-02',
            allDayEnd: '2030-01-03',
          ),
        ];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        payload['events'] = <Object>[
          _eventRow(
            startsAt: '2030-01-01T00:00:00.000Z',
            endsAt: '2030-01-02T00:00:00.000Z',
            isAllDay: true,
            allDayStart: '2030-02-30',
            allDayEnd: '2030-03-01',
          ),
        ];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
      },
    );

    test('rejects normalized or noncanonical timed timestamps', () async {
      final payload = <String, dynamic>{
        'events': <Object>[_eventRow()],
        'next_cursor': null,
        'has_more': false,
      };
      final transport = _RpcTransport(payload);
      final client = _client(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);
      final range = calendarDayBounds(
        DateTime(2030, 1, 2),
        'UTC',
      ).toEventRange();

      const invalidStarts = <String>[
        '2030-01-32T09:00:00Z',
        '2031-02-29T09:00:00Z',
        '2030-01-02T24:00:00Z',
        '2030-01-02T09:60:00Z',
        '2030-01-02T09:00:60Z',
        '2030-01-02T09:00:00+24:00',
        '2030-01-02T09:00:00+09:60',
        '2030-1-02T09:00:00Z',
        '2030-01-02 09:00:00Z',
        '2030-01-02T09:00Z',
        '2030-01-02T09:00:00z',
        '2030-01-02T09:00:00+0900',
        '2030-01-02T09:00:00',
      ];
      for (final startsAt in invalidStarts) {
        payload['events'] = <Object>[_eventRow(startsAt: startsAt)];
        await expectLater(
          repository.eventsForRange(
            userId: 'ignored-local-hint',
            groupId: 'group-1',
            range: range,
          ),
          throwsA(isA<ScheduleConflictException>()),
          reason: startsAt,
        );
      }

      payload['events'] = <Object>[
        _eventRow(
          startsAt: '2030-01-02T09:00:00.123456+09:00',
          endsAt: '2030-01-02T10:00:00.654321+09:00',
        ),
      ];
      final valid = await repository.eventsForRange(
        userId: 'ignored-local-hint',
        groupId: 'group-1',
        range: range,
      );
      expect(
        valid.events.single.startAt,
        DateTime.utc(2030, 1, 2, 0, 0, 0, 123, 456),
      );
      expect(
        valid.events.single.endAt,
        DateTime.utc(2030, 1, 2, 1, 0, 0, 654, 321),
      );
    });
  });

  test(
    'legacy realtime merge rejects malformed rows and accepts strict offsets',
    () async {
      final repository = _LegacyRealtimeRepository();
      final values = <List<PlannerEvent>>[];
      final errors = <Object>[];
      final subscription = repository
          .watchEvents('group-1')
          .listen(
            values.add,
            onError: (Object error, StackTrace _) => errors.add(error),
          );
      addTearDown(() async {
        await subscription.cancel();
        await repository.parentRows.close();
        await repository.client.dispose();
      });

      repository.parentRows.add(<Map<String, dynamic>>[
        _eventRow(startsAt: '2030-02-30T09:00:00Z'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(values, isEmpty);
      expect(errors, isNotEmpty);

      repository.parentRows.add(<Map<String, dynamic>>[_eventRow()]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(values, hasLength(1));
      expect(values.single.single.id, 'event-1');

      final errorsAfterValid = errors.length;
      repository.parentRows.add(<Map<String, dynamic>>[
        _eventRow(
          startsAt: '2030-01-02T10:00:00Z',
          endsAt: '2030-01-02T09:00:00Z',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(values, hasLength(1));
      expect(errors.length, greaterThan(errorsAfterValid));

      repository.parentRows.add(<Map<String, dynamic>>[
        _eventRow(
          id: 'offset-event',
          startsAt: '2030-01-02T09:00:00.123456+09:00',
          endsAt: '2030-01-02T10:00:00.654321+09:00',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(values, hasLength(2));
      expect(
        values.last.single.startAt,
        DateTime.utc(2030, 1, 2, 0, 0, 0, 123, 456),
      );
      expect(
        values.last.single.endAt,
        DateTime.utc(2030, 1, 2, 1, 0, 0, 654, 321),
      );
    },
  );

  test(
    'legacy Local subclasses may normalize omitted creator responses, while strict opt-in rejects them',
    () async {
      Future<PlannerController> controllerFor(
        ScheduleRepository repository,
      ) async {
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.selectedGroup = const PlannerGroup(
          id: 'group-1',
          name: 'Group',
          timezone: 'UTC',
        );
        return controller;
      }

      final legacy = _LegacyEmptyCreateRepository();
      final legacyController = await controllerFor(legacy);
      addTearDown(() {
        legacyController.dispose();
      });
      await legacyController.saveEvent(
        draft: EventDraft(
          title: 'Legacy',
          startAt: DateTime.utc(2030, 1, 2, 9),
          endAt: DateTime.utc(2030, 1, 2, 10),
        ),
      );
      expect(legacyController.events.single.memberIds, <String>['demo-user']);

      final strict = _StrictEmptyCreateRepository();
      final strictController = await controllerFor(strict);
      addTearDown(strictController.dispose);
      await expectLater(
        strictController.saveEvent(
          draft: EventDraft(
            title: 'Malformed strict',
            startAt: DateTime.utc(2030, 1, 2, 9),
            endAt: DateTime.utc(2030, 1, 2, 10),
          ),
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      expect(strictController.events, isEmpty);
    },
  );

  group('PlannerController bounded range state', () {
    test(
      'preserves an identical month range while changing selected day',
      () async {
        final event = _event(
          id: 'month-event',
          groupId: 'group-1',
          startAt: DateTime.utc(2030, 1, 10, 9),
          endAt: DateTime.utc(2030, 1, 10, 10),
        );
        final repository = _RangeRepository(<EventRangePage>[
          EventRangePage(
            events: <PlannerEvent>[event],
            nextCursor: null,
            hasMore: false,
          ),
        ]);
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
        ];
        controller.selectedGroup = controller.groups.single;
        controller.selectedDay = DateTime(2030, 1, 5);

        controller.setCalendarView(CalendarViewMode.month);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(repository.ranges, hasLength(1));
        expect(controller.events.single.id, 'month-event');
        final originalRange = controller.selectedEventRange;

        controller.setSelectedDay(DateTime(2030, 1, 20));
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(repository.ranges, hasLength(1));
        expect(controller.selectedEventRange, originalRange);
        expect(controller.events.single.id, 'month-event');
        expect(controller.selectedDay, DateTime(2030, 1, 20));
      },
    );

    test('late first-page result cannot overwrite a newer range', () async {
      final first = Completer<EventRangePage>();
      final second = Completer<EventRangePage>();
      final repository = _RangeRepository(<EventRangePage>[]);
      final pending = <Completer<EventRangePage>>[first, second];
      repository.responseForRange = (range) {
        return pending.removeAt(0).future;
      };
      final controller = PlannerController(
        auth: AuthRepository(),
        repository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = _rangeUser;
      controller.groups = const <PlannerGroup>[
        PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
      ];
      controller.selectedGroup = controller.groups.single;
      controller.selectedDay = DateTime(2030, 1, 5);

      controller.setSelectedDay(DateTime(2030, 1, 5));
      await Future<void>.delayed(Duration.zero);
      controller.setSelectedDay(DateTime(2030, 1, 6));
      await Future<void>.delayed(Duration.zero);
      expect(repository.ranges, hasLength(2));

      final newerRange = repository.ranges.last;
      final newerEvent = _event(
        id: 'newer',
        groupId: 'group-1',
        startAt: newerRange.startUtc.add(const Duration(hours: 1)),
        endAt: newerRange.startUtc.add(const Duration(hours: 2)),
      );
      second.complete(
        EventRangePage(
          events: <PlannerEvent>[newerEvent],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      first.complete(
        EventRangePage(
          events: <PlannerEvent>[
            _event(
              id: 'stale',
              groupId: 'group-1',
              startAt: repository.ranges.first.startUtc.add(
                const Duration(hours: 1),
              ),
              endAt: repository.ranges.first.startUtc.add(
                const Duration(hours: 2),
              ),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(controller.events.map((event) => event.id), <String>['newer']);
      expect(controller.isLoadingEvents, isFalse);
    });

    test(
      'identity and group changes fence late first-page responses',
      () async {
        final first = Completer<EventRangePage>();
        final second = Completer<EventRangePage>();
        final repository = _RangeRepository(<EventRangePage>[]);
        final pending = <Completer<EventRangePage>>[first, second];
        repository.responseForRange = (_) => pending.removeAt(0).future;
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group 1', timezone: 'UTC'),
          PlannerGroup(id: 'group-2', name: 'Group 2', timezone: 'UTC'),
        ];
        controller.selectedGroup = controller.groups.first;
        controller.selectedDay = DateTime(2030, 1, 5);
        controller.setSelectedDay(DateTime(2030, 1, 5));
        await Future<void>.delayed(Duration.zero);
        controller.selectedGroup = controller.groups.last;
        controller.setSelectedDay(DateTime(2030, 1, 6));
        await Future<void>.delayed(Duration.zero);
        expect(repository.ranges, hasLength(2));

        final currentRange = repository.ranges.last;
        second.complete(
          EventRangePage(
            events: <PlannerEvent>[
              _event(
                id: 'group-two',
                groupId: 'group-2',
                startAt: currentRange.startUtc.add(const Duration(hours: 1)),
                endAt: currentRange.startUtc.add(const Duration(hours: 2)),
              ),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
        first.complete(
          EventRangePage(
            events: <PlannerEvent>[
              _event(
                id: 'group-one',
                groupId: 'group-1',
                startAt: repository.ranges.first.startUtc.add(
                  const Duration(hours: 1),
                ),
                endAt: repository.ranges.first.startUtc.add(
                  const Duration(hours: 2),
                ),
              ),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(controller.events.map((event) => event.id), <String>[
          'group-two',
        ]);

        // A user identity change is an independent privacy fence even when the
        // selected group/range happens to remain unchanged.
        final identityPending = Completer<EventRangePage>();
        repository.responseForRange = (_) => identityPending.future;
        controller.user = _rangeUser;
        controller.setSelectedDay(DateTime(2030, 1, 7));
        await Future<void>.delayed(Duration.zero);
        controller.user = const PlannerUser(
          id: 'other-user',
          email: 'other@example.com',
        );
        identityPending.complete(EventRangePage.empty());
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(controller.events, isEmpty);
      },
    );

    test(
      'participant filter fences stale pages and sends the new filter',
      () async {
        final first = Completer<EventRangePage>();
        final second = Completer<EventRangePage>();
        final repository = _RangeRepository(<EventRangePage>[]);
        final pending = <Completer<EventRangePage>>[first, second];
        final requestedParticipants = <String?>[];
        repository.responseForRangeWithParticipant = (range, participantId) {
          requestedParticipants.add(participantId);
          return pending.removeAt(0).future;
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.selectedGroup = const PlannerGroup(
          id: 'group-1',
          name: 'Group',
          timezone: 'UTC',
        );
        controller.selectedDay = DateTime(2030, 1, 5);
        controller.setSelectedDay(DateTime(2030, 1, 5));
        await Future<void>.delayed(Duration.zero);
        controller.setMemberFilter('member-jin');
        await Future<void>.delayed(Duration.zero);
        expect(requestedParticipants, <String?>[null, 'member-jin']);
        final currentRange = repository.ranges.last;
        second.complete(
          EventRangePage(
            events: <PlannerEvent>[
              _event(
                id: 'filtered',
                groupId: 'group-1',
                startAt: currentRange.startUtc.add(const Duration(hours: 1)),
                endAt: currentRange.startUtc.add(const Duration(hours: 2)),
                memberIds: const <String>['member-jin'],
              ),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
        first.complete(EventRangePage.empty());
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(controller.events.map((event) => event.id), <String>[
          'filtered',
        ]);
        expect(controller.selectedMemberId, 'member-jin');
      },
    );

    test(
      'load more is serialized and stale pagination cannot alter a new range',
      () async {
        final initial = Completer<EventRangePage>();
        final loadMore = Completer<EventRangePage>();
        final nextRange = Completer<EventRangePage>();
        final repository = _RangeRepository(<EventRangePage>[]);
        final pending = <Completer<EventRangePage>>[
          initial,
          loadMore,
          nextRange,
        ];
        repository.responseForRange = (_) => pending.removeAt(0).future;
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.selectedGroup = const PlannerGroup(
          id: 'group-1',
          name: 'Group',
          timezone: 'UTC',
        );
        controller.selectedDay = DateTime(2030, 1, 5);
        controller.setSelectedDay(DateTime(2030, 1, 5));
        await Future<void>.delayed(Duration.zero);
        final firstRange = repository.ranges.first;
        final firstEvent = _event(
          id: 'first-page',
          groupId: 'group-1',
          startAt: firstRange.startUtc.add(const Duration(hours: 1)),
          endAt: firstRange.startUtc.add(const Duration(hours: 2)),
        );
        final firstCursor = EventRangeCursor(
          startsAtUtc: firstEvent.startAt,
          eventId: firstEvent.id,
        );
        initial.complete(
          EventRangePage(
            events: <PlannerEvent>[firstEvent],
            nextCursor: firstCursor,
            hasMore: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final oldLoad = controller.loadMoreEvents();
        final duplicateLoad = controller.loadMoreEvents();
        await Future<void>.delayed(Duration.zero);
        expect(repository.ranges, hasLength(2));
        expect(controller.isLoadingMoreEvents, isTrue);

        controller.setSelectedDay(DateTime(2030, 1, 6));
        await Future<void>.delayed(Duration.zero);
        expect(controller.isLoadingMoreEvents, isFalse);
        final currentRange = repository.ranges.last;
        nextRange.complete(
          EventRangePage(
            events: <PlannerEvent>[
              _event(
                id: 'new-range',
                groupId: 'group-1',
                startAt: currentRange.startUtc.add(const Duration(hours: 1)),
                endAt: currentRange.startUtc.add(const Duration(hours: 2)),
              ),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        );
        loadMore.complete(
          EventRangePage(
            events: <PlannerEvent>[
              _event(
                id: 'stale-page',
                groupId: 'group-1',
                startAt: firstRange.startUtc.add(const Duration(hours: 3)),
                endAt: firstRange.startUtc.add(const Duration(hours: 4)),
              ),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        );
        await Future.wait(<Future<void>>[oldLoad, duplicateLoad]);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        expect(controller.events.map((event) => event.id), <String>[
          'new-range',
        ]);
        expect(controller.hasMoreEvents, isFalse);
        expect(controller.isLoadingEvents, isFalse);
        expect(controller.isLoadingMoreEvents, isFalse);
      },
    );

    test(
      'debounced invalidation refetches once and queues during an active refresh',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        var responseCount = 0;
        final refresh = Completer<EventRangePage>();
        repository.responseForRange = (range) {
          responseCount++;
          if (responseCount == 1) {
            final first = _event(
              id: 'initial',
              groupId: 'group-1',
              startAt: range.startUtc.add(const Duration(hours: 1)),
              endAt: range.startUtc.add(const Duration(hours: 2)),
            );
            return Future<EventRangePage>.value(
              EventRangePage(
                events: <PlannerEvent>[first],
                nextCursor: null,
                hasMore: false,
              ),
            );
          }
          if (responseCount == 2) return refresh.future;
          return Future<EventRangePage>.value(EventRangePage.empty());
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        final group = const PlannerGroup(
          id: 'group-1',
          name: 'Group',
          timezone: 'UTC',
        );
        controller.groups = <PlannerGroup>[group];
        await controller.selectGroup(group.id);
        expect(controller.events.single.id, 'initial');

        repository.invalidations.add(null);
        repository.invalidations.add(null);
        repository.invalidations.add(null);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(responseCount, 2);
        expect(controller.events.single.id, 'initial');
        expect(controller.isLoadingEvents, isTrue);

        repository.invalidations.add(null);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(responseCount, 2); // queued behind the in-flight refresh
        refresh.complete(EventRangePage.empty());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(responseCount, 3);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(controller.events, isEmpty);
        expect(controller.isLoadingEvents, isFalse);
      },
    );

    test(
      'authoritative range denial clears the last-good private snapshot',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        var responses = 0;
        repository.responseForRange = (range) {
          responses++;
          if (responses == 1) {
            final event = _event(
              id: 'private',
              groupId: 'group-1',
              startAt: range.startUtc.add(const Duration(hours: 1)),
              endAt: range.startUtc.add(const Duration(hours: 2)),
            );
            return Future<EventRangePage>.value(
              EventRangePage(
                events: <PlannerEvent>[event],
                nextCursor: null,
                hasMore: false,
              ),
            );
          }
          return Future<EventRangePage>.error(
            const ScheduleAuthorizationException('그룹을 사용할 수 없습니다.'),
          );
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
        ];
        await controller.selectGroup('group-1');
        expect(controller.events, hasLength(1));
        await controller.refreshSelectedEventRange(force: true);
        expect(controller.events, isEmpty);
        expect(controller.hasMoreEvents, isFalse);
        expect(controller.isLoadingEvents, isFalse);
      },
    );

    test(
      'transient range refresh failure preserves the last-good snapshot',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        var responses = 0;
        repository.responseForRange = (range) {
          responses++;
          if (responses == 1) {
            final event = _event(
              id: 'private',
              groupId: 'group-1',
              startAt: range.startUtc.add(const Duration(hours: 1)),
              endAt: range.startUtc.add(const Duration(hours: 2)),
            );
            return Future<EventRangePage>.value(
              EventRangePage(
                events: <PlannerEvent>[event],
                nextCursor: null,
                hasMore: false,
              ),
            );
          }
          return Future<EventRangePage>.error(
            StateError('transport unavailable'),
          );
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
        ];
        await controller.selectGroup('group-1');
        await controller.refreshSelectedEventRange(force: true);
        expect(controller.events.map((event) => event.id), <String>['private']);
      },
    );

    test(
      'load more idempotently merges an invalidation duplicate with equal payload',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        var responses = 0;
        repository.responseForRange = (range) {
          responses++;
          final first = _event(
            id: 'first',
            groupId: 'group-1',
            startAt: range.startUtc.add(const Duration(hours: 1)),
            endAt: range.startUtc.add(const Duration(hours: 2)),
          );
          final duplicate = _event(
            id: 'duplicate',
            groupId: 'group-1',
            startAt: range.startUtc.add(const Duration(hours: 3)),
            endAt: range.startUtc.add(const Duration(hours: 4)),
          );
          final third = _event(
            id: 'third',
            groupId: 'group-1',
            startAt: range.startUtc.add(const Duration(hours: 5)),
            endAt: range.startUtc.add(const Duration(hours: 6)),
          );
          if (responses == 1) {
            return Future<EventRangePage>.value(
              EventRangePage(
                events: <PlannerEvent>[first],
                nextCursor: EventRangeCursor(
                  startsAtUtc: first.startAt,
                  eventId: first.id,
                ),
                hasMore: true,
              ),
            );
          }
          return Future<EventRangePage>.value(
            EventRangePage(
              events: <PlannerEvent>[duplicate, third],
              nextCursor: EventRangeCursor(
                startsAtUtc: third.startAt,
                eventId: third.id,
              ),
              hasMore: true,
            ),
          );
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
        ];
        await controller.selectGroup('group-1');
        final range = repository.ranges.first;
        final first = controller.events.single;
        final duplicate = _event(
          id: 'duplicate',
          groupId: 'group-1',
          startAt: range.startUtc.add(const Duration(hours: 3)),
          endAt: range.startUtc.add(const Duration(hours: 4)),
        );
        // Simulate a parent invalidation/upsert arriving before the page that
        // already contains this immutable payload.
        controller.events = <PlannerEvent>[first, duplicate];
        await controller.loadMoreEvents();
        expect(controller.events.map((event) => event.id), <String>[
          'first',
          'duplicate',
          'third',
        ]);
        expect(controller.isLoadingMoreEvents, isFalse);
      },
    );

    test(
      'bounded controller rejects a response larger than the requested limit',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        repository.responseForRange = (range) {
          final rows = List<PlannerEvent>.generate(
            101,
            (index) => _event(
              id: 'event-${index.toString().padLeft(3, '0')}',
              groupId: 'group-1',
              startAt: range.startUtc.add(const Duration(hours: 1)),
              endAt: range.startUtc.add(const Duration(hours: 2)),
            ),
          );
          return Future<EventRangePage>.value(
            EventRangePage(events: rows, nextCursor: null, hasMore: false),
          );
        };
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'group-1', name: 'Group', timezone: 'UTC'),
        ];
        await controller.selectGroup('group-1');
        expect(controller.events, isEmpty);
        expect(controller.rangeError, isNotNull);
      },
    );

    test(
      'legacy refreshSelectedEventRange restarts the selected-group refresh path',
      () async {
        final repository = _LegacyRefreshRepository();
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() {
          controller.dispose();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.groups = const <PlannerGroup>[
          PlannerGroup(id: 'demo-group', name: 'Demo', timezone: 'UTC'),
        ];
        await controller.selectGroup('demo-group');
        final before = repository.groupsReads;
        await controller.refreshSelectedEventRange();
        expect(repository.groupsReads, greaterThan(before));
      },
    );

    test(
      'detail lookup loads an event outside the selected range without mixing pages',
      () async {
        final repository = _RangeRepository(<EventRangePage>[]);
        final detail = _event(
          id: 'outside-range',
          groupId: 'group-1',
          startAt: DateTime.utc(2030, 2, 1, 9),
          endAt: DateTime.utc(2030, 2, 1, 10),
        );
        repository.eventByIdResult = detail;
        final controller = PlannerController(
          auth: AuthRepository(),
          repository: repository,
        );
        addTearDown(() async {
          controller.dispose();
          await repository.close();
        });
        await Future<void>.delayed(Duration.zero);
        controller.user = _rangeUser;
        controller.selectedGroup = const PlannerGroup(
          id: 'group-1',
          name: 'Group',
          timezone: 'UTC',
        );
        final loaded = await controller.loadEventById(detail.id);
        expect(loaded, detail);
        expect(controller.events, isEmpty);
        expect(repository.eventByIdCalls, 1);
      },
    );

    test('late detail lookup after group switch is discarded', () async {
      final pending = Completer<PlannerEvent?>();
      final repository = _RangeRepository(<EventRangePage>[]);
      repository.eventByIdCallback = (_, _, _) => pending.future;
      final controller = PlannerController(
        auth: AuthRepository(),
        repository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = _rangeUser;
      controller.selectedGroup = const PlannerGroup(
        id: 'group-1',
        name: 'Group 1',
        timezone: 'UTC',
      );
      final request = controller.loadEventById('outside-range');
      controller.selectedGroup = const PlannerGroup(
        id: 'group-2',
        name: 'Group 2',
        timezone: 'UTC',
      );
      pending.complete(
        _event(
          id: 'outside-range',
          groupId: 'group-1',
          startAt: DateTime.utc(2030, 2, 1, 9),
          endAt: DateTime.utc(2030, 2, 1, 10),
        ),
      );
      expect(await request, isNull);
      expect(controller.events, isEmpty);
    });
  });
}
