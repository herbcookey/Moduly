// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/core/recurrence.dart';
import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

class _RpcTransport extends http.BaseClient {
  _RpcTransport(this.payload);
  Object? payload;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
        200,
        request: request,
        headers: const <String, String>{'content-type': 'application/json'},
      );
}

SupabaseClient _client(Object? payload) => SupabaseClient(
  'https://example.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
  httpClient: _RpcTransport(payload),
);

class _AuthenticatedSupabaseScheduleRepository
    extends SupabaseScheduleRepository {
  _AuthenticatedSupabaseScheduleRepository(super.client, this._sessionUserId);

  final String? _sessionUserId;

  @override
  String? get currentSessionUserId => _sessionUserId;
}

EventDraft _draft({
  required DateTime start,
  required DateTime end,
  required RecurrenceRule rule,
  bool allDay = false,
}) => EventDraft(
  title: 'series',
  startAt: start,
  endAt: end,
  allDay: allDay,
  timezone: 'UTC',
  recurrence: rule,
  memberIds: const <String>['demo-user'],
  allDayStartDate: allDay ? DateTime(start.year, start.month, start.day) : null,
  allDayEndDate: allDay ? DateTime(end.year, end.month, end.day) : null,
);

EventRange _range(DateTime start, DateTime end) => EventRange(
  startUtc: start.toUtc(),
  endUtc: end.toUtc(),
  viewTimezone: 'UTC',
);

void main() {
  test('recurrence JSON is exact and keys are decimal ordinals', () {
    final rule = RecurrenceRule(
      frequency: RecurrenceFrequency.weekly,
      interval: 2,
      weekdays: const <int>[1, 3],
      end: RecurrenceEnd.count,
      count: 4,
    );
    expect(rule.toJson().keys, <String>{
      'frequency',
      'interval',
      'weekdays',
      'end',
      'count',
      'until_date',
      'monthly_day',
    });
    expect(RecurrenceRule.fromJson(rule.toJson()), rule);
    expect(occurrenceKeyForIndex(0), 'o00000000000000000000');
    expect(occurrenceKeyForIndex(12), 'o00000000000000000012');
    expect(occurrenceIndexFromKey('o00000000000000000012'), 12);
    expect(
      () => RecurrenceRule.fromJson(<String, dynamic>{
        ...rule.toJson(),
        'extra': true,
      }),
      throwsFormatException,
    );
    expect(
      () => RecurrenceRule.fromJson(<String, dynamic>{
        ...rule.toJson(),
        'until_date': '2030-01-01',
      }),
      throwsFormatException,
    );
    expect(
      RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        interval: 999,
      ).interval,
      999,
    );
    expect(
      () => RecurrenceRule(frequency: RecurrenceFrequency.daily, interval: 0),
      throwsFormatException,
    );
    expect(
      () =>
          RecurrenceRule(frequency: RecurrenceFrequency.daily, interval: 1000),
      throwsFormatException,
    );
    expect(
      () => RecurrenceRule.fromJson(<String, dynamic>{
        ...rule.toJson(),
        'interval': 2.0,
      }),
      throwsFormatException,
    );
  });

  test('mutation receipts distinguish committed no-op from a version bump', () {
    final noOp = RecurrenceMutationReceipt.fromJson(<String, dynamic>{
      'group_id': 'group-1',
      'event_id': 'event-1',
      'occurrence_key': 'single',
      'series_version': 4,
      'occurrence_version': 0,
      'scope': 'all',
      'committed': true,
      'changed': false,
    });
    expect(noOp.changed, isFalse);
    expect(noOp.toJson().keys, <String>{
      'group_id',
      'event_id',
      'occurrence_key',
      'series_version',
      'occurrence_version',
      'scope',
      'committed',
      'changed',
    });
    expect(
      () => RecurrenceMutationReceipt.fromJson(
        <String, dynamic>{...noOp.toJson()}..remove('changed'),
      ),
      throwsFormatException,
    );
  });

  test('daily interval/count and inclusive until expansion', () {
    final event = PlannerEvent(
      id: 'daily',
      groupId: 'g',
      title: 'daily',
      startAt: DateTime.utc(2030, 1, 1, 9),
      endAt: DateTime.utc(2030, 1, 1, 10),
      ownerId: 'demo-user',
      timezone: 'UTC',
      recurrenceRule: RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        interval: 2,
        end: RecurrenceEnd.until,
        untilDate: DateTime(2030, 1, 7),
      ),
    );
    final rows = expandRecurringEvent(
      event,
      _range(DateTime.utc(2030, 1, 1), DateTime.utc(2030, 1, 9)),
    );
    expect(rows.map((row) => row.occurrenceIndex), <int>[0, 1, 2, 3]);
    expect(rows.map((row) => row.startAt.day), <int>[1, 3, 5, 7]);
  });

  test('weekly weekday selection uses stable global ordinals', () {
    final event = PlannerEvent(
      id: 'weekly',
      groupId: 'g',
      title: 'weekly',
      startAt: DateTime.utc(2030, 1, 2, 9), // Wednesday
      endAt: DateTime.utc(2030, 1, 2, 10),
      ownerId: 'demo-user',
      timezone: 'UTC',
      recurrenceRule: RecurrenceRule(
        frequency: RecurrenceFrequency.weekly,
        weekdays: const <int>[1, 3],
        end: RecurrenceEnd.count,
        count: 5,
      ),
    );
    final rows = expandRecurringEvent(
      event,
      _range(DateTime.utc(2030, 1, 1), DateTime.utc(2030, 1, 31)),
    );
    expect(rows.map((row) => row.occurrenceIndex), <int>[0, 1, 2, 3, 4]);
    expect(rows.map((row) => row.startAt.weekday), <int>[3, 1, 3, 1, 3]);
  });

  test('monthly day clamps February and short months', () {
    final event = PlannerEvent(
      id: 'monthly',
      groupId: 'g',
      title: 'monthly',
      startAt: DateTime.utc(2028, 1, 31, 9),
      endAt: DateTime.utc(2028, 1, 31, 10),
      ownerId: 'demo-user',
      timezone: 'UTC',
      recurrenceRule: RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        monthlyDay: 31,
        end: RecurrenceEnd.count,
        count: 4,
      ),
    );
    final rows = expandRecurringEvent(
      event,
      _range(DateTime.utc(2028, 1, 1), DateTime.utc(2028, 5, 1)),
    );
    expect(
      rows.map(
        (row) => '${row.startAt.year}-${row.startAt.month}-${row.startAt.day}',
      ),
      <String>['2028-1-31', '2028-2-29', '2028-3-31', '2028-4-30'],
    );
  });

  test('Local recurring range paging and this/future/all mutations', () async {
    final repository = LocalScheduleRepository(
      seedMembers: const <PlannerMember>[],
    );
    final rule = RecurrenceRule(
      frequency: RecurrenceFrequency.daily,
      end: RecurrenceEnd.count,
      count: 5,
    );
    final anchor = await repository.createRecurringEvent(
      'demo-user',
      'demo-group',
      _draft(
        start: DateTime.utc(2030, 1, 1, 9),
        end: DateTime.utc(2030, 1, 1, 10),
        rule: rule,
      ),
    );
    final range = _range(DateTime.utc(2030, 1, 1), DateTime.utc(2030, 1, 8));
    final first = await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 2,
    );
    expect(first.events.length, 2);
    expect(first.nextCursor, isNotNull);
    final second = await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      cursor: first.nextCursor,
      limit: 10,
    );
    expect(second.events.map((event) => event.identityKey).toSet().length, 3);

    final target = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 20,
    )).events[1];
    final receipt = await repository.updateEventOccurrence(
      event: target,
      draft: EventDraft(
        title: 'changed',
        startAt: target.startAt,
        endAt: target.endAt,
        timezone: 'UTC',
        memberIds: target.memberIds,
      ),
      scope: EventEditScope.thisOccurrence,
      expectedSeriesVersion: anchor.version,
      expectedOccurrenceVersion: target.occurrenceVersion,
      actorId: 'demo-user',
    );
    expect(receipt.committed, isTrue);
    final changed = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 20,
    )).events;
    expect(
      changed.singleWhere((e) => e.occurrenceKey == target.occurrenceKey).title,
      'changed',
    );
    final far = await repository.eventOccurrenceByKey(
      userId: 'demo-user',
      groupId: 'demo-group',
      eventId: anchor.id,
      occurrenceKey: occurrenceKeyForIndex(10000),
    );
    expect(far, isNull);
  });

  test(
    'Local all-scope converts singleton to recurring and back without fanout',
    () async {
      final repository = LocalScheduleRepository();
      final single = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'convertible',
          startAt: DateTime.utc(2030, 2, 1, 9),
          endAt: DateTime.utc(2030, 2, 1, 10),
          timezone: 'UTC',
        ),
      );
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 3,
      );
      final recurrenceDraft = EventDraft(
        title: single.title,
        startAt: single.startAt,
        endAt: single.endAt,
        timezone: 'UTC',
        recurrence: rule,
        memberIds: single.memberIds,
      );
      final toSeries = await repository.updateEventOccurrence(
        event: single,
        draft: recurrenceDraft,
        scope: EventEditScope.all,
        expectedSeriesVersion: single.version,
        expectedOccurrenceVersion: single.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(toSeries.changed, isTrue);
      expect(toSeries.seriesVersion, single.version + 1);
      final range = _range(DateTime.utc(2030, 2, 1), DateTime.utc(2030, 2, 5));
      final seriesRows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == single.id).toList();
      expect(seriesRows.map((event) => event.occurrenceKey), <String>[
        occurrenceKeyForIndex(0),
        occurrenceKeyForIndex(1),
        occurrenceKeyForIndex(2),
      ]);

      final noOp = await repository.updateEventOccurrence(
        event: seriesRows.first,
        draft: recurrenceDraft,
        scope: EventEditScope.all,
        expectedSeriesVersion: toSeries.seriesVersion,
        expectedOccurrenceVersion: seriesRows.first.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(noOp.changed, isFalse);
      expect(noOp.seriesVersion, toSeries.seriesVersion);

      final toSingle = await repository.updateEventOccurrence(
        event: seriesRows.first,
        draft: EventDraft(
          title: 'converted single',
          startAt: seriesRows.first.startAt,
          endAt: seriesRows.first.endAt,
          timezone: 'UTC',
          memberIds: seriesRows.first.memberIds,
        ),
        scope: EventEditScope.all,
        expectedSeriesVersion: toSeries.seriesVersion,
        expectedOccurrenceVersion: seriesRows.first.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(toSingle.changed, isTrue);
      final singletonRows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == single.id).toList();
      expect(singletonRows, hasLength(1));
      expect(singletonRows.single.occurrenceKey, 'single');
      expect(singletonRows.single.recurrenceRule, isNull);
      expect(singletonRows.single.title, 'converted single');
    },
  );

  test('Local future splits close the immediately prior segment', () async {
    final repository = LocalScheduleRepository();
    final anchor = await repository.createRecurringEvent(
      'demo-user',
      'demo-group',
      EventDraft(
        title: 'future split',
        startAt: DateTime.utc(2032, 1, 1, 9),
        endAt: DateTime.utc(2032, 1, 1, 10),
        timezone: 'UTC',
        recurrence: RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          end: RecurrenceEnd.never,
        ),
      ),
    );
    final range = _range(DateTime.utc(2032, 1, 1), DateTime.utc(2032, 1, 10));
    var rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 50,
    )).events.where((event) => event.id == anchor.id).toList();
    final firstFuture = rows.singleWhere((event) => event.occurrenceIndex == 2);
    final firstReceipt = await repository.updateEventOccurrence(
      event: firstFuture,
      draft: EventDraft(
        title: 'first future',
        startAt: firstFuture.startAt,
        endAt: firstFuture.endAt,
        timezone: 'UTC',
        memberIds: firstFuture.memberIds,
      ),
      scope: EventEditScope.future,
      expectedSeriesVersion: anchor.version,
      expectedOccurrenceVersion: firstFuture.occurrenceVersion,
      actorId: 'demo-user',
    );
    expect(firstReceipt.changed, isTrue);

    rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 50,
    )).events.where((event) => event.id == anchor.id).toList();
    final secondFuture = rows.singleWhere(
      (event) => event.occurrenceIndex == 4,
    );
    await repository.updateEventOccurrence(
      event: secondFuture,
      draft: EventDraft(
        title: 'second future',
        startAt: secondFuture.startAt,
        endAt: secondFuture.endAt,
        timezone: 'UTC',
        memberIds: secondFuture.memberIds,
      ),
      scope: EventEditScope.future,
      expectedSeriesVersion: firstReceipt.seriesVersion,
      expectedOccurrenceVersion: secondFuture.occurrenceVersion,
      actorId: 'demo-user',
    );

    rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 50,
    )).events.where((event) => event.id == anchor.id).toList();
    expect(rows.map((event) => event.occurrenceIndex), <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
    expect(
      rows.where((event) => event.occurrenceIndex == 2).single.title,
      'first future',
    );
    expect(
      rows.where((event) => event.occurrenceIndex == 3).single.title,
      'first future',
    );
    expect(
      rows.where((event) => event.occurrenceIndex == 4).single.title,
      'second future',
    );
    expect(
      rows.map((event) => event.identityKey).toSet(),
      hasLength(rows.length),
    );
  });

  test(
    'Local recurrence segments and overrides stay isolated per series',
    () async {
      final repository = LocalScheduleRepository();
      final first = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'series one',
          startAt: DateTime.utc(2032, 2, 1, 9),
          endAt: DateTime.utc(2032, 2, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.never,
          ),
        ),
      );
      final second = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'series two',
          startAt: DateTime.utc(2032, 2, 1, 12),
          endAt: DateTime.utc(2032, 2, 1, 13),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.never,
          ),
        ),
      );
      final range = _range(DateTime.utc(2032, 2, 1), DateTime.utc(2032, 2, 6));
      var rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 50,
      )).events;
      final firstTarget = rows.singleWhere(
        (event) => event.id == first.id && event.occurrenceIndex == 2,
      );
      final secondTarget = rows.singleWhere(
        (event) => event.id == second.id && event.occurrenceIndex == 2,
      );
      await repository.updateEventOccurrence(
        event: firstTarget,
        draft: EventDraft(
          title: 'series one future',
          startAt: firstTarget.startAt,
          endAt: firstTarget.endAt,
          timezone: 'UTC',
          memberIds: firstTarget.memberIds,
        ),
        scope: EventEditScope.future,
        expectedSeriesVersion: first.version,
        expectedOccurrenceVersion: firstTarget.occurrenceVersion,
        actorId: 'demo-user',
      );
      await repository.updateEventOccurrence(
        event: secondTarget,
        draft: EventDraft(
          title: 'series two occurrence',
          startAt: secondTarget.startAt,
          endAt: secondTarget.endAt,
          timezone: 'UTC',
          memberIds: secondTarget.memberIds,
        ),
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: second.version,
        expectedOccurrenceVersion: secondTarget.occurrenceVersion,
        actorId: 'demo-user',
      );
      rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 50,
      )).events;
      final firstRows = rows.where((event) => event.id == first.id).toList();
      final secondRows = rows.where((event) => event.id == second.id).toList();
      expect(firstRows, hasLength(5));
      expect(secondRows, hasLength(5));
      expect(
        firstRows
            .where((event) => event.occurrenceIndex >= 2)
            .every((event) => event.title == 'series one future'),
        isTrue,
      );
      expect(
        secondRows.singleWhere((event) => event.occurrenceIndex == 2).title,
        'series two occurrence',
      );
      expect(
        rows.map((event) => event.identityKey).toSet(),
        hasLength(rows.length),
      );
    },
  );

  test('Local future edits inherit the active segment rule', () async {
    final repository = LocalScheduleRepository();
    final anchor = await repository.createRecurringEvent(
      'demo-user',
      'demo-group',
      EventDraft(
        title: 'rule inheritance',
        startAt: DateTime.utc(2032, 3, 1, 9),
        endAt: DateTime.utc(2032, 3, 1, 10),
        timezone: 'UTC',
        recurrence: RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          end: RecurrenceEnd.never,
        ),
      ),
    );
    final range = _range(DateTime.utc(2032, 3, 1), DateTime.utc(2032, 4, 1));
    var rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 100,
    )).events.where((event) => event.id == anchor.id).toList();
    final firstTarget = rows.singleWhere((event) => event.occurrenceIndex == 2);
    final weeklyRule = RecurrenceRule(
      frequency: RecurrenceFrequency.weekly,
      weekdays: <int>[firstTarget.startAt.toUtc().weekday],
      end: RecurrenceEnd.never,
    );
    await repository.updateEventOccurrence(
      event: firstTarget,
      draft: EventDraft(
        title: firstTarget.title,
        startAt: firstTarget.startAt,
        endAt: firstTarget.endAt,
        timezone: 'UTC',
        memberIds: firstTarget.memberIds,
        recurrence: weeklyRule,
      ),
      scope: EventEditScope.future,
      expectedSeriesVersion: anchor.version,
      expectedOccurrenceVersion: firstTarget.occurrenceVersion,
      actorId: 'demo-user',
    );
    rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 100,
    )).events.where((event) => event.id == anchor.id).toList();
    final secondTarget = rows.singleWhere(
      (event) => event.occurrenceIndex == 4,
    );
    await repository.updateEventOccurrence(
      event: secondTarget,
      draft: EventDraft(
        title: 'inherited weekly',
        startAt: secondTarget.startAt,
        endAt: secondTarget.endAt,
        timezone: 'UTC',
        memberIds: secondTarget.memberIds,
      ),
      scope: EventEditScope.future,
      expectedSeriesVersion: anchor.version + 1,
      expectedOccurrenceVersion: secondTarget.occurrenceVersion,
      actorId: 'demo-user',
    );
    rows = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 100,
    )).events.where((event) => event.id == anchor.id).toList();
    final index4 = rows.singleWhere((event) => event.occurrenceIndex == 4);
    final index5 = rows.singleWhere((event) => event.occurrenceIndex == 5);
    expect(index4.title, 'inherited weekly');
    expect(index5.startAt.difference(index4.startAt).inDays, 7);
  });

  test('all-day recurring rows use local half-open date boundaries', () async {
    final event = PlannerEvent(
      id: 'all-day',
      groupId: 'g',
      title: 'all-day',
      startAt: wallTimeToUtc(DateTime(2030, 3, 1), 'Asia/Seoul'),
      endAt: wallTimeToUtc(DateTime(2030, 3, 3), 'Asia/Seoul'),
      allDay: true,
      allDayStartDate: DateTime(2030, 3, 1),
      allDayEndDate: DateTime(2030, 3, 3),
      ownerId: 'u',
      timezone: 'Asia/Seoul',
      recurrenceRule: RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 2,
      ),
    );
    final rows = expandRecurringEvent(
      event,
      EventRange(
        startUtc: wallTimeToUtc(DateTime(2030, 3, 2), 'Asia/Seoul'),
        endUtc: wallTimeToUtc(DateTime(2030, 3, 5), 'Asia/Seoul'),
        viewTimezone: 'Asia/Seoul',
      ),
    );
    expect(rows, hasLength(2));
    expect(
      rows.first.allDayEndDate!.difference(rows.first.allDayStartDate!).inDays,
      2,
    );
  });

  test(
    'wall time conversion resolves DST gap forward and fold to standard time',
    () {
      final gap = wallTimeToUtc(
        DateTime(2026, 3, 8, 2, 30),
        'America/New_York',
      );
      expect(gap, DateTime.utc(2026, 3, 8, 7, 30));
      final fold = wallTimeToUtc(
        DateTime(2026, 11, 1, 1, 30),
        'America/New_York',
      );
      expect(fold, DateTime.utc(2026, 11, 1, 6, 30));
    },
  );

  test(
    'Local rule duration uses civil wall days across both DST directions',
    () async {
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.never,
      );

      final fallRepository = LocalScheduleRepository();
      final fallStartWall = DateTime(2025, 11, 1, 9);
      final fallEndWall = DateTime(2026, 11, 2, 9);
      final fallStart = wallTimeToUtc(fallStartWall, 'America/New_York');
      final fallEnd = wallTimeToUtc(fallEndWall, 'America/New_York');
      expect(
        fallEnd.difference(fallStart),
        const Duration(days: 366, hours: 1),
      );
      final fall = await fallRepository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'fall civil span',
          startAt: fallStart,
          endAt: fallEnd,
          timezone: 'America/New_York',
          recurrence: rule,
        ),
      );
      expect(fall.startAt, fallStart);

      final springRepository = LocalScheduleRepository();
      final springStartWall = DateTime(2025, 3, 8, 9);
      final springEndWall = DateTime(2026, 3, 9, 9);
      final springStart = wallTimeToUtc(springStartWall, 'America/New_York');
      final springEnd = wallTimeToUtc(springEndWall, 'America/New_York');
      expect(
        springEnd.difference(springStart),
        const Duration(days: 365, hours: 23),
      );
      final spring = await springRepository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'spring civil span',
          startAt: springStart,
          endAt: springEnd,
          timezone: 'America/New_York',
          recurrence: rule,
        ),
      );
      expect(spring.startAt, springStart);

      final tooLongRepository = LocalScheduleRepository();
      await expectLater(
        tooLongRepository.createRecurringEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: 'over civil limit',
            startAt: springStart,
            endAt: wallTimeToUtc(DateTime(2026, 3, 10, 9), 'America/New_York'),
            timezone: 'America/New_York',
            recurrence: rule,
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'Supabase v2 row parser retains the complete occurrence projection',
    () async {
      final row = <String, dynamic>{
        'id': 'event-1',
        'event_id': 'event-1',
        'series_id': 'event-1',
        'group_id': 'group-1',
        'created_by': 'demo-user',
        'title': 'series',
        'description': '',
        'starts_at': '2030-01-02T09:00:00.000Z',
        'ends_at': '2030-01-02T10:00:00.000Z',
        'timezone': 'UTC',
        'is_all_day': false,
        'all_day_start': null,
        'all_day_end': null,
        'version': 1,
        'deleted_at': null,
        'created_at': '2030-01-01T00:00:00.000Z',
        'updated_at': '2030-01-01T00:00:00.000Z',
        'color_value': 1,
        'member_ids': <String>['demo-user'],
        'occurrence_key': 'o00000000000000000000',
        'occurrence_index': 0,
        'occurrence_version': 0,
        'is_occurrence': true,
        'scheduled_starts_at': '2030-01-02T09:00:00.000Z',
        'scheduled_ends_at': '2030-01-02T10:00:00.000Z',
        'recurrence_rule': <String, dynamic>{
          'frequency': 'daily',
          'interval': 1,
          'weekdays': <int>[],
          'end': 'never',
          'count': null,
          'until_date': null,
          'monthly_day': null,
        },
      };
      final client = _client(<String, dynamic>{
        'events': <Object>[row],
        'next_cursor': null,
        'has_more': false,
      });
      addTearDown(client.dispose);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'hint',
      );
      final page = await repository.eventsForRange(
        userId: 'hint',
        groupId: 'group-1',
        range: _range(DateTime.utc(2030, 1, 2), DateTime.utc(2030, 1, 3)),
      );
      expect(page.events.single.occurrenceKey, 'o00000000000000000000');
      expect(page.events.single.scheduledEndsAt, DateTime.utc(2030, 1, 2, 10));
      expect(
        page.events.single.recurrenceRule?.frequency,
        RecurrenceFrequency.daily,
      );
    },
  );

  test('occurrence ordinals and v2 cursors stay within signed bigint', () {
    const max = 9223372036854775807;
    final maxKey = occurrenceKeyForIndex(max);
    expect(maxKey, 'o09223372036854775807');
    expect(occurrenceIndexFromKey(maxKey), max);
    expect(isValidOccurrenceKey(maxKey), isTrue);
    const overflowKey = 'o9223372036854775808';
    expect(isValidOccurrenceKey(overflowKey), isFalse);
    expect(occurrenceIndexFromKey(overflowKey), isNull);
    expect(
      () => EventRangeCursor(
        startsAtUtc: DateTime.utc(2030),
        eventId: 'event-1',
        occurrenceKey: overflowKey,
      ),
      throwsFormatException,
    );
    expect(() => occurrenceKeyForIndex(-1), throwsFormatException);
  });

  test(
    'Local point lookup treats valid but unmaterializable ordinals as missing',
    () async {
      final repository = LocalScheduleRepository();
      final daily = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'large daily',
          startAt: DateTime.utc(2030, 1, 1, 9),
          endAt: DateTime.utc(2030, 1, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.never,
          ),
        ),
      );
      for (final ordinal in <int>[2147483648, 9223372036854775807]) {
        expect(
          await repository.eventOccurrenceByKey(
            userId: 'demo-user',
            groupId: 'demo-group',
            eventId: daily.id,
            occurrenceKey: occurrenceKeyForIndex(ordinal),
          ),
          isNull,
        );
      }

      final weekly = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'large weekly',
          startAt: DateTime.utc(2030, 1, 7, 9),
          endAt: DateTime.utc(2030, 1, 7, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.weekly,
            interval: 999,
            weekdays: const <int>[1],
            end: RecurrenceEnd.never,
          ),
        ),
      );
      expect(
        await repository.eventOccurrenceByKey(
          userId: 'demo-user',
          groupId: 'demo-group',
          eventId: weekly.id,
          occurrenceKey: occurrenceKeyForIndex(2000000),
        ),
        isNull,
      );

      final monthly = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'large monthly',
          startAt: DateTime.utc(2030, 1, 1, 9),
          endAt: DateTime.utc(2030, 1, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.monthly,
            interval: 999,
            monthlyDay: 1,
            end: RecurrenceEnd.never,
          ),
        ),
      );
      expect(
        await repository.eventOccurrenceByKey(
          userId: 'demo-user',
          groupId: 'demo-group',
          eventId: monthly.id,
          occurrenceKey: occurrenceKeyForIndex(2000000),
        ),
        isNull,
      );
    },
  );

  test('civil wall recurrence arithmetic is stable across DST transitions', () {
    PlannerEvent seriesFor(String timezone, DateTime wallStart) {
      final start = wallTimeToUtc(wallStart, timezone);
      final end = wallTimeToUtc(
        wallStart.add(const Duration(hours: 1)),
        timezone,
      );
      return PlannerEvent(
        id: 'dst-${wallStart.month}',
        groupId: 'g',
        title: 'dst',
        startAt: start,
        endAt: end,
        ownerId: 'u',
        timezone: timezone,
        recurrenceRule: RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          end: RecurrenceEnd.count,
          count: 3,
        ),
      );
    }

    final spring = seriesFor('America/New_York', DateTime(2026, 3, 7, 9));
    final springRows = expandRecurringEvent(
      spring,
      EventRange(
        startUtc: DateTime.utc(2026, 3, 7),
        endUtc: DateTime.utc(2026, 3, 11),
        viewTimezone: 'America/New_York',
      ),
    );
    expect(
      springRows.map(
        (row) => utcToCivilWallTimePrecise(row.startAt, row.timezone).hour,
      ),
      <int>[9, 9, 9],
    );
    expect(springRows.map((row) => row.startAt), <DateTime>[
      DateTime.utc(2026, 3, 7, 14),
      DateTime.utc(2026, 3, 8, 13),
      DateTime.utc(2026, 3, 9, 13),
    ]);

    final fall = seriesFor('America/New_York', DateTime(2026, 10, 31, 9));
    final fallRows = expandRecurringEvent(
      fall,
      EventRange(
        startUtc: DateTime.utc(2026, 10, 31),
        endUtc: DateTime.utc(2026, 11, 4),
        viewTimezone: 'America/New_York',
      ),
    );
    expect(
      fallRows.map(
        (row) => utcToCivilWallTimePrecise(row.startAt, row.timezone).hour,
      ),
      <int>[9, 9, 9],
    );
    expect(fallRows.map((row) => row.startAt), <DateTime>[
      DateTime.utc(2026, 10, 31, 13),
      DateTime.utc(2026, 11, 1, 14),
      DateTime.utc(2026, 11, 2, 14),
    ]);
  });

  test('cross-midnight timed occurrence uses a one-day civil lookbehind', () {
    final wallStart = DateTime(2030, 1, 1, 23);
    final series = PlannerEvent(
      id: 'overnight',
      groupId: 'g',
      title: 'overnight',
      startAt: wallTimeToUtc(wallStart, 'UTC'),
      endAt: wallTimeToUtc(DateTime(2030, 1, 2, 1), 'UTC'),
      ownerId: 'u',
      timezone: 'UTC',
      recurrenceRule: RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 2,
      ),
    );
    final rows = expandRecurringEvent(
      series,
      _range(DateTime.utc(2030, 1, 2), DateTime.utc(2030, 1, 3)),
    );
    expect(rows.map((row) => row.occurrenceIndex), <int>[0, 1]);
  });

  test('Local future delete at ordinal zero tombstones the anchor', () async {
    final repository = LocalScheduleRepository();
    final anchor = await repository.createRecurringEvent(
      'demo-user',
      'demo-group',
      EventDraft(
        title: 'delete from start',
        startAt: DateTime.utc(2030, 1, 1, 9),
        endAt: DateTime.utc(2030, 1, 1, 10),
        timezone: 'UTC',
        recurrence: RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          end: RecurrenceEnd.count,
          count: 4,
        ),
      ),
    );
    final range = _range(DateTime.utc(2030, 1, 1), DateTime.utc(2030, 1, 8));
    final first = (await repository.eventsForRange(
      userId: 'demo-user',
      groupId: 'demo-group',
      range: range,
      limit: 20,
    )).events.first;
    expect(first.occurrenceIndex, 0);
    final receipt = await repository.deleteEventOccurrence(
      event: first,
      scope: EventEditScope.future,
      expectedSeriesVersion: anchor.version,
      expectedOccurrenceVersion: first.occurrenceVersion,
      actorId: 'demo-user',
    );
    expect(receipt.changed, isTrue);
    expect(
      (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events,
      isEmpty,
    );
    expect(
      await repository.eventOccurrenceByKey(
        userId: 'demo-user',
        groupId: 'demo-group',
        eventId: anchor.id,
        occurrenceKey: 'single',
      ),
      isNull,
    );
  });

  test(
    'Local moved-in overrides are included once and sorted by effective time',
    () async {
      final repository = LocalScheduleRepository();
      final anchor = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'moves',
          startAt: DateTime.utc(2030, 1, 1, 9),
          endAt: DateTime.utc(2030, 1, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.never,
          ),
        ),
      );
      final movedIn = await repository.eventOccurrenceByKey(
        userId: 'demo-user',
        groupId: 'demo-group',
        eventId: anchor.id,
        occurrenceKey: occurrenceKeyForIndex(20),
      );
      expect(movedIn, isNotNull);
      final moveReceipt = await repository.updateEventOccurrence(
        event: movedIn!,
        draft: EventDraft(
          title: 'moved in',
          startAt: DateTime.utc(2030, 1, 3, 12),
          endAt: DateTime.utc(2030, 1, 3, 13),
          timezone: 'UTC',
          memberIds: movedIn.memberIds,
        ),
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: anchor.version,
        expectedOccurrenceVersion: movedIn.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(moveReceipt.changed, isTrue);

      final movedOut = await repository.eventOccurrenceByKey(
        userId: 'demo-user',
        groupId: 'demo-group',
        eventId: anchor.id,
        occurrenceKey: occurrenceKeyForIndex(2),
      );
      expect(movedOut, isNotNull);
      final moveOutReceipt = await repository.updateEventOccurrence(
        event: movedOut!,
        draft: EventDraft(
          title: movedOut.title,
          startAt: DateTime.utc(2030, 2, 1, 9),
          endAt: DateTime.utc(2030, 2, 1, 10),
          timezone: 'UTC',
          memberIds: movedOut.memberIds,
        ),
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: anchor.version + 1,
        expectedOccurrenceVersion: movedOut.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(moveOutReceipt.changed, isTrue);

      final cancelled = await repository.eventOccurrenceByKey(
        userId: 'demo-user',
        groupId: 'demo-group',
        eventId: anchor.id,
        occurrenceKey: occurrenceKeyForIndex(3),
      );
      expect(cancelled, isNotNull);
      final cancelReceipt = await repository.deleteEventOccurrence(
        event: cancelled!,
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: anchor.version + 2,
        expectedOccurrenceVersion: cancelled.occurrenceVersion,
        actorId: 'demo-user',
      );
      expect(cancelReceipt.changed, isTrue);

      final rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: _range(DateTime.utc(2030, 1, 3), DateTime.utc(2030, 1, 6)),
        limit: 20,
      )).events;
      expect(rows.map((row) => row.occurrenceIndex), <int>[20, 4]);
      expect(
        rows.map((row) => row.identityKey).toSet(),
        hasLength(rows.length),
      );
      expect(rows.first.title, 'moved in');
      expect(rows.any((row) => row.occurrenceIndex == 2), isFalse);
      expect(rows.any((row) => row.occurrenceIndex == 3), isFalse);
    },
  );

  test(
    'Local recurring member changes update full override snapshots',
    () async {
      final repository = LocalScheduleRepository();
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 3,
      );
      final draft = EventDraft(
        title: 'assigned series',
        startAt: DateTime.utc(2030, 6, 1, 9),
        endAt: DateTime.utc(2030, 6, 1, 10),
        timezone: 'UTC',
        memberIds: const <String>['demo-user', 'member-jin'],
        recurrence: rule,
      );
      final anchor = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        draft,
      );
      final range = _range(DateTime.utc(2030, 6, 1), DateTime.utc(2030, 6, 5));
      var rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == anchor.id).toList();
      final overridden = rows.singleWhere(
        (event) => event.occurrenceIndex == 1,
      );
      await repository.updateEventOccurrence(
        event: overridden,
        draft: EventDraft(
          title: 'override keeps assignment',
          startAt: overridden.startAt,
          endAt: overridden.endAt,
          timezone: 'UTC',
          memberIds: overridden.memberIds,
        ),
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: anchor.version,
        expectedOccurrenceVersion: overridden.occurrenceVersion,
        actorId: 'demo-user',
      );

      final replaced = await repository.replaceEventMembers(
        anchor.id,
        memberIds: const <String>['demo-user'],
        expectedVersion: anchor.version + 1,
        actorId: 'demo-user',
      );
      expect(replaced.memberIds, <String>['demo-user']);
      rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == anchor.id).toList();
      expect(rows, hasLength(3));
      expect(
        rows.every(
          (event) =>
              event.memberIds.length == 1 &&
              event.memberIds.single == 'demo-user',
        ),
        isTrue,
      );
      expect(
        rows.singleWhere((event) => event.occurrenceIndex == 1).title,
        'override keeps assignment',
      );

      await repository.setMemberActive(
        'demo-group',
        'member-jin',
        false,
        actorId: 'demo-user',
      );
      await repository.setMemberActive(
        'demo-group',
        'member-jin',
        true,
        actorId: 'demo-user',
      );
      final second = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        draft.copyWith(title: 'deactivation series'),
      );
      rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == second.id).toList();
      final secondOverride = rows.singleWhere(
        (event) => event.occurrenceIndex == 1,
      );
      await repository.updateEventOccurrence(
        event: secondOverride,
        draft: EventDraft(
          title: 'deactivation override',
          startAt: secondOverride.startAt,
          endAt: secondOverride.endAt,
          timezone: 'UTC',
          memberIds: secondOverride.memberIds,
        ),
        scope: EventEditScope.thisOccurrence,
        expectedSeriesVersion: second.version,
        expectedOccurrenceVersion: secondOverride.occurrenceVersion,
        actorId: 'demo-user',
      );
      await repository.setMemberActive(
        'demo-group',
        'member-jin',
        false,
        actorId: 'demo-user',
      );
      rows = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: range,
        limit: 20,
      )).events.where((event) => event.id == second.id).toList();
      expect(rows, hasLength(3));
      expect(
        rows.every(
          (event) =>
              event.memberIds.length == 1 &&
              event.memberIds.single == 'demo-user',
        ),
        isTrue,
      );
      expect(
        rows.singleWhere((event) => event.occurrenceIndex == 1).title,
        'deactivation override',
      );
    },
  );

  test(
    'controller default detail lookup aliases recurring anchor to ordinal zero',
    () async {
      final repository = LocalScheduleRepository();
      final anchor = await repository.createRecurringEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'deep link series',
          startAt: DateTime.utc(2030, 5, 1, 9),
          endAt: DateTime.utc(2030, 5, 1, 10),
          timezone: 'UTC',
          recurrence: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            end: RecurrenceEnd.count,
            count: 2,
          ),
        ),
      );
      final auth = AuthRepository();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = const PlannerUser(
        id: 'demo-user',
        email: 'demo@example.com',
      );
      controller.selectedGroup = const PlannerGroup(
        id: 'demo-group',
        name: 'Demo',
        timezone: 'UTC',
      );
      final loaded = await controller.loadEventById(anchor.id);
      expect(loaded, isNotNull);
      expect(loaded!.occurrenceKey, occurrenceKeyForIndex(0));
      expect(loaded.isOccurrence, isTrue);
      expect(loaded.recurrenceRule, isNotNull);
    },
  );

  test(
    'Local recurring participant replacement retains creator and returns exact receipts',
    () async {
      final repository = LocalScheduleRepository();
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 3,
      );
      final anchor = await repository.createRecurringEvent(
        'member-jin',
        'demo-group',
        EventDraft(
          title: 'owner-administered series',
          startAt: DateTime.utc(2030, 7, 1, 9),
          endAt: DateTime.utc(2030, 7, 1, 10),
          timezone: 'UTC',
          memberIds: const <String>['member-jin'],
          recurrence: rule,
        ),
      );
      final occurrence = (await repository.eventsForRange(
        userId: 'demo-user',
        groupId: 'demo-group',
        range: _range(DateTime.utc(2030, 7, 1), DateTime.utc(2030, 7, 5)),
        limit: 20,
      )).events.first;

      await expectLater(
        repository.replaceRecurringEventMembers(
          event: occurrence,
          memberIds: const <String>[],
          expectedVersion: anchor.version,
          actorId: 'demo-user',
        ),
        throwsA(isA<ScheduleValidationException>()),
      );
      final unchanged = await repository.eventOccurrenceByKey(
        userId: 'demo-user',
        groupId: 'demo-group',
        eventId: anchor.id,
        occurrenceKey: occurrence.occurrenceKey,
      );
      expect(unchanged, isNotNull);
      expect(unchanged!.memberIds, <String>['member-jin']);
      expect(unchanged.version, anchor.version);

      final changed = await repository.replaceRecurringEventMembers(
        event: occurrence,
        memberIds: const <String>['demo-user', 'member-jin'],
        expectedVersion: anchor.version,
        actorId: 'demo-user',
      );
      expect(changed.groupId, 'demo-group');
      expect(changed.eventId, anchor.id);
      expect(changed.occurrenceKey, occurrence.occurrenceKey);
      expect(changed.scope, EventEditScope.all);
      expect(changed.seriesVersion, anchor.version + 1);
      expect(changed.occurrenceVersion, 0);
      expect(changed.changed, isTrue);

      final noOp = await repository.replaceRecurringEventMembers(
        event: occurrence,
        memberIds: const <String>['member-jin', 'demo-user', 'member-jin'],
        expectedVersion: anchor.version + 1,
        actorId: 'demo-user',
      );
      expect(noOp.changed, isFalse);
      expect(noOp.seriesVersion, anchor.version + 1);
      expect(noOp.occurrenceVersion, 0);

      await expectLater(
        repository.replaceEventMembers(
          anchor.id,
          memberIds: const <String>['demo-user'],
          expectedVersion: anchor.version + 1,
          actorId: 'demo-user',
        ),
        throwsA(isA<ScheduleValidationException>()),
      );
    },
  );

  test(
    'Supabase v2 rejects short has_more pages and incoherent materialized rows',
    () async {
      final row = <String, dynamic>{
        'id': 'event-1',
        'event_id': 'event-1',
        'series_id': 'event-1',
        'group_id': 'group-1',
        'created_by': 'demo-user',
        'title': 'series',
        'description': '',
        'starts_at': '2030-01-02T09:00:00.000Z',
        'ends_at': '2030-01-02T10:00:00.000Z',
        'timezone': 'UTC',
        'is_all_day': false,
        'all_day_start': null,
        'all_day_end': null,
        'version': 1,
        'deleted_at': null,
        'created_at': '2030-01-01T00:00:00.000Z',
        'updated_at': '2030-01-01T00:00:00.000Z',
        'color_value': 1,
        'member_ids': <String>['demo-user'],
        'occurrence_key': occurrenceKeyForIndex(0),
        'occurrence_index': 0,
        'occurrence_version': 0,
        'is_occurrence': true,
        'scheduled_starts_at': '2030-01-02T09:00:00.000Z',
        'scheduled_ends_at': '2030-01-02T10:00:00.000Z',
        'recurrence_rule': <String, dynamic>{
          'frequency': 'daily',
          'interval': 1,
          'weekdays': <int>[],
          'end': 'never',
          'count': null,
          'until_date': null,
          'monthly_day': null,
        },
      };
      final transport = _RpcTransport(<String, dynamic>{
        'events': <Object>[row],
        'next_cursor': EventRangeCursor(
          startsAtUtc: DateTime.utc(2030, 1, 2, 9),
          eventId: 'event-1',
          occurrenceKey: occurrenceKeyForIndex(0),
        ).encode(),
        'has_more': true,
      });
      final client = _client(transport.payload);
      addTearDown(client.dispose);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'demo-user',
      );
      await expectLater(
        repository.eventsForRange(
          userId: 'demo-user',
          groupId: 'group-1',
          range: _range(DateTime.utc(2030, 1, 2), DateTime.utc(2030, 1, 3)),
          limit: 2,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    },
  );

  test(
    'Supabase recurring create accepts only the canonical first occurrence row',
    () async {
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 2,
      );
      final draft = EventDraft(
        title: 'created series',
        note: 'note',
        startAt: DateTime.utc(2030, 1, 2, 9),
        endAt: DateTime.utc(2030, 1, 2, 10),
        timezone: 'UTC',
        memberIds: const <String>['demo-user'],
        recurrence: rule,
      );
      Map<String, dynamic> row({String seriesId = 'event-create'}) =>
          <String, dynamic>{
            'id': 'event-create',
            'event_id': 'event-create',
            'series_id': seriesId,
            'group_id': 'group-1',
            'created_by': 'demo-user',
            'title': 'created series',
            'description': 'note',
            'starts_at': '2030-01-02T09:00:00.000Z',
            'ends_at': '2030-01-02T10:00:00.000Z',
            'timezone': 'UTC',
            'is_all_day': false,
            'all_day_start': null,
            'all_day_end': null,
            'version': 1,
            'deleted_at': null,
            'created_at': '2030-01-01T00:00:00.000Z',
            'updated_at': '2030-01-02T09:00:00.000Z',
            'color_value': 0xff476a6f,
            'member_ids': <String>['demo-user'],
            'occurrence_key': occurrenceKeyForIndex(0),
            'occurrence_index': 0,
            'occurrence_version': 0,
            'is_occurrence': true,
            'scheduled_starts_at': '2030-01-02T09:00:00.000Z',
            'scheduled_ends_at': '2030-01-02T10:00:00.000Z',
            'recurrence_rule': rule.toJson(),
          };
      final goodClient = _client(row());
      addTearDown(goodClient.dispose);
      final goodRepository = _AuthenticatedSupabaseScheduleRepository(
        goodClient,
        'demo-user',
      );
      final created = await goodRepository.createRecurringEvent(
        'demo-user',
        'group-1',
        draft,
      );
      expect(created.id, 'event-create');
      expect(created.seriesId, 'event-create');
      expect(created.occurrenceKey, occurrenceKeyForIndex(0));
      expect(created.occurrenceIndex, 0);
      expect(created.occurrenceVersion, 0);
      expect(created.isOccurrence, isTrue);
      expect(created.memberIds, <String>['demo-user']);

      final malformedClient = _client(row(seriesId: 'different-series'));
      addTearDown(malformedClient.dispose);
      final malformedRepository = _AuthenticatedSupabaseScheduleRepository(
        malformedClient,
        'demo-user',
      );
      await expectLater(
        malformedRepository.createRecurringEvent('demo-user', 'group-1', draft),
        throwsA(isA<ScheduleConflictException>()),
      );
    },
  );

  test(
    'Supabase recurring create validates rule-derived ordinal zero materialization',
    () async {
      Map<String, dynamic> rowFor({
        required String id,
        required EventDraft draft,
        required RecurrenceRule rule,
        required PlannerEvent occurrence,
      }) => <String, dynamic>{
        'id': id,
        'event_id': id,
        'series_id': id,
        'group_id': 'group-1',
        'created_by': 'demo-user',
        'title': draft.title.trim(),
        'description': draft.note.trim(),
        'starts_at': occurrence.startAt.toUtc().toIso8601String(),
        'ends_at': occurrence.endAt.toUtc().toIso8601String(),
        'timezone': draft.timezone,
        'is_all_day': draft.allDay,
        'all_day_start': draft.allDay
            ? '${occurrence.allDayStartDate!.year.toString().padLeft(4, '0')}-${occurrence.allDayStartDate!.month.toString().padLeft(2, '0')}-${occurrence.allDayStartDate!.day.toString().padLeft(2, '0')}'
            : null,
        'all_day_end': draft.allDay
            ? '${occurrence.allDayEndDate!.year.toString().padLeft(4, '0')}-${occurrence.allDayEndDate!.month.toString().padLeft(2, '0')}-${occurrence.allDayEndDate!.day.toString().padLeft(2, '0')}'
            : null,
        'version': 1,
        'deleted_at': null,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
        'color_value': draft.colorValue,
        'member_ids': <String>['demo-user'],
        'occurrence_key': occurrenceKeyForIndex(0),
        'occurrence_index': 0,
        'occurrence_version': 0,
        'is_occurrence': true,
        'scheduled_starts_at': occurrence.scheduledStartsAt!
            .toUtc()
            .toIso8601String(),
        'scheduled_ends_at': occurrence.scheduledEndsAt!
            .toUtc()
            .toIso8601String(),
        'recurrence_rule': rule.toJson(),
      };

      PlannerEvent seriesFor(
        String id,
        EventDraft draft,
        RecurrenceRule rule,
      ) => PlannerEvent(
        id: id,
        groupId: 'group-1',
        title: draft.title,
        note: draft.note,
        startAt: draft.startAt,
        endAt: draft.endAt,
        allDay: draft.allDay,
        ownerId: 'demo-user',
        memberIds: const <String>['demo-user'],
        colorValue: draft.colorValue,
        timezone: draft.timezone,
        allDayStartDate: draft.allDayStartDate,
        allDayEndDate: draft.allDayEndDate,
        recurrenceRule: rule,
      );

      final monthlyRule = RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        monthlyDay: 31,
        end: RecurrenceEnd.count,
        count: 3,
      );
      final monthlyDraft = EventDraft(
        title: 'monthly clamp',
        note: 'anchor differs from ordinal zero',
        startAt: DateTime.utc(2030, 1, 15, 9),
        endAt: DateTime.utc(2030, 1, 15, 10),
        timezone: 'UTC',
        memberIds: const <String>['demo-user'],
        recurrence: monthlyRule,
      );
      final monthlySeries = seriesFor(
        'event-monthly',
        monthlyDraft,
        monthlyRule,
      );
      final monthlyO0 = recurringOccurrenceAtIndex(monthlySeries, 0)!;
      expect(monthlyO0.startAt, DateTime.utc(2030, 1, 31, 9));
      final monthlyClient = _client(
        rowFor(
          id: 'event-monthly',
          draft: monthlyDraft,
          rule: monthlyRule,
          occurrence: monthlyO0,
        ),
      );
      addTearDown(monthlyClient.dispose);
      final monthlyRepository = _AuthenticatedSupabaseScheduleRepository(
        monthlyClient,
        'demo-user',
      );
      final monthlyCreated = await monthlyRepository.createRecurringEvent(
        'demo-user',
        'group-1',
        monthlyDraft,
      );
      expect(monthlyCreated.startAt, DateTime.utc(2030, 1, 31, 9));

      final dstRule = RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        monthlyDay: 31,
        end: RecurrenceEnd.count,
        count: 2,
      );
      final dstWallStart = DateTime(2026, 3, 15, 9);
      final dstWallEnd = DateTime(2026, 3, 15, 10);
      final dstDraft = EventDraft(
        title: 'monthly DST',
        startAt: wallTimeToUtc(dstWallStart, 'America/New_York'),
        endAt: wallTimeToUtc(dstWallEnd, 'America/New_York'),
        timezone: 'America/New_York',
        memberIds: const <String>['demo-user'],
        recurrence: dstRule,
      );
      final dstSeries = seriesFor('event-dst', dstDraft, dstRule);
      final dstO0 = recurringOccurrenceAtIndex(dstSeries, 0)!;
      expect(
        utcToCivilWallTimePrecise(dstO0.startAt, dstO0.timezone),
        DateTime.utc(2026, 3, 31, 9),
      );
      final dstClient = _client(
        rowFor(
          id: 'event-dst',
          draft: dstDraft,
          rule: dstRule,
          occurrence: dstO0,
        ),
      );
      addTearDown(dstClient.dispose);
      final dstRepository = _AuthenticatedSupabaseScheduleRepository(
        dstClient,
        'demo-user',
      );
      final dstCreated = await dstRepository.createRecurringEvent(
        'demo-user',
        'group-1',
        dstDraft,
      );
      expect(
        utcToCivilWallTimePrecise(dstCreated.startAt, dstCreated.timezone),
        DateTime.utc(2026, 3, 31, 9),
      );

      final allDayRule = RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        monthlyDay: 31,
        end: RecurrenceEnd.count,
        count: 2,
      );
      // The anchor day (15) differs from monthly_day (31), while the
      // materialized date crosses the spring DST boundary in this zone.
      final allDayStart = DateTime(2026, 3, 15);
      final allDayEnd = DateTime(2026, 3, 17);
      final allDayDraft = EventDraft(
        title: 'monthly all day',
        startAt: wallTimeToUtc(allDayStart, 'America/New_York'),
        endAt: wallTimeToUtc(allDayEnd, 'America/New_York'),
        allDay: true,
        timezone: 'America/New_York',
        allDayStartDate: allDayStart,
        allDayEndDate: allDayEnd,
        memberIds: const <String>['demo-user'],
        recurrence: allDayRule,
      );
      final allDaySeries = seriesFor('event-all-day', allDayDraft, allDayRule);
      final allDayO0 = recurringOccurrenceAtIndex(allDaySeries, 0)!;
      expect(allDayO0.allDayStartDate, DateTime(2026, 3, 31));
      expect(allDayO0.allDayEndDate, DateTime(2026, 4, 2));
      final allDayClient = _client(
        rowFor(
          id: 'event-all-day',
          draft: allDayDraft,
          rule: allDayRule,
          occurrence: allDayO0,
        ),
      );
      addTearDown(allDayClient.dispose);
      final allDayRepository = _AuthenticatedSupabaseScheduleRepository(
        allDayClient,
        'demo-user',
      );
      final allDayCreated = await allDayRepository.createRecurringEvent(
        'demo-user',
        'group-1',
        allDayDraft,
      );
      expect(allDayCreated.allDayStartDate, DateTime(2026, 3, 31));
      expect(allDayCreated.allDayEndDate, DateTime(2026, 4, 2));
    },
  );

  test('Supabase v2 rejects timezone-less lifecycle timestamps', () async {
    final row = <String, dynamic>{
      'id': 'event-lifecycle',
      'event_id': 'event-lifecycle',
      'series_id': 'event-lifecycle',
      'group_id': 'group-1',
      'created_by': 'demo-user',
      'title': 'lifecycle',
      'description': '',
      'starts_at': '2030-01-02T09:00:00.000Z',
      'ends_at': '2030-01-02T10:00:00.000Z',
      'timezone': 'UTC',
      'is_all_day': false,
      'all_day_start': null,
      'all_day_end': null,
      'version': 1,
      'deleted_at': null,
      'created_at': '2030-01-01T00:00:00.000Z',
      'updated_at': '2030-01-01T00:00:00.000Z',
      'color_value': 0xff476a6f,
      'member_ids': <String>['demo-user'],
      'occurrence_key': occurrenceKeyForIndex(0),
      'occurrence_index': 0,
      'occurrence_version': 0,
      'is_occurrence': true,
      'scheduled_starts_at': '2030-01-02T09:00:00.000Z',
      'scheduled_ends_at': '2030-01-02T10:00:00.000Z',
      'recurrence_rule': <String, dynamic>{
        'frequency': 'daily',
        'interval': 1,
        'weekdays': <int>[],
        'end': 'never',
        'count': null,
        'until_date': null,
        'monthly_day': null,
      },
    };
    final range = _range(DateTime.utc(2030, 1, 2), DateTime.utc(2030, 1, 3));
    for (final field in <String>['created_at', 'updated_at', 'deleted_at']) {
      final malformed = <String, dynamic>{
        ...row,
        field: '2030-01-01T00:00:00.000',
      };
      final client = _client(<String, dynamic>{
        'events': <Object>[malformed],
        'next_cursor': null,
        'has_more': false,
      });
      addTearDown(client.dispose);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'demo-user',
      );
      await expectLater(
        repository.eventsForRange(
          userId: 'demo-user',
          groupId: 'group-1',
          range: range,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    }
  });
}
