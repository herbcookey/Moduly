// Focused model/repository/controller coverage for event participant
// assignments.  The database migration has its own static/integration tests;
// this file stays entirely on the Dart adapter and state boundaries.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _demo = PlannerUser(id: 'demo-user', email: 'demo@example.com');

final _eventStart = DateTime.utc(2026, 9, 7, 9);
final _eventEnd = DateTime.utc(2026, 9, 7, 10);

EventDraft _draft({Iterable<String> memberIds = const <String>[]}) =>
    EventDraft(
      title: 'Planning',
      startAt: _eventStart,
      endAt: _eventEnd,
      memberIds: memberIds.toList(growable: false),
    );

class _NoAuth extends AuthRepository {
  _NoAuth(this._user) : super();

  final PlannerUser? _user;

  @override
  PlannerUser? get currentUser => _user;
}

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

class _AuthenticatedSupabaseScheduleRepository
    extends SupabaseScheduleRepository {
  _AuthenticatedSupabaseScheduleRepository(super.client, this._userId);

  final String? _userId;

  @override
  String? get currentSessionUserId => _userId;
}

Map<String, dynamic> _eventRow({
  String id = 'event-1',
  String groupId = 'group-1',
  String ownerId = 'owner-1',
  Object? version = 2,
  Object? memberIds = const <String>['owner-1', 'member-1'],
}) => <String, dynamic>{
  'id': id,
  'group_id': groupId,
  'created_by': ownerId,
  'title': 'Planning',
  'description': 'Details',
  'starts_at': '2026-09-07T09:00:00.000Z',
  'ends_at': '2026-09-07T10:00:00.000Z',
  'timezone': 'UTC',
  'is_all_day': false,
  'all_day_start': null,
  'all_day_end': null,
  'version': version,
  'deleted_at': null,
  'created_at': '2026-09-07T08:00:00.000Z',
  'updated_at': '2026-09-07T09:00:00.000Z',
  'color_value': 0xff476a6f,
  'member_ids': memberIds,
};

void main() {
  group('event member model', () {
    test('canonicalizes, snapshots, and compares member IDs', () {
      final source = <String>[' member-a ', 'member-a', 'member-b'];
      final event = PlannerEvent(
        id: 'event-1',
        groupId: 'group-1',
        title: 'Event',
        startAt: _eventStart,
        endAt: _eventEnd,
        ownerId: 'owner-1',
        memberIds: source,
      );
      source.add('member-c');

      expect(event.memberIds, <String>['member-a', 'member-b']);
      expect(() => event.memberIds.add('member-c'), throwsUnsupportedError);
      expect(event.copyWith(), equals(event));
      expect(
        event.copyWith(memberIds: const <String>['member-b']),
        isNot(equals(event)),
      );

      final draft = _draft(memberIds: source);
      source.clear();
      expect(draft.memberIds, <String>['member-a', 'member-b', 'member-c']);
      expect(() => draft.memberIds.add('member-d'), throwsUnsupportedError);

      final omitted = EventDraft(
        title: 'Omitted',
        startAt: _eventStart,
        endAt: _eventEnd,
      );
      final explicitEmpty = EventDraft(
        title: 'Explicit empty',
        startAt: _eventStart,
        endAt: _eventEnd,
        memberIds: const <String>[],
      );
      expect(omitted.memberIds, isEmpty);
      expect(omitted.hasExplicitMemberIds, isFalse);
      expect(explicitEmpty.memberIds, isEmpty);
      expect(explicitEmpty.hasExplicitMemberIds, isTrue);
      expect(omitted, isNot(equals(explicitEmpty)));
      expect(omitted.copyWith(), equals(omitted));
      expect(
        omitted.copyWith(memberIds: const <String>[]).hasExplicitMemberIds,
        isTrue,
      );
    });

    test(
      'rejects blank member IDs instead of silently accepting malformed state',
      () {
        expect(
          () => PlannerEvent(
            id: 'event-1',
            groupId: 'group-1',
            title: 'Event',
            startAt: _eventStart,
            endAt: _eventEnd,
            ownerId: 'owner-1',
            memberIds: const <String>[' '],
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('local event member assignment', () {
    late LocalScheduleRepository repository;

    setUp(() {
      repository = LocalScheduleRepository(
        seedMembers: <PlannerMember>[
          const PlannerMember(
            id: 'member-extra',
            name: 'Extra',
            email: 'extra@example.com',
          ),
        ],
      );
    });

    test(
      'create defaults creator and round-trips an explicit active list',
      () async {
        final omitted = EventDraft(
          title: 'Omitted',
          startAt: _eventStart,
          endAt: _eventEnd,
        );
        final defaulted = await repository.createEvent(
          _demo.id,
          'demo-group',
          omitted,
        );
        expect(defaulted.memberIds, <String>[_demo.id]);

        final explicitEmpty = await repository.createEvent(
          _demo.id,
          'demo-group',
          EventDraft(
            title: 'Unassigned',
            startAt: _eventStart,
            endAt: _eventEnd,
            memberIds: const <String>[],
          ),
        );
        expect(explicitEmpty.memberIds, isEmpty);

        final explicit = await repository.createEvent(
          _demo.id,
          'demo-group',
          _draft(memberIds: <String>['member-extra', _demo.id, 'member-extra']),
        );
        expect(explicit.memberIds, <String>[_demo.id, 'member-extra']);
      },
    );

    test(
      'creator and group owner can replace; ordinary participant cannot',
      () async {
        final creator = await repository.joinGroup('member-extra', 'family');
        expect(creator.id, 'demo-group');
        final event = await repository.createEvent(
          'member-extra',
          'demo-group',
          _draft(memberIds: const <String>['member-extra']),
        );

        final bodyUpdated = await repository.updateEvent(
          event.copyWith(title: 'Creator edit'),
          expectedVersion: event.version,
          actorId: 'member-extra',
        );
        expect(bodyUpdated.title, 'Creator edit');
        await expectLater(
          repository.updateEvent(
            bodyUpdated.copyWith(title: 'Owner body edit'),
            expectedVersion: bodyUpdated.version,
            actorId: _demo.id,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );

        final cleared = await repository.replaceEventMembers(
          event.id,
          memberIds: const <String>[],
          expectedVersion: bodyUpdated.version,
          actorId: 'member-extra',
        );
        expect(cleared.memberIds, isEmpty);
        expect(cleared.version, bodyUpdated.version + 1);

        final ownerUpdated = await repository.replaceEventMembers(
          event.id,
          memberIds: const <String>['member-extra'],
          expectedVersion: cleared.version,
          actorId: _demo.id,
        );
        expect(ownerUpdated.memberIds, <String>['member-extra']);

        final noOp = await repository.replaceEventMembers(
          event.id,
          memberIds: const <String>['member-extra'],
          expectedVersion: ownerUpdated.version,
          actorId: _demo.id,
        );
        expect(noOp.version, ownerUpdated.version);

        await expectLater(
          repository.replaceEventMembers(
            event.id,
            memberIds: const <String>[],
            expectedVersion: ownerUpdated.version,
            actorId: 'member-jin',
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        await expectLater(
          repository.replaceEventMembers(
            event.id,
            memberIds: const <String>[],
            expectedVersion: event.version,
            actorId: _demo.id,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
      },
    );

    test(
      'rejects inactive targets and prunes assignments without restoring on rejoin',
      () async {
        final event = await repository.createEvent(
          _demo.id,
          'demo-group',
          _draft(memberIds: const <String>['member-extra']),
        );
        await repository.setMemberActive(
          'demo-group',
          'member-extra',
          false,
          actorId: _demo.id,
        );

        final afterDeactivate = await repository
            .watchEvents('demo-group')
            .first;
        final pruned = afterDeactivate.singleWhere(
          (item) => item.id == event.id,
        );
        expect(pruned.memberIds, isEmpty);
        expect(pruned.version, event.version + 1);

        await expectLater(
          repository.replaceEventMembers(
            event.id,
            memberIds: const <String>['member-extra'],
            expectedVersion: pruned.version,
            actorId: _demo.id,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
        await repository.joinGroup('member-extra', 'family');
        final afterRejoin = await repository.watchEvents('demo-group').first;
        expect(
          afterRejoin.singleWhere((item) => item.id == event.id).memberIds,
          isEmpty,
        );
      },
    );

    test(
      'deactivation prunes active events but preserves deleted history versions',
      () async {
        final active = await repository.createEvent(
          _demo.id,
          'demo-group',
          _draft(memberIds: const <String>['member-extra']),
        );
        final deleted = await repository.createEvent(
          _demo.id,
          'demo-group',
          _draft(memberIds: const <String>['member-extra']),
        );
        await repository.softDeleteEvent(
          deleted.id,
          expectedVersion: deleted.version,
          actorId: _demo.id,
        );
        final deletedVersion = deleted.version + 1;

        await repository.setMemberActive(
          'demo-group',
          'member-extra',
          false,
          actorId: _demo.id,
        );

        final visible = await repository.watchEvents('demo-group').first;
        final prunedActive = visible.singleWhere(
          (item) => item.id == active.id,
        );
        expect(prunedActive.memberIds, isEmpty);
        expect(prunedActive.version, active.version + 1);

        // A second delete at the version immediately after the original
        // delete still succeeds. If pruning touched the historical row it
        // would have advanced this version and incorrectly conflict here.
        await expectLater(
          repository.softDeleteEvent(
            deleted.id,
            expectedVersion: deletedVersion,
            actorId: _demo.id,
          ),
          completes,
        );
      },
    );
  });

  group('Supabase event member RPCs', () {
    test(
      'create/update/replace use exact RPC contracts and round-trip IDs',
      () async {
        final transport = _RpcTransport(<Object?>[_eventRow()]);
        final client = _client(transport);
        final repository = SupabaseScheduleRepository(client);
        addTearDown(client.dispose);

        final created = await repository.createEvent(
          'owner-1',
          'group-1',
          _draft(memberIds: const <String>['member-1', 'owner-1']),
        );
        expect(created.memberIds, <String>['member-1', 'owner-1']);
        final createRequest = transport.requests.single;
        final createBody =
            jsonDecode((createRequest as http.Request).body) as Map;
        expect(
          createRequest.url.path,
          contains('/rpc/create_event_with_members'),
        );
        expect(createBody.keys, isNot(contains('actorId')));
        expect(createBody['p_member_ids'], <Object?>['member-1', 'owner-1']);

        transport.payload = <Object?>[_eventRow(version: 3)];
        final updated = await repository.updateEvent(
          created,
          expectedVersion: 2,
          actorId: 'owner-1',
        );
        expect(updated.version, 3);
        expect(updated.memberIds, <String>['member-1', 'owner-1']);
        expect(
          transport.requests.last.url.path,
          contains('/rpc/update_event_with_members_if_version'),
        );

        transport.payload = <Object?>[
          _eventRow(version: 4, memberIds: const <String>[]),
        ];
        final replaced = await repository.replaceEventMembers(
          created.id,
          memberIds: const <String>[],
          expectedVersion: 3,
          actorId: 'owner-1',
        );
        expect(replaced.memberIds, isEmpty);
        expect(replaced.version, 4);
        final replaceBody =
            jsonDecode((transport.requests.last as http.Request).body) as Map;
        expect(replaceBody['p_member_ids'], isEmpty);
        expect(replaceBody.keys, isNot(contains('p_actor_id')));

        transport.payload = <Object?>[
          _eventRow(version: 4, memberIds: const <String>[]),
        ];
        final noOp = await repository.replaceEventMembers(
          created.id,
          memberIds: const <String>[],
          expectedVersion: 4,
          actorId: 'owner-1',
        );
        expect(noOp.version, 4);
      },
    );

    test(
      'recurring replacement uses dedicated RPC, creator guard, and strict receipts',
      () async {
        final receipt = <String, dynamic>{
          'group_id': 'group-1',
          'event_id': 'event-series',
          'occurrence_key': occurrenceKeyForIndex(2),
          'series_version': 3,
          'occurrence_version': 0,
          'scope': 'all',
          'committed': true,
          'changed': true,
        };
        final transport = _RpcTransport(receipt);
        final client = _client(transport);
        final repository = _AuthenticatedSupabaseScheduleRepository(
          client,
          'group-owner',
        );
        addTearDown(client.dispose);
        final event = PlannerEvent(
          id: 'event-series',
          seriesId: 'event-series',
          groupId: 'group-1',
          title: 'Series',
          startAt: _eventStart,
          endAt: _eventEnd,
          ownerId: 'creator-1',
          memberIds: const <String>['creator-1'],
          timezone: 'UTC',
          version: 2,
          occurrenceKey: occurrenceKeyForIndex(2),
          occurrenceIndex: 2,
          occurrenceVersion: 1,
          isOccurrence: true,
          recurrenceRule: RecurrenceRule(frequency: RecurrenceFrequency.daily),
        );

        await expectLater(
          repository.replaceRecurringEventMembers(
            event: event,
            memberIds: const <String>[],
            expectedVersion: event.version,
            actorId: 'group-owner',
          ),
          throwsA(isA<ScheduleValidationException>()),
        );
        expect(transport.requests, isEmpty);

        final changed = await repository.replaceRecurringEventMembers(
          event: event,
          memberIds: const <String>['member-2', 'creator-1', 'member-2'],
          expectedVersion: event.version,
          actorId: 'group-owner',
        );
        expect(changed.groupId, 'group-1');
        expect(changed.eventId, event.id);
        expect(changed.occurrenceKey, event.occurrenceKey);
        expect(changed.seriesVersion, 3);
        expect(changed.occurrenceVersion, 0);
        expect(changed.scope, EventEditScope.all);
        expect(changed.changed, isTrue);
        final request =
            transport.requests.singleWhere(
                  (item) =>
                      item is http.Request && item.url.path.contains('/rpc/'),
                )
                as http.Request;
        expect(
          request.url.path,
          contains('/rpc/replace_recurring_event_members_if_version'),
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['p_event_id'], event.id);
        expect(body['p_expected_version'], event.version);
        expect(body['p_occurrence_key'], event.occurrenceKey);
        expect(body['p_member_ids'], <Object?>['creator-1', 'member-2']);

        transport.payload = <String, dynamic>{
          ...receipt,
          'series_version': 3,
          'changed': false,
        };
        final noOp = await repository.replaceRecurringEventMembers(
          event: event,
          memberIds: const <String>['creator-1'],
          expectedVersion: 3,
          actorId: 'group-owner',
        );
        expect(noOp.changed, isFalse);
        expect(noOp.seriesVersion, 3);
        expect(noOp.occurrenceVersion, 0);

        transport.payload = <String, dynamic>{
          ...receipt,
          'occurrence_key': occurrenceKeyForIndex(1),
          'series_version': 3,
          'changed': false,
        };
        await expectLater(
          repository.replaceRecurringEventMembers(
            event: event,
            memberIds: const <String>['creator-1'],
            expectedVersion: 3,
            actorId: 'group-owner',
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
      },
    );

    test(
      'create preserves omitted versus explicit empty member assignments',
      () async {
        final transport = _RpcTransport(<Object?>[
          _eventRow(memberIds: const <String>['owner-1']),
        ]);
        final client = _client(transport);
        final repository = SupabaseScheduleRepository(client);
        addTearDown(client.dispose);

        final omitted = await repository.createEvent(
          'owner-1',
          'group-1',
          EventDraft(
            title: 'Default creator',
            startAt: _eventStart,
            endAt: _eventEnd,
          ),
        );
        expect(omitted.memberIds, <String>['owner-1']);
        final omittedBody =
            jsonDecode((transport.requests.single as http.Request).body) as Map;
        expect(omittedBody['p_member_ids'], isNull);

        transport.payload = <Object?>[_eventRow(memberIds: const <String>[])];
        final explicitEmpty = await repository.createEvent(
          'owner-1',
          'group-1',
          EventDraft(
            title: 'Unassigned',
            startAt: _eventStart,
            endAt: _eventEnd,
            memberIds: const <String>[],
          ),
        );
        expect(explicitEmpty.memberIds, isEmpty);
        final explicitBody =
            jsonDecode((transport.requests.last as http.Request).body) as Map;
        expect(explicitBody['p_member_ids'], isEmpty);
      },
    );

    test('rejects malformed or fractional RPC versions', () async {
      final transport = _RpcTransport(<Object?>[_eventRow(version: 2.5)]);
      final client = _client(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.replaceEventMembers(
          'event-1',
          memberIds: const <String>[],
          expectedVersion: 1,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('rejects a capable create response with missing member_ids', () async {
      final transport = _RpcTransport(<Object?>[_eventRow(memberIds: null)]);
      final client = _client(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.createEvent(
          'owner-1',
          'group-1',
          EventDraft(
            title: 'Malformed',
            startAt: _eventStart,
            endAt: _eventEnd,
            memberIds: const <String>[],
          ),
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });
  });

  test(
    'controller exposes participant-only authorization and member filtering',
    () async {
      final repository = LocalScheduleRepository();
      final auth = _NoAuth(_demo);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.user = _demo;
      controller.selectedGroup = const PlannerGroup(
        id: 'demo-group',
        name: '우리 가족',
        ownerId: 'demo-user',
      );
      controller.members = await repository.membersForGroup('demo-group');
      final event = await repository.createEvent(
        'member-jin',
        'demo-group',
        _draft(memberIds: const <String>['member-jin']),
      );
      // Keep this projection test deterministic when the wall clock rolls
      // past the fixture date (the fixture intentionally uses a fixed UTC
      // day rather than DateTime.now()). Assign the public field directly so
      // a bounded local adapter does not start an unrelated range fetch.
      controller.selectedDay = _eventStart;
      controller.events = <PlannerEvent>[event];

      expect(controller.canEditEventParticipants(event), isTrue);
      controller.setMemberFilter('member-jin');
      expect(controller.visibleEvents.single.id, event.id);
      controller.setMemberFilter('demo-user');
      expect(controller.visibleEvents, isEmpty);
      await expectLater(
        controller.saveEvent(existing: event, draft: _draft()),
        throwsA(isA<ScheduleConflictException>()),
      );

      await controller.saveEvent(
        draft: EventDraft(
          title: 'Controller default',
          startAt: _eventStart,
          endAt: _eventEnd,
        ),
      );
      expect(
        controller.events
            .firstWhere((item) => item.title == 'Controller default')
            .memberIds,
        <String>[_demo.id],
      );

      await controller.saveEvent(
        draft: EventDraft(
          title: 'Controller empty',
          startAt: _eventStart,
          endAt: _eventEnd,
          memberIds: const <String>[],
        ),
      );
      expect(
        controller.events
            .firstWhere((item) => item.title == 'Controller empty')
            .memberIds,
        isEmpty,
      );

      await controller.replaceEventMembers(event, const <String>['member-soo']);
      expect(
        controller.events.firstWhere((item) => item.id == event.id).memberIds,
        <String>['member-soo'],
      );
    },
  );
}
