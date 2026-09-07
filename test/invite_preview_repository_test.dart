// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/core/demo_identity.dart';
import 'package:moduly/core/invite_code_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/schedule_repository.dart';

class _RpcTransport extends http.BaseClient {
  _RpcTransport(this.payload, {this.statusCode = 200});

  Object? payload;
  int statusCode;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      statusCode,
      request: request,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

class _JoinThenFetchFailureTransport extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final isJoinRpc = request.url.path.endsWith('/rpc/join_group_with_invite');
    final payload = isJoinRpc
        ? <String, dynamic>{
            'group_id': '123e4567-e89b-12d3-a456-426614174000',
            'membership_id': '123e4567-e89b-12d3-a456-426614174001',
            'joined': true,
            'reason': 'joined',
          }
        : <String, dynamic>{'message': 'projection unavailable'};
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      isJoinRpc ? 200 : 500,
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

  final String _userId;

  @override
  String? get currentSessionUserId => _userId;
}

void main() {
  test(
    'local creates unique strict tokens that round-trip through manual entry',
    () async {
      final repository = LocalScheduleRepository();
      final first = await repository.createInviteCodeWithOptions('demo-group');
      final second = await repository.createInviteCodeWithOptions('demo-group');

      expect(first.token, isNotNull);
      expect(second.token, isNotNull);
      expect(isStrictInviteToken(first.token!), isTrue);
      expect(isStrictInviteToken(second.token!), isTrue);
      expect(first.token, isNot(second.token));
      expect(first.token, isNot(contains('family-')));

      final listed = await repository.inviteCodesForGroup('demo-group');
      expect(listed, hasLength(2));
      expect(listed.every((invite) => invite.token == null), isTrue);

      final copied = formatInviteCode(first.token!);
      expect(normalizeInviteCode(copied), first.token);
      final preview = await repository.previewInvite(
        userId: 'round-trip-user',
        token: copied,
      );
      expect(preview.groupId, 'demo-group');
      await repository.joinGroup('round-trip-user', copied);
      expect(
        (await repository.groupsForUser(
          'round-trip-user',
        )).map((group) => group.id),
        contains('demo-group'),
      );
    },
  );

  test(
    'local invite attempts use separate actor-scoped sliding-hour ledgers',
    () async {
      var now = DateTime.utc(2030, 1, 1, 12);
      final repository = LocalScheduleRepository(clock: () => now);

      // Preview accepts exactly 60 real attempts, then rejects the 61st.
      for (var attempt = 0; attempt < 60; attempt++) {
        await expectLater(
          repository.previewInvite(userId: 'preview-actor', token: 'unknown'),
          throwsA(isA<InviteUnavailableException>()),
        );
      }
      await expectLater(
        repository.previewInvite(userId: 'preview-actor', token: 'unknown'),
        throwsA(isA<InviteRateLimitedException>()),
      );

      // A different actor is isolated, and the join budget is independent.
      await expectLater(
        repository.previewInvite(userId: 'other-actor', token: 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );
      await expectLater(
        repository.joinGroup('preview-actor', 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );

      // Rejected requests do not append a timestamp or extend the lockout.
      now = now.add(const Duration(minutes: 59));
      await expectLater(
        repository.previewInvite(userId: 'preview-actor', token: 'unknown'),
        throwsA(isA<InviteRateLimitedException>()),
      );
      now = now.add(const Duration(minutes: 1));
      await expectLater(
        repository.previewInvite(userId: 'preview-actor', token: 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );

      // Join accepts exactly 20 attempts, then rejects the 21st.  Invalid
      // input is still a real attempt and therefore consumes one slot.
      for (var attempt = 0; attempt < 20; attempt++) {
        await expectLater(
          repository.joinGroup('join-actor', ''),
          throwsA(isA<FormatException>()),
        );
      }
      await expectLater(
        repository.joinGroup('join-actor', ''),
        throwsA(isA<InviteRateLimitedException>()),
      );
      await expectLater(
        repository.previewInvite(userId: 'join-actor', token: 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );

      // At the exact one-hour boundary the old attempts are pruned.
      now = now.add(const Duration(hours: 1));
      await expectLater(
        repository.joinGroup('join-actor', 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );
    },
  );

  test(
    'local demo preview is sanitized and does not consume the code',
    () async {
      final repository = LocalScheduleRepository();

      final first = await repository.previewInvite(
        userId: 'new-user',
        token: 'family',
      );
      final second = await repository.previewInvite(
        userId: 'new-user',
        token: 'family',
      );

      expect(first.groupId, 'demo-group');
      expect(first.groupName, '우리 가족');
      expect(first.groupDescription, isNot(contains('family')));
      expect(first.alreadyMember, isFalse);
      expect(second, first);
    },
  );

  test(
    'local preview marks an active existing member without joining',
    () async {
      final repository = LocalScheduleRepository();
      final preview = await repository.previewInvite(
        userId: demoUserId,
        token: 'family',
      );

      expect(preview.alreadyMember, isTrue);
      expect(
        (await repository.groupsForUser(demoUserId)).map((group) => group.id),
        contains('demo-group'),
      );
    },
  );

  test('unknown local preview uses one terminal unavailable error', () {
    final repository = LocalScheduleRepository();
    expect(
      repository.previewInvite(userId: 'new-user', token: 'unknown'),
      throwsA(isA<InviteUnavailableException>()),
    );
  });

  test(
    'local unknown, archived, and expired joins use one terminal type',
    () async {
      final repository = LocalScheduleRepository();
      await expectLater(
        repository.joinGroup('new-user', 'unknown'),
        throwsA(isA<InviteUnavailableException>()),
      );

      final invite = await repository.createInviteCodeWithOptions(
        'demo-group',
        ttl: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await expectLater(
        repository.joinGroup('new-user', invite.token!),
        throwsA(isA<InviteUnavailableException>()),
      );

      final archivedGroup = await repository.createGroup(
        'archive-owner',
        'Archived',
        '',
      );
      final archivedInvite = await repository.createInviteCodeWithOptions(
        archivedGroup.id,
      );
      await repository.archiveGroupIfVersion(
        actorId: 'archive-owner',
        groupId: archivedGroup.id,
        expectedVersion: archivedGroup.version,
      );
      await expectLater(
        repository.joinGroup('new-user', archivedInvite.token!),
        throwsA(isA<InviteUnavailableException>()),
      );
    },
  );

  test('invite expiry boundary is inclusive', () {
    final now = DateTime.now().toUtc();
    final invite = InviteCode(
      id: 'i',
      groupId: 'g',
      expiresAt: now,
      maxUses: 1,
      usesCount: 0,
      version: 1,
    );
    expect(invite.isExpired, isTrue);
  });

  test(
    'Supabase preview sends only p_token and parses exact valid JSON',
    () async {
      final transport = _RpcTransport(<String, dynamic>{
        'valid': true,
        'group_id': '123e4567-e89b-12d3-a456-426614174000',
        'group_name': 'Group',
        'group_description': 'Description',
        'group_timezone': 'UTC',
        'expires_at': '2099-01-01T00:00:00Z',
        'already_member': false,
      });
      final client = _client(transport);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'user-1',
      );
      addTearDown(client.dispose);

      final preview = await repository.previewInvite(
        userId: 'user-1',
        token: '7k9mw3pxq2rt',
      );
      expect(preview.groupId, '123e4567-e89b-12d3-a456-426614174000');
      expect(preview.expiresAt, DateTime.utc(2099, 1, 1));
      final request = transport.requests.single as http.Request;
      final body = jsonDecode(request.body) as Map;
      expect(request.url.path, contains('/rpc/preview_invite'));
      expect(body.keys, <Object?>['p_token']);
      expect(body.containsKey('userId'), isFalse);
    },
  );

  test(
    'Supabase preview fails closed when no authenticated session exists',
    () async {
      final transport = _RpcTransport(<String, dynamic>{
        'valid': false,
        'reason': 'invalid_or_expired',
      });
      final client = _client(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.previewInvite(userId: 'user-1', token: _token),
        throwsA(isA<ScheduleAuthorizationException>()),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'Supabase join fails closed when no authenticated session exists',
    () async {
      final transport = _RpcTransport(<String, dynamic>{
        'group_id': '123e4567-e89b-12d3-a456-426614174000',
        'joined': true,
      });
      final client = _client(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.joinGroup('user-1', _token),
        throwsA(isA<ScheduleAuthorizationException>()),
      );
      expect(transport.requests, isEmpty);

      final mismatched = _AuthenticatedSupabaseScheduleRepository(
        client,
        'other-user',
      );
      await expectLater(
        mismatched.joinGroup('user-1', _token),
        throwsA(isA<ScheduleAuthorizationException>()),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'Supabase preview maps terminal and rate-limit oracle reasons',
    () async {
      final transport = _RpcTransport(<String, dynamic>{
        'valid': false,
        'reason': 'invalid_or_expired',
      });
      final client = _client(transport);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'user-1',
      );
      addTearDown(client.dispose);
      await expectLater(
        repository.previewInvite(userId: 'user-1', token: _token),
        throwsA(isA<InviteUnavailableException>()),
      );
      transport.payload = <String, dynamic>{
        'valid': false,
        'reason': 'rate_limited',
      };
      await expectLater(
        repository.previewInvite(userId: 'user-1', token: _token),
        throwsA(isA<InviteRateLimitException>()),
      );
    },
  );

  test('Supabase preview rejects partial or extra response fields', () async {
    final transport = _RpcTransport(<String, dynamic>{
      'valid': true,
      'group_id': '123e4567-e89b-12d3-a456-426614174000',
      'group_name': 'Group',
      'group_description': 'Description',
      'group_timezone': 'UTC',
      'expires_at': '2099-01-01T00:00:00Z',
      'already_member': false,
      'token': 'must-not-be-returned',
    });
    final client = _client(transport);
    final repository = _AuthenticatedSupabaseScheduleRepository(
      client,
      'user-1',
    );
    addTearDown(client.dispose);
    await expectLater(
      repository.previewInvite(userId: 'user-1', token: _token),
      throwsA(isA<ScheduleCapabilityException>()),
    );
  });

  test('Supabase join maps HTTP 429 to the typed rate-limit error', () async {
    final transport = _RpcTransport(<String, dynamic>{
      'message': 'rate limited',
    }, statusCode: 429);
    final client = _client(transport);
    final repository = _AuthenticatedSupabaseScheduleRepository(
      client,
      'user-1',
    );
    addTearDown(client.dispose);

    await expectLater(
      repository.joinGroup('user-1', _token),
      throwsA(isA<InviteRateLimitedException>()),
    );
    expect(
      transport.requests.single.url.path,
      contains('/rpc/join_group_with_invite'),
    );
  });

  test(
    'Supabase join marks membership committed when projection fetch fails',
    () async {
      final transport = _JoinThenFetchFailureTransport();
      final client = _client(transport);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'user-1',
      );
      addTearDown(client.dispose);

      await expectLater(
        repository.joinGroup('user-1', _token),
        throwsA(isA<InviteJoinCommittedException>()),
      );
      final paths = transport.requests.map((request) => request.url.path);
      expect(
        paths.any((path) => path.contains('/rpc/join_group_with_invite')),
        isTrue,
      );
      expect(paths.any((path) => path.contains('/groups')), isTrue);
    },
  );

  test(
    'Supabase preview rejects an array wrapper and non-UUID group id',
    () async {
      final transport = _RpcTransport(<Object>[
        <String, dynamic>{
          'valid': true,
          'group_id': 'group-1',
          'group_name': 'Group',
          'group_description': 'Description',
          'group_timezone': 'UTC',
          'expires_at': '2099-01-01T00:00:00Z',
          'already_member': false,
        },
      ]);
      final client = _client(transport);
      final repository = _AuthenticatedSupabaseScheduleRepository(
        client,
        'user-1',
      );
      addTearDown(client.dispose);
      await expectLater(
        repository.previewInvite(userId: 'user-1', token: _token),
        throwsA(isA<ScheduleCapabilityException>()),
      );
    },
  );
}

const _token = '7K9MW3PXQ2RT';
