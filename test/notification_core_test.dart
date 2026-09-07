// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/core/notification_identity.dart';
import 'package:moduly/core/reminder_planner.dart';
import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/models/notification_models.dart';
import 'package:moduly/repositories/notification_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/notification_state.dart';

const _user = 'user-a';
const _eventUuid = '550e8400-e29b-41d4-a716-446655440000';
const _otherEventUuid = '550e8400-e29b-41d4-a716-446655440001';
const _groupUuid = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';

PlannerEvent _event({
  required String id,
  required DateTime startAt,
  required DateTime endAt,
  String groupId = 'group-a',
  String ownerId = _user,
  List<String> memberIds = const <String>[_user],
  String timezone = 'UTC',
  bool allDay = false,
  DateTime? allDayStartDate,
  DateTime? allDayEndDate,
  String? seriesId,
  String occurrenceKey = 'single',
  int occurrenceIndex = 0,
}) => PlannerEvent(
  id: id,
  groupId: groupId,
  title: id,
  startAt: startAt,
  endAt: endAt,
  ownerId: ownerId,
  memberIds: memberIds,
  timezone: timezone,
  allDay: allDay,
  allDayStartDate: allDayStartDate,
  allDayEndDate: allDayEndDate,
  seriesId: seriesId,
  occurrenceKey: occurrenceKey,
  occurrenceIndex: occurrenceIndex,
);

EventNotificationPreference _preference({
  String eventId = 'event-a',
  int timedLeadSeconds = 900,
  int allDayDaysBefore = 0,
  NotificationChannel channel = NotificationChannel.local,
}) => EventNotificationPreference(
  id: 'setting-$eventId',
  userId: _user,
  eventId: eventId,
  channel: channel,
  enabled: true,
  timedLeadSeconds: timedLeadSeconds,
  allDayDaysBefore: allDayDaysBefore,
  version: 1,
);

ReminderCandidate _candidate({
  required DateTime fireAt,
  String eventId = _eventUuid,
  String groupId = _groupUuid,
  String occurrenceKey = 'single',
  int occurrenceIndex = 0,
}) {
  final startsAt = fireAt.add(const Duration(minutes: 15));
  return ReminderCandidate(
    eventId: eventId,
    groupId: groupId,
    occurrenceKey: occurrenceKey,
    occurrenceIndex: occurrenceIndex,
    fireAt: fireAt,
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'UTC',
    isAllDay: false,
    title: 'private title',
    settingId: _eventUuid,
    settingVersion: 1,
    eventVersion: 1,
    occurrenceVersion: 0,
  );
}

String _occurrenceKey(int ordinal) => 'o${ordinal.toString().padLeft(20, '0')}';

int _baseIdFor(ReminderIdentity identity) {
  final digest = sha256.convert(utf8.encode(identity.stableKey)).bytes;
  var value = 0;
  for (var index = 0; index < 4; index++) {
    value = (value << 8) | digest[index];
  }
  value &= NotificationIdAllocator.maxPositive31Bit;
  return value == 0 ? 1 : value;
}

class _Registry implements NotificationIdRegistry {
  _Registry(this.entries);

  Map<String, Map<int, String>> entries;
  Object? loadError;
  bool persistentLoadError = false;
  Object? saveError;
  bool persistentSaveError = false;
  Future<void>? saveGate;

  @override
  Future<Map<int, String>> load(String userId) async {
    final error = loadError;
    if (error != null) {
      if (!persistentLoadError) loadError = null;
      throw error;
    }
    return Map<int, String>.from(entries[userId] ?? const <int, String>{});
  }

  @override
  Future<void> save(String userId, Map<int, String> values) async {
    final error = saveError;
    if (error != null) {
      if (!persistentSaveError) saveError = null;
      throw error;
    }
    final gate = saveGate;
    if (gate != null) {
      saveGate = null;
      await gate;
    }
    entries[userId] = Map<int, String>.from(values);
  }
}

class _Scheduler implements LocalNotificationScheduler {
  NotificationPermissionState state = NotificationPermissionState.authorized;
  NotificationCapabilityState capabilityState =
      NotificationCapabilityState.available;
  final List<NotificationScheduleRequest> scheduled =
      <NotificationScheduleRequest>[];
  final List<int> cancelled = <int>[];
  final List<int> pendingOnly = <int>[];
  bool removePendingOnCancel = false;
  Object? cancelError;
  Object? pendingError;

  @override
  NotificationCapabilityState get capability => capabilityState;

  @override
  Future<NotificationPermissionState> permissionStatus() async => state;

  @override
  Future<NotificationPermissionState> requestPermission() async => state;

  @override
  Future<void> schedule(NotificationScheduleRequest request) async {
    scheduled.removeWhere(
      (value) => value.notificationId == request.notificationId,
    );
    scheduled.add(request);
  }

  @override
  Future<void> cancel(Iterable<int> notificationIds) async {
    final error = cancelError;
    if (error != null) throw error;
    final ids = notificationIds.toSet();
    cancelled.addAll(ids);
    if (removePendingOnCancel) {
      pendingOnly.removeWhere(ids.contains);
      scheduled.removeWhere((request) => ids.contains(request.notificationId));
    }
  }

  @override
  Future<List<int>> pendingNotificationIds() async {
    final error = pendingError;
    if (error != null) throw error;
    return <int>{
      ...scheduled.map((value) => value.notificationId),
      ...pendingOnly,
    }.toList(growable: false);
  }
}

class _Repository implements NotificationRepository {
  _Repository({required this.pages, this.candidateGate});

  UserNotificationSettings settings = const UserNotificationSettings(
    userId: _user,
    enabled: true,
    localEnabled: true,
  );
  final List<EventNotificationPreference> preferences =
      <EventNotificationPreference>[];
  Future<UserNotificationSettings>? settingsGate;
  Future<List<EventNotificationPreference>>? userPreferencesGate;
  List<EventNotificationPreference>? userPreferenceSnapshot;
  List<EventNotificationPreference>? eventPreferenceSnapshot;
  Future<List<EventNotificationPreference>>? eventPreferenceGate;
  Object? eventPreferenceError;
  int eventPreferenceCalls = 0;
  final List<ReminderCandidatePage> pages;
  Future<void>? candidateGate;
  Object? candidateError;
  int candidateCalls = 0;

  @override
  NotificationCapabilityState get capability =>
      NotificationCapabilityState.available;

  @override
  Future<UserNotificationSettings> settingsForUser(String userId) async {
    final gate = settingsGate;
    if (gate != null) {
      settingsGate = null;
      return gate;
    }
    return settings.copyWith(userId: userId);
  }

  @override
  Future<UserNotificationSettings> saveSettings(
    UserNotificationSettings value, {
    int? expectedVersion,
  }) async {
    settings = value.copyWith(version: value.version + 1);
    return settings;
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForUser(
    String userId,
  ) async {
    final gate = userPreferencesGate;
    if (gate != null) {
      userPreferencesGate = null;
      return gate;
    }
    return List<EventNotificationPreference>.unmodifiable(
      userPreferenceSnapshot ?? preferences,
    );
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async {
    eventPreferenceCalls++;
    final gate = eventPreferenceGate;
    if (gate != null) {
      eventPreferenceGate = null;
      return gate;
    }
    final error = eventPreferenceError;
    if (error != null) throw error;
    final snapshot = eventPreferenceSnapshot;
    if (snapshot != null) {
      return List<EventNotificationPreference>.from(snapshot);
    }
    return preferences
        .where((item) => item.userId == userId && item.eventId == eventId)
        .toList(growable: false);
  }

  @override
  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference value, {
    int? expectedVersion,
  }) async {
    preferences.removeWhere(
      (item) => item.eventId == value.eventId && item.channel == value.channel,
    );
    preferences.add(value);
    return value;
  }

  @override
  Future<void> deleteEventPreference({
    required String userId,
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  }) async {
    preferences.removeWhere(
      (item) => item.eventId == eventId && item.channel == channel,
    );
  }

  @override
  Future<ReminderCandidatePage> reminderCandidatesForUser({
    required String userId,
    required DateTime fireAtStart,
    required DateTime fireAtEnd,
    ReminderCandidateCursor? cursor,
    int limit = reminderPageLimit,
  }) async {
    candidateCalls++;
    final gate = candidateGate;
    candidateGate = null;
    if (gate != null) await gate;
    final error = candidateError;
    if (error != null) throw error;
    return pages.isEmpty ? ReminderCandidatePage.empty() : pages.removeAt(0);
  }
}

class _RpcTransport extends http.BaseClient {
  _RpcTransport(this.rpcPayload);

  final Object? rpcPayload;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final payload = request.url.path.endsWith('/auth/v1/user')
        ? <String, dynamic>{
            'id': _user,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': 'user@example.com',
            'created_at': '2030-01-01T00:00:00.000Z',
          }
        : rpcPayload;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
      request: request,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

String _testJwt() {
  String segment(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${segment(<String, Object>{'alg': 'none', 'typ': 'JWT'})}.${segment(<String, Object>{'sub': _user, 'exp': now + 3600, 'iat': now})}.sig';
}

Future<({SupabaseClient client, _RpcTransport transport})> _authenticatedClient(
  Object? payload,
) async {
  final transport = _RpcTransport(payload);
  final client = SupabaseClient(
    'https://example.supabase.co',
    'sb_publishable_test',
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      authFlowType: AuthFlowType.implicit,
    ),
    httpClient: transport,
  );
  await client.auth.setSession('refresh-token', accessToken: _testJwt());
  return (client: client, transport: transport);
}

void main() {
  group('notification identity and strict wire models', () {
    test(
      'SHA-256 IDs are positive, framed, persistent, and probe collisions',
      () async {
        final first = ReminderIdentity(
          userId: _user,
          eventId: 'ab',
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final second = ReminderIdentity(
          userId: _user,
          eventId: 'a',
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        expect(first.framedKey, isNot(second.framedKey));
        final digest = sha256.convert(utf8.encode(first.stableKey)).bytes;
        var base = 0;
        for (final byte in digest.take(4)) {
          base = (base << 8) | byte;
        }
        base &= NotificationIdAllocator.maxPositive31Bit;
        if (base == 0) base = 1;
        final registry = _Registry(<String, Map<int, String>>{
          _user: <int, String>{base: 'occupied'},
        });
        final allocator = NotificationIdAllocator(
          registry: registry,
          maxProbe: 4,
        );
        final id = await allocator.idFor(first);
        expect(
          id,
          ((base - 1 + 1) % NotificationIdAllocator.maxPositive31Bit) + 1,
        );
        expect(
          id,
          inInclusiveRange(1, NotificationIdAllocator.maxPositive31Bit),
        );
        expect(await allocator.idFor(first), id);
        final reloaded = NotificationIdAllocator(
          registry: registry,
          maxProbe: 4,
        );
        expect(await reloaded.idFor(first), id);
        expect(await reloaded.idFor(second), isNot(id));
        final otherUser = ReminderIdentity(
          userId: 'user-b',
          eventId: first.eventId,
          occurrenceKey: first.occurrenceKey,
          offsetValue: first.offsetValue,
          offsetUnit: first.offsetUnit,
          channel: first.channel,
        );
        final otherId = await reloaded.idFor(otherUser);
        expect(
          otherId,
          inInclusiveRange(1, NotificationIdAllocator.maxPositive31Bit),
        );
        expect(
          (await reloaded.entriesFor('user-b')).map((entry) => entry.id),
          contains(otherId),
        );
        expect(
          (await reloaded.entriesFor(_user)).map((entry) => entry.id),
          isNot(contains(otherId)),
        );
      },
    );

    test(
      'cursor and payload parsers reject unknown keys and malformed tuples',
      () {
        final cursor = ReminderCandidateCursor(
          fireAt: DateTime.utc(2030, 1, 1, 9),
          eventId: _eventUuid,
          occurrenceKey: 'single',
          channel: NotificationChannel.local,
        );
        final decoded = ReminderCandidateCursor.decode(cursor.encode());
        expect(decoded.fireAt, cursor.fireAt);
        expect(decoded.eventId, cursor.eventId);
        expect(decoded.occurrenceKey, cursor.occurrenceKey);
        expect(decoded.channel, cursor.channel);

        final cursorJson = <String, Object?>{
          'v': 1,
          'fire_at': cursor.fireAt.toIso8601String(),
          'event_id': cursor.eventId,
          'occurrence_key': cursor.occurrenceKey,
          'channel': 'local',
          'extra': false,
        };
        final malformedCursor = base64Url
            .encode(utf8.encode(jsonEncode(cursorJson)))
            .replaceAll('=', '');
        expect(
          () => ReminderCandidateCursor.decode(malformedCursor),
          throwsFormatException,
        );

        final payload = const NotificationPayload(
          eventId: _eventUuid,
          groupId: _groupUuid,
          occurrenceKey: 'o00000000000000000001',
        );
        final roundTrip = NotificationPayload.decode(payload.encode());
        expect(roundTrip.eventId, payload.eventId);
        expect(roundTrip.groupId, payload.groupId);
        expect(roundTrip.occurrenceKey, payload.occurrenceKey);
        expect(
          () => NotificationPayload.fromJson(<String, Object?>{
            ...payload.toJson(),
            'title': 'must not be trusted',
          }),
          throwsFormatException,
        );
        expect(
          () => NotificationPayload.fromJson(
            const NotificationPayload(
              eventId: 'event-1',
              occurrenceKey: 'single',
            ).toJson(),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'allocator save failure rolls back cache and a retry persists across reload',
      () async {
        final identity = ReminderIdentity(
          userId: _user,
          eventId: 'rollback-event',
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final registry = _Registry(<String, Map<int, String>>{})
          ..saveError = StateError('registry unavailable');
        final allocator = NotificationIdAllocator(registry: registry);

        await expectLater(
          allocator.idFor(identity),
          throwsA(isA<StateError>()),
        );
        expect(await allocator.entriesFor(_user), isEmpty);
        expect(registry.entries[_user], isNull);

        final id = await allocator.idFor(identity);
        final reloaded = NotificationIdAllocator(registry: registry);
        expect(await reloaded.idFor(identity), id);
        expect(await reloaded.entriesFor(_user), hasLength(1));
      },
    );

    test(
      'concurrent colliding allocations remain unique and durable',
      () async {
        final first = ReminderIdentity(
          userId: _user,
          eventId: 'collision-27513',
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final second = ReminderIdentity(
          userId: _user,
          eventId: 'collision-37040',
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        expect(_baseIdFor(first), _baseIdFor(second));
        final registry = _Registry(<String, Map<int, String>>{});
        final gate = Completer<void>();
        registry.saveGate = gate.future;
        final allocator = NotificationIdAllocator(registry: registry);
        final firstId = allocator.idFor(first);
        final secondId = allocator.idFor(second);
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        final ids = await Future.wait(<Future<int>>[firstId, secondId]);

        expect(ids.toSet(), hasLength(2));
        expect(await allocator.entriesFor(_user), hasLength(2));
        final reloaded = NotificationIdAllocator(registry: registry);
        expect(await reloaded.idFor(first), ids[0]);
        expect(await reloaded.idFor(second), ids[1]);
      },
    );

    test(
      'event preference snapshots round-trip their optional event version',
      () {
        final preference = _preference(eventId: 'series-a');
        final roundTrip = EventNotificationPreference.fromJson(
          preference.toJson(),
        );
        expect(roundTrip, preference);
        final publicRow = Map<String, Object?>.from(preference.toJson())
          ..remove('event_version');
        expect(EventNotificationPreference.fromJson(publicRow).eventVersion, 1);
        expect(
          () => EventNotificationPreference.fromJson({
            ...publicRow,
            'unexpected': true,
          }),
          throwsFormatException,
        );
      },
    );
  });

  group('Supabase notification RPC boundary', () {
    test(
      'settings RPC uses the actor session and exact response shape',
      () async {
        final harness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': false,
          'version': 2,
          'local_enabled': true,
          'push_enabled': false,
          'capability_local': 'client_local_scheduler',
          'capability_push': 'disabled',
        });
        final repository = SupabaseNotificationRepository(harness.client);
        final settings = await repository.settingsForUser(_user);
        expect(settings.userId, _user);
        expect(settings.localDesired, isTrue);
        expect(settings.pushEnabled, isFalse);
        final rpc = harness.transport.requests.last;
        expect(
          rpc.url.path,
          endsWith('/rest/v1/rpc/get_notification_preferences'),
        );
        expect(rpc.method, 'POST');
      },
    );

    test(
      'set settings serializes expected version and rejects stale receipts',
      () async {
        final harness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': true,
          'version': 5,
          'local_enabled': true,
          'push_enabled': false,
          'cancelled_jobs': 0,
          'capability_local': 'client_local_scheduler',
          'capability_push': 'disabled',
        });
        final repository = SupabaseNotificationRepository(harness.client);
        final saved = await repository.saveSettings(
          const UserNotificationSettings(
            userId: _user,
            enabled: true,
            localEnabled: true,
            version: 4,
          ),
          expectedVersion: 4,
        );
        expect(saved.version, 5);
        final rpc = harness.transport.requests.last as http.Request;
        final body = jsonDecode(rpc.body) as Map<String, dynamic>;
        expect(body, <String, dynamic>{
          'p_local_enabled': true,
          'p_push_enabled': false,
          'p_expected_version': 4,
        });

        final stale = await _authenticatedClient(<String, Object?>{
          'committed': false,
          'changed': false,
          'version': 5,
          'local_enabled': true,
          'push_enabled': false,
          'cancelled_jobs': 0,
          'capability_local': 'client_local_scheduler',
          'capability_push': 'disabled',
        });
        final staleRepository = SupabaseNotificationRepository(stale.client);
        await expectLater(
          staleRepository.saveSettings(
            const UserNotificationSettings(
              userId: _user,
              enabled: true,
              localEnabled: true,
              version: 4,
            ),
            expectedVersion: 4,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
      },
    );

    test(
      'set settings preserves push intent when the local master is off',
      () async {
        final harness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': true,
          'version': 5,
          'local_enabled': false,
          'push_enabled': true,
          'cancelled_jobs': 0,
          'capability_local': 'disabled',
          'capability_push': 'push_configured',
        });
        final repository = SupabaseNotificationRepository(harness.client);
        final saved = await repository.saveSettings(
          const UserNotificationSettings(
            userId: _user,
            enabled: false,
            localEnabled: false,
            pushEnabled: true,
            version: 4,
          ),
          expectedVersion: 4,
        );
        expect(saved.localDesired, isFalse);
        expect(saved.pushDesired, isTrue);
        expect(saved.pushEnabled, isTrue);
        final rpc = harness.transport.requests.last as http.Request;
        expect(jsonDecode(rpc.body), <String, dynamic>{
          'p_local_enabled': false,
          'p_push_enabled': true,
          'p_expected_version': 4,
        });
      },
    );

    test('candidate RPC parses strict rows and keyset cursor', () async {
      final fireAt = DateTime.utc(2030, 1, 1, 10);
      final row = _candidate(fireAt: fireAt).toJson();
      final harness = await _authenticatedClient(<String, Object?>{
        'candidates': <Object?>[row],
        'next_cursor': null,
        'has_more': false,
        'capability': 'client_local_scheduler',
      });
      final repository = SupabaseNotificationRepository(harness.client);
      final page = await repository.reminderCandidatesForUser(
        userId: _user,
        fireAtStart: DateTime.utc(2030, 1, 1),
        fireAtEnd: DateTime.utc(2030, 1, 2),
        limit: 10,
      );
      expect(page.candidates.single.fireAt, fireAt);
      final rpc = harness.transport.requests.last as http.Request;
      final body = jsonDecode(rpc.body) as Map<String, dynamic>;
      expect(body['p_limit'], 10);
      expect(body['p_cursor'], isNull);

      final malformed = await _authenticatedClient(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{...row, 'unexpected': true},
        ],
        'next_cursor': null,
        'has_more': false,
        'capability': 'client_local_scheduler',
      });
      final malformedRepository = SupabaseNotificationRepository(
        malformed.client,
      );
      await expectLater(
        malformedRepository.reminderCandidatesForUser(
          userId: _user,
          fireAtStart: DateTime.utc(2030, 1, 1),
          fireAtEnd: DateTime.utc(2030, 1, 2),
          limit: 10,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test(
      'event reminder RPCs consume the exact envelopes and optimistic versions',
      () async {
        final row = <String, Object?>{
          'id': _groupUuid,
          'channel': 'local',
          'enabled': true,
          'lead_seconds': 900,
          'all_day_days_before': 1,
          'all_day_local_time': '09:00:00',
          'version': 3,
          'created_at': '2030-01-01T00:00:00Z',
          'updated_at': '2030-01-01T00:00:00Z',
        };
        final getHarness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': false,
          'event_id': _eventUuid,
          'event_version': 4,
          'settings': <Object?>[row],
          'capabilities': <String, Object?>{
            'local': 'client_local_scheduler',
            'push': 'disabled',
          },
        });
        final getRepository = SupabaseNotificationRepository(getHarness.client);
        final values = await getRepository.preferencesForEvent(
          userId: _user,
          eventId: _eventUuid,
        );
        expect(values.single.eventVersion, 4);
        expect(values.single.version, 3);
        expect(values.single.allDayDaysBefore, 1);
        expect(values.single.updatedAt, DateTime.utc(2030, 1, 1));

        final malformedHarness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': false,
          'event_id': _eventUuid,
          'event_version': 4,
          'settings': <Object?>[],
          'capabilities': <String, Object?>{
            'local': 'client_local_scheduler',
            'push': 'disabled',
          },
          'unexpected': true,
        });
        await expectLater(
          SupabaseNotificationRepository(
            malformedHarness.client,
          ).preferencesForEvent(userId: _user, eventId: _eventUuid),
          throwsA(isA<ScheduleConflictException>()),
        );

        final setHarness = await _authenticatedClient(<String, Object?>{
          'committed': true,
          'changed': true,
          'event_id': _eventUuid,
          'channel': 'local',
          'enabled': false,
          'lead_seconds': 1200,
          'all_day_days_before': 2,
          'all_day_local_time': '09:00:00',
          'setting_version': 4,
          'event_version': 5,
          'queued_jobs': 0,
          'cancelled_jobs': 1,
          'skipped_past': 0,
          'capability': 'disabled',
        });
        final setRepository = SupabaseNotificationRepository(setHarness.client);
        final saved = await setRepository.saveEventPreference(
          EventNotificationPreference(
            id: _groupUuid,
            userId: _user,
            eventId: _eventUuid,
            channel: NotificationChannel.local,
            enabled: true,
            timedLeadSeconds: 900,
            allDayDaysBefore: 1,
            version: 3,
            eventVersion: 4,
          ),
          expectedVersion: 3,
        );
        expect(saved.enabled, isFalse);
        expect(saved.version, 4);
        expect(saved.eventVersion, 5);
        final request = setHarness.transport.requests.last as http.Request;
        expect(jsonDecode(request.body), <String, dynamic>{
          'p_event_id': _eventUuid,
          'p_channel': 'local',
          'p_enabled': true,
          'p_lead_seconds': 900,
          'p_all_day_days_before': 1,
          'p_expected_event_version': 4,
          'p_expected_setting_version': 3,
        });
      },
    );
  });

  group('local notification repository parity', () {
    test(
      'first settings/preference writes start at version one and plan candidates',
      () async {
        final now = DateTime.utc(2030, 1, 1, 9);
        final schedule = LocalScheduleRepository(clock: () => now);
        final group = await schedule.createGroup(
          _user,
          'Local reminders',
          '',
          timezone: 'UTC',
        );
        final event = await schedule.createEvent(
          _user,
          group.id,
          EventDraft(
            title: 'first reminder',
            startAt: now.add(const Duration(hours: 2)),
            endAt: now.add(const Duration(hours: 3)),
            timezone: 'UTC',
          ),
        );
        final repository = LocalNotificationRepository(schedule);

        final initial = await repository.settingsForUser(_user);
        final enabled = await repository.saveSettings(
          initial.copyWith(enabled: true, localEnabled: true),
          expectedVersion: initial.version,
        );
        expect(enabled.version, 1);
        final unchangedSettings = await repository.saveSettings(
          enabled,
          expectedVersion: enabled.version,
        );
        expect(unchangedSettings.version, 1);

        final firstPreference = EventNotificationPreference(
          id: 'setting-${event.id}',
          userId: _user,
          eventId: event.id,
          channel: NotificationChannel.local,
          enabled: true,
          version: 0,
          eventVersion: event.version,
        );
        final savedPreference = await repository.saveEventPreference(
          firstPreference,
          expectedVersion: firstPreference.version,
        );
        expect(savedPreference.version, 1);
        final unchangedPreference = await repository.saveEventPreference(
          savedPreference,
          expectedVersion: savedPreference.version,
        );
        expect(unchangedPreference.version, 1);

        final page = await repository.reminderCandidatesForUser(
          userId: _user,
          fireAtStart: now,
          fireAtEnd: now.add(reminderPlanningHorizon),
        );
        expect(page.candidates, hasLength(1));
        expect(page.candidates.single.settingVersion, 1);
      },
    );
  });

  group('reminder planner', () {
    test('timed reminders subtract elapsed seconds from the UTC instant', () {
      final now = DateTime.utc(2030, 1, 1, 9);
      final event = _event(
        id: 'event-a',
        startAt: DateTime.utc(2030, 1, 1, 10),
        endAt: DateTime.utc(2030, 1, 1, 11),
      );
      final planned = ReminderPlanner.plan(
        userId: _user,
        events: <PlannerEvent>[event],
        settings: const UserNotificationSettings(
          userId: _user,
          enabled: true,
          localEnabled: true,
        ),
        preferences: <EventNotificationPreference>[_preference()],
        nowUtc: now,
      );
      expect(planned, hasLength(1));
      expect(planned.single.fireAt, DateTime.utc(2030, 1, 1, 9, 45));
      expect(
        planned.single.identity.offsetUnit,
        NotificationOffsetUnit.seconds,
      );
      expect(planned.single.identity.offsetValue, 900);
    });

    test(
      'all-day reminders use event-zone civil days and local 09:00 across DST',
      () {
        const timezone = 'America/New_York';
        final startDate = DateTime.utc(2026, 3, 9);
        final endDate = DateTime.utc(2026, 3, 10);
        final event = _event(
          id: 'event-all-day',
          startAt: wallTimeToUtc(startDate, timezone),
          endAt: wallTimeToUtc(endDate, timezone),
          timezone: timezone,
          allDay: true,
          allDayStartDate: startDate,
          allDayEndDate: endDate,
        );
        final planned = ReminderPlanner.plan(
          userId: _user,
          events: <PlannerEvent>[event],
          settings: const UserNotificationSettings(
            userId: _user,
            enabled: true,
            localEnabled: true,
          ),
          preferences: <EventNotificationPreference>[
            _preference(eventId: event.id, allDayDaysBefore: 1),
          ],
          nowUtc: DateTime.utc(2026, 3, 7, 12),
        );
        expect(planned, hasLength(1));
        // March 8 is the DST transition date in New York; 09:00 is UTC-04.
        expect(planned.single.fireAt, DateTime.utc(2026, 3, 8, 13));
        expect(
          planned.single.identity.offsetUnit,
          NotificationOffsetUnit.calendarDays,
        );
        expect(planned.single.identity.offsetValue, 1);
      },
    );

    test('wall-time conversion is deterministic for a DST gap and fold', () {
      const timezone = 'America/New_York';
      // The nonexistent 02:30 wall time is shifted forward to 03:30 EDT.
      expect(
        wallTimeToUtc(DateTime.utc(2026, 3, 8, 2, 30), timezone),
        DateTime.utc(2026, 3, 8, 7, 30),
      );
      // The repeated 01:30 wall time chooses the later (standard-time) fold.
      expect(
        wallTimeToUtc(DateTime.utc(2026, 11, 1, 1, 30), timezone),
        DateTime.utc(2026, 11, 1, 6, 30),
      );
    });

    test(
      'planner excludes the horizon boundary and deduplicates identities',
      () {
        final now = DateTime.utc(2030, 1, 1);
        final inside = _event(
          id: 'event-inside',
          startAt: now.add(const Duration(hours: 2)),
          endAt: now.add(const Duration(hours: 3)),
        );
        final boundary = _event(
          id: 'event-boundary',
          startAt: now
              .add(reminderPlanningHorizon)
              .add(const Duration(minutes: 15)),
          endAt: now
              .add(reminderPlanningHorizon)
              .add(const Duration(minutes: 30)),
        );
        final past = _event(
          id: 'event-past',
          startAt: now.add(const Duration(minutes: 10)),
          endAt: now.add(const Duration(minutes: 20)),
        );
        final preference = _preference(eventId: inside.id);
        final planned = ReminderPlanner.plan(
          userId: _user,
          events: <PlannerEvent>[inside, inside, boundary, past],
          settings: const UserNotificationSettings(
            userId: _user,
            enabled: true,
            localEnabled: true,
          ),
          preferences: <EventNotificationPreference>[preference],
          nowUtc: now,
        );
        expect(planned, hasLength(1));
        expect(planned.single.eventId, inside.id);
      },
    );

    test(
      'recurrence occurrence keys remain distinct and the earliest 48 win',
      () {
        final now = DateTime.utc(2030, 1, 1);
        final events = List<PlannerEvent>.generate(60, (index) {
          final start = now.add(Duration(hours: index + 1));
          return _event(
            id: 'event-$index',
            seriesId: 'series-a',
            occurrenceKey: occurrenceKeyForIndex(index),
            occurrenceIndex: index,
            startAt: start,
            endAt: start.add(const Duration(hours: 1)),
          );
        });
        final planned = ReminderPlanner.plan(
          userId: _user,
          events: events,
          settings: const UserNotificationSettings(
            userId: _user,
            enabled: true,
            localEnabled: true,
          ),
          preferences: <EventNotificationPreference>[
            _preference(eventId: 'series-a'),
          ],
          nowUtc: now,
        );
        expect(planned, hasLength(reminderPlanningLimit));
        expect(
          planned.map((value) => value.occurrenceKey).toSet(),
          hasLength(reminderPlanningLimit),
        );
        expect(planned.first.occurrenceKey, occurrenceKeyForIndex(0));
        expect(planned.last.occurrenceKey, occurrenceKeyForIndex(47));
      },
    );
  });

  group('notification controller lifecycle', () {
    test(
      'auth switch fences an in-flight account load before scheduling',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final settingsGate = Completer<UserNotificationSettings>();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        )..settingsGate = settingsGate.future;
        final scheduler = _Scheduler();
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        final first = controller.onAuthenticated(_user);
        await Future<void>.delayed(Duration.zero);
        final second = controller.onAuthenticated('user-b');
        settingsGate.complete(
          const UserNotificationSettings(
            userId: _user,
            enabled: false,
            localEnabled: false,
          ),
        );

        await first;
        await second;

        expect(controller.userId, 'user-b');
        expect(controller.settings.userId, 'user-b');
        expect(repository.candidateCalls, 1);
        expect(scheduler.scheduled, hasLength(1));
      },
    );

    test(
      'auth switch fences an in-flight candidate reconcile before scheduling',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final candidatePage = ReminderCandidatePage(
          candidates: <ReminderCandidate>[
            _candidate(fireAt: now.add(const Duration(hours: 1))),
          ],
          nextCursor: null,
          hasMore: false,
        );
        final gate = Completer<void>();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage.empty(),
            candidatePage,
            candidatePage,
          ],
        );
        final scheduler = _Scheduler();
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);
        await controller.onAuthenticated(_user);
        repository.candidateGate = gate.future;

        final first = controller.reconcile();
        await Future<void>.delayed(Duration.zero);
        final second = controller.onAuthenticated('user-b');
        gate.complete();

        await first;
        await second;

        expect(controller.userId, 'user-b');
        expect(repository.candidateCalls, 3);
        expect(scheduler.scheduled, hasLength(1));
      },
    );

    test(
      'loads and replaces one event while preserving other event preferences',
      () async {
        final repository = _Repository(pages: <ReminderCandidatePage>[]);
        final other = _preference(eventId: 'other-event');
        final local = _preference(
          eventId: 'target-event',
          timedLeadSeconds: 600,
        );
        final push = _preference(
          eventId: 'target-event',
          channel: NotificationChannel.push,
          timedLeadSeconds: 1200,
        );
        // The account-wide remote snapshot intentionally omits target-event;
        // the one-event RPC below is the only source for its rows.
        repository.userPreferenceSnapshot = <EventNotificationPreference>[
          other,
        ];
        repository.preferences
          ..add(other)
          ..add(local)
          ..add(push);
        final controller = NotificationController(
          repository: repository,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        // Seed a stale target row to prove the operation replaces, rather
        // than appends/duplicates, the logical event's channel set.
        controller.eventPreferences = <EventNotificationPreference>[
          other,
          _preference(eventId: 'target-event', timedLeadSeconds: 30),
        ];
        final loaded = await controller.loadEventPreferences('target-event');

        expect(repository.eventPreferenceCalls, 1);
        expect(
          loaded.map((value) => value.channel),
          containsAll(<NotificationChannel>[
            NotificationChannel.local,
            NotificationChannel.push,
          ]),
        );
        expect(
          controller.eventPreferences
              .where((value) => value.eventId == 'target-event')
              .map((value) => value.timedLeadSeconds),
          containsAll(<int>[600, 1200]),
        );
        expect(
          controller.eventPreferences.where(
            (value) => value.eventId == 'other-event',
          ),
          <EventNotificationPreference>[other],
        );
      },
    );

    test(
      'ignores a per-event result made stale by a queued account switch',
      () async {
        final gate = Completer<List<EventNotificationPreference>>();
        final repository = _Repository(pages: <ReminderCandidatePage>[])
          ..eventPreferenceGate = gate.future;
        final controller = NotificationController(
          repository: repository,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final load = controller.loadEventPreferences('target-event');
        await Future<void>.delayed(Duration.zero);
        expect(repository.eventPreferenceCalls, 1);
        final switched = controller.onAuthenticated('user-b');
        gate.complete(<EventNotificationPreference>[
          _preference(eventId: 'target-event'),
        ]);
        await load;
        await switched;

        expect(controller.userId, 'user-b');
        expect(
          controller.eventPreferences.where(
            (value) => value.eventId == 'target-event',
          ),
          isEmpty,
        );
      },
    );

    test(
      'surfaces repository errors without mutating preferences or scheduling',
      () async {
        final repository = _Repository(pages: <ReminderCandidatePage>[])
          ..eventPreferenceError = StateError('transport down');
        final controller = NotificationController(
          repository: repository,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final preserved = _preference(eventId: 'other-event');
        controller.eventPreferences = <EventNotificationPreference>[preserved];
        await expectLater(
          controller.loadEventPreferences('target-event'),
          throwsA(isA<StateError>()),
        );
        expect(controller.errorMessage, isNotNull);
        expect(controller.eventPreferences, <EventNotificationPreference>[
          preserved,
        ]);
      },
    );

    test(
      'rejects mismatched or duplicate rows from a per-event repository',
      () async {
        final repository = _Repository(pages: <ReminderCandidatePage>[]);
        final controller = NotificationController(
          repository: repository,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
        );
        addTearDown(controller.dispose);
        await controller.onAuthenticated(_user);

        final preserved = _preference(eventId: 'other-event');
        controller.eventPreferences = <EventNotificationPreference>[preserved];
        repository.eventPreferenceError = null;
        repository.eventPreferenceSnapshot = <EventNotificationPreference>[
          _preference(eventId: 'different-event'),
        ];
        await expectLater(
          controller.loadEventPreferences('target-event'),
          throwsA(isA<ScheduleConflictException>()),
        );
        expect(controller.eventPreferences, <EventNotificationPreference>[
          preserved,
        ]);

        repository.eventPreferenceSnapshot = <EventNotificationPreference>[
          _preference(eventId: 'target-event'),
          _preference(eventId: 'target-event'),
        ];
        await expectLater(
          controller.loadEventPreferences('target-event'),
          throwsA(isA<ScheduleConflictException>()),
        );
        expect(controller.eventPreferences, <EventNotificationPreference>[
          preserved,
        ]);
      },
    );

    test(
      'evictEventPreferences removes one event cache and preserves others',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final target = _candidate(
          eventId: _eventUuid,
          fireAt: now.add(const Duration(hours: 1)),
        );
        final other = _candidate(
          eventId: _otherEventUuid,
          fireAt: now.add(const Duration(hours: 2)),
        );
        final repository = _Repository(pages: <ReminderCandidatePage>[]);
        final controller = NotificationController(
          repository: repository,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);
        await controller.onAuthenticated(_user);
        controller.eventPreferences = <EventNotificationPreference>[
          _preference(eventId: _eventUuid),
          _preference(eventId: _otherEventUuid),
        ];
        controller.plannedReminders = ReminderPlanner.fromCandidates(
          userId: _user,
          candidates: <ReminderCandidate>[target, other],
          nowUtc: now,
        );

        await controller.evictEventPreferences(_eventUuid);

        expect(
          controller.eventPreferences.map((value) => value.eventId),
          <String>[_otherEventUuid],
        );
        expect(
          controller.plannedReminders.map((value) => value.eventId),
          <String>[_otherEventUuid],
        );
      },
    );

    test(
      'denied permission cancels known IDs while retaining desired settings',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        expect(scheduler.scheduled, hasLength(1));
        expect(controller.settings.localDesired, isTrue);
        scheduler.state = NotificationPermissionState.denied;
        await controller.onResume();
        expect(controller.permission, NotificationPermissionState.denied);
        expect(controller.settings.localDesired, isTrue);
        expect(
          scheduler.cancelled,
          contains(scheduler.scheduled.single.notificationId),
        );
      },
    );

    test(
      'disabled scheduler capability cancels known IDs while retaining desired settings',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final oldId = scheduler.scheduled.single.notificationId;
        scheduler.capabilityState = NotificationCapabilityState.disabled;
        await controller.onResume();
        expect(controller.capability, NotificationCapabilityState.disabled);
        expect(controller.settings.localDesired, isTrue);
        expect(scheduler.cancelled, contains(oldId));
      },
    );

    test(
      'disabled transition cancels pending-only native IDs after a restart',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(pages: <ReminderCandidatePage>[]);
        final registry = _Registry(<String, Map<int, String>>{});
        final identity = ReminderIdentity(
          userId: _user,
          eventId: _eventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final firstAllocator = NotificationIdAllocator(registry: registry);
        final allocated = await firstAllocator.idFor(identity);
        final restartedAllocator = NotificationIdAllocator(registry: registry);
        expect(await restartedAllocator.idFor(identity), allocated);
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: restartedAllocator,
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        scheduler.pendingOnly.add(0x12345);
        scheduler.state = NotificationPermissionState.denied;
        await controller.onResume();
        expect(scheduler.cancelled, contains(0x12345));
        expect(scheduler.cancelled, contains(allocated));
      },
    );

    test(
      'account switch cancels pending-only IDs before loading the new user',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..pendingOnly.add(0x23456);
        final controller = NotificationController(
          repository: _Repository(pages: <ReminderCandidatePage>[]),
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        await controller.onAuthenticated('user-b');
        expect(scheduler.cancelled, contains(0x23456));
        expect(controller.userId, 'user-b');
      },
    );

    test(
      'group invalidation purges cold-start IDs then rebuilds remaining groups',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final removedIdentity = ReminderIdentity(
          userId: _user,
          eventId: _eventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final remainingIdentity = ReminderIdentity(
          userId: _user,
          eventId: _otherEventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final registry = _Registry(<String, Map<int, String>>{});
        final seeded = NotificationIdAllocator(registry: registry);
        final removedId = await seeded.idFor(removedIdentity);
        final remainingId = await seeded.idFor(remainingIdentity);
        final scheduler = _Scheduler()
          ..removePendingOnCancel = true
          ..pendingOnly.addAll(<int>[removedId, remainingId]);
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(
                  eventId: _otherEventUuid,
                  groupId: 'remaining-group',
                  fireAt: now.add(const Duration(hours: 1)),
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller =
            NotificationController(
                repository: repository,
                scheduler: scheduler,
                idAllocator: NotificationIdAllocator(registry: registry),
                clock: () => now,
              )
              ..userId = _user
              ..settings = repository.settings
              ..capability = NotificationCapabilityState.available
              ..permission = NotificationPermissionState.authorized;
        addTearDown(controller.dispose);

        // The process restarted with no in-memory schedule map. Both the
        // removed-group and still-valid-group native IDs must be cancelled
        // before the authoritative all-group read can schedule the latter.
        await controller.cancelForGroup('removed-group');

        expect(scheduler.cancelled, containsAll(<int>[removedId, remainingId]));
        expect(scheduler.pendingOnly, isEmpty);
        expect(scheduler.scheduled, hasLength(1));
        expect(scheduler.scheduled.single.payload.groupId, 'remaining-group');
        final retained = await controller.idAllocator.entriesFor(_user);
        expect(retained, hasLength(1));
        expect(retained.single.id, remainingId);
      },
    );

    test(
      'group invalidation keeps removed IDs cancelled when replacement fetch fails',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final removedIdentity = ReminderIdentity(
          userId: _user,
          eventId: _eventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final remainingIdentity = ReminderIdentity(
          userId: _user,
          eventId: _otherEventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final registry = _Registry(<String, Map<int, String>>{});
        final seeded = NotificationIdAllocator(registry: registry);
        final removedId = await seeded.idFor(removedIdentity);
        final remainingId = await seeded.idFor(remainingIdentity);
        final scheduler = _Scheduler()
          ..removePendingOnCancel = true
          ..pendingOnly.addAll(<int>[removedId, remainingId]);
        final repository = _Repository(pages: <ReminderCandidatePage>[])
          ..candidateError = StateError('range unavailable');
        final controller =
            NotificationController(
                repository: repository,
                scheduler: scheduler,
                idAllocator: NotificationIdAllocator(registry: registry),
                clock: () => now,
              )
              ..userId = _user
              ..settings = repository.settings
              ..capability = NotificationCapabilityState.available
              ..permission = NotificationPermissionState.authorized;
        addTearDown(controller.dispose);

        await controller.cancelForGroup('removed-group');

        expect(scheduler.cancelled, containsAll(<int>[removedId, remainingId]));
        expect(scheduler.pendingOnly, isEmpty);
        expect(scheduler.scheduled, isEmpty);
        expect(await controller.idAllocator.entriesFor(_user), isEmpty);
        expect(controller.candidatesIncomplete, isTrue);
        expect(controller.errorMessage, isNotNull);
      },
    );

    test(
      'group invalidation never reschedules the old account after a session switch',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final removedIdentity = ReminderIdentity(
          userId: _user,
          eventId: _eventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final remainingIdentity = ReminderIdentity(
          userId: _user,
          eventId: _otherEventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final registry = _Registry(<String, Map<int, String>>{});
        final seeded = NotificationIdAllocator(registry: registry);
        final removedId = await seeded.idFor(removedIdentity);
        final remainingId = await seeded.idFor(remainingIdentity);
        final scheduler = _Scheduler()
          ..removePendingOnCancel = true
          ..pendingOnly.addAll(<int>[removedId, remainingId]);
        final gate = Completer<void>();
        final repository = _Repository(pages: <ReminderCandidatePage>[])
          ..candidateGate = gate.future;
        final controller =
            NotificationController(
                repository: repository,
                scheduler: scheduler,
                idAllocator: NotificationIdAllocator(registry: registry),
                clock: () => now,
              )
              ..userId = _user
              ..settings = repository.settings
              ..capability = NotificationCapabilityState.available
              ..permission = NotificationPermissionState.authorized;
        addTearDown(controller.dispose);

        final invalidation = controller.cancelForGroup('removed-group');
        await Future<void>.delayed(Duration.zero);
        expect(repository.candidateCalls, 1);
        final switched = controller.onAuthenticated('user-b');
        gate.complete();
        await invalidation;
        await switched;

        expect(scheduler.cancelled, containsAll(<int>[removedId, remainingId]));
        expect(scheduler.scheduled, isEmpty);
        expect(controller.userId, 'user-b');
      },
    );

    test(
      'reconcile stays fail closed while a group purge cancellation is failing',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final removedIdentity = ReminderIdentity(
          userId: _user,
          eventId: _eventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final remainingIdentity = ReminderIdentity(
          userId: _user,
          eventId: _otherEventUuid,
          occurrenceKey: 'single',
          offsetValue: 900,
          offsetUnit: NotificationOffsetUnit.seconds,
          channel: NotificationChannel.local,
        );
        final registry = _Registry(<String, Map<int, String>>{});
        final seeded = NotificationIdAllocator(registry: registry);
        final removedId = await seeded.idFor(removedIdentity);
        final remainingId = await seeded.idFor(remainingIdentity);
        final scheduler = _Scheduler()
          ..removePendingOnCancel = true
          ..pendingOnly.addAll(<int>[removedId, remainingId])
          ..cancelError = StateError('native cancellation unavailable');
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(
                  eventId: _otherEventUuid,
                  groupId: 'remaining-group',
                  fireAt: now.add(const Duration(hours: 1)),
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller =
            NotificationController(
                repository: repository,
                scheduler: scheduler,
                idAllocator: NotificationIdAllocator(registry: registry),
                clock: () => now,
              )
              ..userId = _user
              ..settings = repository.settings
              ..capability = NotificationCapabilityState.available
              ..permission = NotificationPermissionState.authorized;
        addTearDown(controller.dispose);

        await controller.cancelForGroup('removed-group');
        final scheduledAfterGroupFailure = scheduler.scheduled.length;
        final candidateCallsAfterGroupFailure = repository.candidateCalls;

        // A normal event/realtime reconcile must retry the failed purge and
        // stop before fetching or scheduling a replacement while the native
        // cancellation remains unavailable.
        await controller.reconcile();

        expect(scheduler.scheduled.length, scheduledAfterGroupFailure);
        expect(repository.candidateCalls, candidateCallsAfterGroupFailure);
        expect(
          scheduler.pendingOnly,
          containsAll(<int>[removedId, remainingId]),
        );
        expect(controller.candidatesIncomplete, isTrue);
        expect(await controller.idAllocator.entriesFor(_user), hasLength(2));

        scheduler.cancelError = null;
        await controller.reconcile();

        expect(scheduler.cancelled, containsAll(<int>[removedId, remainingId]));
        expect(scheduler.pendingOnly, isEmpty);
        expect(scheduler.scheduled, hasLength(1));
        expect(scheduler.scheduled.single.payload.eventId, _otherEventUuid);
        expect(await controller.idAllocator.entriesFor(_user), hasLength(1));
        expect(
          (await controller.idAllocator.entriesFor(_user)).single.id,
          remainingId,
        );
      },
    );

    test(
      'candidate capability denial fails closed without scheduling the page',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage.empty(
              capability: NotificationCapabilityState.disabled,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        expect(scheduler.scheduled, isEmpty);
        expect(controller.capability, NotificationCapabilityState.disabled);
      },
    );

    test(
      'account switch cancels persisted IDs before loading the new user',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
            ReminderCandidatePage.empty(),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final oldId = scheduler.scheduled.single.notificationId;
        await controller.onAuthenticated('user-b');
        expect(scheduler.cancelled, contains(oldId));
        expect(controller.userId, 'user-b');
      },
    );

    test(
      'complete rolling windows prune stale recurring IDs instead of accumulating',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final occurrences = List<ReminderCandidate>.generate(
          16,
          (index) => _candidate(
            fireAt: now.add(Duration(hours: index + 1)),
            occurrenceKey: _occurrenceKey(index),
            occurrenceIndex: index,
          ),
        );
        final repository = _Repository(
          pages: occurrences
              .map(
                (candidate) => ReminderCandidatePage(
                  candidates: <ReminderCandidate>[candidate],
                  nextCursor: null,
                  hasMore: false,
                ),
              )
              .toList(),
        );
        final scheduler = _Scheduler();
        final registry = _Registry(<String, Map<int, String>>{});
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        for (var index = 1; index < occurrences.length; index++) {
          await controller.reconcile();
          expect(await controller.idAllocator.entriesFor(_user), hasLength(1));
        }
        expect(registry.entries[_user], hasLength(1));
      },
    );

    test(
      'unreadable allocator recovers by cancelling pending IDs then reschedules',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..pendingOnly.add(0x34567);
        final registry = _Registry(<String, Map<int, String>>{})
          ..loadError = const FormatException('corrupt registry');
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);

        expect(scheduler.cancelled, contains(0x34567));
        expect(scheduler.scheduled, hasLength(1));
        expect(controller.candidatesIncomplete, isFalse);
        expect(controller.errorMessage, isNull);
        expect(await controller.idAllocator.entriesFor(_user), hasLength(1));
      },
    );

    test(
      'unreadable allocator fails closed when native cancellation cannot complete',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()
          ..pendingOnly.add(0x45678)
          ..cancelError = StateError('native cancellation unavailable');
        final registry = _Registry(<String, Map<int, String>>{})
          ..loadError = const FormatException('corrupt registry')
          ..persistentLoadError = true;
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);

        expect(scheduler.scheduled, isEmpty);
        expect(scheduler.cancelled, isEmpty);
        expect(controller.candidatesIncomplete, isTrue);
        expect(controller.errorMessage, isNotNull);
        expect(registry.loadError, isNotNull);
      },
    );

    test(
      'unreadable allocator remains fail closed when registry clear fails',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..pendingOnly.add(0x56789);
        final registry = _Registry(<String, Map<int, String>>{})
          ..loadError = const FormatException('corrupt registry')
          ..saveError = StateError('registry unavailable')
          ..persistentSaveError = true;
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);

        expect(scheduler.cancelled, contains(0x56789));
        expect(scheduler.scheduled, isEmpty);
        expect(controller.candidatesIncomplete, isTrue);
        expect(controller.errorMessage, isNotNull);
        expect(registry.saveError, isNotNull);
      },
    );

    test(
      'unreadable allocator remains fail closed when pending enumeration fails',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()
          ..pendingError = StateError('native pending read unavailable');
        final registry = _Registry(<String, Map<int, String>>{})
          ..loadError = const FormatException('corrupt registry')
          ..persistentLoadError = true;
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);

        expect(scheduler.cancelled, isEmpty);
        expect(scheduler.scheduled, isEmpty);
        expect(controller.candidatesIncomplete, isTrue);
        expect(controller.errorMessage, isNotNull);
        expect(registry.loadError, isNotNull);
      },
    );

    test(
      'cancellation failure retains stale allocator rows for a later retry',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final first = _candidate(
          fireAt: now.add(const Duration(hours: 1)),
          occurrenceKey: _occurrenceKey(1),
          occurrenceIndex: 1,
        );
        final second = _candidate(
          fireAt: now.add(const Duration(hours: 2)),
          occurrenceKey: _occurrenceKey(2),
          occurrenceIndex: 2,
        );
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[first],
              nextCursor: null,
              hasMore: false,
            ),
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[second],
              nextCursor: null,
              hasMore: false,
            ),
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[second],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final scheduler = _Scheduler();
        final registry = _Registry(<String, Map<int, String>>{});
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final firstId = (await controller.idAllocator.entriesFor(
          _user,
        )).single.id;
        scheduler.cancelError = StateError('native cancellation unavailable');
        await controller.reconcile();
        final retainedAfterFailure = await controller.idAllocator.entriesFor(
          _user,
        );
        expect(retainedAfterFailure, hasLength(2));
        expect(
          retainedAfterFailure.map((entry) => entry.id),
          contains(firstId),
        );

        scheduler.cancelError = null;
        await controller.reconcile();
        final retainedAfterRetry = await controller.idAllocator.entriesFor(
          _user,
        );
        expect(retainedAfterRetry, hasLength(1));
        expect(
          retainedAfterRetry.map((entry) => entry.id),
          isNot(contains(firstId)),
        );
      },
    );

    test('successful sign-out clears durable allocator ownership', () async {
      final now = DateTime.utc(2030, 1, 1);
      final repository = _Repository(
        pages: <ReminderCandidatePage>[
          ReminderCandidatePage(
            candidates: <ReminderCandidate>[
              _candidate(fireAt: now.add(const Duration(hours: 1))),
            ],
            nextCursor: null,
            hasMore: false,
          ),
        ],
      );
      final scheduler = _Scheduler();
      final registry = _Registry(<String, Map<int, String>>{});
      final controller = NotificationController(
        repository: repository,
        scheduler: scheduler,
        idAllocator: NotificationIdAllocator(registry: registry),
        clock: () => now,
      );
      addTearDown(controller.dispose);

      await controller.onAuthenticated(_user);
      expect(registry.entries[_user], isNotEmpty);
      await controller.onSignedOut();
      expect(registry.entries[_user], isEmpty);
      expect(await controller.idAllocator.entriesFor(_user), isEmpty);
    });

    test(
      'signed-out startup cancels valid pending IDs without a user registry',
      () async {
        final scheduler = _Scheduler()
          ..pendingOnly.addAll(<int>[0x6789a, 0x6789b]);
        final controller = NotificationController(
          repository: _Repository(pages: <ReminderCandidatePage>[]),
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
        );
        addTearDown(controller.dispose);

        await controller.onSignedOut();

        expect(scheduler.cancelled, containsAll(<int>[0x6789a, 0x6789b]));
      },
    );

    test(
      'signed-out resume retries a native cancellation that failed once',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..removePendingOnCancel = true;
        final registry = _Registry(<String, Map<int, String>>{});
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final oldId = scheduler.scheduled.single.notificationId;
        scheduler.cancelError = StateError('native cancellation unavailable');
        await controller.onSignedOut();

        expect(controller.userId, isNull);
        expect(registry.entries[_user], isNotEmpty);
        expect(scheduler.cancelled, isEmpty);
        expect(scheduler.pendingOnly, isEmpty);
        expect(scheduler.scheduled, hasLength(1));

        scheduler.cancelError = null;
        await controller.onResume();

        expect(scheduler.cancelled, contains(oldId));
        expect(scheduler.scheduled, isEmpty);
        expect(scheduler.pendingOnly, isEmpty);
        expect(registry.entries[_user], isEmpty);
        expect(await controller.idAllocator.entriesFor(_user), isEmpty);
      },
    );

    test(
      'account switch retries a failed old-user purge before scheduling B',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..removePendingOnCancel = true;
        final registry = _Registry(<String, Map<int, String>>{});
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(
                  eventId: _eventUuid,
                  groupId: _groupUuid,
                  fireAt: now.add(const Duration(hours: 1)),
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(
                  eventId: _otherEventUuid,
                  groupId: 'group-b',
                  fireAt: now.add(const Duration(hours: 2)),
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(registry: registry),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final oldId = scheduler.scheduled.single.notificationId;
        scheduler.cancelError = StateError('native cancellation unavailable');
        await controller.onAuthenticated('user-b');

        expect(controller.userId, 'user-b');
        expect(scheduler.scheduled, hasLength(1));
        expect(scheduler.scheduled.single.notificationId, oldId);
        expect(await controller.idAllocator.entriesFor(_user), hasLength(1));
        expect(await controller.idAllocator.entriesFor('user-b'), isEmpty);

        scheduler.cancelError = null;
        await controller.onResume();

        expect(scheduler.cancelled, contains(oldId));
        expect(scheduler.scheduled, hasLength(1));
        expect(scheduler.scheduled.single.payload.eventId, _otherEventUuid);
        expect(await controller.idAllocator.entriesFor(_user), isEmpty);
        expect(await controller.idAllocator.entriesFor('user-b'), hasLength(1));
      },
    );

    test(
      'cold-start authentication purges unknown native IDs before B schedules',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        const unknownPriorId = 0x6a5b4;
        final scheduler = _Scheduler()
          ..removePendingOnCancel = true
          ..pendingOnly.add(unknownPriorId);
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(
                  eventId: _otherEventUuid,
                  groupId: 'group-b',
                  fireAt: now.add(const Duration(hours: 1)),
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated('user-b');

        expect(scheduler.cancelled, contains(unknownPriorId));
        expect(scheduler.pendingOnly, isEmpty);
        expect(scheduler.scheduled, hasLength(1));
        expect(scheduler.scheduled.single.payload.eventId, _otherEventUuid);
        expect(controller.userId, 'user-b');
      },
    );

    test(
      'incomplete candidate pagination never cancels an unknown persisted ID',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
            ),
            ReminderCandidatePage(
              candidates: const <ReminderCandidate>[],
              nextCursor: null,
              hasMore: false,
              complete: false,
            ),
          ],
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);
        final oldId = scheduler.scheduled.single.notificationId;
        final cancelsBefore = scheduler.cancelled.length;
        await controller.reconcile();
        expect(controller.candidatesIncomplete, isTrue);
        expect(scheduler.cancelled.length, cancelsBefore);
        expect(await controller.idAllocator.entriesFor(_user), isNotEmpty);
        expect(oldId, isNotNull);
      },
    );

    test(
      'incomplete candidate pages never trigger unreadable-registry recovery',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final scheduler = _Scheduler()..pendingOnly.add(0x789ab);
        final registry = _Registry(<String, Map<int, String>>{})
          ..loadError = const FormatException('corrupt registry')
          ..persistentLoadError = true;
        final repository = _Repository(
          pages: <ReminderCandidatePage>[
            ReminderCandidatePage(
              candidates: <ReminderCandidate>[
                _candidate(fireAt: now.add(const Duration(hours: 1))),
              ],
              nextCursor: null,
              hasMore: false,
              complete: false,
            ),
          ],
        );
        final controller =
            NotificationController(
                repository: repository,
                scheduler: scheduler,
                idAllocator: NotificationIdAllocator(registry: registry),
                clock: () => now,
              )
              // This test starts from an already-authenticated account so the
              // cold-start pending-ID purge is not the behavior under test.
              ..userId = _user
              ..settings = repository.settings
              ..capability = NotificationCapabilityState.available
              ..permission = NotificationPermissionState.authorized;
        addTearDown(controller.dispose);

        await controller.onAuthenticated(_user);

        expect(scheduler.cancelled, isEmpty);
        expect(scheduler.scheduled, isEmpty);
        expect(controller.candidatesIncomplete, isTrue);
        expect(controller.errorMessage, isNotNull);
        expect(registry.loadError, isNotNull);
      },
    );

    test(
      'reconcile requests serialize behind an in-flight candidate read',
      () async {
        final now = DateTime.utc(2030, 1, 1);
        final gate = Completer<void>();
        final scheduler = _Scheduler();
        final repository = _Repository(
          pages: <ReminderCandidatePage>[],
          candidateGate: gate.future,
        );
        final controller = NotificationController(
          repository: repository,
          scheduler: scheduler,
          idAllocator: NotificationIdAllocator(
            registry: InMemoryNotificationIdRegistry(),
          ),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        final first = controller.onAuthenticated(_user);
        await Future<void>.delayed(Duration.zero);
        expect(repository.candidateCalls, 1);
        final second = controller.reconcile();
        gate.complete();
        await Future.wait(<Future<void>>[first, second]);
        expect(repository.candidateCalls, 2);
      },
    );
  });
}
