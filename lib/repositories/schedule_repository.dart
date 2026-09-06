import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/demo_identity.dart';
import '../core/invite_code_utils.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';

abstract class ScheduleRepository {
  Future<List<PlannerGroup>> groupsForUser(String userId);
  Future<List<PlannerMember>> membersForGroup(String groupId);
  Stream<List<PlannerEvent>> watchEvents(String groupId);
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  );
  Future<PlannerGroup> joinGroup(String userId, String inviteCode);
  Future<String> createInviteCode(String groupId);
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) async {
    final token = await createInviteCode(groupId);
    final now = DateTime.now().toUtc();
    return InviteCode(
      id: 'local-$groupId-${now.microsecondsSinceEpoch}',
      groupId: groupId,
      expiresAt: now.add(ttl),
      maxUses: maxUses,
      usesCount: 0,
      version: 1,
      token: token,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async =>
      const <InviteCode>[];
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) async => throw UnimplementedError();
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) async => throw UnimplementedError();
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  );
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  });
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  });
}

class ScheduleConflictException implements Exception {
  const ScheduleConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ScheduleValidationException implements Exception {
  const ScheduleValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 메모리 기반 미리보기 저장소다. Supabase URL과 공개 키가 없거나 초기화가
/// 실패해 설정 화면에 오류가 표시될 때만 선택되므로, 설정된 백엔드를
/// 실수로 가리지 않는다.
class LocalScheduleRepository implements ScheduleRepository {
  LocalScheduleRepository() {
    _seed();
  }

  final Map<String, PlannerGroup> _groups = <String, PlannerGroup>{};
  final Map<String, List<PlannerMember>> _members =
      <String, List<PlannerMember>>{};
  final Map<String, List<PlannerEvent>> _events =
      <String, List<PlannerEvent>>{};
  final Map<String, InviteCode> _invites = <String, InviteCode>{};
  final Map<String, StreamController<List<PlannerEvent>>> _controllers =
      <String, StreamController<List<PlannerEvent>>>{};
  int _counter = 0;

  void _seed() {
    const group = PlannerGroup(
      id: 'demo-group',
      name: '우리 가족',
      description: '함께 정리하는 한 주',
      timezone: 'Asia/Seoul',
      colorValue: 0xff477b76,
    );
    _groups[group.id] = group;
    _members[group.id] = <PlannerMember>[
      PlannerMember(
        id: demoUserId,
        name: demoUserName,
        email: demoUserEmail,
        isOwner: true,
        avatarColor: 0xff477b76,
      ),
      PlannerMember(
        id: 'member-jin',
        name: '진우',
        email: 'jin@example.com',
        avatarColor: 0xffb66d58,
      ),
      PlannerMember(
        id: 'member-soo',
        name: '수진',
        email: 'soo@example.com',
        avatarColor: 0xff8266a5,
      ),
    ];
    final now = DateTime.now();
    final monday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    _events[group.id] = <PlannerEvent>[
      PlannerEvent(
        id: 'event-1',
        groupId: group.id,
        title: '주간 장보기',
        note: '채소와 우유 챙기기',
        startAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day, 18),
          group.timezone,
        ),
        endAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day, 19),
          group.timezone,
        ),
        ownerId: demoUserId,
        memberIds: const <String>[demoUserId],
        colorValue: 0xff477b76,
        timezone: group.timezone,
      ),
      PlannerEvent(
        id: 'event-2',
        groupId: group.id,
        title: '치과 예약',
        startAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day + 2, 10, 30),
          group.timezone,
        ),
        endAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day + 2, 11, 30),
          group.timezone,
        ),
        ownerId: 'member-jin',
        memberIds: const <String>['member-jin'],
        colorValue: 0xff8266a5,
        timezone: group.timezone,
      ),
      PlannerEvent(
        id: 'event-3',
        groupId: group.id,
        title: '가족 영화의 밤',
        startAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day + 5),
          group.timezone,
        ),
        endAt: wallTimeToUtc(
          DateTime(monday.year, monday.month, monday.day + 6),
          group.timezone,
        ),
        allDay: true,
        ownerId: demoUserId,
        memberIds: const <String>[demoUserId],
        colorValue: 0xffb66d58,
        timezone: group.timezone,
        allDayStartDate: DateTime(monday.year, monday.month, monday.day + 5),
        allDayEndDate: DateTime(monday.year, monday.month, monday.day + 6),
      ),
    ];
  }

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    return List<PlannerGroup>.unmodifiable(_groups.values);
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return List<PlannerMember>.unmodifiable(
      (_members[groupId] ?? const <PlannerMember>[]).where(
        (member) => member.isActive,
      ),
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) {
    final controller = _controllers.putIfAbsent(
      groupId,
      () => StreamController<List<PlannerEvent>>.broadcast(),
    );
    scheduleMicrotask(() => controller.add(_visibleEvents(groupId)));
    return controller.stream;
  }

  List<PlannerEvent> _visibleEvents(String groupId) =>
      List<PlannerEvent>.unmodifiable(
        (_events[groupId] ?? const <PlannerEvent>[]).where(
          (event) => !event.isDeleted,
        ),
      );

  void _emit(String groupId) =>
      _controllers[groupId]?.add(_visibleEvents(groupId));

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  ) async {
    _validateGroup(name);
    _validateGroupDescription(description);
    final id = 'group-${DateTime.now().microsecondsSinceEpoch}';
    final group = PlannerGroup(
      id: id,
      name: name.trim(),
      description: description.trim(),
      timezone: 'Asia/Seoul',
      colorValue: 0xff477b76,
    );
    _groups[id] = group;
    _members[id] = <PlannerMember>[
      PlannerMember(
        id: ownerId,
        name: demoUserName,
        email: demoUserEmail,
        isOwner: true,
        avatarColor: 0xff477b76,
      ),
    ];
    _events[id] = <PlannerEvent>[];
    return group;
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    final code = normalizeInviteCode(inviteCode);
    final matchingInvite = _invites.values
        .where((invite) => normalizeInviteCode(invite.token ?? '') == code)
        .firstOrNull;
    final group = matchingInvite == null
        ? _groups.values.firstWhere(
            (candidate) =>
                candidate.id == inviteCode.trim() ||
                (candidate.id == 'demo-group' &&
                    code == normalizeInviteCode('family')),
            orElse: () => throw StateError('초대 코드를 찾을 수 없습니다.'),
          )
        : _groups[matchingInvite.groupId]!;
    if (matchingInvite != null &&
        (matchingInvite.isRevoked ||
            matchingInvite.isExpired ||
            matchingInvite.isExhausted)) {
      throw StateError('초대 코드가 만료되었거나 사용 횟수를 초과했습니다.');
    }
    final current = _members[group.id] ?? <PlannerMember>[];
    if (!current.any((member) => member.id == userId)) {
      current.add(
        PlannerMember(
          id: userId,
          name: demoUserName,
          email: demoUserEmail,
          avatarColor: 0xff477b76,
        ),
      );
      _members[group.id] = current;
    }
    if (matchingInvite != null) {
      final now = DateTime.now().toUtc();
      _invites[matchingInvite.id] = InviteCode(
        id: matchingInvite.id,
        groupId: matchingInvite.groupId,
        expiresAt: matchingInvite.expiresAt,
        maxUses: matchingInvite.maxUses,
        usesCount: matchingInvite.usesCount + 1,
        version: matchingInvite.version + 1,
        token: matchingInvite.token,
        revokedAt: matchingInvite.revokedAt,
        createdAt: matchingInvite.createdAt,
        updatedAt: now,
      );
    }
    return group;
  }

  @override
  Future<String> createInviteCode(String groupId) async {
    final invite = await createInviteCodeWithOptions(groupId);
    return invite.token!;
  }

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) async {
    if (!_groups.containsKey(groupId)) {
      throw StateError('그룹을 찾을 수 없습니다.');
    }
    if (maxUses < 1 || maxUses > 100000 || ttl <= Duration.zero) {
      throw const FormatException('초대 만료일과 사용 횟수를 확인해 주세요.');
    }
    final now = DateTime.now().toUtc();
    final id = 'invite-${now.microsecondsSinceEpoch}';
    final token =
        groupId == 'demo-group' &&
            !_invites.values.any((invite) => invite.groupId == groupId)
        ? 'family'
        : 'family-${now.microsecondsSinceEpoch}';
    final invite = InviteCode(
      id: id,
      groupId: groupId,
      expiresAt: now.add(ttl),
      maxUses: maxUses,
      usesCount: 0,
      version: 1,
      token: token,
      createdAt: now,
      updatedAt: now,
    );
    _invites[id] = invite;
    return invite;
  }

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async {
    return List<InviteCode>.unmodifiable(
      _invites.values.where((invite) => invite.groupId == groupId),
    );
  }

  @override
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) async {
    final invite = _invites[inviteId];
    if (invite == null) throw StateError('초대 코드를 찾을 수 없습니다.');
    final owner = _members[invite.groupId]
        ?.where((member) => member.isOwner)
        .firstOrNull;
    if (actorId != null && actorId != owner?.id) {
      throw const ScheduleConflictException('초대 코드를 취소할 권한이 없습니다.');
    }
    if (invite.version != expectedVersion || invite.isRevoked) {
      throw const ScheduleConflictException('초대 코드가 이미 변경되었거나 취소되었습니다.');
    }
    final now = DateTime.now().toUtc();
    final revoked = InviteCode(
      id: invite.id,
      groupId: invite.groupId,
      expiresAt: invite.expiresAt,
      maxUses: invite.maxUses,
      usesCount: invite.usesCount,
      version: invite.version + 1,
      token: invite.token,
      revokedAt: now,
      createdAt: invite.createdAt,
      updatedAt: now,
    );
    _invites[inviteId] = revoked;
    return revoked;
  }

  @override
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) async {
    final list = _members[groupId];
    if (list == null) throw StateError('그룹을 찾을 수 없습니다.');
    final owner = list.where((member) => member.isOwner).firstOrNull;
    if (actorId != null && actorId != owner?.id) {
      throw const ScheduleConflictException('멤버를 변경할 권한이 없습니다.');
    }
    if (userId == owner?.id) {
      throw const ScheduleConflictException('그룹 소유자는 제거할 수 없습니다.');
    }
    final index = list.indexWhere((member) => member.id == userId);
    if (index == -1) throw StateError('멤버를 찾을 수 없습니다.');
    final current = list[index];
    final updated = PlannerMember(
      id: current.id,
      name: current.name,
      email: current.email,
      isOwner: current.isOwner,
      isActive: isActive,
      removedAt: isActive
          ? null
          : (current.removedAt ?? DateTime.now().toUtc()),
      avatarColor: current.avatarColor,
    );
    list[index] = updated;
    return updated;
  }

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    _validateDraft(draft);
    if (!_groups.containsKey(groupId)) throw StateError('그룹을 찾을 수 없습니다.');
    final event = PlannerEvent(
      id: 'event-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
      groupId: groupId,
      title: draft.title.trim(),
      note: draft.note,
      startAt: draft.startAt.toUtc(),
      endAt: draft.endAt.toUtc(),
      allDay: draft.allDay,
      ownerId: userId,
      memberIds: List<String>.unmodifiable(draft.memberIds),
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      updatedAt: DateTime.now().toUtc(),
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
    );
    _events.putIfAbsent(groupId, () => <PlannerEvent>[]).add(event);
    _emit(groupId);
    return event;
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    _validateEvent(event);
    final list = _events[event.groupId];
    final index =
        list?.indexWhere((candidate) => candidate.id == event.id) ?? -1;
    if (list == null || index < 0) {
      throw StateError('일정을 찾을 수 없습니다.');
    }
    final existing = list[index];
    if (event.groupId != existing.groupId ||
        event.ownerId != existing.ownerId) {
      throw const ScheduleConflictException('일정의 그룹과 소유자는 변경할 수 없습니다.');
    }
    if (actorId != null && actorId != existing.ownerId) {
      throw const ScheduleConflictException('이 일정을 변경할 권한이 없습니다.');
    }
    if (existing.version != expectedVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    final updated = event.copyWith(
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
      memberIds: List<String>.unmodifiable(event.memberIds),
    );
    list[index] = updated;
    _emit(event.groupId);
    return updated;
  }

  @override
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  }) async {
    for (final entry in _events.entries) {
      final index = entry.value.indexWhere((event) => event.id == eventId);
      if (index == -1) continue;
      final existing = entry.value[index];
      if (actorId != null && actorId != existing.ownerId) {
        throw const ScheduleConflictException('이 일정을 삭제할 권한이 없습니다.');
      }
      if (existing.version != expectedVersion) {
        throw const ScheduleConflictException(
          '다른 사람이 이 일정을 변경했습니다. 삭제하지 않았어요.',
        );
      }
      entry.value[index] = existing.copyWith(
        version: existing.version + 1,
        updatedAt: DateTime.now().toUtc(),
        deletedAt: DateTime.now().toUtc(),
      );
      _emit(entry.key);
      return;
    }
    throw StateError('일정을 찾을 수 없습니다.');
  }

  static void _validateGroup(String name) {
    if (name.trim().isEmpty || name.trim().length > 160) {
      throw const FormatException('그룹 이름을 확인해 주세요.');
    }
  }

  static void _validateGroupDescription(String description) {
    if (description.trim().length > 10000) {
      throw const FormatException('그룹 설명을 확인해 주세요.');
    }
  }

  static void _validateDraft(EventDraft draft) {
    if (draft.title.trim().isEmpty ||
        draft.title.trim().length > 240 ||
        draft.note.trim().length > 10000 ||
        !draft.endAt.isAfter(draft.startAt)) {
      throw const FormatException('일정 제목과 시간을 확인해 주세요.');
    }
    _validateColorValue(draft.colorValue);
  }

  static void _validateEvent(PlannerEvent event) {
    if (event.title.trim().isEmpty ||
        event.title.trim().length > 240 ||
        event.note.trim().length > 10000 ||
        event.groupId.isEmpty ||
        event.ownerId.isEmpty ||
        !event.endAt.isAfter(event.startAt)) {
      throw const FormatException('일정 내용을 확인해 주세요.');
    }
    _validateColorValue(event.colorValue);
  }

  static void _validateColorValue(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const FormatException('일정 색상을 확인해 주세요.');
    }
  }
}

/// 릴리스 빌드에 원격 설정이 없을 때만 사용하는 일정 어댑터다. 시드된
/// 데모 일정방이나 일정을 노출하는 대신 모든 데이터 작업을 실패시킨다.
class ConfigurationBlockedScheduleRepository extends LocalScheduleRepository {
  ConfigurationBlockedScheduleRepository(this.message) : super();

  final String message;

  RuntimeConfigurationException get _error =>
      RuntimeConfigurationException(message);

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) =>
      Future<List<PlannerGroup>>.error(_error);

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) =>
      Future<List<PlannerMember>>.error(_error);

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) =>
      Stream<List<PlannerEvent>>.error(_error);

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  ) => Future<PlannerGroup>.error(_error);

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) =>
      Future<PlannerGroup>.error(_error);

  @override
  Future<String> createInviteCode(String groupId) =>
      Future<String>.error(_error);

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) => Future<InviteCode>.error(_error);

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) =>
      Future<List<InviteCode>>.error(_error);

  @override
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<InviteCode>.error(_error);

  @override
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) => Future<PlannerMember>.error(_error);

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) => Future<PlannerEvent>.error(_error);

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) => Future<PlannerEvent>.error(_error);

  @override
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  }) => Future<void>.error(_error);
}

/// 마이그레이션과 맞춘 운영용 저장소다. 멤버십, UTC `starts_at`/`ends_at`,
/// IANA 시간대와 버전 확인 RPC를 사용한다.
class SupabaseScheduleRepository implements ScheduleRepository {
  SupabaseScheduleRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    final rows = await _client
        .from('groups')
        .select(
          'id,name,description,timezone,version,memberships!inner(user_id,is_active)',
        )
        .eq('memberships.user_id', userId)
        .eq('memberships.is_active', true)
        .isFilter('deleted_at', null);
    return List<PlannerGroup>.unmodifiable(
      (rows as List).whereType<Map<String, dynamic>>().map(_groupFromRow),
    );
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async {
    // PostgREST는 여기서 profiles 임베드를 추론할 수 없다. memberships.user_id와
    // profiles.id는 모두 auth.users를 참조하지만 두 공개 테이블 사이에 직접
    // 연결된 외래 키가 없기 때문이다. 먼저 볼 수 있는 멤버십을 가져온 뒤
    // 400 오류를 만드는 임베드 대신 메모리에서 프로필 행을 결합한다.
    final membershipRows = await _client
        .from('memberships')
        .select('user_id,role,is_active,removed_at')
        .eq('group_id', groupId)
        .eq('is_active', true);
    final memberships = (membershipRows as List)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    if (memberships.isEmpty) return const <PlannerMember>[];
    final userIds = memberships
        .map((row) => row['user_id'])
        .whereType<String>()
        .toList(growable: false);
    if (userIds.isEmpty) return const <PlannerMember>[];
    final profileRows = await _client
        .from('profiles')
        .select('id,display_name')
        .inFilter('id', userIds);
    final profiles = <String, Map<String, dynamic>>{
      for (final row in (profileRows as List).whereType<Map<String, dynamic>>())
        if (row['id'] is String) row['id'] as String: row,
    };
    return List<PlannerMember>.unmodifiable(
      memberships.map(
        (row) => _memberFromRow(row, profile: profiles[row['user_id']]),
      ),
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) {
    return _client
        .from('events')
        .stream(primaryKey: const <String>['id'])
        .eq('group_id', groupId)
        .map(
          (rows) => List<PlannerEvent>.unmodifiable(
            rows.map(_eventFromRow).where((event) => !event.isDeleted),
          ),
        );
  }

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  ) async {
    LocalScheduleRepository._validateGroup(name);
    LocalScheduleRepository._validateGroupDescription(description);
    final row = await _client.rpc<dynamic>(
      'create_group',
      params: <String, dynamic>{
        'p_name': name.trim(),
        'p_timezone': 'Asia/Seoul',
        'p_description': description.trim(),
      },
    );
    final data = row is List ? row.first : row;
    if (data is! Map<String, dynamic>) {
      throw StateError('그룹을 만들 수 없습니다.');
    }
    return _groupFromRow(data);
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    final normalizedCode = normalizeInviteCode(inviteCode);
    if (normalizedCode.isEmpty) {
      throw const FormatException('초대 코드를 입력해 주세요.');
    }
    final result = await _client.rpc<dynamic>(
      'join_group_with_invite',
      params: <String, dynamic>{'p_token': normalizedCode},
    );
    final row = result is List
        ? (result.isEmpty ? null : result.first)
        : result;
    if (row is! Map<String, dynamic> ||
        row['group_id'] == null ||
        row['joined'] != true) {
      throw StateError('초대 코드가 만료되었거나 올바르지 않습니다.');
    }
    final group = await _client
        .from('groups')
        .select('id,name,description,timezone,version')
        .eq('id', row['group_id'])
        .single();
    return _groupFromRow(group);
  }

  @override
  Future<String> createInviteCode(String groupId) async {
    final invite = await createInviteCodeWithOptions(groupId);
    return invite.token!;
  }

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) async {
    if (maxUses < 1 || maxUses > 100000 || ttl <= Duration.zero) {
      throw const FormatException('초대 만료일과 사용 횟수를 확인해 주세요.');
    }
    final result = await _client.rpc<dynamic>(
      'create_invite_code',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_expires_at': DateTime.now().toUtc().add(ttl).toIso8601String(),
        'p_max_uses': maxUses,
      },
    );
    final row = result is List
        ? (result.isEmpty ? null : result.first)
        : result;
    if (row is! Map) throw StateError('초대 코드를 만들 수 없습니다.');
    final now = DateTime.now().toUtc();
    return _inviteFromRow(<String, dynamic>{
      ...row.cast<String, dynamic>(),
      'group_id': groupId,
      'token': row['token'],
      'expires_at': row['expires_at'] ?? now.add(ttl).toIso8601String(),
      'max_uses': row['max_uses'] ?? maxUses,
      'uses_count': row['uses_count'] ?? 0,
      'version': row['version'] ?? 1,
      'created_at': row['created_at'] ?? now.toIso8601String(),
      'updated_at': row['updated_at'] ?? now.toIso8601String(),
    });
  }

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async {
    final rows = await _client
        .from('invite_codes')
        .select(
          'id,group_id,expires_at,max_uses,uses_count,revoked_at,version,created_at,updated_at',
        )
        .eq('group_id', groupId)
        .order('created_at', ascending: false);
    return List<InviteCode>.unmodifiable(
      (rows as List).whereType<Map<String, dynamic>>().map(_inviteFromRow),
    );
  }

  @override
  Future<InviteCode> revokeInviteCode(
    String inviteId, {
    required int expectedVersion,
    String? actorId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'revoke_invite_code',
      params: <String, dynamic>{
        'p_invite_id': inviteId,
        'p_expected_version': expectedVersion,
      },
    );
    final row = result is List
        ? (result.isEmpty ? null : result.first)
        : result;
    if (row is! Map) {
      throw const ScheduleConflictException('초대 코드가 이미 변경되었거나 취소되었습니다.');
    }
    return _inviteFromRow(row.cast<String, dynamic>());
  }

  @override
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'set_member_active',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_user_id': userId,
        'p_is_active': isActive,
      },
    );
    final row = result is List
        ? (result.isEmpty ? null : result.first)
        : result;
    if (row is! Map) throw StateError('멤버 상태를 변경할 수 없습니다.');
    return PlannerMember(
      id: '${row['user_id'] ?? userId}',
      name: '${row['display_name'] ?? '멤버'}',
      email: '${row['email'] ?? ''}',
      isActive: row['is_active'] == true,
      removedAt: row['removed_at'] == null
          ? null
          : DateTime.tryParse('${row['removed_at']}')?.toUtc(),
    );
  }

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    LocalScheduleRepository._validateDraft(draft);
    final payload = <String, dynamic>{
      'group_id': groupId,
      'created_by': userId,
      'title': draft.title.trim(),
      'description': draft.note.trim(),
      'color_value': draft.colorValue,
      'starts_at': draft.startAt.toUtc().toIso8601String(),
      'ends_at': draft.endAt.toUtc().toIso8601String(),
      'timezone': draft.timezone,
      'is_all_day': draft.allDay,
      'version': 1,
    };
    if (draft.allDay) {
      payload['all_day_start'] = _dateString(
        draft.allDayStartDate ?? draft.startAt,
      );
      payload['all_day_end'] = _dateString(draft.allDayEndDate ?? draft.endAt);
    }
    final row = await _client.from('events').insert(payload).select().single();
    return _eventFromRow(row);
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    LocalScheduleRepository._validateEvent(event);
    if (actorId != null && actorId != event.ownerId) {
      throw const ScheduleConflictException('이 일정을 변경할 권한이 없습니다.');
    }
    final payload = <String, dynamic>{
      'title': event.title.trim(),
      'description': event.note.trim(),
      'color_value': event.colorValue,
      'starts_at': event.startAt.toUtc().toIso8601String(),
      'ends_at': event.endAt.toUtc().toIso8601String(),
      'timezone': event.timezone,
      'is_all_day': event.allDay,
      'version': expectedVersion + 1,
    };
    if (event.allDay) {
      payload['all_day_start'] = _dateString(
        event.allDayStartDate ?? event.startAt,
      );
      payload['all_day_end'] = _dateString(event.allDayEndDate ?? event.endAt);
    } else {
      payload['all_day_start'] = null;
      payload['all_day_end'] = null;
    }
    var query = _client
        .from('events')
        .update(payload)
        .eq('id', event.id)
        .eq('group_id', event.groupId)
        .eq('created_by', event.ownerId)
        .eq('version', expectedVersion);
    final rows = await query.select();
    final list = (rows as List).whereType<Map<String, dynamic>>().toList();
    if (list.isEmpty) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    return _eventFromRow(list.first);
  }

  @override
  Future<void> softDeleteEvent(
    String eventId, {
    required int expectedVersion,
    String? actorId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'soft_delete_event_if_version',
      params: <String, dynamic>{
        'p_event_id': eventId,
        'p_expected_version': expectedVersion,
      },
    );
    if (result == null || (result is List && result.isEmpty)) {
      throw const ScheduleConflictException('일정이 이미 변경되었거나 권한이 없습니다.');
    }
  }

  PlannerGroup _groupFromRow(Map<String, dynamic> row) => PlannerGroup(
    id: '${row['id']}',
    name: '${row['name'] ?? '그룹'}',
    description: '${row['description'] ?? ''}',
    timezone: '${row['timezone'] ?? 'UTC'}',
    version: _intValue(row['version'], 1),
  );

  PlannerMember _memberFromRow(
    Map<String, dynamic> row, {
    Map<String, dynamic>? profile,
  }) {
    final embeddedProfile = row['profiles'] is Map
        ? (row['profiles'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final profileData = profile ?? embeddedProfile;
    return PlannerMember(
      id: '${row['user_id']}',
      name: '${profileData['display_name'] ?? '멤버'}',
      email: '',
      isOwner: row['role'] == 'owner',
      isActive: row['is_active'] != false,
      removedAt: row['removed_at'] == null
          ? null
          : DateTime.tryParse('${row['removed_at']}')?.toUtc(),
    );
  }

  InviteCode _inviteFromRow(Map<String, dynamic> row) => InviteCode(
    id: '${row['id'] ?? row['invite_id']}',
    groupId: '${row['group_id']}',
    expiresAt: DateTime.parse('${row['expires_at']}').toUtc(),
    maxUses: _intValue(row['max_uses'], 1),
    usesCount: _intValue(row['uses_count'], 0),
    version: _intValue(row['version'], 1),
    token: row['token'] as String?,
    revokedAt: row['revoked_at'] == null
        ? null
        : DateTime.tryParse('${row['revoked_at']}')?.toUtc(),
    createdAt: DateTime.tryParse('${row['created_at']}')?.toUtc(),
    updatedAt: DateTime.tryParse('${row['updated_at']}')?.toUtc(),
  );

  PlannerEvent _eventFromRow(Map<String, dynamic> row) => PlannerEvent(
    id: '${row['id']}',
    groupId: '${row['group_id']}',
    title: '${row['title'] ?? ''}',
    note: '${row['description'] ?? ''}',
    startAt: DateTime.parse('${row['starts_at']}').toUtc(),
    endAt: DateTime.parse('${row['ends_at']}').toUtc(),
    allDay: row['is_all_day'] == true,
    ownerId: '${row['created_by']}',
    memberIds: <String>['${row['created_by']}'],
    colorValue: _colorValue(row['color_value'], 0xff477b76),
    timezone: '${row['timezone'] ?? 'UTC'}',
    version: _intValue(row['version'], 1),
    allDayStartDate: _parseDate(row['all_day_start']),
    allDayEndDate: _parseDate(row['all_day_end']),
    updatedAt: DateTime.tryParse('${row['updated_at']}')?.toUtc(),
    deletedAt: row['deleted_at'] == null
        ? null
        : DateTime.tryParse('${row['deleted_at']}')?.toUtc(),
  );

  static int _intValue(Object? value, int fallback) =>
      value is int ? value : int.tryParse('$value') ?? fallback;
  static int _colorValue(Object? value, int fallback) {
    final parsed = _intValue(value, fallback);
    return parsed >= 0 && parsed <= 0xffffffff ? parsed : fallback;
  }

  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    final parts = '$value'.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
