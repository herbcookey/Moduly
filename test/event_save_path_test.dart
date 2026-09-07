// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(id: 'user-1', email: 'user@example.com');
const _group = PlannerGroup(
  id: 'group-1',
  name: 'Group',
  timezone: 'America/Los_Angeles',
);

class _CurrentAuth extends AuthRepository {
  _CurrentAuth({this._currentUser = _user}) : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();
  final PlannerUser? _currentUser;

  @override
  PlannerUser? get currentUser => _currentUser;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _SilentCreateRepository extends LocalScheduleRepository {
  PlannerEvent? created;
  PlannerEvent? updated;

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    created = PlannerEvent(
      id: 'created-1',
      groupId: groupId,
      title: draft.title,
      startAt: draft.startAt,
      endAt: draft.endAt,
      ownerId: userId,
      timezone: draft.timezone,
      allDay: draft.allDay,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
    );
    // 실시간 전달이 지연되거나 사용할 수 없는 상황에서 성공한 삽입을
    // 재현한다. 컨트롤러는 이때도 반환된 일정을 노출해야 한다.
    return created!;
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    updated = event.copyWith(version: expectedVersion + 1);
    return updated!;
  }
}

class _MemberFailureRepository extends LocalScheduleRepository {
  bool watchStarted = false;

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) {
    return Future<List<PlannerMember>>.error(
      StateError('profiles lookup failed'),
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) {
    watchStarted = true;
    return Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);
  }
}

class _RecordingRpcTransport extends http.BaseClient {
  _RecordingRpcTransport(this.payload);

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

class _RecordingSupabaseScheduleRepository extends SupabaseScheduleRepository {
  _RecordingSupabaseScheduleRepository(super.client);

  @override
  String? get currentSessionUserId => 'user-1';

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async => EventRangePage.empty();
}

void main() {
  test(
    'saveEvent reports a missing group instead of silently succeeding',
    () async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        controller.saveEvent(
          draft: EventDraft(
            title: 'Not saved',
            startAt: DateTime.utc(2026, 8, 14, 16),
            endAt: DateTime.utc(2026, 8, 14, 17),
          ),
        ),
        throwsA(
          isA<ScheduleValidationException>().having(
            (error) => error.message,
            'message',
            '일정을 저장하려면 로그인하고 그룹을 선택해 주세요.',
          ),
        ),
      );
      expect(repository.created, isNull);
      expect(controller.errorMessage, '일정을 저장하려면 로그인하고 그룹을 선택해 주세요.');
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'saveEvent upserts the create result before realtime delivery',
    () async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = _user;
      controller.selectedGroup = _group;

      await controller.saveEvent(
        draft: EventDraft(
          title: 'Created remotely',
          startAt: DateTime.utc(2026, 8, 14, 16),
          endAt: DateTime.utc(2026, 8, 14, 17),
        ),
      );

      expect(repository.created, isNotNull);
      expect(
        controller.events.map((event) => event.id),
        contains(repository.created!.id),
      );
    },
  );

  test('saveEvent upserts the versioned update result', () async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    controller.user = _user;
    controller.selectedGroup = _group;
    final existing = PlannerEvent(
      id: 'event-1',
      groupId: _group.id,
      title: 'Before',
      startAt: DateTime.utc(2026, 8, 14, 16),
      endAt: DateTime.utc(2026, 8, 14, 17),
      ownerId: _user.id,
      version: 4,
      timezone: _group.timezone,
    );
    controller.events = <PlannerEvent>[existing];

    await controller.saveEvent(
      existing: existing,
      draft: EventDraft(
        title: 'After',
        startAt: DateTime.utc(2026, 8, 15, 16),
        endAt: DateTime.utc(2026, 8, 15, 17),
        timezone: _group.timezone,
      ),
    );

    expect(repository.updated?.title, 'After');
    expect(repository.updated?.version, 5);
    expect(controller.events.single.title, 'After');
    expect(controller.events.single.version, 5);
  });

  test(
    'event author keeps the normal atomic update path for member-only saves',
    () async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = _user;
      controller.selectedGroup = _group;
      final existing = PlannerEvent(
        id: 'event-author-members',
        groupId: _group.id,
        title: 'Shared event',
        startAt: DateTime.utc(2026, 8, 14, 16),
        endAt: DateTime.utc(2026, 8, 14, 17),
        ownerId: _user.id,
        memberIds: const <String>['user-1'],
        timezone: _group.timezone,
        version: 4,
      );
      controller.events = <PlannerEvent>[existing];

      await controller.saveEvent(
        existing: existing,
        draft: EventDraft(
          title: existing.title,
          note: existing.note,
          startAt: existing.startAt,
          endAt: existing.endAt,
          timezone: existing.timezone,
          colorValue: existing.colorValue,
          memberIds: const <String>['user-1', 'member-a'],
        ),
      );

      expect(repository.updated, isNotNull);
      expect(repository.updated!.version, 5);
      expect(repository.updated!.memberIds, <String>['member-a', 'user-1']);
      expect(controller.events.single.memberIds, <String>[
        'member-a',
        'user-1',
      ]);
    },
  );

  test(
    'saveEvent routes singleton/series conversions through recurrence capability',
    () async {
      final repository = LocalScheduleRepository();
      const demo = PlannerUser(id: 'demo-user', email: 'demo@example.com');
      final auth = _CurrentAuth(currentUser: demo);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      const group = PlannerGroup(
        id: 'demo-group',
        name: 'Demo',
        timezone: 'UTC',
        ownerId: 'demo-user',
      );
      controller.user = demo;
      controller.selectedGroup = group;
      final start = DateTime.utc(2030, 2, 1, 9);
      final range = EventRange(
        startUtc: DateTime.utc(2030, 2, 1),
        endUtc: DateTime.utc(2030, 2, 5),
        viewTimezone: 'UTC',
      );
      controller.selectedEventRange = range;
      final single = await repository.createEvent(
        demo.id,
        group.id,
        EventDraft(
          title: 'convert',
          startAt: start,
          endAt: start.add(const Duration(hours: 1)),
          timezone: 'UTC',
        ),
      );
      controller.events = <PlannerEvent>[single];
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 2,
      );

      await controller.saveEvent(
        existing: single,
        draft: EventDraft(
          title: single.title,
          startAt: single.startAt,
          endAt: single.endAt,
          timezone: 'UTC',
          recurrence: rule,
          memberIds: single.memberIds,
        ),
      );
      var rows = (await repository.eventsForRange(
        userId: demo.id,
        groupId: group.id,
        range: range,
        limit: 20,
      )).events.where((event) => event.id == single.id).toList();
      expect(rows.map((event) => event.occurrenceKey), <String>[
        occurrenceKeyForIndex(0),
        occurrenceKeyForIndex(1),
      ]);

      final occurrence = rows.first;
      controller.events = <PlannerEvent>[occurrence];
      await controller.saveEvent(
        existing: occurrence,
        draft: EventDraft(
          title: 'converted back',
          startAt: occurrence.startAt,
          endAt: occurrence.endAt,
          timezone: 'UTC',
          memberIds: occurrence.memberIds,
        ),
      );
      rows = (await repository.eventsForRange(
        userId: demo.id,
        groupId: group.id,
        range: range,
        limit: 20,
      )).events.where((event) => event.id == single.id).toList();
      expect(rows, hasLength(1));
      expect(rows.single.occurrenceKey, 'single');
      expect(rows.single.recurrenceRule, isNull);
      expect(rows.single.title, 'converted back');
    },
  );

  test(
    'saveEvent routes recurring member-only changes through assignment capability',
    () async {
      final repository = LocalScheduleRepository();
      const admin = PlannerUser(id: 'demo-user', email: 'demo@example.com');
      const creator = PlannerUser(id: 'member-jin', email: 'jin@example.com');
      const group = PlannerGroup(
        id: 'demo-group',
        name: '우리 가족',
        timezone: 'Asia/Seoul',
        ownerId: 'demo-user',
      );
      final auth = _CurrentAuth(currentUser: admin);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      final anchor = DateTime.utc(2031, 2, 3, 9);
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 3,
      );
      final created = await repository.createRecurringEvent(
        creator.id,
        group.id,
        EventDraft(
          title: 'shared series',
          startAt: anchor,
          endAt: anchor.add(const Duration(hours: 1)),
          timezone: 'UTC',
          recurrence: rule,
          memberIds: const <String>['member-jin'],
        ),
      );
      final range = EventRange(
        startUtc: DateTime.utc(2031, 2, 3),
        endUtc: DateTime.utc(2031, 2, 8),
        viewTimezone: 'UTC',
      );
      final occurrence = (await repository.eventsForRange(
        userId: admin.id,
        groupId: group.id,
        range: range,
        limit: 20,
      )).events.first;
      expect(occurrence.id, created.id);
      controller.user = admin;
      controller.selectedGroup = group;
      controller.members = await repository.membersForGroup(group.id);
      controller.selectedEventRange = range;
      controller.events = <PlannerEvent>[occurrence];

      await controller.saveEvent(
        existing: occurrence,
        draft: EventDraft(
          title: occurrence.title,
          note: occurrence.note,
          startAt: occurrence.startAt,
          endAt: occurrence.endAt,
          timezone: occurrence.timezone,
          colorValue: occurrence.colorValue,
          memberIds: const <String>['member-jin', 'member-soo'],
          recurrence: occurrence.recurrenceRule,
        ),
      );

      final refreshed = (await repository.eventsForRange(
        userId: admin.id,
        groupId: group.id,
        range: range,
        limit: 20,
      )).events;
      expect(refreshed, hasLength(3));
      expect(
        refreshed.every(
          (event) => event.memberIds.toSet().containsAll(const <String>{
            'member-jin',
            'member-soo',
          }),
        ),
        isTrue,
      );
      expect(
        refreshed.every((event) => event.version == occurrence.version + 1),
        isTrue,
      );
      expect(controller.events, hasLength(3));
      expect(
        controller.events.every((event) => event.occurrenceKey != 'single'),
        isTrue,
      );
    },
  );

  test(
    'Supabase member-only save dispatches assignment RPC instead of recurrence RPC',
    () async {
      final transport = _RecordingRpcTransport(<String, dynamic>{
        'group_id': 'group-remote',
        'event_id': 'event-remote',
        'occurrence_key': occurrenceKeyForIndex(0),
        'series_version': 3,
        'occurrence_version': 0,
        'scope': 'all',
        'committed': true,
        'changed': true,
      });
      final client = SupabaseClient(
        'https://example.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: transport,
      );
      final repository = _RecordingSupabaseScheduleRepository(client);
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
        client.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      const group = PlannerGroup(
        id: 'group-remote',
        name: 'Remote',
        timezone: 'UTC',
        ownerId: 'user-1',
      );
      final rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        end: RecurrenceEnd.count,
        count: 2,
      );
      final existing = PlannerEvent(
        id: 'event-remote',
        groupId: group.id,
        seriesId: 'event-remote',
        title: 'remote series',
        startAt: DateTime.utc(2031, 2, 3, 9),
        endAt: DateTime.utc(2031, 2, 3, 10),
        ownerId: 'creator-remote',
        memberIds: const <String>['creator-remote'],
        timezone: 'UTC',
        version: 2,
        occurrenceKey: occurrenceKeyForIndex(0),
        occurrenceIndex: 0,
        occurrenceVersion: 0,
        isOccurrence: true,
        recurrenceRule: rule,
      );
      controller.user = _user;
      controller.selectedGroup = group;
      controller.members = const <PlannerMember>[
        PlannerMember(
          id: 'user-1',
          name: 'Owner',
          email: 'user@example.com',
          isOwner: true,
        ),
        PlannerMember(
          id: 'creator-remote',
          name: 'Creator',
          email: 'creator@example.com',
        ),
      ];
      controller.selectedEventRange = EventRange(
        startUtc: DateTime.utc(2031, 2, 3),
        endUtc: DateTime.utc(2031, 2, 5),
        viewTimezone: 'UTC',
      );
      controller.events = <PlannerEvent>[existing];

      await expectLater(
        controller.saveEvent(
          existing: existing,
          draft: EventDraft(
            title: existing.title,
            note: existing.note,
            startAt: existing.startAt,
            endAt: existing.endAt,
            timezone: existing.timezone,
            colorValue: existing.colorValue,
            memberIds: const <String>[],
            recurrence: rule,
          ),
        ),
        throwsA(isA<ScheduleValidationException>()),
      );
      // Creator exclusion is rejected before any RPC is issued.
      expect(
        transport.requests.whereType<http.Request>().where(
          (request) => request.url.path.contains('/rpc/'),
        ),
        isEmpty,
      );

      await controller.saveEvent(
        existing: existing,
        draft: EventDraft(
          title: existing.title,
          note: existing.note,
          startAt: existing.startAt,
          endAt: existing.endAt,
          timezone: existing.timezone,
          colorValue: existing.colorValue,
          memberIds: const <String>['creator-remote', 'user-1'],
          recurrence: rule,
        ),
      );

      final rpcPaths = transport.requests
          .whereType<http.Request>()
          .map((request) => request.url.path)
          .toList(growable: false);
      expect(
        rpcPaths,
        contains('/rest/v1/rpc/replace_recurring_event_members_if_version'),
      );
      expect(
        rpcPaths,
        isNot(
          contains('/rest/v1/rpc/update_event_occurrence_scope_if_version'),
        ),
      );
      final replaceRequest = transport.requests
          .whereType<http.Request>()
          .firstWhere(
            (request) => request.url.path.contains(
              '/rpc/replace_recurring_event_members_if_version',
            ),
          );
      final body = jsonDecode(replaceRequest.body) as Map<String, dynamic>;
      expect(body['p_event_id'], 'event-remote');
      expect(body['p_expected_version'], 2);
      expect(body['p_occurrence_key'], occurrenceKeyForIndex(0));
      expect(body['p_member_ids'], <Object?>['creator-remote', 'user-1']);
    },
  );

  test('selectGroup starts events when member metadata fails', () async {
    final repository = _MemberFailureRepository();
    final auth = _CurrentAuth();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    controller.user = _user;
    controller.groups = const <PlannerGroup>[_group];

    await controller.selectGroup(_group.id);
    await Future<void>.delayed(Duration.zero);

    expect(repository.watchStarted, isTrue);
    expect(controller.isOffline, isFalse);
    expect(controller.selectedGroup?.id, _group.id);
    expect(controller.errorMessage, '잠시 후 다시 시도해 주세요.');
  });

  testWidgets('editor renders a save error and stays on the form', (
    tester,
  ) async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    // Inject the controller directly so this widget test exercises the form
    // without depending on provider-created bootstrap timing.
    controller.user = _user;
    controller.isLoading = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: EventEditorScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextFormField).first, 'Not saved');
    final saveButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '저장'),
    );
    saveButton.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();

    expect(find.text('일정을 저장하려면 로그인하고 그룹을 선택해 주세요.'), findsOneWidget);
    expect(find.text('새 일정'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'editor round-trips legacy all-day dates without extending the end date',
    (tester) async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth(currentUser: null);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(auth.dispose);
      controller.user = _user;
      controller.selectedGroup = _group;
      final existing = PlannerEvent(
        id: 'legacy-all-day',
        groupId: _group.id,
        title: 'Legacy all-day',
        startAt: DateTime.utc(2026, 8, 10),
        endAt: DateTime.utc(2026, 8, 13),
        allDay: true,
        ownerId: _user.id,
        timezone: 'UTC',
      );
      controller.events = <PlannerEvent>[existing];

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: EventEditorScreen(eventId: 'legacy-all-day'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final updated = repository.updated;
      expect(updated, isNotNull);
      expect(updated!.allDay, isTrue);
      expect(updated.startAt, existing.startAt);
      expect(updated.endAt, existing.endAt);
      expect(updated.allDayStartDate, DateTime(2026, 8, 10));
      expect(updated.allDayEndDate, DateTime(2026, 8, 13));
    },
  );

  testWidgets('editor preserves all existing event member assignments', (
    tester,
  ) async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    controller.user = _user;
    controller.selectedGroup = _group;
    final existing = PlannerEvent(
      id: 'multi-member-event',
      groupId: _group.id,
      title: 'Shared event',
      startAt: DateTime.utc(2026, 8, 10, 16),
      endAt: DateTime.utc(2026, 8, 10, 17),
      ownerId: _user.id,
      memberIds: const <String>['user-1', 'member-a', 'member-b'],
      timezone: 'UTC',
    );
    controller.events = <PlannerEvent>[existing];

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: EventEditorScreen(eventId: 'multi-member-event'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.updated?.memberIds, existing.memberIds);
  });

  testWidgets(
    'non-owner events open read-only without save or delete actions',
    (tester) async {
      final repository = LocalScheduleRepository();
      final auth = _CurrentAuth(currentUser: null);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(auth.dispose);
      controller.user = _user;
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'other-event',
          groupId: _group.id,
          title: 'Other member event',
          startAt: DateTime.utc(2026, 8, 14, 16),
          endAt: DateTime.utc(2026, 8, 14, 17),
          ownerId: 'other-user',
          timezone: _group.timezone,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: EventEditorScreen(eventId: 'other-event'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('일정 보기'), findsOneWidget);
      expect(find.byTooltip('삭제'), findsNothing);
      expect(find.text('저장'), findsNothing);
      expect(find.text('일정 저장하기'), findsNothing);
      expect(find.text('이 일정은 작성자만 수정할 수 있어요.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        isTrue,
      );
    },
  );

  testWidgets('event color choices expose distinct Korean semantics labels', (
    tester,
  ) async {
    final repository = LocalScheduleRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    controller.user = _user;
    controller.selectedGroup = _group;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: EventEditorScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    for (final label in <String>[
      '청록색 일정 색상',
      '산호색 일정 색상',
      '보라색 일정 색상',
      '파란색 일정 색상',
      '황금색 일정 색상',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      expect(
        tester.getSize(find.bySemanticsLabel(label)),
        const Size(48, 48),
        reason: '$label must meet the minimum touch target',
      );
    }
    semantics.dispose();
  });
}
