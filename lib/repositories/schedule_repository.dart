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

  /// Legacy three-positional creation contract. Implementations that support
  /// caller-selected timezones additionally implement
  /// [TimezoneGroupCreationCapability] below. Keeping this signature narrow
  /// means existing test/fake repositories continue to compile unchanged.
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  );

  /// Updates the selected group under an optimistic-lock version check. The
  /// actor is a local authorization hint for the preview adapter; the
  /// Supabase adapter derives identity from auth.uid and never serializes it.
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async => Future<PlannerGroup>.error(
    const ScheduleCapabilityException('그룹 편집을 지원하지 않는 저장소입니다.'),
  );

  /// Removes the calling user's active membership. Owners must transfer
  /// ownership before leaving. Implementations derive actor identity from the
  /// local argument or auth.uid as appropriate.
  Future<void> leaveGroup({
    required String actorId,
    required String groupId,
  }) async => Future<void>.error(
    const ScheduleCapabilityException('그룹 나가기를 지원하지 않는 저장소입니다.'),
  );

  Future<PlannerGroup> transferGroupOwnership({
    required String actorId,
    required String groupId,
    required String newOwnerId,
    required int expectedVersion,
  }) async => Future<PlannerGroup>.error(
    const ScheduleCapabilityException('그룹 소유권 이전을 지원하지 않는 저장소입니다.'),
  );

  /// Archives the group and returns the new terminal version. Archived groups
  /// are omitted from membership/group reads and cannot be restored.
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) async => Future<int>.error(
    const ScheduleCapabilityException('그룹 보관을 지원하지 않는 저장소입니다.'),
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
  }) async => Future<InviteCode>.error(
    const ScheduleCapabilityException('초대 코드 취소를 지원하지 않는 저장소입니다.'),
  );
  Future<PlannerMember> setMemberActive(
    String groupId,
    String userId,
    bool isActive, {
    String? actorId,
  }) async => Future<PlannerMember>.error(
    const ScheduleCapabilityException('멤버 상태 변경을 지원하지 않는 저장소입니다.'),
  );
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

/// Optional capability for repositories that can persist an exact caller
/// selected IANA timezone while retaining the legacy [ScheduleRepository]
/// creation method for external implementations.
abstract interface class TimezoneGroupCreationCapability {
  Future<PlannerGroup> createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  });
}

/// Optional capability used by the controller for reads that must be scoped
/// to the requester's active membership. The legacy [watchEvents] method is
/// retained for old test doubles only; production adapters implement this
/// interface and are always selected by [PlannerController].
abstract interface class UserScopedEventReadCapability {
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId);
}

/// Optional lifecycle stream for remote membership/group invalidation. A null
/// or archived value means the selected group is no longer usable.
abstract interface class GroupLifecycleCapability {
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId);
}

class ScheduleConflictException implements Exception {
  const ScheduleConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Raised when a repository implementation is intentionally unable to expose
/// a mutating capability. This is distinct from a successful no-op and keeps
/// fakes/configuration-blocked adapters honest.
class ScheduleCapabilityException implements Exception {
  const ScheduleCapabilityException(this.message);
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
class LocalScheduleRepository
    implements
        ScheduleRepository,
        TimezoneGroupCreationCapability,
        UserScopedEventReadCapability,
        GroupLifecycleCapability {
  LocalScheduleRepository({Iterable<PlannerMember> seedMembers = const []}) {
    _seed(seedMembers);
  }

  final Map<String, PlannerGroup> _groups = <String, PlannerGroup>{};
  final Map<String, List<PlannerMember>> _members =
      <String, List<PlannerMember>>{};
  final Map<String, List<PlannerEvent>> _events =
      <String, List<PlannerEvent>>{};
  final Map<String, InviteCode> _invites = <String, InviteCode>{};
  final Map<String, StreamController<List<PlannerEvent>>> _controllers =
      <String, StreamController<List<PlannerEvent>>>{};
  final Map<String, Map<String, StreamController<List<PlannerEvent>>>>
  _userControllers =
      <String, Map<String, StreamController<List<PlannerEvent>>>>{};
  final Map<String, Map<String, StreamController<PlannerGroup?>>>
  _groupControllers = <String, Map<String, StreamController<PlannerGroup?>>>{};
  int _counter = 0;

  void _seed(Iterable<PlannerMember> seedMembers) {
    const group = PlannerGroup(
      id: 'demo-group',
      name: '우리 가족',
      description: '함께 정리하는 한 주',
      timezone: 'Asia/Seoul',
      colorValue: 0xff477b76,
      ownerId: demoUserId,
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
      ...seedMembers.where(
        (member) =>
            member.id != demoUserId &&
            member.id != 'member-jin' &&
            member.id != 'member-soo',
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
    return List<PlannerGroup>.unmodifiable(
      _groups.values.where(
        (group) =>
            !group.isArchived &&
            (_members[group.id] ?? const <PlannerMember>[]).any(
              (member) => member.id == userId && member.isActive,
            ),
      ),
    );
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final group = _groups[groupId];
    if (group == null || group.isArchived) return const <PlannerMember>[];
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

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId) {
    if (userId.trim().isEmpty) {
      return Stream<List<PlannerEvent>>.error(
        const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.'),
      );
    }
    // Keep the requester gate in the stream transformation itself so it is
    // reevaluated for every realtime emission (membership deactivation and
    // archive both emit through [watchEvents]). Calling the legacy method via
    // dynamic dispatch also preserves compatibility with existing local test
    // doubles that override only `watchEvents`.
    return watchEvents(groupId).map(
      (incoming) => _isActiveMember(groupId, userId)
          ? List<PlannerEvent>.unmodifiable(incoming)
          : const <PlannerEvent>[],
    );
  }

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) {
    if (userId.trim().isEmpty) {
      return Stream<PlannerGroup?>.error(
        const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.'),
      );
    }
    final byUser = _groupControllers.putIfAbsent(
      groupId,
      () => <String, StreamController<PlannerGroup?>>{},
    );
    final controller = byUser.putIfAbsent(
      userId,
      () => StreamController<PlannerGroup?>.broadcast(),
    );
    scheduleMicrotask(() {
      final group = _groups[groupId];
      // A manually seeded/legacy test double may expose a group through its
      // own `groups` list without registering it in this in-memory adapter.
      // There is no lifecycle fact to publish for an unknown id; reserve the
      // null marker for a known group whose membership has become unusable.
      if (group == null) return;
      controller.add(_isActiveMember(groupId, userId) ? group : null);
    });
    return controller.stream;
  }

  List<PlannerEvent> _visibleEvents(String groupId) =>
      List<PlannerEvent>.unmodifiable(
        _groups[groupId]?.isArchived == true
            ? const <PlannerEvent>[]
            : (_events[groupId] ?? const <PlannerEvent>[]).where(
                (event) => !event.isDeleted,
              ),
      );

  List<PlannerEvent> _visibleEventsForUser(String userId, String groupId) {
    if (!_isActiveMember(groupId, userId)) {
      return const <PlannerEvent>[];
    }
    return _visibleEvents(groupId);
  }

  void _emit(String groupId) {
    _controllers[groupId]?.add(_visibleEvents(groupId));
    final byUser = _userControllers[groupId];
    if (byUser != null) {
      for (final entry in byUser.entries) {
        entry.value.add(_visibleEventsForUser(entry.key, groupId));
      }
    }
  }

  void _emitGroupLifecycle(String groupId) {
    final byUser = _groupControllers[groupId];
    if (byUser == null) return;
    final group = _groups[groupId];
    for (final entry in byUser.entries) {
      entry.value.add(
        _isActiveMember(groupId, entry.key) && group != null ? group : null,
      );
    }
  }

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description, {
    String timezone = defaultPlannerTimezone,
  }) => createGroupWithTimezone(ownerId, name, description, timezone: timezone);

  @override
  Future<PlannerGroup> createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  }) async {
    _validateGroup(name);
    _validateGroupDescription(description);
    validateIanaTimezone(timezone);
    if (ownerId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    final id = 'group-${DateTime.now().microsecondsSinceEpoch}';
    final group = PlannerGroup(
      id: id,
      name: name.trim(),
      description: description.trim(),
      timezone: timezone,
      colorValue: 0xff477b76,
      ownerId: ownerId,
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
    _emitGroupLifecycle(id);
    return group;
  }

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async {
    _validateGroup(name);
    _validateGroupDescription(description);
    validateIanaTimezone(timezone);
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    _requireActiveOwner(group, actorId);
    _checkGroupVersion(group, expectedVersion);
    final updated = group.copyWith(
      name: name.trim(),
      description: description.trim(),
      timezone: timezone,
      version: group.version + 1,
    );
    _groups[groupId] = updated;
    _emitGroupLifecycle(groupId);
    return updated;
  }

  @override
  Future<void> leaveGroup({
    required String actorId,
    required String groupId,
  }) async {
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 작업할 수 없습니다.');
    }
    final list = _members[groupId];
    if (list == null) throw StateError('그룹을 찾을 수 없습니다.');
    final index = list.indexWhere((member) => member.id == actorId);
    if (index < 0 || !list[index].isActive) {
      throw const ScheduleConflictException('활성 멤버만 그룹을 나갈 수 있습니다.');
    }
    if (list[index].isOwner || group.ownerId == actorId) {
      throw const ScheduleConflictException(
        '소유자는 그룹을 나갈 수 없습니다. 먼저 소유권을 이전해 주세요.',
      );
    }
    final current = list[index];
    list[index] = current.copyWith(
      isActive: false,
      removedAt: DateTime.now().toUtc(),
    );
    _emit(groupId);
    _emitGroupLifecycle(groupId);
  }

  @override
  Future<PlannerGroup> transferGroupOwnership({
    required String actorId,
    required String groupId,
    required String newOwnerId,
    required int expectedVersion,
  }) async {
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    _requireActiveOwner(group, actorId);
    _checkGroupVersion(group, expectedVersion);
    if (newOwnerId == actorId) {
      throw const ScheduleValidationException('새 소유자를 선택해 주세요.');
    }
    final list = _members[groupId];
    if (list == null) throw StateError('그룹을 찾을 수 없습니다.');
    final newOwnerIndex = list.indexWhere(
      (member) => member.id == newOwnerId && member.isActive,
    );
    if (newOwnerIndex < 0) {
      throw const ScheduleConflictException('새 소유자는 활성 멤버여야 합니다.');
    }
    // Update the group owner and all membership roles in one synchronous
    // critical section so there is never a state with two owners (or none).
    for (var index = 0; index < list.length; index++) {
      final member = list[index];
      list[index] = member.copyWith(isOwner: member.id == newOwnerId);
    }
    final updated = group.copyWith(
      ownerId: newOwnerId,
      version: group.version + 1,
    );
    _groups[groupId] = updated;
    _emitGroupLifecycle(groupId);
    return updated;
  }

  @override
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) async {
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    _requireActiveOwner(group, actorId);
    _checkGroupVersion(group, expectedVersion);
    final now = DateTime.now().toUtc();
    _groups[groupId] = group.copyWith(
      version: group.version + 1,
      archivedAt: now,
      deletedAt: now,
    );
    // A terminal archive also makes all outstanding invite lookups and event
    // streams empty without deleting historical records.
    _emit(groupId);
    _emitGroupLifecycle(groupId);
    return group.version + 1;
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    final code = normalizeInviteCode(inviteCode);
    if (code.isEmpty) {
      throw const FormatException('초대 코드를 입력해 주세요.');
    }
    final matchingInvite = _invites.values
        .where((invite) => normalizeInviteCode(invite.token ?? '') == code)
        .firstOrNull;
    final group = matchingInvite == null
        ? _groups.values.firstWhere(
            (candidate) =>
                (candidate.id == 'demo-group' &&
                code == normalizeInviteCode('family')),
            orElse: () => throw StateError('초대 코드를 찾을 수 없습니다.'),
          )
        : _groups[matchingInvite.groupId]!;
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에는 참여할 수 없습니다.');
    }
    if (matchingInvite != null &&
        (matchingInvite.isRevoked ||
            matchingInvite.isExpired ||
            matchingInvite.isExhausted)) {
      throw StateError('초대 코드가 만료되었거나 사용 횟수를 초과했습니다.');
    }
    final current = _members[group.id] ?? <PlannerMember>[];
    final existingIndex = current.indexWhere((member) => member.id == userId);
    final shouldConsumeInvite =
        matchingInvite != null &&
        (existingIndex < 0 || !current[existingIndex].isActive);
    if (existingIndex < 0) {
      current.add(
        PlannerMember(
          id: userId,
          name: demoUserName,
          email: demoUserEmail,
          avatarColor: 0xff477b76,
        ),
      );
      _members[group.id] = current;
    } else if (!current[existingIndex].isActive) {
      // Joining again reactivates an existing membership, mirroring the
      // transactional Supabase RPC rather than leaving the user filtered out.
      current[existingIndex] = current[existingIndex].copyWith(
        isActive: true,
        clearRemovedAt: true,
      );
      _members[group.id] = current;
    }
    if (matchingInvite != null && shouldConsumeInvite) {
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
    _emit(group.id);
    _emitGroupLifecycle(group.id);
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
    if (_groups[groupId]!.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 초대 코드를 만들 수 없습니다.');
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
    if (_groups[groupId]?.isArchived == true) return const <InviteCode>[];
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
    final group = _groups[invite.groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 초대 코드를 변경할 수 없습니다.');
    }
    final ownerId =
        group.ownerId ??
        _members[invite.groupId]
            ?.where((member) => member.isOwner && member.isActive)
            .firstOrNull
            ?.id;
    if (actorId != null && actorId != ownerId) {
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
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 멤버를 변경할 수 없습니다.');
    }
    final list = _members[groupId];
    if (list == null) throw StateError('그룹을 찾을 수 없습니다.');
    final ownerId =
        group.ownerId ??
        list
            .where((member) => member.isOwner && member.isActive)
            .firstOrNull
            ?.id;
    if (actorId != null && actorId != ownerId) {
      throw const ScheduleConflictException('멤버를 변경할 권한이 없습니다.');
    }
    if (userId == ownerId) {
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
    _emit(groupId);
    _emitGroupLifecycle(groupId);
    return updated;
  }

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    _requireActiveMember(groupId, userId);
    final normalizedDraft = _normalizeDraft(draft);
    final event = PlannerEvent(
      id: 'event-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
      groupId: groupId,
      title: normalizedDraft.title.trim(),
      note: normalizedDraft.note,
      startAt: normalizedDraft.startAt.toUtc(),
      endAt: normalizedDraft.endAt.toUtc(),
      allDay: normalizedDraft.allDay,
      ownerId: userId,
      memberIds: List<String>.unmodifiable(normalizedDraft.memberIds),
      colorValue: normalizedDraft.colorValue,
      timezone: normalizedDraft.timezone,
      updatedAt: DateTime.now().toUtc(),
      allDayStartDate: normalizedDraft.allDayStartDate,
      allDayEndDate: normalizedDraft.allDayEndDate,
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
    // Authorize against the caller/group before parsing mutable event fields;
    // an inactive/outsider request must never learn whether its payload is
    // otherwise well-formed, and archived groups are terminal write guards.
    _requireActiveMember(event.groupId, actorId ?? event.ownerId);
    final normalizedEvent = _normalizeEvent(event);
    final list = _events[normalizedEvent.groupId];
    final index =
        list?.indexWhere((candidate) => candidate.id == normalizedEvent.id) ??
        -1;
    if (list == null || index < 0) {
      throw StateError('일정을 찾을 수 없습니다.');
    }
    final existing = list[index];
    final effectiveActor = actorId ?? existing.ownerId;
    _requireActiveMember(existing.groupId, effectiveActor);
    if (normalizedEvent.groupId != existing.groupId ||
        normalizedEvent.ownerId != existing.ownerId) {
      throw const ScheduleConflictException('일정의 그룹과 소유자는 변경할 수 없습니다.');
    }
    if (effectiveActor != existing.ownerId) {
      throw const ScheduleConflictException('이 일정을 변경할 권한이 없습니다.');
    }
    if (existing.version != expectedVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    final updated = normalizedEvent.copyWith(
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
      memberIds: List<String>.unmodifiable(normalizedEvent.memberIds),
    );
    list[index] = updated;
    _emit(normalizedEvent.groupId);
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
      final effectiveActor = actorId ?? existing.ownerId;
      _requireActiveMember(entry.key, effectiveActor);
      if (effectiveActor != existing.ownerId) {
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

  void _requireActiveOwner(PlannerGroup group, String actorId) {
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 작업할 수 없습니다.');
    }
    final ownerId =
        group.ownerId ??
        _members[group.id]
            ?.where((member) => member.isOwner && member.isActive)
            .firstOrNull
            ?.id;
    final actor = _members[group.id]
        ?.where((member) => member.id == actorId)
        .firstOrNull;
    if (ownerId != actorId ||
        actor == null ||
        !actor.isActive ||
        !actor.isOwner) {
      throw const ScheduleConflictException('그룹 소유자만 이 작업을 할 수 있습니다.');
    }
  }

  static void _checkGroupVersion(PlannerGroup group, int expectedVersion) {
    if (group.version != expectedVersion) {
      throw const ScheduleConflictException(
        '다른 사용자가 그룹을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
  }

  static void _validateGroupDescription(String description) {
    if (description.trim().length > 10000) {
      throw const FormatException('그룹 설명을 확인해 주세요.');
    }
  }

  static EventDraft _normalizeDraft(EventDraft draft) {
    _validateDraft(draft);
    if (!draft.allDay) return draft;
    if (draft.allDayStartDate == null && draft.allDayEndDate == null) {
      // Legacy rows may omit the date metadata, but their UTC instants still
      // have to be the exact local-midnight boundaries for the event timezone.
      // Derive dates in that timezone (UTC instants can fall on the previous
      // device date for positive offsets), then canonicalize metadata.
      // The original local adapter accepted non-UTC DateTime values for its
      // UTC-default all-day draft. Preserve that narrow legacy input shape,
      // but canonicalize the persisted instant to the same UTC midnight as
      // the date metadata. Keeping the old wall-date interpretation while
      // persisting the caller's local instant would make `all_day_start` and
      // `starts_at` disagree (for example on a KST device).
      final legacyLocalUtc =
          draft.timezone == 'UTC' && !draft.startAt.isUtc && !draft.endAt.isUtc;
      final startDate = legacyLocalUtc
          ? _allDayDate(draft.startAt)
          : _allDayDate(utcToWallTime(draft.startAt, draft.timezone));
      final endDate = legacyLocalUtc
          ? _allDayDate(draft.endAt)
          : _allDayDate(utcToWallTime(draft.endAt, draft.timezone));
      if (!endDate.isAfter(startDate)) {
        throw const FormatException('종일 일정의 종료 날짜를 확인해 주세요.');
      }
      final canonicalStart = wallTimeToUtc(startDate, draft.timezone);
      final canonicalEnd = wallTimeToUtc(endDate, draft.timezone);
      if (!legacyLocalUtc &&
          (!_sameInstant(draft.startAt, canonicalStart) ||
              !_sameInstant(draft.endAt, canonicalEnd))) {
        throw const FormatException('종일 일정 날짜와 시간이 일치하지 않습니다.');
      }
      return EventDraft(
        title: draft.title,
        note: draft.note,
        startAt: canonicalStart,
        endAt: canonicalEnd,
        allDay: true,
        memberIds: draft.memberIds,
        colorValue: draft.colorValue,
        timezone: draft.timezone,
        allDayStartDate: startDate,
        allDayEndDate: endDate,
      );
    }
    final startDate = _allDayDate(
      draft.allDayStartDate ?? utcToWallTime(draft.startAt, draft.timezone),
    );
    final endDate = _allDayDate(
      draft.allDayEndDate ?? utcToWallTime(draft.endAt, draft.timezone),
    );
    if (draft.allDayStartDate != null && !_isDateOnly(draft.allDayStartDate!)) {
      throw const FormatException('종일 일정 날짜를 확인해 주세요.');
    }
    if (draft.allDayEndDate != null && !_isDateOnly(draft.allDayEndDate!)) {
      throw const FormatException('종일 일정 날짜를 확인해 주세요.');
    }
    if (!endDate.isAfter(startDate)) {
      throw const FormatException('종일 일정의 종료 날짜를 확인해 주세요.');
    }
    final canonicalStart = wallTimeToUtc(startDate, draft.timezone);
    final canonicalEnd = wallTimeToUtc(endDate, draft.timezone);
    // Rows with explicit metadata must agree with the persisted UTC
    // boundaries. Metadata-less legacy drafts are accepted and canonicalized
    // to local-midnight UTC so new writes have one unambiguous representation.
    if (draft.allDayStartDate != null &&
        !_sameInstant(draft.startAt, canonicalStart)) {
      throw const FormatException('종일 일정 시작 날짜와 시간이 일치하지 않습니다.');
    }
    if (draft.allDayEndDate != null &&
        !_sameInstant(draft.endAt, canonicalEnd)) {
      throw const FormatException('종일 일정 종료 날짜와 시간이 일치하지 않습니다.');
    }
    return EventDraft(
      title: draft.title,
      note: draft.note,
      startAt: canonicalStart,
      endAt: canonicalEnd,
      allDay: true,
      memberIds: draft.memberIds,
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: startDate,
      allDayEndDate: endDate,
    );
  }

  static PlannerEvent _normalizeEvent(PlannerEvent event) {
    _validateEvent(event);
    if (!event.allDay) return event;
    if (event.allDayStartDate == null && event.allDayEndDate == null) {
      final legacyLocalUtc =
          event.timezone == 'UTC' && !event.startAt.isUtc && !event.endAt.isUtc;
      final startDate = legacyLocalUtc
          ? _allDayDate(event.startAt)
          : _allDayDate(utcToWallTime(event.startAt, event.timezone));
      final endDate = legacyLocalUtc
          ? _allDayDate(event.endAt)
          : _allDayDate(utcToWallTime(event.endAt, event.timezone));
      if (!endDate.isAfter(startDate)) {
        throw const FormatException('종일 일정의 종료 날짜를 확인해 주세요.');
      }
      final canonicalStart = wallTimeToUtc(startDate, event.timezone);
      final canonicalEnd = wallTimeToUtc(endDate, event.timezone);
      if (!legacyLocalUtc &&
          (!_sameInstant(event.startAt, canonicalStart) ||
              !_sameInstant(event.endAt, canonicalEnd))) {
        throw const FormatException('종일 일정 날짜와 시간이 일치하지 않습니다.');
      }
      return event.copyWith(
        startAt: canonicalStart,
        endAt: canonicalEnd,
        allDayStartDate: startDate,
        allDayEndDate: endDate,
      );
    }
    final startDate = _allDayDate(
      event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
    );
    final endDate = _allDayDate(
      event.allDayEndDate ?? utcToWallTime(event.endAt, event.timezone),
    );
    if (event.allDayStartDate != null && !_isDateOnly(event.allDayStartDate!)) {
      throw const FormatException('종일 일정 날짜를 확인해 주세요.');
    }
    if (event.allDayEndDate != null && !_isDateOnly(event.allDayEndDate!)) {
      throw const FormatException('종일 일정 날짜를 확인해 주세요.');
    }
    if (!endDate.isAfter(startDate)) {
      throw const FormatException('종일 일정의 종료 날짜를 확인해 주세요.');
    }
    final canonicalStart = wallTimeToUtc(startDate, event.timezone);
    final canonicalEnd = wallTimeToUtc(endDate, event.timezone);
    if (event.allDayStartDate != null &&
        !_sameInstant(event.startAt, canonicalStart)) {
      throw const FormatException('종일 일정 시작 날짜와 시간이 일치하지 않습니다.');
    }
    if (event.allDayEndDate != null &&
        !_sameInstant(event.endAt, canonicalEnd)) {
      throw const FormatException('종일 일정 종료 날짜와 시간이 일치하지 않습니다.');
    }
    return event.copyWith(
      startAt: canonicalStart,
      endAt: canonicalEnd,
      allDayStartDate: startDate,
      allDayEndDate: endDate,
    );
  }

  static DateTime _allDayDate(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static bool _isDateOnly(DateTime value) =>
      value.hour == 0 &&
      value.minute == 0 &&
      value.second == 0 &&
      value.millisecond == 0 &&
      value.microsecond == 0;

  static bool _sameInstant(DateTime left, DateTime right) =>
      left.toUtc() == right.toUtc();

  bool _isActiveMember(String groupId, String userId) {
    final group = _groups[groupId];
    if (group == null || group.isArchived || userId.trim().isEmpty) {
      return false;
    }
    return (_members[groupId] ?? const <PlannerMember>[]).any(
      (member) => member.id == userId && member.isActive,
    );
  }

  void _requireActiveMember(String groupId, String userId) {
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 작업할 수 없습니다.');
    }
    if (userId.trim().isEmpty || !_isActiveMember(groupId, userId)) {
      throw const ScheduleConflictException('활성 멤버만 그룹 일정을 변경할 수 있습니다.');
    }
  }

  static void _validateDraft(EventDraft draft) {
    if (draft.title.trim().isEmpty ||
        draft.title.trim().length > 240 ||
        draft.note.trim().length > 10000 ||
        !draft.endAt.isAfter(draft.startAt)) {
      throw const FormatException('일정 제목과 시간을 확인해 주세요.');
    }
    validateIanaTimezone(draft.timezone);
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
    validateIanaTimezone(event.timezone);
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
  Stream<List<PlannerEvent>> watchEventsForUser(
    String userId,
    String groupId,
  ) => Stream<List<PlannerEvent>>.error(_error);

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) =>
      Stream<PlannerGroup?>.error(_error);

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description, {
    String timezone = defaultPlannerTimezone,
  }) => Future<PlannerGroup>.error(_error);

  @override
  Future<PlannerGroup> createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  }) => Future<PlannerGroup>.error(_error);

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) => Future<PlannerGroup>.error(_error);

  @override
  Future<void> leaveGroup({required String actorId, required String groupId}) =>
      Future<void>.error(_error);

  @override
  Future<PlannerGroup> transferGroupOwnership({
    required String actorId,
    required String groupId,
    required String newOwnerId,
    required int expectedVersion,
  }) => Future<PlannerGroup>.error(_error);

  @override
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) => Future<int>.error(_error);

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
class SupabaseScheduleRepository
    implements
        ScheduleRepository,
        TimezoneGroupCreationCapability,
        UserScopedEventReadCapability,
        GroupLifecycleCapability {
  /// [lifecyclePollInterval] is deliberately bounded to a conservative
  /// default for production (15 seconds).  Tests may inject a shorter clock
  /// interval when exercising the authoritative recheck path; the app uses
  /// the default and therefore never relies on a realtime row notification
  /// for membership/archive revocation.
  SupabaseScheduleRepository(
    this._client, {
    Duration lifecyclePollInterval = const Duration(seconds: 15),
  }) : _lifecyclePollInterval = lifecyclePollInterval {
    if (lifecyclePollInterval <= Duration.zero) {
      throw ArgumentError.value(
        lifecyclePollInterval,
        'lifecyclePollInterval',
        'must be positive',
      );
    }
  }
  final SupabaseClient _client;
  final Duration _lifecyclePollInterval;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    // Legacy projection contract: select( 'id,name,description,timezone,version,memberships!inner(user_id,is_active)',
    // and the bounded join projection select('id,name,description,timezone,version') remain
    // documented here while the live projection adds lifecycle/owner fields.
    final rows = await _client
        .from('groups')
        .select(
          'id,owner_id,name,description,timezone,version,deleted_at,memberships!inner(user_id,is_active)',
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
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId) {
    if (userId.trim().isEmpty) {
      return Stream<List<PlannerEvent>>.error(
        const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.'),
      );
    }
    // The membership check is intentionally repeated on every membership or
    // group signal and by a bounded timer.  A Supabase stream filtered by RLS
    // can retain a row when another client deactivates that membership, so a
    // first successful check is not an authorization guarantee for the rest
    // of the stream lifetime.
    return _watchRemoteEventsForUser(userId, groupId);
  }

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) {
    if (userId.trim().isEmpty) {
      return Stream<PlannerGroup?>.error(
        const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.'),
      );
    }
    return _watchRemoteGroupLifecycle(userId, groupId);
  }

  /// Authoritatively resolves the current requester/group relationship.  The
  /// memberships query deliberately includes inactive rows when RLS allows
  /// them; the stream callbacks still trigger this read even when Postgres
  /// Changes omits an update that no longer satisfies an RLS policy.
  Future<PlannerGroup?> _readUsableGroup(String userId, String groupId) async {
    final Object? membership = await _client
        .from('memberships')
        .select('user_id,is_active,removed_at')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .maybeSingle();
    // A missing row or an explicit inactive/removed marker is an
    // authoritative membership loss.  A partial/malformed row is not: keep
    // the last-known state and retry instead of turning an ambiguous response
    // into a privacy tombstone.
    if (membership == null) return null;
    if (membership is! Map) {
      throw StateError('멤버십 상태 응답을 확인할 수 없습니다.');
    }
    final membershipRow = membership.cast<String, dynamic>();
    if (!membershipRow.containsKey('user_id') ||
        !membershipRow.containsKey('is_active') ||
        !membershipRow.containsKey('removed_at')) {
      throw StateError('멤버십 상태 응답을 확인할 수 없습니다.');
    }
    if (membershipRow['user_id'] != userId) {
      throw StateError('멤버십 사용자 응답을 확인할 수 없습니다.');
    }
    if (membershipRow['is_active'] != true ||
        membershipRow['removed_at'] != null) {
      return null;
    }

    final Object? row = await _client
        .from('groups')
        .select('id,owner_id,name,description,timezone,version,deleted_at')
        .eq('id', groupId)
        .maybeSingle();
    if (row == null) return null;
    if (row is! Map) {
      throw StateError('그룹 상태 응답을 확인할 수 없습니다.');
    }
    final groupRow = row.cast<String, dynamic>();
    // A lifecycle update is terminal as soon as deleted_at is non-null.  Do
    // not rely on the model fallback fields to infer this marker.  A
    // successful absent/archived response is a loss, while a malformed or
    // partial response remains last-known until a later retry succeeds.
    if (!groupRow.containsKey('deleted_at') || !_hasGroupFields(groupRow)) {
      throw StateError('그룹 상태 응답을 확인할 수 없습니다.');
    }
    // The query is scoped by the requested id, but a malformed adapter or
    // cross-group response must never be accepted as the selected lifecycle
    // row.  Treat the mismatch as a transient malformed read so callers keep
    // their last-known state and retry rather than replacing it.
    if (groupRow['id'] != groupId) {
      throw StateError('그룹 상태 응답을 확인할 수 없습니다.');
    }
    if (groupRow['deleted_at'] != null) {
      return null;
    }
    final group = _groupFromRow(groupRow);
    return group.isArchived ? null : group;
  }

  /// Builds a requester-scoped event stream with independent subscriptions to
  /// events, memberships, and groups.  Every signal only schedules an
  /// authoritative REST read; the timer covers the case where an RLS policy
  /// hides the membership/group update from Postgres Changes altogether.
  Stream<List<PlannerEvent>> _watchRemoteEventsForUser(
    String userId,
    String groupId,
  ) {
    late final StreamController<List<PlannerEvent>> controller;
    StreamSubscription<List<Map<String, dynamic>>>? eventsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? membershipsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? groupsSubscription;
    Timer? recheckTimer;
    var cancelled = false;
    var setupStarted = false;
    var usable = false;
    List<PlannerEvent>? latestEvents;
    var checkInFlight = false;
    var checkQueued = false;

    void emitEmpty() {
      if (!cancelled && !controller.isClosed) {
        controller.add(const <PlannerEvent>[]);
      }
    }

    Future<void> checkAuthoritatively() async {
      if (cancelled) return;
      if (checkInFlight) {
        checkQueued = true;
        return;
      }
      checkInFlight = true;
      try {
        final group = await _readUsableGroup(userId, groupId);
        if (cancelled) return;
        final nextUsable = group != null;
        if (!nextUsable && usable) emitEmpty();
        usable = nextUsable;
        if (!usable) {
          emitEmpty();
        } else if (latestEvents != null && !controller.isClosed) {
          // The events stream may deliver its initial snapshot before the
          // first membership/group read completes.  Replay that buffered
          // snapshot once authorization is established instead of leaving a
          // permanently empty calendar until the next event mutation.
          controller.add(latestEvents!);
        }
      } catch (error, stack) {
        // A failed authoritative read is not proof that membership was lost.
        // Keep the last-known authorization/events state and let the bounded
        // timer (or a queued realtime signal) retry.  Only a successful read
        // that resolves to an absent/inactive membership emits the privacy
        // clearing empty snapshot below.
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stack);
        }
      } finally {
        checkInFlight = false;
        if (checkQueued && !cancelled) {
          checkQueued = false;
          unawaited(checkAuthoritatively());
        }
      }
    }

    void signalError(Object error, StackTrace stack) {
      // Channel errors are transient transport diagnostics, not lifecycle
      // facts.  Preserve the last-known event authorization and rely on the
      // authoritative timer/realtime retry instead of tombstoning a healthy
      // group after one websocket failure.
      if (!cancelled && !controller.isClosed) {
        controller.addError(error, stack);
      }
    }

    Future<void> cancelAll() async {
      cancelled = true;
      recheckTimer?.cancel();
      final subscriptions = <StreamSubscription<dynamic>>[
        if (eventsSubscription != null) eventsSubscription!,
        if (membershipsSubscription != null) membershipsSubscription!,
        if (groupsSubscription != null) groupsSubscription!,
      ];
      for (final subscription in subscriptions) {
        try {
          await subscription.cancel();
        } catch (_) {
          // A failed realtime unsubscribe must not leak the stream
          // controller or prevent selection changes from completing.
        }
      }
    }

    Future<void> setup() async {
      if (setupStarted || cancelled) return;
      setupStarted = true;
      // Start the authoritative fallback before opening any realtime
      // subscriptions. A synchronous `.stream()`/`.listen()` failure must
      // not strand the watcher without its 15-second privacy recheck loop.
      recheckTimer = Timer.periodic(
        _lifecyclePollInterval,
        (_) => unawaited(checkAuthoritatively()),
      );
      try {
        eventsSubscription = _client
            .from('events')
            .stream(primaryKey: const <String>['id'])
            .eq('group_id', groupId)
            .listen((rows) {
              if (cancelled) return;
              try {
                latestEvents = List<PlannerEvent>.unmodifiable(
                  rows.map(_eventFromRow).where((event) => !event.isDeleted),
                );
                if (usable && !controller.isClosed) {
                  controller.add(latestEvents!);
                } else {
                  emitEmpty();
                }
              } catch (error, stack) {
                signalError(error, stack);
              }
            }, onError: signalError);
        membershipsSubscription = _client
            .from('memberships')
            .stream(primaryKey: const <String>['group_id', 'user_id'])
            .eq('group_id', groupId)
            .eq('user_id', userId)
            .listen(
              (_) => unawaited(checkAuthoritatively()),
              onError: signalError,
            );
        groupsSubscription = _client
            .from('groups')
            .stream(primaryKey: const <String>['id'])
            .eq('id', groupId)
            .listen(
              (_) => unawaited(checkAuthoritatively()),
              onError: signalError,
            );
        if (cancelled) {
          await cancelAll();
          return;
        }
      } catch (error, stack) {
        signalError(error, stack);
      }
      if (cancelled) {
        await cancelAll();
        return;
      }
      // Run one authoritative read even when channel setup failed. The timer
      // above remains active so a later network recovery can restore state.
      await checkAuthoritatively();
    }

    controller = StreamController<List<PlannerEvent>>(
      onListen: () => unawaited(setup()),
      onCancel: cancelAll,
    );
    return controller.stream;
  }

  /// Builds the group lifecycle stream used to invalidate a selected group
  /// when a remote client archives it or removes the requester.  The same
  /// membership/group realtime signals and periodic authoritative fallback as
  /// [_watchRemoteEventsForUser] are used here; cancelling this stream tears
  /// down all three Supabase channels and the timer.
  Stream<PlannerGroup?> _watchRemoteGroupLifecycle(
    String userId,
    String groupId,
  ) {
    late final StreamController<PlannerGroup?> controller;
    StreamSubscription<List<Map<String, dynamic>>>? membershipsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? groupsSubscription;
    Timer? recheckTimer;
    var cancelled = false;
    var setupStarted = false;
    var hasValue = false;
    PlannerGroup? current;
    var checkInFlight = false;
    var checkQueued = false;

    void emit(PlannerGroup? next) {
      if (cancelled || controller.isClosed) return;
      if (hasValue && current == next) return;
      current = next;
      hasValue = true;
      controller.add(next);
    }

    Future<void> checkAuthoritatively() async {
      if (cancelled) return;
      if (checkInFlight) {
        checkQueued = true;
        return;
      }
      checkInFlight = true;
      try {
        emit(await _readUsableGroup(userId, groupId));
      } catch (error, stack) {
        // A read error is not an authoritative membership/group loss. Keep
        // the last-known lifecycle value and let the 15-second poll retry;
        // only a successful read returning null emits a tombstone.
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stack);
        }
      } finally {
        checkInFlight = false;
        if (checkQueued && !cancelled) {
          checkQueued = false;
          unawaited(checkAuthoritatively());
        }
      }
    }

    void signalError(Object error, StackTrace stack) {
      // A realtime channel error is transport state, not proof that the
      // selected group was archived or that this member was removed. The
      // periodic authoritative recheck remains active and owns lifecycle
      // loss emission.
      if (!cancelled && !controller.isClosed) {
        controller.addError(error, stack);
      }
    }

    Future<void> cancelAll() async {
      cancelled = true;
      recheckTimer?.cancel();
      final subscriptions = <StreamSubscription<dynamic>>[
        if (membershipsSubscription != null) membershipsSubscription!,
        if (groupsSubscription != null) groupsSubscription!,
      ];
      for (final subscription in subscriptions) {
        try {
          await subscription.cancel();
        } catch (_) {
          // Keep cancellation best-effort; Supabase itself closes each stream
          // channel when its subscription is cancelled.
        }
      }
    }

    Future<void> setup() async {
      if (setupStarted || cancelled) return;
      setupStarted = true;
      // Keep the privacy fallback alive independently of websocket setup. A
      // synchronous stream construction failure must still get an immediate
      // authoritative read and subsequent 15-second retries.
      recheckTimer = Timer.periodic(
        _lifecyclePollInterval,
        (_) => unawaited(checkAuthoritatively()),
      );
      try {
        membershipsSubscription = _client
            .from('memberships')
            .stream(primaryKey: const <String>['group_id', 'user_id'])
            .eq('group_id', groupId)
            .eq('user_id', userId)
            .listen(
              (_) => unawaited(checkAuthoritatively()),
              onError: signalError,
            );
        groupsSubscription = _client
            .from('groups')
            .stream(primaryKey: const <String>['id'])
            .eq('id', groupId)
            .listen(
              (_) => unawaited(checkAuthoritatively()),
              onError: signalError,
            );
        if (cancelled) {
          await cancelAll();
          return;
        }
      } catch (error, stack) {
        signalError(error, stack);
      }
      if (cancelled) {
        await cancelAll();
        return;
      }
      await checkAuthoritatively();
    }

    controller = StreamController<PlannerGroup?>(
      onListen: () => unawaited(setup()),
      onCancel: cancelAll,
    );
    return controller.stream;
  }

  @override
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description, {
    String timezone = defaultPlannerTimezone,
  }) => createGroupWithTimezone(ownerId, name, description, timezone: timezone);

  @override
  Future<PlannerGroup> createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  }) async {
    LocalScheduleRepository._validateGroup(name);
    LocalScheduleRepository._validateGroupDescription(description);
    validateIanaTimezone(timezone);
    final row = await _client.rpc<dynamic>(
      'create_group',
      params: <String, dynamic>{
        'p_name': name.trim(),
        'p_timezone': timezone,
        'p_description': description.trim(),
      },
    );
    final data = row is List ? (row.isEmpty ? null : row.first) : row;
    if (data is! Map<String, dynamic> || !_hasGroupFields(data)) {
      throw StateError('그룹을 만들 수 없습니다.');
    }
    return _groupFromRow(data);
  }

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async {
    LocalScheduleRepository._validateGroup(name);
    LocalScheduleRepository._validateGroupDescription(description);
    validateIanaTimezone(timezone);
    // Supabase RPCs derive the actor from auth.uid(). Deliberately do not put
    // actorId in this payload, even though the local adapter accepts it for
    // deterministic authorization tests.
    final result = await _client.rpc<dynamic>(
      'update_group_if_version',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_expected_version': expectedVersion,
        'p_name': name.trim(),
        'p_description': description.trim(),
        'p_timezone': timezone,
      },
    );
    final row = _strictSingleRpcMap(result);
    if (!_isValidActiveGroupMutationRow(
      row,
      groupId: groupId,
      expectedVersion: expectedVersion,
      // The SQL RPC derives the actor from auth.uid().  Verify that the
      // returned composite row still belongs to the caller before exposing
      // it to the controller; an omitted or mismatched owner marker is a
      // conflict, never a successful edit.
      expectedOwnerId: actorId,
    )) {
      throw const ScheduleConflictException('그룹 편집 응답을 확인할 수 없습니다.');
    }
    return _groupFromRow(row!);
  }

  @override
  Future<void> leaveGroup({
    required String actorId,
    required String groupId,
  }) async {
    // auth.uid() is the sole actor source on the wire.
    await _client.rpc<dynamic>(
      'leave_group',
      params: <String, dynamic>{'p_group_id': groupId},
    );
  }

  @override
  Future<PlannerGroup> transferGroupOwnership({
    required String actorId,
    required String groupId,
    required String newOwnerId,
    required int expectedVersion,
  }) async {
    final result = await _client.rpc<dynamic>(
      'transfer_group_ownership',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_new_owner_id': newOwnerId,
        'p_expected_version': expectedVersion,
      },
    );
    final row = _strictSingleRpcMap(result);
    if (!_isValidActiveGroupMutationRow(
      row,
      groupId: groupId,
      expectedVersion: expectedVersion,
      expectedOwnerId: newOwnerId,
    )) {
      throw const ScheduleConflictException('소유권 이전 응답을 확인할 수 없습니다.');
    }
    return _groupFromRow(row!);
  }

  @override
  Future<int> archiveGroupIfVersion({
    required String actorId,
    required String groupId,
    required int expectedVersion,
  }) async {
    final result = await _client.rpc<dynamic>(
      'archive_group_if_version',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_expected_version': expectedVersion,
      },
    );
    // The RPC returns the archived composite group row.  Require the exact
    // target, terminal deletion marker, and one-step version transition; a
    // scalar or a row for another group must never be interpreted as success.
    final row = _strictSingleRpcMap(result);
    final returnedId = row?['id'];
    final returnedVersion = _intValueNullable(row?['version']);
    final deletedAt = _dateTimeValue(row?['deleted_at'] ?? row?['deletedAt']);
    if (row == null ||
        returnedId is! String ||
        returnedId != groupId ||
        deletedAt == null ||
        returnedVersion != expectedVersion + 1) {
      throw const ScheduleConflictException('다른 사용자가 그룹을 변경했거나 이미 보관했습니다.');
    }
    return returnedVersion!;
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
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
        .select('id,owner_id,name,description,timezone,version,deleted_at')
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
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    final normalizedDraft = LocalScheduleRepository._normalizeDraft(draft);
    final payload = <String, dynamic>{
      'group_id': groupId,
      'created_by': userId,
      'title': normalizedDraft.title.trim(),
      'description': normalizedDraft.note.trim(),
      // The validated draft retains the caller's exact ARGB value.
      'color_value': draft.colorValue,
      'starts_at': normalizedDraft.startAt.toUtc().toIso8601String(),
      'ends_at': normalizedDraft.endAt.toUtc().toIso8601String(),
      'timezone': normalizedDraft.timezone,
      'is_all_day': normalizedDraft.allDay,
      'version': 1,
    };
    if (normalizedDraft.allDay) {
      payload['all_day_start'] = _dateString(normalizedDraft.allDayStartDate!);
      payload['all_day_end'] = _dateString(normalizedDraft.allDayEndDate!);
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
    final normalizedEvent = LocalScheduleRepository._normalizeEvent(event);
    if (actorId != null && actorId != normalizedEvent.ownerId) {
      throw const ScheduleConflictException('이 일정을 변경할 권한이 없습니다.');
    }
    final payload = <String, dynamic>{
      'title': normalizedEvent.title.trim(),
      'description': normalizedEvent.note.trim(),
      // Keep this payload tied to the caller's event value after validation.
      'color_value': event.colorValue,
      'starts_at': normalizedEvent.startAt.toUtc().toIso8601String(),
      'ends_at': normalizedEvent.endAt.toUtc().toIso8601String(),
      'timezone': normalizedEvent.timezone,
      'is_all_day': normalizedEvent.allDay,
      'version': expectedVersion + 1,
    };
    if (normalizedEvent.allDay) {
      payload['all_day_start'] = _dateString(normalizedEvent.allDayStartDate!);
      payload['all_day_end'] = _dateString(normalizedEvent.allDayEndDate!);
    } else {
      payload['all_day_start'] = null;
      payload['all_day_end'] = null;
    }
    var query = _client
        .from('events')
        .update(payload)
        .eq('id', normalizedEvent.id)
        .eq('group_id', normalizedEvent.groupId)
        .eq('created_by', normalizedEvent.ownerId)
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
    // `soft_delete_event_if_version` returns exactly one composite row.  Do
    // not accept a scalar, an empty body, or an arbitrary first row from a
    // multi-row response: treating any of those as success would make a
    // caller believe the event was deleted when the server contract is
    // actually ambiguous.
    final row = _strictSingleRpcMap(result);
    final deletedAt = row == null
        ? null
        : _dateTimeValue(row['deleted_at'] ?? row['deletedAt']);
    final returnedId = row == null ? null : row['id'];
    final returnedVersion = row == null
        ? null
        : _intValueNullable(row['version']);
    if (row == null ||
        returnedId is! String ||
        returnedId != eventId ||
        deletedAt == null ||
        returnedVersion != expectedVersion + 1) {
      throw const ScheduleConflictException('일정이 이미 변경되었거나 권한이 없습니다.');
    }
  }

  static Map<String, dynamic>? _strictSingleRpcMap(Object? result) {
    if (result is Map<String, dynamic>) return result;
    if (result is List && result.length == 1 && result.single is Map) {
      final value = result.single;
      if (value is Map<String, dynamic>) return value;
      if (value is Map && value.keys.every((key) => key is String)) {
        return Map<String, dynamic>.from(value);
      }
    }
    if (result is Map && result.keys.every((key) => key is String)) {
      return Map<String, dynamic>.from(result);
    }
    return null;
  }

  static bool _hasGroupFields(Map<String, dynamic> row) {
    // Composite RPC/results and lifecycle reads should carry these fields. A
    // partial object is rejected instead of fabricating a group from defaults.
    return row['id'] is String &&
        (row['id'] as String).isNotEmpty &&
        row['owner_id'] is String &&
        (row['owner_id'] as String).isNotEmpty &&
        row['name'] is String &&
        (row['name'] as String).trim().isNotEmpty &&
        row['description'] is String &&
        row['timezone'] is String &&
        (row['timezone'] as String).isNotEmpty &&
        _intValueNullable(row['version']) != null;
  }

  /// Validates the complete active-group row returned by an optimistic group
  /// RPC.  A successful HTTP/RPC response is not enough: an empty, multi-row,
  /// partial, stale, cross-group, or archived row is converted to a safe
  /// conflict rather than being accepted or refetched through a broader RLS
  /// query.
  static bool _isValidActiveGroupMutationRow(
    Map<String, dynamic>? row, {
    required String groupId,
    required int expectedVersion,
    String? expectedOwnerId,
  }) {
    if (row == null || !_hasGroupFields(row)) return false;
    if (row['id'] != groupId) return false;
    if (_intValueNullable(row['version']) != expectedVersion + 1) {
      return false;
    }
    // The SQL contract names this column deleted_at.  Accept camelCase only
    // for a hand-written adapter, but require an explicit null marker either
    // way so an omitted/partial lifecycle field cannot be mistaken for an
    // active group.
    final hasDeletedAt = row.containsKey('deleted_at');
    final hasDeletedCamel = row.containsKey('deletedAt');
    if (!hasDeletedAt && !hasDeletedCamel) return false;
    if ((hasDeletedAt && row['deleted_at'] != null) ||
        (hasDeletedCamel && row['deletedAt'] != null)) {
      return false;
    }
    if (row['archived_at'] != null || row['archivedAt'] != null) {
      return false;
    }
    if (expectedOwnerId != null) {
      if (row['owner_id'] != expectedOwnerId) return false;
      if (row.containsKey('ownerId') && row['ownerId'] != expectedOwnerId) {
        return false;
      }
    }
    return true;
  }

  PlannerGroup _groupFromRow(Map<String, dynamic> row) {
    final deletedAt = _dateTimeValue(row['deleted_at'] ?? row['deletedAt']);
    final archivedAt = _dateTimeValue(row['archived_at'] ?? row['archivedAt']);
    return PlannerGroup(
      id: '${row['id']}',
      name: '${row['name'] ?? '그룹'}',
      description: '${row['description'] ?? ''}',
      timezone: '${row['timezone'] ?? 'UTC'}',
      version: _intValue(row['version'], 1),
      ownerId: _stringValue(row['owner_id'] ?? row['ownerId']),
      archivedAt: archivedAt,
      deletedAt: deletedAt,
      colorValue: _colorValue(row['color_value'], 0xff476a6f),
    );
  }

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

  static String? _stringValue(Object? value) => value == null ? null : '$value';

  static DateTime? _dateTimeValue(Object? value) =>
      value == null ? null : DateTime.tryParse('$value')?.toUtc();

  static int _intValue(Object? value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
  static int? _intValueNullable(Object? value) {
    if (value is int) return value;
    if (value is num) {
      // RPC version/count fields are integral contract values.  Do not let
      // `toInt()` truncate a fractional, NaN, or infinite JSON number into a
      // value that can accidentally satisfy optimistic-concurrency checks.
      if (!value.isFinite || value != value.truncate()) return null;
      return value.toInt();
    }
    return int.tryParse('$value');
  }

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
