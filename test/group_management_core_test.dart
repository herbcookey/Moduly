// 앱은 이미 supabase_flutter를 통해 http에 의존한다. 이 테스트는 해당 전이
// 패키지를 런타임 의존성으로 승격하지 않고 결정적인 전송 계층을 주입한다.
// ignore_for_file: depend_on_referenced_packages, use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

const _owner = PlannerUser(id: 'owner', email: 'owner@example.com');

class _RpcResponseClient extends http.BaseClient {
  _RpcResponseClient(this.payload);

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

class _LifecycleReadClient extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = request.url.path;
    final wantsSingle = request.headers.values.any(
      (value) => value.contains('vnd.pgrst.object'),
    );
    Object payload;
    if (path.endsWith('/memberships')) {
      payload = <String, dynamic>{
        'user_id': 'user-1',
        'is_active': true,
        'removed_at': null,
      };
      if (!wantsSingle) payload = <Object?>[payload];
    } else if (path.endsWith('/groups')) {
      final row = _rpcGroupRow(id: 'other-group');
      payload = wantsSingle ? row : <Object?>[row];
    } else {
      payload = const <Object?>[];
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
      request: request,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

SupabaseClient _rpcClient(http.BaseClient httpClient) => SupabaseClient(
  'https://example.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
  httpClient: httpClient,
);

Map<String, dynamic> _rpcGroupRow({
  String id = 'group-1',
  String ownerId = 'owner',
  int version = 2,
  Object? deletedAt,
  Object? archivedAt,
}) => <String, dynamic>{
  'id': id,
  'owner_id': ownerId,
  'name': 'Group',
  'description': 'Description',
  'timezone': 'UTC',
  'version': version,
  'deleted_at': deletedAt,
  if (archivedAt != null) 'archived_at': archivedAt,
};

void main() {
  group('그룹 모델 및 시간대 검증', () {
    test('PlannerGroup copyWith가 수명 주기 필드와 동등성을 유지한다', () {
      final archivedAt = DateTime.utc(2026, 9, 7, 1);
      final group = PlannerGroup(
        id: 'g',
        name: 'Name',
        description: 'Description',
        timezone: 'UTC',
        version: 3,
        ownerId: 'owner',
        archivedAt: archivedAt,
      );
      final copy = group.copyWith();
      expect(copy, equals(group));
      expect(copy.hashCode, group.hashCode);
      expect(copy.copyWith(name: 'New').name, 'New');
      expect(copy.copyWith(clearArchivedAt: true).archivedAt, isNull);
      expect(copy.isArchived, isTrue);
    });

    test('정확한 IANA 이름을 허용하고 공백이나 알 수 없는 이름을 거부한다', () {
      expect(isValidIanaTimezone('America/Los_Angeles'), isTrue);
      expect(isValidIanaTimezone('UTC'), isTrue);
      expect(isValidIanaTimezone(' America/Los_Angeles'), isFalse);
      expect(isValidIanaTimezone('Not/A_Timezone'), isFalse);
      expect(
        () => validateIanaTimezone('Not/A_Timezone'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('LocalScheduleRepository 그룹 수명 주기', () {
    test('선택한 시간대를 만들고 활성 멤버십을 기준으로 필터링한다', () async {
      final repository = LocalScheduleRepository();
      final group = await repository.createGroup(
        _owner.id,
        'New',
        '',
        timezone: 'America/Los_Angeles',
      );
      expect(group.timezone, 'America/Los_Angeles');
      expect((await repository.groupsForUser(_owner.id)), contains(group));
      expect((await repository.groupsForUser('not-a-member')), isEmpty);
      await expectLater(
        repository.createGroup(
          _owner.id,
          'Bad',
          '',
          timezone: 'Not/A_Timezone',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('소유자만 수정하고 오래된 버전을 거부한다', () async {
      final repository = LocalScheduleRepository();
      final group = await repository.createGroup(_owner.id, 'Before', '');
      final updated = await repository.updateGroupIfVersion(
        actorId: _owner.id,
        groupId: group.id,
        name: 'After',
        description: 'Details',
        timezone: 'UTC',
        expectedVersion: group.version,
      );
      expect(updated.version, group.version + 1);
      expect(updated.name, 'After');
      await expectLater(
        repository.updateGroupIfVersion(
          actorId: _owner.id,
          groupId: group.id,
          name: 'Stale',
          description: '',
          timezone: 'UTC',
          expectedVersion: group.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      await expectLater(
        repository.updateGroupIfVersion(
          actorId: 'other',
          groupId: group.id,
          name: 'Spoof',
          description: '',
          timezone: 'UTC',
          expectedVersion: updated.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('일반 멤버는 탈퇴할 수 있지만 소유자는 탈퇴할 수 없다', () async {
      final repository = LocalScheduleRepository();
      final group = await repository.createGroup(_owner.id, 'Group', '');
      final invite = await repository.createInviteCodeWithOptions(group.id);
      await repository.joinGroup('member', invite.token!);
      expect((await repository.groupsForUser('member')), contains(group));
      await repository.leaveGroup(actorId: 'member', groupId: group.id);
      expect((await repository.groupsForUser('member')), isEmpty);
      expect(
        (await repository.membersForGroup(
          group.id,
        )).any((member) => member.id == 'member'),
        isFalse,
      );
      await expectLater(
        repository.leaveGroup(actorId: _owner.id, groupId: group.id),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('한 명의 활성 소유자에게 원자적으로 이전한다', () async {
      final repository = LocalScheduleRepository();
      final group = await repository.createGroup(_owner.id, 'Group', '');
      final invite = await repository.createInviteCodeWithOptions(group.id);
      await repository.joinGroup('member', invite.token!);
      final transferred = await repository.transferGroupOwnership(
        actorId: _owner.id,
        groupId: group.id,
        newOwnerId: 'member',
        expectedVersion: group.version,
      );
      expect(transferred.ownerId, 'member');
      final members = await repository.membersForGroup(group.id);
      expect(members.where((member) => member.isOwner), hasLength(1));
      expect(members.singleWhere((member) => member.isOwner).id, 'member');
      await expectLater(
        repository.transferGroupOwnership(
          actorId: 'member',
          groupId: group.id,
          newOwnerId: _owner.id,
          expectedVersion: group.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      await expectLater(
        repository.transferGroupOwnership(
          actorId: _owner.id,
          groupId: group.id,
          newOwnerId: 'member',
          expectedVersion: transferred.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('보관이 종료 상태이며 그룹, 일정, 초대를 걸러낸다', () async {
      final repository = LocalScheduleRepository();
      final group = await repository.createGroup(_owner.id, 'Group', '');
      await repository.createInviteCodeWithOptions(group.id);
      await repository.createEvent(
        _owner.id,
        group.id,
        EventDraft(
          title: 'Event',
          startAt: DateTime.utc(2026, 9, 7, 9),
          endAt: DateTime.utc(2026, 9, 7, 10),
        ),
      );
      final stream = repository.watchEvents(group.id);
      final visibleEvents = <List<PlannerEvent>>[];
      final subscription = stream.listen(visibleEvents.add);
      await Future<void>.delayed(Duration.zero);
      final archivedVersion = await repository.archiveGroupIfVersion(
        actorId: _owner.id,
        groupId: group.id,
        expectedVersion: group.version,
      );
      expect(archivedVersion, group.version + 1);
      expect(await repository.groupsForUser(_owner.id), isEmpty);
      expect(await repository.membersForGroup(group.id), isEmpty);
      expect(await repository.inviteCodesForGroup(group.id), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(visibleEvents.last, isEmpty);
      await subscription.cancel();
      await expectLater(
        repository.archiveGroupIfVersion(
          actorId: _owner.id,
          groupId: group.id,
          expectedVersion: group.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });
  });

  test('Supabase 그룹 RPC 페이로드에 사용자 위조 필드가 포함되지 않는다', () {
    final source = File(
      'lib/repositories/schedule_repository.dart',
    ).readAsStringSync();
    expect(source, contains("'update_group_if_version'"));
    expect(source, contains("'leave_group'"));
    expect(source, contains("'transfer_group_ownership'"));
    expect(source, contains("'archive_group_if_version'"));
    expect(source, isNot(contains("'p_actor_id'")));
  });

  group('Supabase 낙관적 그룹 RPC 응답 검증', () {
    test('갱신이 완전한 활성 행 하나를 허용하고 다시 조회하지 않는다', () async {
      final transport = _RpcResponseClient(_rpcGroupRow());
      final client = _rpcClient(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      final updated = await repository.updateGroupIfVersion(
        actorId: _owner.id,
        groupId: 'group-1',
        name: 'Group',
        description: 'Description',
        timezone: 'UTC',
        expectedVersion: 1,
      );
      expect(updated.id, 'group-1');
      expect(updated.version, 2);
      expect(
        transport.requests.where(
          (request) => request.url.path.contains('/groups'),
        ),
        isEmpty,
      );
    });

    test('갱신 응답 행에 현재 소유자가 있어야 한다', () async {
      final transport = _RpcResponseClient(
        _rpcGroupRow(ownerId: 'different-owner'),
      );
      final client = _rpcClient(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.updateGroupIfVersion(
          actorId: _owner.id,
          groupId: 'group-1',
          name: 'Group',
          description: 'Description',
          timezone: 'UTC',
          expectedVersion: 1,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );

      final missingOwner = <String, dynamic>{..._rpcGroupRow()}
        ..remove('owner_id');
      transport.payload = missingOwner;
      await expectLater(
        repository.updateGroupIfVersion(
          actorId: _owner.id,
          groupId: 'group-1',
          name: 'Group',
          description: 'Description',
          timezone: 'UTC',
          expectedVersion: 1,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      expect(
        transport.requests.where(
          (request) => request.url.path.contains('/groups'),
        ),
        isEmpty,
      );
    });

    test('이전 응답 행에 대상 소유자가 있어야 한다', () async {
      final transport = _RpcResponseClient(
        _rpcGroupRow(ownerId: 'other-owner'),
      );
      final client = _rpcClient(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      await expectLater(
        repository.transferGroupOwnership(
          actorId: _owner.id,
          groupId: 'group-1',
          newOwnerId: 'new-owner',
          expectedVersion: 1,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      expect(
        transport.requests.where(
          (request) => request.url.path.contains('/groups'),
        ),
        isEmpty,
      );
    });

    test('이전이 요청한 소유자의 완전한 활성 행을 허용한다', () async {
      final transport = _RpcResponseClient(_rpcGroupRow(ownerId: 'new-owner'));
      final client = _rpcClient(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      final transferred = await repository.transferGroupOwnership(
        actorId: _owner.id,
        groupId: 'group-1',
        newOwnerId: 'new-owner',
        expectedVersion: 1,
      );
      expect(transferred.ownerId, 'new-owner');
      expect(transferred.version, 2);
    });

    test('빈 행, 여러 행, 불완전함, 오래됨, 보관됨 응답은 충돌 처리된다', () async {
      final transport = _RpcResponseClient(<String, dynamic>{});
      final client = _rpcClient(transport);
      final repository = SupabaseScheduleRepository(client);
      addTearDown(client.dispose);

      final malformed = <Object?>[
        null,
        const <Object?>[],
        <Object?>[_rpcGroupRow(), _rpcGroupRow()],
        <String, dynamic>{..._rpcGroupRow(), 'description': null},
        _rpcGroupRow(id: 'other-group'),
        _rpcGroupRow(version: 1),
        _rpcGroupRow()..['version'] = 2.5,
        _rpcGroupRow(deletedAt: '2026-09-07T00:00:00Z'),
        _rpcGroupRow(archivedAt: '2026-09-07T00:00:00Z'),
      ];
      for (final payload in malformed) {
        transport.payload = payload;
        await expectLater(
          repository.updateGroupIfVersion(
            actorId: _owner.id,
            groupId: 'group-1',
            name: 'Group',
            description: 'Description',
            timezone: 'UTC',
            expectedVersion: 1,
          ),
          throwsA(isA<ScheduleConflictException>()),
        );
      }
      expect(
        transport.requests.where(
          (request) => request.url.path.contains('/groups'),
        ),
        isEmpty,
      );
    });
  });

  test('수명 주기 읽기가 다른 그룹의 행을 거부한다', () async {
    final transport = _LifecycleReadClient();
    final client = _rpcClient(transport);
    final repository = SupabaseScheduleRepository(
      client,
      lifecyclePollInterval: const Duration(hours: 1),
    );
    addTearDown(client.dispose);
    final values = <PlannerGroup?>[];
    final errors = <Object>[];
    final subscription = repository
        .watchGroupLifecycle('user-1', 'requested-group')
        .listen(values.add, onError: (Object error) => errors.add(error));
    addTearDown(subscription.cancel);

    // Realtime 스트림도 초기 투영 읽기를 수행하므로 주입된 전송 계층의 고정된
    // 요청 순서를 가정하지 말고 권위 있는 검사가 끝날 때까지 기다린다.
    for (
      var attempt = 0;
      attempt < 20 && errors.whereType<StateError>().isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(errors.whereType<StateError>(), isNotEmpty);
    expect(values, isEmpty);
  });

  test('컨트롤러가 중복 편집을 거부하고 오래된 완료를 버린다', () async {
    final auth = _StaticAuth(_owner);
    final repository = _ControllerRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    controller.user = _owner;
    controller.groups = <PlannerGroup>[repository.group];
    controller.selectedGroup = repository.group;
    controller.members = <PlannerMember>[
      PlannerMember(
        id: _owner.id,
        name: 'Owner',
        email: _owner.email,
        isOwner: true,
      ),
    ];

    final pending = Completer<PlannerGroup>();
    repository.updateLoad = pending;
    final first = controller.updateGroup(
      name: 'Edited',
      description: '',
      timezone: 'UTC',
    );
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      controller.updateGroup(
        name: 'Duplicate',
        description: '',
        timezone: 'UTC',
      ),
      throwsA(isA<ScheduleConflictException>()),
    );
    await controller.signOut();
    pending.complete(repository.group.copyWith(name: 'Stale', version: 2));
    await first;
    expect(controller.user, isNull);
    expect(controller.selectedGroup, isNull);
    expect(controller.groups, isEmpty);
    expect(controller.isSaving, isFalse);
  });

  test('충돌 다시 불러오기가 같은 컨텍스트의 최신 작업 오류를 덮어쓰지 않는다', () async {
    final auth = _NullAuth();
    final repository = _ConflictReloadRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    controller.user = _owner;
    controller.groups = <PlannerGroup>[repository.group];
    controller.selectedGroup = repository.group;
    controller.members = <PlannerMember>[
      PlannerMember(
        id: _owner.id,
        name: 'Owner',
        email: _owner.email,
        isOwner: true,
      ),
    ];

    final first = controller.updateGroup(
      name: 'Edited',
      description: '',
      timezone: 'UTC',
      expectedVersion: repository.group.version,
    );
    // 충돌 처리기가 제어된 그룹 새로 고침에 진입하게 한다.
    await Future<void>.delayed(Duration.zero);
    expect(repository.groupReads, 1);

    await expectLater(
      controller.updateDisplayName('New display name'),
      throwsA(isA<AuthException>()),
    );
    expect(controller.errorMessage, '이름을 변경할 계정이 없습니다.');

    repository.releaseReload.complete();
    await expectLater(first, throwsA(isA<ScheduleConflictException>()));
    // 이전 충돌 다시 불러오기 후속 작업이 끝난 뒤에도 새 작업의 진단 메시지가
    // 계속 표시된다.
    expect(controller.errorMessage, '이름을 변경할 계정이 없습니다.');
  });

  test('초대 완료가 수명 주기로 새로 고친 행을 중복하지 않고 교체한다', () async {
    final auth = _NullAuth();
    final repository = _InviteRaceRepository();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    controller.user = _owner;
    controller.groups = <PlannerGroup>[repository.group];
    controller.selectedGroup = repository.group;
    controller.members = <PlannerMember>[
      const PlannerMember(
        id: 'owner',
        name: 'Owner',
        email: 'owner@example.com',
        isOwner: true,
      ),
    ];

    // 생성 RPC가 아직 진행 중인 동안 동시에 실행된 수명 주기 메타데이터
    // 새로 고침이 이미 삽입한 행이다.
    controller.invites = <InviteCode>[repository.lifecycleInvite];
    final creation = controller.createInviteCode();
    await Future<void>.delayed(Duration.zero);
    repository.release.complete(repository.mutationInvite);

    final returned = await creation;
    expect(returned.id, repository.lifecycleInvite.id);
    expect(
      controller.invites.where((invite) => invite.id == returned.id),
      hasLength(1),
    );
    // 생성 RPC는 평문을 한 번 반환할 수 있지만 컨트롤러 목록 상태는 항상
    // 정제된 복사본이므로 이후 새로 고침에서 토큰을 노출할 수 없다.
    expect(controller.invites.single.token, isNull);
    expect(controller.invites.single.id, returned.id);
    expect(controller.invites.single.groupId, returned.groupId);
    expect(controller.invites.single.expiresAt, returned.expiresAt);
    expect(controller.invites.single.maxUses, returned.maxUses);
    expect(controller.invites.single.usesCount, returned.usesCount);
    expect(controller.invites.single.version, returned.version);
    expect(controller.invites.single.revokedAt, returned.revokedAt);
    expect(controller.invites.single.createdAt, returned.createdAt);
    expect(controller.invites.single.updatedAt, returned.updatedAt);
    expect(
      controller.invites.single.version,
      repository.mutationInvite.version,
    );
  });
}

class _StaticAuth extends AuthRepository {
  _StaticAuth(this._user) : super();
  final PlannerUser _user;

  @override
  PlannerUser? get currentUser => _user;
}

class _NullAuth extends AuthRepository {
  _NullAuth() : super();

  @override
  PlannerUser? get currentUser => null;

  @override
  Future<PlannerUser> updateDisplayName(String displayName) =>
      Future<PlannerUser>.error(const AuthException('이름을 변경할 계정이 없습니다.'));
}

class _ConflictReloadRepository extends LocalScheduleRepository {
  final PlannerGroup group = const PlannerGroup(
    id: 'conflict-reload-group',
    name: 'Group',
    timezone: 'UTC',
    version: 1,
    ownerId: 'owner',
  );
  final Completer<void> releaseReload = Completer<void>();
  var groupReads = 0;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    groupReads += 1;
    // 테스트가 컨트롤러 상태를 직접 시드하므로 이 첫 읽기는 충돌이 일으킨 다시
    // 불러오기다. 새 작업이 진단 메시지를 설정할 때까지 대기 상태로 둔다.
    if (groupReads >= 1) await releaseReload.future;
    return userId == group.ownerId
        ? <PlannerGroup>[group.copyWith(version: 2)]
        : const <PlannerGroup>[];
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      <PlannerMember>[
        const PlannerMember(
          id: 'owner',
          name: 'Owner',
          email: 'owner@example.com',
          isOwner: true,
        ),
      ];

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(
    String userId,
    String groupId,
  ) => const Stream<List<PlannerEvent>>.empty();

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) =>
      const Stream<PlannerGroup?>.empty();

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) => Future<PlannerGroup>.error(
    const ScheduleConflictException('최신 그룹 정보가 있어요. 다시 확인해 주세요.'),
  );
}

class _InviteRaceRepository extends LocalScheduleRepository {
  final PlannerGroup group = const PlannerGroup(
    id: 'invite-race-group',
    name: 'Group',
    timezone: 'UTC',
    version: 1,
    ownerId: 'owner',
  );
  final Completer<InviteCode> release = Completer<InviteCode>();
  final InviteCode lifecycleInvite = InviteCode(
    id: 'invite-race-id',
    groupId: 'invite-race-group',
    expiresAt: DateTime.utc(2026, 9, 14),
    maxUses: 20,
    usesCount: 1,
    version: 1,
    createdAt: DateTime.utc(2026, 9, 7),
    updatedAt: DateTime.utc(2026, 9, 7),
  );
  final InviteCode mutationInvite = InviteCode(
    id: 'invite-race-id',
    groupId: 'invite-race-group',
    expiresAt: DateTime.utc(2026, 9, 21),
    maxUses: 20,
    usesCount: 0,
    version: 2,
    token: 'fresh-token',
    createdAt: DateTime.utc(2026, 9, 7),
    updatedAt: DateTime.utc(2026, 9, 7, 1),
  );

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) => release.future;
}

class _ControllerRepository extends LocalScheduleRepository {
  final PlannerGroup group = const PlannerGroup(
    id: 'controller-group',
    name: 'Group',
    timezone: 'UTC',
    ownerId: 'owner',
  );
  Completer<PlannerGroup>? updateLoad;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    return userId == 'owner' ? <PlannerGroup>[group] : const <PlannerGroup>[];
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      <PlannerMember>[
        PlannerMember(
          id: 'owner',
          name: 'Owner',
          email: 'owner@example.com',
          isOwner: true,
        ),
      ];

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) =>
      Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async {
    final pending = updateLoad;
    if (pending != null) return pending.future;
    return group.copyWith(name: name, version: expectedVersion + 1);
  }
}
