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
  test('로컬이 수동 입력으로 왕복 가능한 고유하고 엄격한 토큰을 만든다', () async {
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
  });

  test('로컬 초대 시도가 사용자별로 분리된 최근 1시간 원장을 사용한다', () async {
    var now = DateTime.utc(2030, 1, 1, 12);
    final repository = LocalScheduleRepository(clock: () => now);

    // 미리보기는 실제 시도 60회까지 허용하고 61번째를 거부한다.
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

    // 다른 사용자는 격리되며 참여 한도도 독립적이다.
    await expectLater(
      repository.previewInvite(userId: 'other-actor', token: 'unknown'),
      throwsA(isA<InviteUnavailableException>()),
    );
    await expectLater(
      repository.joinGroup('preview-actor', 'unknown'),
      throwsA(isA<InviteUnavailableException>()),
    );

    // 거부된 요청은 타임스탬프를 추가하거나 잠금 시간을 늘리지 않는다.
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

    // 참여는 20번까지 허용하고 21번째를 거부한다. 잘못된 입력도 실제
    // 시도이므로 한 칸을 소모한다.
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

    // 정확히 1시간 경계에서 이전 시도를 정리한다.
    now = now.add(const Duration(hours: 1));
    await expectLater(
      repository.joinGroup('join-actor', 'unknown'),
      throwsA(isA<InviteUnavailableException>()),
    );
  });

  test('로컬 데모 미리보기가 정제되며 코드를 소모하지 않는다', () async {
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
  });

  test('로컬 미리보기가 참여 처리 없이 기존 활성 멤버를 표시한다', () async {
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
  });

  test('알 수 없는 로컬 미리보기가 단일 종료형 사용 불가 오류를 사용한다', () {
    final repository = LocalScheduleRepository();
    expect(
      repository.previewInvite(userId: 'new-user', token: 'unknown'),
      throwsA(isA<InviteUnavailableException>()),
    );
  });

  test('로컬의 알 수 없음, 보관됨, 만료됨 참여가 하나의 종료형 타입을 사용한다', () async {
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
  });

  test('초대 만료 경계가 포함 범위다', () {
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

  test('Supabase 미리보기가 p_token만 보내고 정확한 유효 JSON을 파싱한다', () async {
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
  });

  test('인증된 세션이 없으면 Supabase 미리보기가 안전하게 실패한다', () async {
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
  });

  test('인증된 세션이 없으면 Supabase 참여가 안전하게 실패한다', () async {
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
  });

  test('Supabase 미리보기가 종료형 및 속도 제한 오라클 사유를 변환한다', () async {
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
  });

  test('Supabase 미리보기가 불완전하거나 추가된 응답 필드를 거부한다', () async {
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

  test('Supabase 참여가 HTTP 429를 타입이 있는 속도 제한 오류로 변환한다', () async {
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

  test('투영 조회가 실패해도 Supabase 참여가 멤버십을 커밋됨으로 표시한다', () async {
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
  });

  test('Supabase 미리보기가 배열 래퍼와 UUID가 아닌 그룹 ID를 거부한다', () async {
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
  });
}

const _token = '7K9MW3PXQ2RT';
