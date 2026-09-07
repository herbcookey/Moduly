import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/demo_identity.dart';
import '../core/invite_code_utils.dart';
import '../core/recurrence.dart';
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

/// Optional capability for bounded calendar reads.  Keeping this additive to
/// [ScheduleRepository] preserves compatibility with older test doubles and
/// adapters while allowing production controllers to fail closed instead of
/// downloading every event in a group.
abstract interface class BoundedEventRangeReadCapability {
  /// Reads one keyset page for an authenticated group member.  [userId] is a
  /// local context hint only; remote adapters derive identity from auth.uid
  /// and must never serialize it as an actor/query parameter.
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  });

  /// Emits a change-only signal for parent `events` rows.  The stream must
  /// not perform an initial full event read; callers fetch the current range
  /// through [eventsForRange] and use this stream only for invalidation.
  Stream<void> watchEventInvalidations(String userId, String groupId);
}

/// Optional point lookup used by deep links/details routes. It is separate
/// from bounded pages so an event outside the current calendar range can be
/// opened without polluting that range's pagination projection.
abstract interface class EventByIdReadCapability {
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  });
}

/// Additive occurrence point lookup.  Keeping this separate means old detail
/// route test doubles that implement [EventByIdReadCapability] continue to
/// compile while recurring routes can use the exact occurrence key.
abstract interface class EventOccurrenceReadCapability {
  Future<PlannerEvent?> eventOccurrenceByKey({
    required String userId,
    required String groupId,
    required String eventId,
    required String occurrenceKey,
  });
}

/// Optional capability for repositories that can atomically replace the
/// participant rows belonging to an existing event.  The base repository
/// deliberately does not require this method so older adapters and tests keep
/// compiling; callers must fail closed when they need a custom participant
/// list but the adapter does not implement this capability.
///
/// [actorId] is a local authorization hint only.  The Supabase implementation
/// derives the actor from `auth.uid()` and never sends this value over the
/// wire.  Implementations also promise that their existing create/update
/// methods persist memberIds atomically when this capability is present.
abstract interface class EventMemberAssignmentCapability {
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  });
}

/// Authenticated capability for replacing the participant assignment of a
/// recurring series.  Recurring assignments are series-wide and must retain
/// the event creator; the operation therefore uses the recurrence RPC and
/// returns its committed receipt instead of the legacy event-row payload.
///
/// Keeping this additive prevents older singleton-only adapters and test
/// doubles from accidentally taking the recurring path through the legacy
/// participant RPC.
abstract interface class RecurringEventMemberAssignmentCapability {
  Future<RecurrenceMutationReceipt> replaceRecurringEventMembers({
    required PlannerEvent event,
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  });
}

/// Recurring-series capability.  Kept additive to [ScheduleRepository] so
/// legacy adapters/fakes retain the singleton API.  Scope writes return a
/// committed receipt; callers must refetch their bounded range rather than
/// fan out an optimistic occurrence projection.
abstract interface class RecurrenceCapability {
  Future<PlannerEvent> createRecurringEvent(
    String userId,
    String groupId,
    EventDraft draft,
  );

  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  });

  Future<RecurrenceMutationReceipt> deleteEventOccurrence({
    required PlannerEvent event,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  });
}

/// Optional authenticated capability for reading the non-sensitive group
/// projection behind an invite token.  The token is a local context hint;
/// Supabase adapters derive the actor from auth.uid() and send only `p_token`
/// to the RPC.
abstract interface class InvitePreviewCapability {
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  });
}

class ScheduleConflictException implements Exception {
  const ScheduleConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A structured authorization/lifecycle denial.  State uses this marker to
/// clear a cached private range after an authoritative access loss, while
/// preserving last-good rows for unrelated transient transport failures.
class ScheduleAuthorizationException extends ScheduleConflictException {
  const ScheduleAuthorizationException(super.message);
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

/// All terminal invite states intentionally collapse to one public reason so
/// callers cannot probe token existence, revocation, usage, or group state.
enum InviteUnavailableReason { invalidOrExpired }

class InviteUnavailableException implements Exception {
  const InviteUnavailableException.invalidOrExpired()
    : reason = InviteUnavailableReason.invalidOrExpired,
      message = '초대 링크가 만료되었거나 올바르지 않습니다.';

  final InviteUnavailableReason reason;
  final String message;

  @override
  String toString() => message;
}

/// The only invite oracle state exposed distinctly is a server-side rate
/// limit.  [retryAfter] is optional and never includes token material.
/// Raised when the actor-local invite preview/join budget is exhausted.  The
/// longer name is the canonical API; the typedef below preserves the original
/// spelling used by older screens and test doubles.
class InviteRateLimitedException implements Exception {
  const InviteRateLimitedException({this.retryAfter})
    : message = '초대 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.';

  final Duration? retryAfter;
  final String message;

  @override
  String toString() => message;
}

/// Backwards-compatible spelling retained for existing callers.  A typedef
/// (rather than a subclass) keeps `isA<InviteRateLimitException>()` and
/// `isA<InviteRateLimitedException>()` equivalent at runtime.
typedef InviteRateLimitException = InviteRateLimitedException;

/// The join RPC has committed membership, but the follow-up group projection
/// could not be read.  Callers must not retry the bearer token: membership is
/// already authoritative on the server.  The message is fixed and contains no
/// transport details or invite material.
class InviteJoinCommittedException extends ScheduleConflictException {
  const InviteJoinCommittedException()
    : super('그룹 참여는 완료되었지만 정보를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.');
}

/// A create response arrived after its originating auth/group context was
/// invalidated.  The raw one-shot token is deliberately discarded instead of
/// returning it to a stale caller.
class InviteOperationStaleException extends ScheduleConflictException {
  const InviteOperationStaleException()
    : super('초대 코드 생성 결과가 더 이상 유효하지 않습니다. 다시 시도해 주세요.');
}

final RegExp _inviteUuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Lifecycle state for one Supabase invalidation channel. Capturing this
/// object in callbacks lets a failed/retired channel be removed without ever
/// clearing or tearing down a newer channel that has replaced it.
class _EventInvalidationChannelState {
  _EventInvalidationChannelState(this.channel);

  final RealtimeChannel channel;
  bool closing = false;
  bool failureHandled = false;
  bool subscribedHandled = false;
}

class _LocalRecurrenceSegment {
  const _LocalRecurrenceSegment({
    required this.template,
    required this.ordinalOffset,
  });

  final PlannerEvent template;
  final int ordinalOffset;
}

/// 메모리 기반 미리보기 저장소다. Supabase URL과 공개 키가 없거나 초기화가
/// 실패해 설정 화면에 오류가 표시될 때만 선택되므로, 설정된 백엔드를
/// 실수로 가리지 않는다.
class LocalScheduleRepository
    implements
        ScheduleRepository,
        TimezoneGroupCreationCapability,
        UserScopedEventReadCapability,
        GroupLifecycleCapability,
        EventMemberAssignmentCapability,
        RecurringEventMemberAssignmentCapability,
        RecurrenceCapability,
        BoundedEventRangeReadCapability,
        EventByIdReadCapability,
        EventOccurrenceReadCapability,
        InvitePreviewCapability {
  LocalScheduleRepository({
    Iterable<PlannerMember> seedMembers = const [],
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    _seed(seedMembers);
  }

  /// Subclasses used as legacy test doubles may override a few methods while
  /// still inheriting this adapter.  Keep their old full-stream controller
  /// path unless they explicitly opt into bounded reads; the concrete local
  /// adapter itself remains the production-capable implementation.
  bool get useBoundedEventRangeReads => runtimeType == LocalScheduleRepository;

  /// Whether mutation responses must echo the exact persisted participant set.
  /// The concrete local adapter and configuration-blocked adapter are strict;
  /// old Local subclasses used as partial test doubles predate participant
  /// responses and may opt into the historical creator-default normalization.
  /// This compatibility bit is only for omitted-member create responses; an
  /// explicit participant list still requires [EventMemberAssignmentCapability]
  /// and is never silently accepted by a legacy adapter.
  bool get requireExactEventMutationResults =>
      runtimeType == LocalScheduleRepository;

  final Map<String, PlannerGroup> _groups = <String, PlannerGroup>{};
  final Map<String, List<PlannerMember>> _members =
      <String, List<PlannerMember>>{};
  final Map<String, List<PlannerEvent>> _events =
      <String, List<PlannerEvent>>{};
  final Map<String, List<_LocalRecurrenceSegment>> _recurrenceSegments =
      <String, List<_LocalRecurrenceSegment>>{};
  final Map<String, Map<String, PlannerEvent>> _occurrenceOverrides =
      <String, Map<String, PlannerEvent>>{};
  final Map<String, InviteCode> _invites = <String, InviteCode>{};
  final Map<String, StreamController<List<PlannerEvent>>> _controllers =
      <String, StreamController<List<PlannerEvent>>>{};
  final Map<String, Map<String, StreamController<List<PlannerEvent>>>>
  _userControllers =
      <String, Map<String, StreamController<List<PlannerEvent>>>>{};
  final Map<String, Map<String, StreamController<PlannerGroup?>>>
  _groupControllers = <String, Map<String, StreamController<PlannerGroup?>>>{};
  final Map<String, Set<StreamController<void>>> _rangeInvalidationControllers =
      <String, Set<StreamController<void>>>{};
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, List<DateTime>> _previewAttempts =
      <String, List<DateTime>>{};
  final Map<String, List<DateTime>> _joinAttempts = <String, List<DateTime>>{};
  int _counter = 0;
  int _inviteCounter = 0;

  DateTime _nowUtc() => _clock().toUtc();

  static String _seriesSegmentsKey(String groupId, String eventId) =>
      '$groupId|$eventId';

  /// Records one real invite attempt in an actor-scoped sliding-hour ledger.
  /// The ledgers intentionally contain timestamps only: bearer tokens never
  /// become part of rate-limit state.  At the limit, the request is rejected
  /// without adding a timestamp, matching the database RPC's lockout
  /// semantics.
  bool _recordInviteAttempt({
    required Map<String, List<DateTime>> ledger,
    required String actorId,
    required int limit,
  }) {
    final now = _nowUtc();
    final cutoff = now.subtract(const Duration(hours: 1));
    final attempts = ledger.putIfAbsent(actorId, () => <DateTime>[]);
    attempts.removeWhere((timestamp) => !timestamp.isAfter(cutoff));
    if (attempts.isEmpty) {
      ledger.remove(actorId);
    }
    final activeAttempts = ledger.putIfAbsent(actorId, () => <DateTime>[]);
    if (activeAttempts.length >= limit) {
      return false;
    }
    activeAttempts.add(now);
    return true;
  }

  String _generateInviteToken() {
    // Random.secure is used by default because this value is a bearer token.
    // The bounded retry also guarantees progress if an injected deterministic
    // source happens to collide with a token already held by this adapter.
    for (var attempt = 0; attempt < 64; attempt++) {
      final token = String.fromCharCodes(
        List<int>.generate(
          inviteCodeLength,
          (_) => inviteCodeAlphabet.codeUnitAt(
            _random.nextInt(inviteCodeAlphabet.length),
          ),
          growable: false,
        ),
      );
      if (normalizeStrictInviteToken(token) != token) continue;
      if (_invites.values.every((invite) => invite.token != token)) {
        return token;
      }
    }
    throw StateError('초대 코드를 만들 수 없습니다.');
  }

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
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async {
    _validateBoundedRangeRequest(
      userId: userId,
      groupId: groupId,
      range: range,
      limit: limit,
      participantId: participantId,
    );
    final normalizedParticipant = participantId?.trim();
    final candidates = _materializedEventsForRange(
      groupId: groupId,
      range: range,
      participantId: normalizedParticipant,
    );
    candidates.sort(_compareEventRangeRows);

    final afterCursor = cursor == null
        ? candidates
        : candidates
              .where((event) => _isAfterEventRangeCursor(event, cursor))
              .toList(growable: false);
    final hasMore = afterCursor.length > limit;
    final pageEvents = afterCursor.take(limit).toList(growable: false);
    final nextCursor = hasMore && pageEvents.isNotEmpty
        ? EventRangeCursor(
            startsAtUtc: pageEvents.last.startAt.toUtc(),
            eventId: pageEvents.last.id,
            occurrenceKey: pageEvents.last.occurrenceKey == 'single'
                ? ''
                : pageEvents.last.occurrenceKey,
          )
        : null;
    return EventRangePage(
      events: pageEvents,
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) async {
    if (eventId.trim().isEmpty || eventId != eventId.trim()) {
      throw const ScheduleValidationException('일정 식별자를 확인해 주세요.');
    }
    _requireBoundedActiveMember(groupId, userId);
    final event = (_events[groupId] ?? const <PlannerEvent>[])
        .where((candidate) => candidate.id == eventId)
        .firstOrNull;
    if (event == null || event.isDeleted) return null;
    if (event.groupId != groupId) return null;
    return event;
  }

  @override
  Future<PlannerEvent?> eventOccurrenceByKey({
    required String userId,
    required String groupId,
    required String eventId,
    required String occurrenceKey,
  }) async {
    if (userId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        eventId.trim().isEmpty ||
        eventId != eventId.trim()) {
      throw const ScheduleValidationException('로그인 세션과 일정을 확인해 주세요.');
    }
    if (!isValidOccurrenceKey(occurrenceKey)) {
      throw const ScheduleValidationException('반복 일정 식별자를 확인해 주세요.');
    }
    _requireBoundedActiveMember(groupId, userId);
    final event = (_events[groupId] ?? const <PlannerEvent>[])
        .where((candidate) => candidate.id == eventId)
        .firstOrNull;
    if (event == null || event.isDeleted) return null;
    if (occurrenceKey == 'single' && event.recurrenceRule == null) {
      return event;
    }
    if (event.recurrenceRule == null) return null;
    final requestedKey = occurrenceKey == 'single'
        ? occurrenceKeyForIndex(0)
        : occurrenceKey;
    final index = occurrenceIndexFromKey(requestedKey);
    if (index == null) return null;
    final segments =
        _recurrenceSegments[_seriesSegmentsKey(groupId, event.id)] ??
        <_LocalRecurrenceSegment>[
          _LocalRecurrenceSegment(template: event, ordinalOffset: 0),
        ];
    for (final segment in segments.reversed) {
      if (index < segment.ordinalOffset) continue;
      final projected = recurringOccurrenceAtIndex(
        segment.template,
        index,
        ordinalOffset: segment.ordinalOffset,
      );
      if (projected == null) continue;
      final overridden = _occurrenceOverrides[groupId]?[projected.identityKey];
      if (overridden?.isDeleted == true) return null;
      return overridden ?? projected;
    }
    return null;
  }

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) {
    try {
      _requireActiveMember(groupId, userId);
    } catch (error, stack) {
      return Stream<void>.error(error, stack);
    }
    late final StreamController<void> controller;
    controller = StreamController<void>.broadcast(
      onListen: () {
        _rangeInvalidationControllers
            .putIfAbsent(groupId, () => <StreamController<void>>{})
            .add(controller);
      },
      onCancel: () {
        final controllers = _rangeInvalidationControllers[groupId];
        controllers?.remove(controller);
        if (controllers != null && controllers.isEmpty) {
          _rangeInvalidationControllers.remove(groupId);
        }
      },
    );
    return controller.stream;
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
    for (final controller in List<StreamController<void>>.from(
      _rangeInvalidationControllers[groupId] ??
          const <StreamController<void>>{},
    )) {
      if (!controller.isClosed) controller.add(null);
    }
  }

  void _validateBoundedRangeRequest({
    required String userId,
    required String groupId,
    required EventRange range,
    required int limit,
    String? participantId,
  }) {
    _requireBoundedActiveMember(groupId, userId);
    if (limit < 1 || limit > 200) {
      throw const ScheduleValidationException('일정 페이지 크기를 확인해 주세요.');
    }
    validateIanaTimezone(range.viewTimezone);
    final localStart = utcToWallTimePrecise(range.startUtc, range.viewTimezone);
    final localEnd = utcToWallTimePrecise(range.endUtc, range.viewTimezone);
    bool isMidnight(DateTime value) =>
        value.hour == 0 &&
        value.minute == 0 &&
        value.second == 0 &&
        value.millisecond == 0 &&
        value.microsecond == 0;
    if (!isMidnight(localStart) || !isMidnight(localEnd)) {
      throw const ScheduleValidationException('일정 범위는 현지 자정 경계여야 합니다.');
    }
    final span = calendarDateSpan(
      range.startUtc,
      range.endUtc,
      range.viewTimezone,
    );
    if (span < 1 || span > 366) {
      throw const ScheduleValidationException('일정 범위는 366일 이내여야 합니다.');
    }
    if (participantId != null) {
      final normalized = participantId.trim();
      if (normalized.isEmpty || !_isActiveMember(groupId, normalized)) {
        throw const ScheduleAuthorizationException('일정 멤버는 이 그룹의 활성 멤버여야 합니다.');
      }
    }
  }

  static int _compareEventRangeRows(PlannerEvent left, PlannerEvent right) {
    final byStart = left.startAt.toUtc().compareTo(right.startAt.toUtc());
    if (byStart != 0) return byStart;
    final byId = left.id.compareTo(right.id);
    return byId != 0 ? byId : left.occurrenceKey.compareTo(right.occurrenceKey);
  }

  static bool _isAfterEventRangeCursor(
    PlannerEvent event,
    EventRangeCursor cursor,
  ) {
    final byStart = event.startAt.toUtc().compareTo(cursor.startsAtUtc);
    if (byStart > 0) return true;
    if (byStart < 0) return false;
    final byId = event.id.compareTo(cursor.eventId);
    if (byId > 0) return true;
    if (byId < 0) return false;
    // A v1 cursor intentionally has no occurrence component and therefore
    // cannot resume a repeated projection for the same anchor.  v2 compares
    // the complete tuple exactly.
    return cursor.occurrenceKey.isNotEmpty &&
        event.occurrenceKey.compareTo(cursor.occurrenceKey) > 0;
  }

  List<PlannerEvent> _materializedEventsForRange({
    required String groupId,
    required EventRange range,
    String? participantId,
  }) {
    final raw = _events[groupId] ?? const <PlannerEvent>[];
    final result = <PlannerEvent>[];
    final recurring = <_LocalRecurrenceSegment>[];
    for (final event in raw.where((event) => event.recurrenceRule != null)) {
      final segments =
          _recurrenceSegments[_seriesSegmentsKey(groupId, event.id)];
      if (segments == null) {
        recurring.add(
          _LocalRecurrenceSegment(template: event, ordinalOffset: 0),
        );
      } else {
        recurring.addAll(segments);
      }
    }
    for (final event in raw.where((event) => event.recurrenceRule == null)) {
      if (!event.isDeleted &&
          eventOverlapsCalendarRange(event, range) &&
          (participantId == null || event.memberIds.contains(participantId))) {
        result.add(event);
      }
    }
    // Keep track of identities emitted by the arithmetic schedule walk. An
    // occurrence override may move its effective start into this range while
    // its scheduled start is outside the bounded look-behind (or even years
    // away). Discover such rows from the sparse override index before the
    // final overlap filter instead of requiring the schedule walk to find the
    // original occurrence first.
    final emittedIdentities = <String>{
      for (final event in result) event.identityKey,
    };
    for (final segment in recurring) {
      for (final occurrence in expandRecurringEvent(
        segment.template,
        range,
        ordinalOffset: segment.ordinalOffset,
      )) {
        final overridden =
            _occurrenceOverrides[groupId]?[occurrence.identityKey];
        final resolved = overridden ?? occurrence;
        if (resolved.isDeleted ||
            !eventOverlapsCalendarRange(resolved, range) ||
            (participantId != null &&
                !resolved.memberIds.contains(participantId))) {
          continue;
        }
        result.add(resolved);
        emittedIdentities.add(resolved.identityKey);
      }
    }
    final overrides = _occurrenceOverrides[groupId];
    if (overrides != null) {
      for (final resolved in overrides.values) {
        if (resolved.groupId != groupId ||
            resolved.recurrenceRule == null ||
            !resolved.isOccurrence ||
            resolved.isDeleted ||
            !isValidOccurrenceKey(resolved.occurrenceKey) ||
            !eventOverlapsCalendarRange(resolved, range) ||
            (participantId != null &&
                !resolved.memberIds.contains(participantId)) ||
            !emittedIdentities.add(resolved.identityKey)) {
          continue;
        }
        result.add(resolved);
      }
    }
    return result;
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
    // Membership removal uses current-assignment semantics: an inactive user
    // must not remain on events and rejoining must not resurrect old rows.
    _pruneEventMemberAssignments(groupId, actorId);
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
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    if (!_recordInviteAttempt(
      ledger: _previewAttempts,
      actorId: userId,
      limit: 60,
    )) {
      throw const InviteRateLimitedException();
    }
    final strict = normalizeStrictInviteToken(token);
    final normalized = strict ?? normalizeInviteCode(token);
    if (normalized.isEmpty ||
        (normalizeStrictInviteToken(normalized) == null &&
            normalized != normalizeInviteCode('family'))) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    final matchingInvite = _invites.values
        .where(
          (invite) => normalizeInviteCode(invite.token ?? '') == normalized,
        )
        .firstOrNull;
    PlannerGroup? group;
    DateTime? expiresAt;
    if (matchingInvite != null) {
      group = _groups[matchingInvite.groupId];
      expiresAt = matchingInvite.expiresAt;
      if (group == null || group.isArchived) {
        throw const InviteUnavailableException.invalidOrExpired();
      }
      final isActiveMember = (_members[group.id] ?? const <PlannerMember>[])
          .any((member) => member.id == userId && member.isActive);
      if (!isActiveMember &&
          (matchingInvite.isRevoked ||
              matchingInvite.isExpired ||
              matchingInvite.isExhausted)) {
        throw const InviteUnavailableException.invalidOrExpired();
      }
    } else if (normalized == normalizeInviteCode('family')) {
      // The local demo's hand-written code is intentionally available for
      // manual fallback.  It is not emitted by the strict share-link builder.
      group = _groups['demo-group'];
      expiresAt = DateTime.utc(9999, 12, 31, 23, 59, 59);
      if (group == null || group.isArchived) {
        throw const InviteUnavailableException.invalidOrExpired();
      }
    } else {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    final alreadyMember = (_members[group.id] ?? const <PlannerMember>[]).any(
      (member) => member.id == userId && member.isActive,
    );
    return InvitePreview(
      groupId: group.id,
      groupName: group.name,
      groupDescription: group.description,
      groupTimezone: group.timezone,
      expiresAt: expiresAt.toUtc(),
      alreadyMember: alreadyMember,
    );
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    if (!_recordInviteAttempt(
      ledger: _joinAttempts,
      actorId: userId,
      limit: 20,
    )) {
      throw const InviteRateLimitedException();
    }
    final code = normalizeInviteCode(inviteCode);
    if (code.isEmpty) {
      throw const FormatException('초대 코드를 입력해 주세요.');
    }
    final matchingInvite = _invites.values
        .where((invite) => normalizeInviteCode(invite.token ?? '') == code)
        .firstOrNull;
    final PlannerGroup? group = matchingInvite == null
        ? _groups.values
              .where(
                (candidate) =>
                    candidate.id == 'demo-group' &&
                    code == normalizeInviteCode('family'),
              )
              .firstOrNull
        : _groups[matchingInvite.groupId];
    // Missing, archived, revoked, expired, and exhausted invites deliberately
    // collapse to one terminal reason.  This keeps Local parity with the
    // Supabase preview/join oracle and avoids a token/group existence probe.
    if (group == null || group.isArchived) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    final current = _members[group.id] ?? <PlannerMember>[];
    final existingIndex = current.indexWhere((member) => member.id == userId);
    // Acceptance is idempotent for an already-active member.  The server
    // oracle may have returned this hint even after token expiry/revocation;
    // re-check the live membership before applying invite validity or usage
    // limits and never consume another use in this branch.
    if (existingIndex >= 0 && current[existingIndex].isActive) {
      return group;
    }
    if (matchingInvite != null &&
        (matchingInvite.isRevoked ||
            matchingInvite.isExpired ||
            matchingInvite.isExhausted)) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
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
    final now = _nowUtc();
    final id = 'invite-${now.microsecondsSinceEpoch}-${_inviteCounter++}';
    final token = _generateInviteToken();
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
      _invites.values
          .where((invite) => invite.groupId == groupId)
          .map(
            (invite) => InviteCode(
              id: invite.id,
              groupId: invite.groupId,
              expiresAt: invite.expiresAt,
              maxUses: invite.maxUses,
              usesCount: invite.usesCount,
              version: invite.version,
              token: null,
              revokedAt: invite.revokedAt,
              createdAt: invite.createdAt,
              updatedAt: invite.updatedAt,
            ),
          ),
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
    if (!isActive) {
      // Advance affected event versions so an in-flight editor cannot restore
      // an assignment after moderation completes.
      _pruneEventMemberAssignments(groupId, userId);
    }
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
    if (draft.recurrence != null) {
      return createRecurringEvent(userId, groupId, draft);
    }
    _requireActiveMember(groupId, userId);
    final normalizedDraft = _normalizeDraft(draft);
    final memberIds = _normalizeEventMemberIds(
      groupId,
      normalizedDraft.memberIds,
      defaultCreatorId: normalizedDraft.hasExplicitMemberIds ? null : userId,
    );
    final event = PlannerEvent(
      id: 'event-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
      groupId: groupId,
      title: normalizedDraft.title.trim(),
      note: normalizedDraft.note,
      startAt: normalizedDraft.startAt.toUtc(),
      endAt: normalizedDraft.endAt.toUtc(),
      allDay: normalizedDraft.allDay,
      ownerId: userId,
      memberIds: memberIds.toList(growable: false),
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
  Future<PlannerEvent> createRecurringEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    _requireActiveMember(groupId, userId);
    final rule = draft.recurrence;
    if (rule == null) return createEvent(userId, groupId, draft);
    final normalizedDraft = _normalizeDraft(draft);
    _validateRuleAnchor(rule, normalizedDraft);
    final memberIds = _normalizeEventMemberIds(
      groupId,
      normalizedDraft.memberIds,
      // Recurring series always include their creator in the canonical
      // series-wide assignment, even when the caller supplied an explicit
      // list.  This mirrors the create RPC's creator invariant.
      defaultCreatorId: userId,
    );
    final id = 'event-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final event = PlannerEvent(
      id: id,
      seriesId: id,
      groupId: groupId,
      title: normalizedDraft.title.trim(),
      note: normalizedDraft.note,
      startAt: normalizedDraft.startAt.toUtc(),
      endAt: normalizedDraft.endAt.toUtc(),
      allDay: normalizedDraft.allDay,
      ownerId: userId,
      memberIds: memberIds.toList(growable: false),
      colorValue: normalizedDraft.colorValue,
      timezone: normalizedDraft.timezone,
      updatedAt: DateTime.now().toUtc(),
      allDayStartDate: normalizedDraft.allDayStartDate,
      allDayEndDate: normalizedDraft.allDayEndDate,
      recurrenceRule: rule,
      occurrenceKey: 'single',
      occurrenceIndex: 0,
      isOccurrence: false,
    );
    _events.putIfAbsent(groupId, () => <PlannerEvent>[]).add(event);
    _recurrenceSegments
        .putIfAbsent(
          _seriesSegmentsKey(groupId, id),
          () => <_LocalRecurrenceSegment>[],
        )
        .add(_LocalRecurrenceSegment(template: event, ordinalOffset: 0));
    _emit(groupId);
    // The first occurrence is the useful result of a create RPC.  Keep the
    // series anchor in the backing list while returning the materialized row.
    final firstRange = EventRange(
      startUtc: event.startAt.subtract(const Duration(days: 1)),
      endUtc: event.startAt.add(const Duration(days: 367)),
      viewTimezone: event.timezone,
    );
    return expandRecurringEvent(event, firstRange).firstOrNull ?? event;
  }

  @override
  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    final effectiveActor = actorId ?? event.ownerId;
    _requireActiveMember(event.groupId, effectiveActor);
    final list = _events[event.groupId];
    final baseIndex =
        list?.indexWhere((candidate) => candidate.id == event.id) ?? -1;
    if (list == null || baseIndex < 0) throw StateError('일정을 찾을 수 없습니다.');
    final base = list[baseIndex];
    if (base.ownerId != effectiveActor) {
      throw const ScheduleConflictException('이 일정을 변경할 권한이 없습니다.');
    }
    if (base.version != expectedSeriesVersion ||
        event.occurrenceVersion != expectedOccurrenceVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    final normalizedDraft = _normalizeDraft(draft);
    final keyIsSingle = event.occurrenceKey == 'single';
    final baseRule = base.recurrenceRule;
    if (!keyIsSingle && baseRule == null) {
      throw const ScheduleConflictException('반복 일정 규칙을 확인해 주세요.');
    }
    final isRecurringIdentity = baseRule != null || !keyIsSingle;
    final convertsSingletonToRecurring =
        keyIsSingle &&
        baseRule == null &&
        scope == EventEditScope.all &&
        normalizedDraft.recurrence != null;
    final convertsRecurringToSingleton =
        isRecurringIdentity &&
        scope == EventEditScope.all &&
        normalizedDraft.recurrence == null;
    if (!isRecurringIdentity && !convertsSingletonToRecurring) {
      throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
    }
    // A series anchor (the singleton key) is only editable as an all-scope
    // conversion/update.  Per-occurrence edits must carry an ordinal key.
    if (keyIsSingle &&
        !convertsSingletonToRecurring &&
        !convertsRecurringToSingleton) {
      throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
    }
    final requestedMembers = normalizedDraft.hasExplicitMemberIds
        ? _normalizeEventMemberIds(event.groupId, normalizedDraft.memberIds)
        : event.memberIds;
    final effectiveRule = normalizedDraft.recurrence ?? baseRule;
    if (!convertsRecurringToSingleton) {
      final rule = effectiveRule;
      if (rule == null) {
        throw const ScheduleConflictException('반복 일정 규칙을 확인해 주세요.');
      }
      _validateRuleAnchor(rule, normalizedDraft);
    }
    if (scope != EventEditScope.all &&
        !_sameMemberIdSet(requestedMembers, event.memberIds)) {
      throw const ScheduleConflictException('반복 일정 멤버는 전체 범위에서만 변경할 수 있습니다.');
    }
    final now = _nowUtc();
    final nextSeriesVersion = base.version + 1;
    final targetOrdinal = event.occurrenceIndex;
    final desiredMembers = normalizedDraft.hasExplicitMemberIds
        ? requestedMembers
        : event.memberIds;
    final sameDraftAsOccurrence = _draftMatchesEvent(
      normalizedDraft,
      event,
      desiredMembers,
    );
    final existingOverride =
        _occurrenceOverrides[event.groupId]?[event.identityKey];
    final thisNoOp =
        scope == EventEditScope.thisOccurrence &&
        !keyIsSingle &&
        existingOverride?.isDeleted != true &&
        sameDraftAsOccurrence &&
        normalizedDraft.recurrence == null;
    final rootSegments =
        _recurrenceSegments[_seriesSegmentsKey(event.groupId, event.id)];
    final hasSparseSeriesState =
        (rootSegments?.length ?? 0) != 1 ||
        (rootSegments?.firstOrNull?.ordinalOffset ?? 0) != 0 ||
        _hasSeriesOverrides(event.groupId, event.seriesId);
    final allNoOp =
        scope == EventEditScope.all &&
        !convertsSingletonToRecurring &&
        !convertsRecurringToSingleton &&
        effectiveRule == baseRule &&
        _draftMatchesEvent(normalizedDraft, base, desiredMembers) &&
        !hasSparseSeriesState;
    if (thisNoOp || allNoOp) {
      return RecurrenceMutationReceipt(
        groupId: event.groupId,
        eventId: event.id,
        occurrenceKey: event.occurrenceKey,
        seriesVersion: expectedSeriesVersion,
        // The occurrence version is meaningful only for a `this` override.
        // Future/all operate on the parent series and therefore return the
        // scope-wide zero even when the request is an idempotent no-op.  This
        // keeps the local adapter byte-for-byte compatible with the receipt
        // contract enforced by the Supabase parser.
        occurrenceVersion: scope == EventEditScope.thisOccurrence
            ? expectedOccurrenceVersion
            : 0,
        scope: scope,
        changed: false,
      );
    }
    switch (scope) {
      case EventEditScope.thisOccurrence:
        if (keyIsSingle || baseRule == null) {
          throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
        }
        final overridden = _eventFromDraft(
          event,
          normalizedDraft,
          memberIds: event.memberIds,
          occurrenceVersion: expectedOccurrenceVersion + 1,
        );
        _occurrenceOverrides.putIfAbsent(
          event.groupId,
          () => <String, PlannerEvent>{},
        )[event.identityKey] = overridden;
      case EventEditScope.future:
        if (keyIsSingle || baseRule == null) {
          throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
        }
        _splitFutureSeries(
          groupId: event.groupId,
          base: base,
          target: event,
          draft: normalizedDraft,
          now: now,
        );
        _clearOccurrenceOverrides(
          event.groupId,
          targetOrdinal,
          seriesId: event.seriesId,
        );
      case EventEditScope.all:
        final allMembers = normalizedDraft.hasExplicitMemberIds
            ? requestedMembers
            : base.memberIds;
        if (!allMembers.contains(base.ownerId)) {
          throw const ScheduleAuthorizationException(
            '일정 작성자는 활성 멤버로 유지되어야 합니다.',
          );
        }
        final updatedBase =
            _eventFromDraft(
              base,
              normalizedDraft,
              memberIds: allMembers,
              occurrenceVersion: convertsRecurringToSingleton
                  ? 0
                  : nextSeriesVersion,
            ).copyWith(
              version: nextSeriesVersion,
              updatedAt: now,
              recurrenceRule: effectiveRule,
              clearRecurrenceRule: convertsRecurringToSingleton,
              occurrenceKey: 'single',
              occurrenceIndex: 0,
              isOccurrence: false,
              // The all-scope draft becomes the new series anchor (or singleton
              // instant). Do not retain the pre-edit scheduled wall timestamp.
              clearScheduledStartsAt: true,
              seriesId: base.seriesId,
            );
        list[baseIndex] = updatedBase;
        if (convertsRecurringToSingleton) {
          _recurrenceSegments.remove(
            _seriesSegmentsKey(event.groupId, event.id),
          );
        } else {
          _recurrenceSegments[_seriesSegmentsKey(
            event.groupId,
            event.id,
          )] = <_LocalRecurrenceSegment>[
            _LocalRecurrenceSegment(template: updatedBase, ordinalOffset: 0),
          ];
        }
        _clearSeriesOverrides(event.groupId, base.seriesId);
    }
    list[baseIndex] = list[baseIndex].copyWith(
      version: nextSeriesVersion,
      updatedAt: now,
    );
    _emit(event.groupId);
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey,
      seriesVersion: nextSeriesVersion,
      occurrenceVersion: scope == EventEditScope.thisOccurrence
          ? expectedOccurrenceVersion + 1
          : 0,
      scope: scope,
      changed: true,
    );
  }

  @override
  Future<RecurrenceMutationReceipt> deleteEventOccurrence({
    required PlannerEvent event,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    final effectiveActor = actorId ?? event.ownerId;
    _requireActiveMember(event.groupId, effectiveActor);
    final list = _events[event.groupId];
    final baseIndex =
        list?.indexWhere((candidate) => candidate.id == event.id) ?? -1;
    if (list == null || baseIndex < 0) throw StateError('일정을 찾을 수 없습니다.');
    final base = list[baseIndex];
    if (base.recurrenceRule == null || event.occurrenceKey == 'single') {
      throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
    }
    if (base.ownerId != effectiveActor ||
        base.version != expectedSeriesVersion ||
        event.occurrenceVersion != expectedOccurrenceVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    final priorOverride =
        _occurrenceOverrides[event.groupId]?[event.identityKey];
    if (scope == EventEditScope.thisOccurrence &&
        priorOverride?.isDeleted == true) {
      return RecurrenceMutationReceipt(
        groupId: event.groupId,
        eventId: event.id,
        occurrenceKey: event.occurrenceKey,
        seriesVersion: expectedSeriesVersion,
        occurrenceVersion: priorOverride!.occurrenceVersion,
        scope: scope,
        changed: false,
      );
    }
    final now = _nowUtc();
    final nextSeriesVersion = base.version + 1;
    switch (scope) {
      case EventEditScope.thisOccurrence:
        _occurrenceOverrides.putIfAbsent(
          event.groupId,
          () => <String, PlannerEvent>{},
        )[event.identityKey] = event.copyWith(
          deletedAt: now,
          version: event.version + 1,
          occurrenceVersion: expectedOccurrenceVersion + 1,
          updatedAt: now,
        );
      case EventEditScope.future:
        if (event.occurrenceIndex == 0) {
          // Ordinal zero is the persisted series anchor. Removing only the
          // recurrence segment would make the materializer fall back to that
          // still-live anchor and resurrect the deleted first occurrence.
          // Tombstone the anchor itself before clearing sparse state so every
          // read path remains deletion-safe.
          list[baseIndex] = base.copyWith(
            deletedAt: now,
            version: nextSeriesVersion,
            updatedAt: now,
          );
          _recurrenceSegments.remove(
            _seriesSegmentsKey(event.groupId, event.id),
          );
          _clearSeriesOverrides(event.groupId, base.seriesId);
        } else {
          _splitFutureSeries(
            groupId: event.groupId,
            base: base,
            target: event,
            draft: null,
            now: now,
            deleteFuture: true,
          );
          _clearOccurrenceOverrides(
            event.groupId,
            event.occurrenceIndex,
            seriesId: event.seriesId,
          );
        }
      case EventEditScope.all:
        list[baseIndex] = base.copyWith(
          deletedAt: now,
          version: nextSeriesVersion,
          updatedAt: now,
        );
        _recurrenceSegments.remove(_seriesSegmentsKey(event.groupId, event.id));
        _clearSeriesOverrides(event.groupId, base.seriesId);
    }
    list[baseIndex] = list[baseIndex].copyWith(
      version: nextSeriesVersion,
      updatedAt: now,
    );
    _emit(event.groupId);
    return RecurrenceMutationReceipt(
      groupId: event.groupId,
      eventId: event.id,
      occurrenceKey: event.occurrenceKey,
      seriesVersion: nextSeriesVersion,
      occurrenceVersion: scope == EventEditScope.thisOccurrence
          ? expectedOccurrenceVersion + 1
          : 0,
      scope: scope,
      changed: true,
    );
  }

  PlannerEvent _eventFromDraft(
    PlannerEvent original,
    EventDraft draft, {
    required Iterable<String> memberIds,
    required int occurrenceVersion,
  }) {
    return original.copyWith(
      title: draft.title.trim(),
      note: draft.note,
      startAt: draft.startAt.toUtc(),
      endAt: draft.endAt.toUtc(),
      allDay: draft.allDay,
      memberIds: memberIds.toList(growable: false),
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
      clearAllDayDates: !draft.allDay,
      occurrenceVersion: occurrenceVersion,
      version: original.version + 1,
      updatedAt: _nowUtc(),
      scheduledStartsAt: original.scheduledStartsAt,
      recurrenceRule: original.recurrenceRule,
      isOccurrence: original.isOccurrence,
    );
  }

  void _splitFutureSeries({
    required String groupId,
    required PlannerEvent base,
    required PlannerEvent target,
    required EventDraft? draft,
    required DateTime now,
    bool deleteFuture = false,
  }) {
    final ordinal = target.occurrenceIndex;
    final segments = _recurrenceSegments.putIfAbsent(
      _seriesSegmentsKey(groupId, base.id),
      () => <_LocalRecurrenceSegment>[
        _LocalRecurrenceSegment(template: base, ordinalOffset: 0),
      ],
    );
    final inheritedSegment = segments.reversed
        .where((segment) => segment.ordinalOffset <= ordinal)
        .firstOrNull;
    final inheritedRule =
        inheritedSegment?.template.recurrenceRule ?? base.recurrenceRule!;
    final inheritedLocalOrdinal = inheritedSegment == null
        ? ordinal
        : ordinal - inheritedSegment.ordinalOffset;
    segments.removeWhere((segment) => segment.ordinalOffset >= ordinal);
    if (segments.isNotEmpty && ordinal > 0) {
      // A prior future edit may already have created several segments. Close
      // the segment immediately preceding this split; shortening only the
      // original anchor would leave an older later segment extending through
      // the new boundary and would materialize duplicate occurrences.
      final lastIndex = segments.length - 1;
      final prior = segments[lastIndex];
      final oldRule = prior.template.recurrenceRule!;
      // A future edit/delete closes the prior segment at the target ordinal
      // regardless of whether the original rule was never/count/until.  A
      // plain never/until rule left intact would resurrect occurrences after
      // the requested split.
      final shortened = oldRule.copyWith(
        end: RecurrenceEnd.count,
        count: ordinal - prior.ordinalOffset,
        clearUntilDate: true,
      );
      segments[lastIndex] = _LocalRecurrenceSegment(
        template: prior.template.copyWith(recurrenceRule: shortened),
        ordinalOffset: prior.ordinalOffset,
      );
    }
    if (deleteFuture || draft == null) return;
    final rule = draft.recurrence ?? inheritedRule;
    final remainingRule =
        draft.recurrence == null && inheritedRule.end == RecurrenceEnd.count
        ? inheritedRule.copyWith(
            end: RecurrenceEnd.count,
            count: (inheritedRule.count! - inheritedLocalOrdinal).clamp(
              1,
              1 << 30,
            ),
            clearUntilDate: true,
          )
        : rule;
    final template = PlannerEvent(
      id: base.id,
      seriesId: base.seriesId,
      groupId: base.groupId,
      title: draft.title.trim(),
      note: draft.note,
      startAt: target.startAt,
      endAt: target.endAt,
      allDay: draft.allDay,
      ownerId: base.ownerId,
      memberIds: base.memberIds,
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
      version: base.version + 1,
      updatedAt: now,
      recurrenceRule: remainingRule,
    );
    segments.add(
      _LocalRecurrenceSegment(template: template, ordinalOffset: ordinal),
    );
  }

  bool _hasSeriesOverrides(String groupId, String seriesId) {
    final overrides = _occurrenceOverrides[groupId];
    if (overrides == null || overrides.isEmpty) return false;
    final prefix = '$seriesId|';
    return overrides.keys.any((key) => key.startsWith(prefix));
  }

  void _clearSeriesOverrides(String groupId, String seriesId) {
    final overrides = _occurrenceOverrides[groupId];
    if (overrides == null) return;
    final prefix = '$seriesId|';
    overrides.removeWhere((key, _) => key.startsWith(prefix));
    if (overrides.isEmpty) _occurrenceOverrides.remove(groupId);
  }

  void _clearOccurrenceOverrides(
    String groupId,
    int fromOrdinal, {
    required String seriesId,
  }) {
    final overrides = _occurrenceOverrides[groupId];
    if (overrides == null) return;
    final prefix = '$seriesId|';
    overrides.removeWhere((key, _) {
      if (!key.startsWith(prefix)) return false;
      final ordinal = occurrenceIndexFromKey(key.substring(prefix.length));
      return ordinal != null && ordinal >= fromOrdinal;
    });
    if (overrides.isEmpty) _occurrenceOverrides.remove(groupId);
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
    final memberIds = _normalizeEventMemberIds(
      existing.groupId,
      normalizedEvent.memberIds,
    );
    final updated = normalizedEvent.copyWith(
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
      memberIds: memberIds,
    );
    list[index] = updated;
    _emit(normalizedEvent.groupId);
    return updated;
  }

  @override
  Future<RecurrenceMutationReceipt> replaceRecurringEventMembers({
    required PlannerEvent event,
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    final stored = _events.values
        .expand((items) => items)
        .where((candidate) => candidate.id == event.id)
        .firstOrNull;
    final recurring =
        stored != null &&
        (stored.recurrenceRule != null || stored.occurrenceKey != 'single');
    if (stored == null ||
        stored.groupId != event.groupId ||
        stored.ownerId != event.ownerId ||
        stored.seriesId != event.seriesId ||
        !recurring ||
        !isValidOccurrenceKey(event.occurrenceKey)) {
      throw const ScheduleValidationException('반복 일정 항목을 확인해 주세요.');
    }
    final normalizedMemberIds = canonicalEventMemberIds(memberIds);
    if (!normalizedMemberIds.contains(stored.ownerId)) {
      throw const ScheduleValidationException('반복 일정 작성자는 멤버에서 제외할 수 없습니다.');
    }
    final updated = await replaceEventMembers(
      stored.id,
      memberIds: normalizedMemberIds,
      expectedVersion: expectedVersion,
      actorId: actorId,
    );
    final selectedKey = event.occurrenceKey == 'single'
        ? occurrenceKeyForIndex(0)
        : event.occurrenceKey;
    return RecurrenceMutationReceipt(
      groupId: stored.groupId,
      eventId: stored.id,
      occurrenceKey: selectedKey,
      seriesVersion: updated.version,
      occurrenceVersion: 0,
      scope: EventEditScope.all,
      changed: updated.version != expectedVersion,
    );
  }

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    PlannerEvent? existing;
    List<PlannerEvent>? list;
    var index = -1;
    for (final entry in _events.entries) {
      final candidateIndex = entry.value.indexWhere(
        (event) => event.id == eventId,
      );
      if (candidateIndex < 0) continue;
      list = entry.value;
      index = candidateIndex;
      existing = list[candidateIndex];
      break;
    }
    if (existing == null || list == null || index < 0) {
      throw StateError('일정을 찾을 수 없습니다.');
    }

    final effectiveActor = actorId ?? existing.ownerId;
    _requireActiveMember(existing.groupId, effectiveActor);
    final isEventOwner = effectiveActor == existing.ownerId;
    final isGroupOwner = _isActiveGroupOwner(existing.groupId, effectiveActor);
    if (!isEventOwner && !isGroupOwner) {
      throw const ScheduleConflictException('이 일정의 멤버를 변경할 권한이 없습니다.');
    }
    if (existing.isDeleted) {
      throw const ScheduleConflictException('삭제된 일정은 변경할 수 없습니다.');
    }
    if (existing.version != expectedVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    // An empty replacement is intentional for legacy singleton events and
    // differs from create's creator default. Recurring series are checked
    // below and must retain their creator assignment.
    final normalizedMemberIds = _normalizeEventMemberIds(
      existing.groupId,
      memberIds,
    );
    final recurring =
        existing.recurrenceRule != null || existing.occurrenceKey != 'single';
    if (recurring && !normalizedMemberIds.contains(existing.ownerId)) {
      throw const ScheduleValidationException('반복 일정 작성자는 멤버에서 제외할 수 없습니다.');
    }
    if (_sameMemberIdSet(existing.memberIds, normalizedMemberIds)) {
      // Replacing with the canonical current set is an idempotent no-op.  Do
      // not manufacture a version transition or realtime event for a write
      // that changed no participant assignment.
      return existing;
    }
    final updated = existing.copyWith(
      memberIds: normalizedMemberIds,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    list[index] = updated;
    final segments =
        _recurrenceSegments[_seriesSegmentsKey(existing.groupId, existing.id)];
    if (segments != null && existing.recurrenceRule != null) {
      for (
        var segmentIndex = 0;
        segmentIndex < segments.length;
        segmentIndex++
      ) {
        final segment = segments[segmentIndex];
        if (segment.template.id != existing.id) continue;
        segments[segmentIndex] = _LocalRecurrenceSegment(
          template: segment.template.copyWith(
            memberIds: normalizedMemberIds,
            version: updated.version,
            updatedAt: updated.updatedAt,
          ),
          ordinalOffset: segment.ordinalOffset,
        );
      }
    }
    _syncSeriesOverrideMembers(
      existing.groupId,
      existing.seriesId,
      normalizedMemberIds,
      version: updated.version,
      updatedAt: updated.updatedAt,
    );
    _emit(existing.groupId);
    return updated;
  }

  static bool _sameMemberIdSet(Iterable<String> left, Iterable<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  void _syncSeriesOverrideMembers(
    String groupId,
    String seriesId,
    Iterable<String> memberIds, {
    required int version,
    required DateTime updatedAt,
  }) {
    final overrides = _occurrenceOverrides[groupId];
    if (overrides == null || overrides.isEmpty) return;
    final canonical = canonicalEventMemberIds(memberIds);
    for (final entry in overrides.entries.toList(growable: false)) {
      final override = entry.value;
      if (override.seriesId != seriesId) continue;
      overrides[entry.key] = override.copyWith(
        memberIds: canonical,
        version: version,
        updatedAt: updatedAt,
      );
    }
  }

  static bool _draftMatchesEvent(
    EventDraft draft,
    PlannerEvent event,
    Iterable<String> memberIds,
  ) {
    final sameDates = !draft.allDay
        ? event.allDay == false &&
              event.allDayStartDate == null &&
              event.allDayEndDate == null
        : event.allDay == true &&
              draft.allDayStartDate == event.allDayStartDate &&
              draft.allDayEndDate == event.allDayEndDate;
    return draft.title.trim() == event.title &&
        draft.note == event.note &&
        draft.startAt.toUtc() == event.startAt.toUtc() &&
        draft.endAt.toUtc() == event.endAt.toUtc() &&
        draft.allDay == event.allDay &&
        sameDates &&
        draft.colorValue == event.colorValue &&
        draft.timezone == event.timezone &&
        _sameMemberIdSet(memberIds, event.memberIds);
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
        memberIds: draft.hasExplicitMemberIds ? draft.memberIds : null,
        colorValue: draft.colorValue,
        timezone: draft.timezone,
        allDayStartDate: startDate,
        allDayEndDate: endDate,
        recurrence: draft.recurrence,
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
      memberIds: draft.hasExplicitMemberIds ? draft.memberIds : null,
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: startDate,
      allDayEndDate: endDate,
      recurrence: draft.recurrence,
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

  bool _isActiveGroupOwner(String groupId, String userId) {
    final group = _groups[groupId];
    if (group == null || group.isArchived) return false;
    final ownerId =
        group.ownerId ??
        _members[groupId]
            ?.where((member) => member.isOwner && member.isActive)
            .firstOrNull
            ?.id;
    final membership = _members[groupId]
        ?.where((member) => member.id == userId)
        .firstOrNull;
    return ownerId == userId && membership?.isActive == true;
  }

  /// Canonicalizes and validates a participant list against the current
  /// active memberships.  [defaultCreatorId] is used only for new-event
  /// creation. When supplied, the creator is always included in the returned
  /// canonical series assignment; callers that intentionally clear an
  /// existing assignment omit this argument.
  List<String> _normalizeEventMemberIds(
    String groupId,
    Iterable<String> memberIds, {
    String? defaultCreatorId,
  }) {
    final group = _groups[groupId];
    if (group == null) throw StateError('그룹을 찾을 수 없습니다.');
    if (group.isArchived) {
      throw const ScheduleConflictException('보관된 그룹에서는 멤버를 변경할 수 없습니다.');
    }
    final normalized = <String>[];
    for (final id in canonicalEventMemberIds(memberIds)) {
      if (!_isActiveMember(groupId, id)) {
        throw const ScheduleConflictException('일정 멤버는 이 그룹의 활성 멤버여야 합니다.');
      }
      normalized.add(id);
    }
    if (defaultCreatorId != null) {
      final creator = defaultCreatorId.trim();
      if (creator.isEmpty || !_isActiveMember(groupId, creator)) {
        throw const ScheduleConflictException('일정 작성자는 활성 멤버여야 합니다.');
      }
      if (!normalized.contains(creator)) normalized.add(creator);
    }
    normalized.sort();
    return List<String>.unmodifiable(normalized);
  }

  void _pruneEventMemberAssignments(String groupId, String userId) {
    final list = _events[groupId];
    if (list == null || userId.trim().isEmpty) return;
    final now = DateTime.now().toUtc();
    for (var index = 0; index < list.length; index++) {
      final event = list[index];
      // Membership pruning is current-assignment maintenance.  Deleted
      // events are retained as history (and the remote database intentionally
      // keeps their child rows), so never rewrite their participant IDs or
      // versions during a later leave/deactivation.
      if (event.isDeleted || _groups[groupId]?.isArchived == true) continue;
      if (!event.memberIds.contains(userId)) continue;
      list[index] = event.copyWith(
        memberIds: event.memberIds.where((id) => id != userId).toList(),
        version: event.version + 1,
        updatedAt: now,
      );
      final updated = list[index];
      final segments =
          _recurrenceSegments[_seriesSegmentsKey(groupId, event.id)];
      if (segments != null && updated.recurrenceRule != null) {
        for (
          var segmentIndex = 0;
          segmentIndex < segments.length;
          segmentIndex++
        ) {
          final segment = segments[segmentIndex];
          if (segment.template.id != updated.id) continue;
          segments[segmentIndex] = _LocalRecurrenceSegment(
            template: segment.template.copyWith(
              memberIds: updated.memberIds,
              version: updated.version,
              updatedAt: updated.updatedAt,
            ),
            ordinalOffset: segment.ordinalOffset,
          );
        }
      }
      // Occurrence overrides are full PlannerEvent snapshots in the local
      // adapter. Keep their inherited series assignment and parent version
      // in lockstep with the anchor/segments; otherwise a this-occurrence
      // override can keep a deactivated participant and still pass a later
      // participant-filtered materialization (unlike the SQL path, which
      // derives every row's members from event_members).
      _syncSeriesOverrideMembers(
        groupId,
        updated.seriesId,
        updated.memberIds,
        version: updated.version,
        updatedAt: updated.updatedAt,
      );
    }
    // The caller emits the membership/lifecycle changes after this helper so
    // all event rows are delivered in one coherent snapshot.
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

  void _requireBoundedActiveMember(String groupId, String userId) {
    try {
      _requireActiveMember(groupId, userId);
    } on ScheduleAuthorizationException {
      rethrow;
    } on ScheduleConflictException {
      throw const ScheduleAuthorizationException('그룹을 사용할 수 없습니다.');
    } on StateError {
      throw const ScheduleAuthorizationException('그룹을 사용할 수 없습니다.');
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

  static void _validateRuleAnchor(RecurrenceRule rule, EventDraft draft) {
    final anchorDate = draft.allDay
        ? dateOnly(
            draft.allDayStartDate ??
                utcToWallTime(draft.startAt, draft.timezone),
          )
        : dateOnly(utcToWallTime(draft.startAt, draft.timezone));
    if (rule.end == RecurrenceEnd.until &&
        (rule.untilDate == null ||
            dateOnly(rule.untilDate!).isBefore(anchorDate))) {
      throw const FormatException('반복 종료 날짜는 시작 날짜 이후여야 합니다.');
    }
    final duration = draft.allDay
        ? civilDateOnly(
            draft.allDayEndDate ?? utcToWallTime(draft.endAt, draft.timezone),
          ).difference(
            civilDateOnly(
              draft.allDayStartDate ??
                  utcToWallTime(draft.startAt, draft.timezone),
            ),
          )
        // SQL validates a timed recurrence's maximum length in the event's
        // IANA wall clock (`at time zone`), not as elapsed UTC seconds. A
        // civil 366-day span crossing fall-back is 366 days + 1h in UTC,
        // while one crossing spring-forward is 366 days - 1h. Use UTC-tagged
        // civil tuples so this check is deterministic on every device.
        : utcToCivilWallTimePrecise(draft.endAt, draft.timezone).difference(
            utcToCivilWallTimePrecise(draft.startAt, draft.timezone),
          );
    if (duration <= Duration.zero || duration > const Duration(days: 366)) {
      throw const FormatException('반복 일정의 길이는 366일 이내여야 합니다.');
    }
    if (rule.frequency != RecurrenceFrequency.weekly) return;
    final wall = utcToWallTimePrecise(draft.startAt, draft.timezone);
    if (!rule.weekdays.contains(wall.weekday)) {
      throw const FormatException('주간 반복 요일에 시작 요일을 포함해 주세요.');
    }
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

  @override
  bool get useBoundedEventRangeReads => true;

  @override
  bool get requireExactEventMutationResults => true;

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
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) => Future<EventRangePage>.error(_error);

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) => Future<PlannerEvent?>.error(_error);

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) =>
      Stream<void>.error(_error);

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
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) => Future<InvitePreview>.error(ScheduleCapabilityException(message));

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
  Future<PlannerEvent> createRecurringEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) => Future<PlannerEvent>.error(_error);

  @override
  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) => Future<RecurrenceMutationReceipt>.error(_error);

  @override
  Future<RecurrenceMutationReceipt> deleteEventOccurrence({
    required PlannerEvent event,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) => Future<RecurrenceMutationReceipt>.error(_error);

  @override
  Future<PlannerEvent?> eventOccurrenceByKey({
    required String userId,
    required String groupId,
    required String eventId,
    required String occurrenceKey,
  }) => Future<PlannerEvent?>.error(_error);

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
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
        GroupLifecycleCapability,
        EventMemberAssignmentCapability,
        RecurringEventMemberAssignmentCapability,
        RecurrenceCapability,
        BoundedEventRangeReadCapability,
        EventByIdReadCapability,
        EventOccurrenceReadCapability,
        InvitePreviewCapability {
  /// Current authenticated actor used by authenticated-only capabilities.
  /// Kept as a small overridable seam so transport tests can provide a
  /// matching session without manufacturing a signed JWT; production code
  /// always reads the Supabase auth client.
  String? get currentSessionUserId => _client.auth.currentUser?.id;

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
  int _rangeInvalidationChannelCounter = 0;

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
    return _watchEventsWithMembers(groupId);
  }

  /// Parent event stream seam used by the legacy member-merge path. Keeping
  /// this as an overridable method lets deterministic tests feed realtime rows
  /// without a live websocket; production callers use the Supabase stream.
  Stream<List<Map<String, dynamic>>> eventRowsStream(String groupId) {
    return _client
        .from('events')
        .stream(primaryKey: const <String>['id'])
        .eq('group_id', groupId);
  }

  @override
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  }) async {
    if (userId.trim().isEmpty || groupId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션과 그룹을 확인해 주세요.');
    }
    _validateRemoteRangeShape(range, limit);
    // The v2 RPC is the default production calendar path.  Do not issue a
    // request with a missing or mismatched auth context: the local user id is
    // only a routing hint and must agree with the current Supabase session.
    _requireCurrentRemoteUser(userId);
    final normalizedParticipant = participantId?.trim();
    if (participantId != null && normalizedParticipant!.isEmpty) {
      throw const ScheduleValidationException('일정 멤버를 확인해 주세요.');
    }
    if (cursor != null &&
        cursor.occurrenceKey.isNotEmpty &&
        !isValidOccurrenceKey(cursor.occurrenceKey)) {
      throw const ScheduleValidationException('지원하지 않는 페이지 커서 버전입니다.');
    }
    final result = await _client.rpc<dynamic>(
      'events_for_range_v2',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_range_start': range.startUtc.toIso8601String(),
        'p_range_end': range.endUtc.toIso8601String(),
        'p_view_timezone': range.viewTimezone,
        'p_limit': limit,
        'p_cursor': cursor?.encode(),
        'p_participant_id': normalizedParticipant,
      },
    );
    return _eventRangePageFromRpcResult(
      result,
      expectedGroupId: groupId,
      range: range,
      cursor: cursor,
      limit: limit,
      participantId: normalizedParticipant,
    );
  }

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) async {
    if (userId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        eventId.trim().isEmpty ||
        eventId != eventId.trim()) {
      throw const ScheduleValidationException('로그인 세션과 일정을 확인해 주세요.');
    }
    _requireCurrentRemoteUser(userId);
    final usableGroup = await _readUsableGroup(userId, groupId);
    if (usableGroup == null) {
      throw const ScheduleAuthorizationException('그룹을 사용할 수 없습니다.');
    }
    final raw = await _client
        .from('events')
        .select(
          'id,group_id,created_by,title,description,starts_at,ends_at,timezone,is_all_day,all_day_start,all_day_end,version,deleted_at,created_at,updated_at,color_value',
        )
        .eq('id', eventId)
        .eq('group_id', groupId)
        .maybeSingle();
    if (raw == null) return null;
    final row = Map<String, dynamic>.from(raw);
    if (row['id'] != eventId || row['group_id'] != groupId) {
      throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
    }
    if (row['deleted_at'] != null) return null;
    final memberRows = await _readEventMemberRows(<String>[eventId]);
    final memberIds = memberRows[eventId];
    if (memberIds == null) {
      throw const ScheduleConflictException('일정 멤버 응답을 확인할 수 없습니다.');
    }
    final complete = <String, dynamic>{...row, 'member_ids': memberIds};
    if (!_hasCompleteEventFields(complete)) {
      throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
    }
    return _eventFromRow(complete, memberIds: memberIds);
  }

  @override
  Future<PlannerEvent?> eventOccurrenceByKey({
    required String userId,
    required String groupId,
    required String eventId,
    required String occurrenceKey,
  }) async {
    if (userId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        eventId.trim().isEmpty ||
        eventId != eventId.trim() ||
        !isValidOccurrenceKey(occurrenceKey)) {
      throw const ScheduleValidationException('로그인 세션과 일정을 확인해 주세요.');
    }
    _requireCurrentRemoteUser(userId);
    final usableGroup = await _readUsableGroup(userId, groupId);
    if (usableGroup == null) {
      throw const ScheduleAuthorizationException('그룹을 사용할 수 없습니다.');
    }
    final result = await _client.rpc<dynamic>(
      'event_occurrence_by_key',
      params: <String, dynamic>{
        'p_event_id': eventId,
        'p_occurrence_key': occurrenceKey,
      },
    );
    final row = _strictSingleRpcMap(result);
    final returnedKey = row?['occurrence_key'];
    final isRecurringAlias =
        occurrenceKey == 'single' && returnedKey == occurrenceKeyForIndex(0);
    if (row == null ||
        !_hasCompleteEventFields(row, strictLifecycleTimestamps: true) ||
        row['group_id'] != groupId ||
        row['id'] != eventId ||
        (returnedKey != occurrenceKey && !isRecurringAlias) ||
        (isRecurringAlias
            ? (row['is_occurrence'] != true || row['recurrence_rule'] == null)
            : (occurrenceKey != 'single' && row['is_occurrence'] != true))) {
      throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
    }
    final memberIds = _strictMemberIds(row['member_ids']);
    if (memberIds == null) {
      throw const ScheduleConflictException('일정 멤버 응답을 확인할 수 없습니다.');
    }
    return _eventFromRow(row, memberIds: memberIds);
  }

  @override
  Stream<void> watchEventInvalidations(String userId, String groupId) {
    if (userId.trim().isEmpty || groupId.trim().isEmpty) {
      return Stream<void>.error(
        const ScheduleValidationException('로그인 세션과 그룹을 확인해 주세요.'),
      );
    }
    late final StreamController<void> controller;
    _EventInvalidationChannelState? active;
    Timer? reconnectTimer;
    Timer? recoveryTimer;
    var cancelled = false;
    var reconnectScheduled = false;
    var reconnectInFlight = false;
    var hasSubscribed = false;
    var currentChannelSubscribed = false;
    var channelRemovalInFlight = 0;
    late Future<void> Function() subscribeChannel;

    Future<void> removeChannel(RealtimeChannel? candidate) async {
      if (candidate == null) return;
      channelRemovalInFlight += 1;
      try {
        await _client.removeChannel(candidate);
      } catch (_) {
        // Best-effort cleanup; the next generation remains guarded by the
        // cancelled/reconnect flags below.
      } finally {
        channelRemovalInFlight -= 1;
      }
    }

    void scheduleReconnect() {
      if (cancelled ||
          controller.isClosed ||
          reconnectScheduled ||
          reconnectInFlight ||
          channelRemovalInFlight > 0) {
        return;
      }
      reconnectScheduled = true;
      reconnectTimer?.cancel();
      reconnectTimer = Timer(const Duration(seconds: 1), () {
        reconnectTimer = null;
        reconnectScheduled = false;
        unawaited(subscribeChannel());
      });
    }

    Future<void> retireFailedChannel(
      _EventInvalidationChannelState state,
    ) async {
      // Mark before awaiting removal: SDKs may report `closed` synchronously
      // as part of removeChannel, and that callback must not schedule a second
      // reconnect or remove a newer channel.
      state.closing = true;
      await removeChannel(state.channel);
      if (!cancelled && !controller.isClosed && active == null) {
        scheduleReconnect();
      }
    }

    _EventInvalidationChannelState buildChannel() {
      late final _EventInvalidationChannelState state;
      final next = _client
          .channel(
            'events-range-invalidation-${++_rangeInvalidationChannelCounter}',
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'events',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'group_id',
              value: groupId,
            ),
            // Parent event version changes are the Feature5 participant
            // signal. Keep the invalidation payload change-only and do
            // not expose descriptions or participant rows.
            select: const <String>['id', 'group_id', 'version', 'deleted_at'],
            callback: (_) {
              // A retired SDK channel can still deliver one queued payload
              // (or even rejoin itself).  Only the currently registered
              // generation may invalidate the controller.
              if (!cancelled &&
                  !controller.isClosed &&
                  !state.closing &&
                  identical(active, state)) {
                controller.add(null);
              }
            },
          );
      state = _EventInvalidationChannelState(next);
      return state;
    }

    subscribeChannel = () async {
      if (cancelled || controller.isClosed || reconnectInFlight) return;
      reconnectInFlight = true;
      final previous = active;
      active = null;
      if (previous != null) {
        previous.closing = true;
        await removeChannel(previous.channel);
      }
      if (cancelled || controller.isClosed) {
        reconnectInFlight = false;
        return;
      }
      try {
        final state = buildChannel();
        active = state;
        currentChannelSubscribed = false;
        state.channel.subscribe((status, [error]) {
          if (cancelled ||
              controller.isClosed ||
              state.closing ||
              !identical(active, state)) {
            return;
          }
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (state.subscribedHandled) return;
            state.subscribedHandled = true;
            // A successful re-subscription is itself a bounded recovery
            // signal: an event mutation could have happened while the old
            // socket was down, so force the controller to refetch once.
            if (hasSubscribed) controller.add(null);
            hasSubscribed = true;
            currentChannelSubscribed = true;
            return;
          }
          if (status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut ||
              status == RealtimeSubscribeStatus.closed) {
            if (state.failureHandled) return;
            state.failureHandled = true;
            // Capture identity before clearing active: a callback from an old
            // channel must never reset the subscription state of a newer one.
            final isCurrent = identical(active, state);
            if (isCurrent) {
              active = null;
              currentChannelSubscribed = false;
            }
            controller.addError(error ?? StateError('일정 실시간 연결을 확인해 주세요.'));
            unawaited(retireFailedChannel(state));
          }
        });
      } catch (error, stack) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stack);
          final state = active;
          if (state != null) {
            state.failureHandled = true;
            state.closing = true;
            active = null;
            unawaited(retireFailedChannel(state));
          } else {
            scheduleReconnect();
          }
        }
      } finally {
        reconnectInFlight = false;
      }
    };

    Future<void> cancel() async {
      cancelled = true;
      reconnectTimer?.cancel();
      reconnectTimer = null;
      recoveryTimer?.cancel();
      recoveryTimer = null;
      final current = active;
      active = null;
      currentChannelSubscribed = false;
      if (current != null) {
        current.closing = true;
        await removeChannel(current.channel);
      }
    }

    controller = StreamController<void>.broadcast(
      onListen: () {
        if (cancelled) return;
        // One active channel at a time.  A bounded retry plus the periodic
        // fallback repairs a dropped/missed socket without an unbounded
        // reconnect loop or duplicate subscriptions.
        recoveryTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
          if (!cancelled && (active == null || !currentChannelSubscribed)) {
            scheduleReconnect();
          }
        });
        unawaited(subscribeChannel());
      },
      onCancel: cancel,
    );
    return controller.stream;
  }

  /// Rebuilds an immutable event snapshot whenever the parent events stream
  /// changes.  Participant rows intentionally have no realtime publication;
  /// every participant mutation bumps the parent event version, which is the
  /// signal that schedules this batch child read.
  Stream<List<PlannerEvent>> _watchEventsWithMembers(String groupId) {
    late final StreamController<List<PlannerEvent>> controller;
    StreamSubscription<List<Map<String, dynamic>>>? subscription;
    Timer? retryTimer;
    var cancelled = false;
    var generation = 0;
    List<PlannerEvent>? latestGood;

    Future<void> refresh(List<Map<String, dynamic>> rows) async {
      retryTimer?.cancel();
      retryTimer = null;
      final token = ++generation;
      try {
        final eventRows = rows.whereType<Map<String, dynamic>>().toList(
          growable: false,
        );
        final ids = <String>[];
        final seen = <String>{};
        for (final row in eventRows) {
          final id = row['id'];
          if (id is! String || id.trim().isEmpty || !seen.add(id)) {
            throw StateError('일정 응답을 확인할 수 없습니다.');
          }
          // The parent realtime projection normally omits event_members.  It
          // must still carry a complete, strictly validated event payload;
          // otherwise _eventFromRow could normalize malformed timestamps or
          // inverted ranges before the child assignment read completes.
          if (!_hasCompleteEventFields(row, requireMemberIds: false)) {
            throw StateError('일정 응답을 확인할 수 없습니다.');
          }
          ids.add(id);
        }
        final memberRows = await eventMemberRows(ids);
        if (cancelled || token != generation) return;
        final merged = <PlannerEvent>[];
        for (final row in eventRows) {
          final id = row['id'] as String;
          final parsed = memberRows[id];
          // A successful child query always creates a map entry, including an
          // explicit empty assignment.  Do not fabricate a creator here.
          if (parsed == null) {
            throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
          }
          final complete = <String, dynamic>{...row, 'member_ids': parsed};
          if (!_hasCompleteEventFields(complete)) {
            throw StateError('일정 응답을 확인할 수 없습니다.');
          }
          final event = _eventFromRow(complete, memberIds: parsed);
          if (!event.isDeleted) merged.add(event);
        }
        latestGood = List<PlannerEvent>.unmodifiable(merged);
        if (!controller.isClosed) controller.add(latestGood!);
      } catch (error, stack) {
        // Keep the last successful snapshot on a child read/parse failure;
        // emitting an empty list would look like a privacy revocation.
        if (!cancelled && token == generation && !controller.isClosed) {
          controller.addError(error, stack);
          // Child rows are not part of the realtime publication, so a
          // transient REST failure would otherwise leave this parent snapshot
          // stale forever. Retry the exact generation after a short delay;
          // any newer parent snapshot or cancellation invalidates this work.
          retryTimer = Timer(const Duration(milliseconds: 250), () {
            if (!cancelled && token == generation && !controller.isClosed) {
              unawaited(refresh(rows));
            }
          });
        }
      }
    }

    Future<void> cancel() async {
      cancelled = true;
      generation++;
      retryTimer?.cancel();
      retryTimer = null;
      final current = subscription;
      subscription = null;
      if (current != null) {
        try {
          await current.cancel();
        } catch (_) {
          // Best-effort cancellation keeps a stale stream from blocking a
          // newer group selection.
        }
      }
    }

    controller = StreamController<List<PlannerEvent>>(
      onListen: () {
        try {
          subscription = eventRowsStream(groupId).listen(
            (rows) => unawaited(refresh(rows)),
            onError: (Object error, StackTrace stack) {
              if (!cancelled && !controller.isClosed) {
                controller.addError(error, stack);
              }
            },
          );
        } catch (error, stack) {
          if (!cancelled && !controller.isClosed) {
            controller.addError(error, stack);
          }
        }
      },
      onCancel: cancel,
    );
    return controller.stream;
  }

  Future<Map<String, List<String>>> _readEventMemberRows(
    Iterable<String> eventIds,
  ) async {
    final ids = eventIds.toList(growable: false);
    final result = <String, List<String>>{for (final id in ids) id: <String>[]};
    if (ids.isEmpty) return result;
    final dynamic rawRows = await _client
        .from('event_members')
        .select('event_id,user_id')
        .inFilter('event_id', ids)
        .order('user_id', ascending: true);
    if (rawRows is! List) {
      throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
    }
    final seen = <String, Set<String>>{for (final id in ids) id: <String>{}};
    for (final raw in rawRows) {
      if (raw is! Map) throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
      final row = raw.cast<String, dynamic>();
      final eventId = row['event_id'];
      final userId = row['user_id'];
      final normalizedEventId = eventId is String ? eventId.trim() : null;
      final normalizedUserId = userId is String ? userId.trim() : null;
      if (eventId is! String ||
          userId is! String ||
          normalizedEventId != eventId ||
          normalizedUserId == null ||
          normalizedUserId.isEmpty ||
          !result.containsKey(normalizedEventId) ||
          !seen[normalizedEventId]!.add(normalizedUserId)) {
        throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
      }
      result[normalizedEventId]!.add(normalizedUserId);
    }
    for (final idsForEvent in result.values) {
      idsForEvent.sort();
    }
    return <String, List<String>>{
      for (final entry in result.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    };
  }

  /// Child assignment read seam paired with [eventRowsStream].  The concrete
  /// implementation performs one ordered batch query; test doubles may
  /// override it to exercise realtime merge and malformed-row handling.
  Future<Map<String, List<String>>> eventMemberRows(
    Iterable<String> eventIds,
  ) => _readEventMemberRows(eventIds);

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

  void _requireCurrentRemoteUser(String? expectedUserId) {
    final current = currentSessionUserId;
    if (expectedUserId == null ||
        expectedUserId.trim().isEmpty ||
        current == null ||
        current != expectedUserId) {
      throw const ScheduleAuthorizationException('로그인 세션을 다시 확인해 주세요.');
    }
  }

  Future<dynamic> _recurrenceRpc(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    try {
      return await _client.rpc<dynamic>(functionName, params: params);
    } catch (error) {
      if (error is PostgrestException) {
        switch (error.code) {
          case '28000':
            throw const ScheduleAuthorizationException('로그인 세션을 다시 확인해 주세요.');
          case '42501':
            throw const ScheduleAuthorizationException('일정을 사용할 권한이 없습니다.');
          case '22023':
            throw const ScheduleValidationException('반복 일정 요청을 확인해 주세요.');
          case '40001':
            throw const ScheduleConflictException(
              '다른 사용자가 반복 일정을 변경했습니다. 최신 내용을 불러왔어요.',
            );
        }
      }
      rethrow;
    }
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
    StreamSubscription<List<PlannerEvent>>? eventsSubscription;
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
        eventsSubscription = _watchEventsWithMembers(groupId).listen((rows) {
          if (cancelled) return;
          latestEvents = List<PlannerEvent>.unmodifiable(rows);
          if (usable && !controller.isClosed) {
            controller.add(latestEvents!);
          } else {
            emitEmpty();
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
    var forceEmitQueued = false;

    void emit(PlannerGroup? next, {bool force = false}) {
      if (cancelled || controller.isClosed) return;
      if (!force && hasValue && current == next) return;
      current = next;
      hasValue = true;
      controller.add(next);
    }

    Future<void> checkAuthoritatively({bool forceEmit = false}) async {
      if (cancelled) return;
      if (checkInFlight) {
        checkQueued = true;
        forceEmitQueued = forceEmitQueued || forceEmit;
        return;
      }
      checkInFlight = true;
      try {
        emit(await _readUsableGroup(userId, groupId), force: forceEmit);
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
          final queuedForceEmit = forceEmitQueued;
          forceEmitQueued = false;
          unawaited(checkAuthoritatively(forceEmit: queuedForceEmit));
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
        (_) => unawaited(checkAuthoritatively(forceEmit: true)),
      );
      try {
        membershipsSubscription = _client
            .from('memberships')
            .stream(primaryKey: const <String>['group_id', 'user_id'])
            .eq('group_id', groupId)
            .listen(
              // A different member's deactivation/removal must refresh the
              // selected group's roster too.  The authoritative read remains
              // requester-scoped; this signal only schedules that read.
              (_) => unawaited(checkAuthoritatively(forceEmit: true)),
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
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    final normalizedToken = normalizeStrictInviteToken(token);
    if (normalizedToken == null) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    // The caller-provided id is only a stale-session guard.  It is never sent
    // as an RPC parameter; the database derives auth.uid() from the session.
    final currentUserId = currentSessionUserId;
    if (currentUserId == null || currentUserId != userId) {
      throw const ScheduleAuthorizationException('로그인 세션을 다시 확인해 주세요.');
    }
    dynamic result;
    try {
      result = await _client.rpc<dynamic>(
        'preview_invite',
        params: <String, dynamic>{'p_token': normalizedToken},
      );
    } catch (error) {
      if (_isInviteRateLimitError(error)) {
        throw const InviteRateLimitedException();
      }
      rethrow;
    }
    return _invitePreviewFromRpcResult(result);
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    if (userId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션을 다시 확인해 주세요.');
    }
    // The local user id is only a stale-session guard.  The RPC derives the
    // actor from auth.uid(), so a missing or mismatched SDK session must fail
    // closed before any bearer token is sent over the wire.
    final currentUserId = currentSessionUserId;
    if (currentUserId == null || currentUserId != userId) {
      throw const ScheduleAuthorizationException('로그인 세션을 다시 확인해 주세요.');
    }
    final normalizedCode = normalizeInviteCode(inviteCode);
    if (normalizedCode.isEmpty) {
      throw const FormatException('초대 코드를 입력해 주세요.');
    }
    dynamic result;
    try {
      result = await _client.rpc<dynamic>(
        'join_group_with_invite',
        params: <String, dynamic>{'p_token': normalizedCode},
      );
    } catch (error) {
      if (_isInviteRateLimitError(error)) {
        throw const InviteRateLimitedException();
      }
      rethrow;
    }
    final row = _strictSingleRpcMap(result);
    if (row == null ||
        row['group_id'] is! String ||
        (row['group_id'] as String).trim().isEmpty ||
        row['joined'] != true) {
      if (row?['reason'] == 'rate_limited') {
        throw const InviteRateLimitException();
      }
      throw const InviteUnavailableException.invalidOrExpired();
    }
    try {
      final group = await _client
          .from('groups')
          .select('id,owner_id,name,description,timezone,version,deleted_at')
          .eq('id', row['group_id'])
          .single();
      return _groupFromRow(group);
    } catch (_) {
      // The RPC has already inserted/reactivated membership.  Never make the
      // caller retry the bearer token merely because this projection read
      // failed; expose a fixed refresh error instead.
      throw const InviteJoinCommittedException();
    }
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
    final memberIds = normalizedDraft.hasExplicitMemberIds
        ? canonicalEventMemberIds(normalizedDraft.memberIds)
        : null;
    // The old direct payload used `'color_value': draft.colorValue`; the RPC
    // keeps the same value under its explicit p_color_value argument.
    // Legacy mapping: 'color_value': draft.colorValue.
    final result = await _client.rpc<dynamic>(
      'create_event_with_members',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_title': normalizedDraft.title.trim(),
        'p_description': normalizedDraft.note.trim(),
        'p_starts_at': normalizedDraft.startAt.toUtc().toIso8601String(),
        'p_ends_at': normalizedDraft.endAt.toUtc().toIso8601String(),
        'p_timezone': normalizedDraft.timezone,
        'p_is_all_day': normalizedDraft.allDay,
        'p_all_day_start': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayStartDate!)
            : null,
        'p_all_day_end': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayEndDate!)
            : null,
        'p_color_value': normalizedDraft.colorValue,
        // NULL lets the create RPC apply its creator default.  An explicit
        // empty list must remain [] so callers can intentionally create an
        // unassigned event.
        'p_member_ids': memberIds,
      },
    );
    return _eventFromRpcResult(result, expectedGroupId: groupId);
  }

  @override
  Future<PlannerEvent> createRecurringEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    if (userId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        draft.recurrence == null) {
      throw const ScheduleValidationException('로그인 세션과 반복 일정을 확인해 주세요.');
    }
    _requireCurrentRemoteUser(userId);
    final normalizedDraft = LocalScheduleRepository._normalizeDraft(draft);
    final rule = normalizedDraft.recurrence!;
    LocalScheduleRepository._validateRuleAnchor(rule, normalizedDraft);
    final memberIds = normalizedDraft.hasExplicitMemberIds
        ? canonicalEventMemberIds(normalizedDraft.memberIds)
        : null;
    final result = await _recurrenceRpc(
      'create_recurring_event_with_members',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_title': normalizedDraft.title.trim(),
        'p_description': normalizedDraft.note.trim(),
        'p_starts_at': normalizedDraft.startAt.toUtc().toIso8601String(),
        'p_ends_at': normalizedDraft.endAt.toUtc().toIso8601String(),
        'p_timezone': normalizedDraft.timezone,
        'p_is_all_day': normalizedDraft.allDay,
        'p_all_day_start': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayStartDate!)
            : null,
        'p_all_day_end': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayEndDate!)
            : null,
        'p_color_value': normalizedDraft.colorValue,
        'p_member_ids': memberIds,
        'p_frequency': rule.frequency.wireName,
        'p_interval': rule.interval,
        'p_weekdays': rule.weekdays,
        'p_end': rule.end.wireName,
        'p_count': rule.count,
        'p_until_date': rule.untilDate == null
            ? null
            : _dateString(rule.untilDate!),
        'p_monthly_day': rule.monthlyDay,
      },
    );
    final row = _strictSingleRpcMap(result);
    if (row == null ||
        !_hasCompleteEventFields(row, strictLifecycleTimestamps: true) ||
        !_isStrictRecurringCreateRow(
          row,
          groupId: groupId,
          userId: userId,
          draft: normalizedDraft,
          rule: rule,
        )) {
      throw const ScheduleConflictException('반복 일정 변경 응답을 확인할 수 없습니다.');
    }
    final parsedMembers = _strictMemberIds(row['member_ids']);
    if (parsedMembers == null) {
      throw const ScheduleConflictException('일정 멤버 응답을 확인할 수 없습니다.');
    }
    return _eventFromRow(row, memberIds: parsedMembers);
  }

  /// Validates the create RPC's first materialized occurrence as a complete,
  /// canonical response.  The row is the only authoritative result of the
  /// atomic event/rule/member write; accepting a partial or mismatched row
  /// would leave the controller with a phantom series that cannot be safely
  /// retried.
  bool _isStrictRecurringCreateRow(
    Map<String, dynamic> row, {
    required String groupId,
    required String userId,
    required EventDraft draft,
    required RecurrenceRule rule,
  }) {
    final id = row['id'];
    final starts = _strictDateTimeValue(row['starts_at']);
    final ends = _strictDateTimeValue(row['ends_at']);
    final scheduledStarts = _strictDateTimeValue(row['scheduled_starts_at']);
    final scheduledEnds = _strictDateTimeValue(row['scheduled_ends_at']);
    final rowRule = row['recurrence_rule'];
    RecurrenceRule? parsedRule;
    if (rowRule != null) {
      try {
        parsedRule = RecurrenceRule.fromJson(rowRule);
      } on FormatException {
        return false;
      }
    }
    final expectedMembers = canonicalEventMemberIds(<String>[
      ...draft.memberIds,
      userId,
    ]);
    final returnedMembers = _strictMemberIds(row['member_ids']);
    // The first materialized row is not necessarily the raw event anchor:
    // monthly rules may deliberately start on a different day (for example,
    // a Jan 15 anchor with monthly_day=31 returns Jan 31), and timezone
    // conversion can move a wall-clock boundary across a DST transition.
    // Reconstruct the canonical ordinal-zero projection with the same bounded
    // arithmetic used by the local adapter instead of comparing against the
    // input anchor instants directly.
    final expectedSeries = PlannerEvent(
      id: id is String ? id : 'invalid',
      groupId: groupId,
      title: draft.title.trim(),
      note: draft.note.trim(),
      startAt: draft.startAt.toUtc(),
      endAt: draft.endAt.toUtc(),
      allDay: draft.allDay,
      ownerId: userId,
      memberIds: expectedMembers,
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
      recurrenceRule: rule,
    );
    final expectedOccurrence = recurringOccurrenceAtIndex(expectedSeries, 0);
    if (expectedOccurrence == null) return false;
    final expectedAllDayStart = draft.allDay
        ? _dateString(expectedOccurrence.allDayStartDate!)
        : null;
    final expectedAllDayEnd = draft.allDay
        ? _dateString(expectedOccurrence.allDayEndDate!)
        : null;
    return id is String &&
        id.trim().isNotEmpty &&
        row['event_id'] == id &&
        row['series_id'] == id &&
        row['group_id'] == groupId &&
        row['created_by'] == userId &&
        _strictVersionValue(row['version']) == 1 &&
        row['deleted_at'] == null &&
        row['occurrence_key'] == occurrenceKeyForIndex(0) &&
        _strictVersionValue(row['occurrence_index']) == 0 &&
        _strictVersionValue(row['occurrence_version']) == 0 &&
        row['is_occurrence'] == true &&
        parsedRule == rule &&
        starts == expectedOccurrence.startAt.toUtc() &&
        ends == expectedOccurrence.endAt.toUtc() &&
        scheduledStarts == expectedOccurrence.scheduledStartsAt?.toUtc() &&
        scheduledEnds == expectedOccurrence.scheduledEndsAt?.toUtc() &&
        row['title'] == draft.title.trim() &&
        row['description'] == draft.note.trim() &&
        row['timezone'] == draft.timezone &&
        row['is_all_day'] == draft.allDay &&
        row['all_day_start'] == expectedAllDayStart &&
        row['all_day_end'] == expectedAllDayEnd &&
        _strictColorValue(row['color_value']) == draft.colorValue &&
        returnedMembers != null &&
        LocalScheduleRepository._sameMemberIdSet(
          returnedMembers,
          expectedMembers,
        );
  }

  @override
  Future<RecurrenceMutationReceipt> updateEventOccurrence({
    required PlannerEvent event,
    required EventDraft draft,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    if (event.groupId.trim().isEmpty ||
        event.id.trim().isEmpty ||
        !isValidOccurrenceKey(event.occurrenceKey) ||
        (event.occurrenceKey == 'single' &&
            (scope != EventEditScope.all || event.recurrenceRule == null) &&
            draft.recurrence == null)) {
      throw const ScheduleValidationException('반복 일정 항목을 확인해 주세요.');
    }
    _requireCurrentRemoteUser(actorId ?? currentSessionUserId);
    final normalizedDraft = LocalScheduleRepository._normalizeDraft(draft);
    final keyIsSingle = event.occurrenceKey == 'single';
    if (!keyIsSingle && event.recurrenceRule == null) {
      throw const ScheduleValidationException('반복 일정 규칙을 확인해 주세요.');
    }
    final hasRecurringIdentity = event.recurrenceRule != null || !keyIsSingle;
    final convertsSingletonToRecurring =
        keyIsSingle &&
        !hasRecurringIdentity &&
        scope == EventEditScope.all &&
        normalizedDraft.recurrence != null;
    final convertsRecurringToSingleton =
        hasRecurringIdentity &&
        scope == EventEditScope.all &&
        normalizedDraft.recurrence == null;
    if (!hasRecurringIdentity && !convertsSingletonToRecurring) {
      throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
    }
    if (keyIsSingle &&
        !convertsSingletonToRecurring &&
        !convertsRecurringToSingleton) {
      throw const ScheduleConflictException('반복 일정 항목을 확인해 주세요.');
    }
    final rule = normalizedDraft.recurrence ?? event.recurrenceRule;
    if (!convertsRecurringToSingleton) {
      if (rule == null) {
        throw const ScheduleValidationException('반복 일정 규칙을 확인해 주세요.');
      }
      LocalScheduleRepository._validateRuleAnchor(rule, normalizedDraft);
    }
    if (scope != EventEditScope.all &&
        normalizedDraft.hasExplicitMemberIds &&
        !LocalScheduleRepository._sameMemberIdSet(
          canonicalEventMemberIds(normalizedDraft.memberIds),
          canonicalEventMemberIds(event.memberIds),
        )) {
      throw const ScheduleConflictException('반복 일정 멤버는 전체 범위에서만 변경할 수 있습니다.');
    }
    final result = await _recurrenceRpc(
      'update_event_occurrence_scope_if_version',
      params: <String, dynamic>{
        'p_event_id': event.id,
        'p_expected_version': expectedSeriesVersion,
        'p_occurrence_key': event.occurrenceKey,
        'p_scope': scope.wireName,
        'p_title': normalizedDraft.title.trim(),
        'p_description': normalizedDraft.note.trim(),
        'p_starts_at': normalizedDraft.startAt.toUtc().toIso8601String(),
        'p_ends_at': normalizedDraft.endAt.toUtc().toIso8601String(),
        'p_timezone': normalizedDraft.timezone,
        'p_is_all_day': normalizedDraft.allDay,
        'p_all_day_start': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayStartDate!)
            : null,
        'p_all_day_end': normalizedDraft.allDay
            ? _dateString(normalizedDraft.allDayEndDate!)
            : null,
        'p_color_value': normalizedDraft.colorValue,
        // The all-scope RPC requires the complete participant set so member
        // replacement is atomic with the body/rule write.  When the draft
        // omits members, preserve the event's current series assignment.
        // NULL is reserved for this/future scopes, where participant edits
        // are rejected and the server inherits the existing rows.
        'p_member_ids': scope == EventEditScope.all
            ? canonicalEventMemberIds(
                normalizedDraft.hasExplicitMemberIds
                    ? normalizedDraft.memberIds
                    : event.memberIds,
              )
            : null,
        'p_frequency': convertsRecurringToSingleton
            ? null
            : rule?.frequency.wireName,
        'p_interval': convertsRecurringToSingleton ? null : rule?.interval,
        'p_weekdays': convertsRecurringToSingleton ? null : rule?.weekdays,
        'p_end': convertsRecurringToSingleton ? null : rule?.end.wireName,
        'p_count': convertsRecurringToSingleton ? null : rule?.count,
        'p_until_date': convertsRecurringToSingleton || rule?.untilDate == null
            ? null
            : _dateString(rule!.untilDate!),
        'p_monthly_day': convertsRecurringToSingleton ? null : rule?.monthlyDay,
      },
    );
    return _receiptFromRpcResult(
      result,
      expectedGroupId: event.groupId,
      expectedEventId: event.id,
      expectedKey: event.occurrenceKey,
      expectedScope: scope,
      expectedSeriesVersion: expectedSeriesVersion,
      expectedOccurrenceVersion: expectedOccurrenceVersion,
    );
  }

  @override
  Future<RecurrenceMutationReceipt> deleteEventOccurrence({
    required PlannerEvent event,
    required EventEditScope scope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
    String? actorId,
  }) async {
    if (event.groupId.trim().isEmpty ||
        event.id.trim().isEmpty ||
        !isValidOccurrenceKey(event.occurrenceKey) ||
        event.occurrenceKey == 'single') {
      throw const ScheduleValidationException('반복 일정 항목을 확인해 주세요.');
    }
    _requireCurrentRemoteUser(actorId ?? currentSessionUserId);
    final result = await _recurrenceRpc(
      'delete_event_occurrence_scope_if_version',
      params: <String, dynamic>{
        'p_event_id': event.id,
        'p_expected_version': expectedSeriesVersion,
        'p_occurrence_key': event.occurrenceKey,
        'p_scope': scope.wireName,
      },
    );
    return _receiptFromRpcResult(
      result,
      expectedGroupId: event.groupId,
      expectedEventId: event.id,
      expectedKey: event.occurrenceKey,
      expectedScope: scope,
      expectedSeriesVersion: expectedSeriesVersion,
      expectedOccurrenceVersion: expectedOccurrenceVersion,
    );
  }

  static RecurrenceMutationReceipt _receiptFromRpcResult(
    Object? result, {
    required String expectedGroupId,
    required String expectedEventId,
    required String expectedKey,
    required EventEditScope expectedScope,
    required int expectedSeriesVersion,
    required int expectedOccurrenceVersion,
  }) {
    final row = _strictSingleRpcMap(result);
    if (row == null) {
      throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
    }
    try {
      final receipt = RecurrenceMutationReceipt.fromJson(row);
      final expectedReceiptSeriesVersion = receipt.changed
          ? expectedSeriesVersion + 1
          : expectedSeriesVersion;
      final expectedReceiptOccurrenceVersion =
          expectedScope == EventEditScope.thisOccurrence
          ? (receipt.changed
                ? expectedOccurrenceVersion + 1
                : expectedOccurrenceVersion)
          : 0;
      if (receipt.groupId != expectedGroupId ||
          receipt.eventId != expectedEventId ||
          receipt.occurrenceKey != expectedKey ||
          receipt.scope != expectedScope ||
          receipt.seriesVersion != expectedReceiptSeriesVersion ||
          receipt.occurrenceVersion != expectedReceiptOccurrenceVersion) {
        throw const FormatException('일정 변경 응답을 확인해 주세요.');
      }
      return receipt;
    } on FormatException {
      throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
    }
  }

  @override
  Future<RecurrenceMutationReceipt> replaceRecurringEventMembers({
    required PlannerEvent event,
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    final recurring =
        event.recurrenceRule != null || event.occurrenceKey != 'single';
    if (event.groupId.trim().isEmpty ||
        event.id.trim().isEmpty ||
        event.ownerId.trim().isEmpty ||
        !recurring ||
        !isValidOccurrenceKey(event.occurrenceKey) ||
        expectedVersion < 0) {
      throw const ScheduleValidationException('반복 일정 항목을 확인해 주세요.');
    }
    final normalizedMemberIds = canonicalEventMemberIds(memberIds);
    if (!normalizedMemberIds.contains(event.ownerId)) {
      throw const ScheduleValidationException('반복 일정 작성자는 멤버에서 제외할 수 없습니다.');
    }
    _requireCurrentRemoteUser(actorId ?? currentSessionUserId);
    final selectedKey = event.occurrenceKey == 'single'
        ? occurrenceKeyForIndex(0)
        : event.occurrenceKey;
    final result = await _recurrenceRpc(
      'replace_recurring_event_members_if_version',
      params: <String, dynamic>{
        'p_event_id': event.id,
        'p_expected_version': expectedVersion,
        'p_occurrence_key': event.occurrenceKey,
        'p_member_ids': normalizedMemberIds,
      },
    );
    return _receiptFromRpcResult(
      result,
      expectedGroupId: event.groupId,
      expectedEventId: event.id,
      expectedKey: selectedKey,
      expectedScope: EventEditScope.all,
      expectedSeriesVersion: expectedVersion,
      expectedOccurrenceVersion: 0,
    );
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
    final memberIds = canonicalEventMemberIds(normalizedEvent.memberIds);
    // The old direct payload used `'color_value': event.colorValue`; the RPC
    // keeps the same value under its explicit p_color_value argument.
    // Legacy mapping: 'color_value': event.colorValue.
    final result = await _client.rpc<dynamic>(
      'update_event_with_members_if_version',
      params: <String, dynamic>{
        'p_event_id': normalizedEvent.id,
        'p_expected_version': expectedVersion,
        'p_title': normalizedEvent.title.trim(),
        'p_description': normalizedEvent.note.trim(),
        'p_starts_at': normalizedEvent.startAt.toUtc().toIso8601String(),
        'p_ends_at': normalizedEvent.endAt.toUtc().toIso8601String(),
        'p_timezone': normalizedEvent.timezone,
        'p_is_all_day': normalizedEvent.allDay,
        'p_all_day_start': normalizedEvent.allDay
            ? _dateString(normalizedEvent.allDayStartDate!)
            : null,
        'p_all_day_end': normalizedEvent.allDay
            ? _dateString(normalizedEvent.allDayEndDate!)
            : null,
        'p_color_value': normalizedEvent.colorValue,
        'p_member_ids': memberIds,
      },
    );
    return _eventFromRpcResult(
      result,
      expectedEventId: normalizedEvent.id,
      expectedGroupId: normalizedEvent.groupId,
      expectedOwnerId: normalizedEvent.ownerId,
      expectedVersion: expectedVersion + 1,
    );
  }

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    final normalizedMemberIds = canonicalEventMemberIds(memberIds);
    // actorId is intentionally ignored: authorization belongs to auth.uid()
    // inside the SECURITY DEFINER RPC, never to caller-provided identity.
    final result = await _client.rpc<dynamic>(
      'replace_event_members_if_version',
      params: <String, dynamic>{
        'p_event_id': eventId,
        'p_expected_version': expectedVersion,
        'p_member_ids': normalizedMemberIds,
      },
    );
    final updated = _eventFromRpcResult(result, expectedEventId: eventId);
    // The RPC is idempotent for an unchanged canonical set and returns the
    // expected version in that case; a changed set advances exactly once.
    if (updated.version != expectedVersion &&
        updated.version != expectedVersion + 1) {
      throw const ScheduleConflictException('일정이 이미 변경되었거나 권한이 없습니다.');
    }
    return updated;
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
        : _strictVersionValue(row['version']);
    if (row == null ||
        returnedId is! String ||
        returnedId != eventId ||
        deletedAt == null ||
        returnedVersion != expectedVersion + 1) {
      throw const ScheduleConflictException('일정이 이미 변경되었거나 권한이 없습니다.');
    }
  }

  PlannerEvent _eventFromRpcResult(
    Object? result, {
    String? expectedEventId,
    String? expectedGroupId,
    String? expectedOwnerId,
    int? expectedVersion,
  }) {
    final row = _strictSingleRpcMap(result);
    if (row == null || !_hasCompleteEventFields(row)) {
      throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
    }
    final returnedId = row['id'];
    final returnedGroupId = row['group_id'];
    final returnedOwnerId = row['created_by'];
    final returnedVersion = _strictVersionValue(row['version']);
    if (returnedId is! String ||
        returnedGroupId is! String ||
        returnedOwnerId is! String ||
        returnedId.trim().isEmpty ||
        returnedGroupId.trim().isEmpty ||
        returnedOwnerId.trim().isEmpty ||
        (expectedEventId != null && returnedId != expectedEventId) ||
        (expectedGroupId != null && returnedGroupId != expectedGroupId) ||
        (expectedOwnerId != null && returnedOwnerId != expectedOwnerId) ||
        (expectedVersion != null && returnedVersion != expectedVersion) ||
        row['deleted_at'] != null) {
      throw const ScheduleConflictException('일정이 이미 변경되었거나 권한이 없습니다.');
    }
    final memberIds = _strictMemberIds(row['member_ids']);
    return _eventFromRow(row, memberIds: memberIds);
  }

  static bool _hasCompleteEventFields(
    Map<String, dynamic> row, {
    bool requireMemberIds = true,
    bool strictLifecycleTimestamps = false,
  }) {
    final required = <String>[
      'id',
      'group_id',
      'created_by',
      'title',
      'description',
      'starts_at',
      'ends_at',
      'timezone',
      'is_all_day',
      'all_day_start',
      'all_day_end',
      'version',
      'deleted_at',
      'created_at',
      'updated_at',
      'color_value',
    ];
    if (requireMemberIds) required.add('member_ids');
    if (!required.every(row.containsKey)) return false;
    final occurrenceFieldNames = <String>{
      'event_id',
      'series_id',
      'occurrence_key',
      'occurrence_index',
      'occurrence_version',
      'is_occurrence',
      'scheduled_starts_at',
      'scheduled_ends_at',
      'recurrence_rule',
    };
    final hasOccurrenceFields = row.keys.any(occurrenceFieldNames.contains);
    if (hasOccurrenceFields && !occurrenceFieldNames.every(row.containsKey)) {
      return false;
    }
    final baseValid =
        row['id'] is String &&
        (row['id'] as String).trim().isNotEmpty &&
        row['group_id'] is String &&
        (row['group_id'] as String).trim().isNotEmpty &&
        row['created_by'] is String &&
        (row['created_by'] as String).trim().isNotEmpty &&
        row['title'] is String &&
        row['description'] is String &&
        row['starts_at'] != null &&
        row['ends_at'] != null &&
        row['timezone'] is String &&
        (row['timezone'] as String).trim().isNotEmpty &&
        isValidIanaTimezone(row['timezone'] as String) &&
        row['is_all_day'] is bool &&
        _strictVersionValue(row['version']) is int &&
        (_strictVersionValue(row['version']) ?? -1) >= 0 &&
        _lifecycleTimestamp(
              row['created_at'],
              strict: strictLifecycleTimestamps,
            ) !=
            null &&
        _lifecycleTimestamp(
              row['updated_at'],
              strict: strictLifecycleTimestamps,
            ) !=
            null &&
        (row['deleted_at'] == null ||
            _lifecycleTimestamp(
                  row['deleted_at'],
                  strict: strictLifecycleTimestamps,
                ) !=
                null) &&
        _strictColorValue(row['color_value']) != null &&
        _validEventDates(row) &&
        (!requireMemberIds || _strictMemberIds(row['member_ids']) != null);
    if (!baseValid || !hasOccurrenceFields) return baseValid;
    if (row['event_id'] is! String ||
        row['event_id'] != row['id'] ||
        row['series_id'] is! String ||
        (row['series_id'] as String).trim().isEmpty ||
        row['occurrence_key'] is! String ||
        !isValidOccurrenceKey(row['occurrence_key']) ||
        (row['occurrence_index'] != null && row['occurrence_index'] is! num) ||
        row['occurrence_version'] is! num ||
        row['is_occurrence'] is! bool ||
        row['scheduled_starts_at'] == null ||
        _strictDateTimeValue(row['scheduled_starts_at']) == null ||
        row['scheduled_ends_at'] == null ||
        _strictDateTimeValue(row['scheduled_ends_at']) == null) {
      return false;
    }
    final index = _strictVersionValue(row['occurrence_index']);
    final occurrenceVersion = _strictVersionValue(row['occurrence_version']);
    final isOccurrence = row['is_occurrence'] == true;
    if ((row['occurrence_key'] != 'single' &&
            (index == null ||
                index < 0 ||
                index != occurrenceIndexFromKey(row['occurrence_key']))) ||
        (row['occurrence_key'] == 'single' && index != null && index != 0) ||
        occurrenceVersion == null ||
        occurrenceVersion < 0) {
      return false;
    }
    final recurrenceRaw = row['recurrence_rule'];
    if (recurrenceRaw != null) {
      try {
        RecurrenceRule.fromJson(recurrenceRaw);
      } on FormatException {
        return false;
      }
    }
    // Every materialized row keeps the parent event id in all three identity
    // columns. A recurring projection is always an occurrence with a
    // non-single ordinal key and a valid rule; a singleton projection is the
    // only legal `single` row and must not carry a recurrence rule. These
    // checks prevent malformed rows from being merged under a colliding
    // composite identity or from being edited through the wrong path.
    if (row['series_id'] != row['id'] ||
        occurrenceVersion > (_strictVersionValue(row['version']) ?? -1) ||
        (isOccurrence &&
            (row['occurrence_key'] == 'single' || recurrenceRaw == null)) ||
        (!isOccurrence &&
            (row['occurrence_key'] != 'single' || recurrenceRaw != null))) {
      return false;
    }
    if (row['occurrence_key'] == 'single' && isOccurrence) {
      return false;
    }
    if (row['occurrence_key'] != 'single' &&
        (!isOccurrence || recurrenceRaw == null)) {
      return false;
    }
    final scheduledStart = _strictDateTimeValue(row['scheduled_starts_at']);
    final scheduledEnd = _strictDateTimeValue(row['scheduled_ends_at']);
    if (scheduledStart == null ||
        scheduledEnd == null ||
        !scheduledEnd.isAfter(scheduledStart)) {
      return false;
    }
    return true;
  }

  static bool _validEventDates(Map<String, dynamic> row) {
    final allDay = row['is_all_day'] == true;
    final start = row['all_day_start'];
    final end = row['all_day_end'];
    final startsAt = _strictDateTimeValue(row['starts_at']);
    final endsAt = _strictDateTimeValue(row['ends_at']);
    if (startsAt == null || endsAt == null || !endsAt.isAfter(startsAt)) {
      return false;
    }
    final startDate = _parseDate(start);
    final endDate = _parseDate(end);
    if (!allDay) {
      // Timed rows must not carry stale date-only metadata from a previous
      // all-day edit.  Treating that mixture as valid would let malformed RPC
      // payloads leak into the editor with a different temporal meaning.
      return start == null && end == null;
    }
    if (startDate == null || endDate == null || !endDate.isAfter(startDate)) {
      return false;
    }
    final timezone = row['timezone'];
    if (timezone is! String || !isValidIanaTimezone(timezone)) return false;
    // All-day timestamps are the exact UTC instants for the local date
    // boundaries.  This catches rows that claim a date range but contain an
    // arbitrary timed instant (including a non-midnight offset).
    final canonicalStart = wallTimeToUtc(startDate, timezone);
    final canonicalEnd = wallTimeToUtc(endDate, timezone);
    return startsAt == canonicalStart && endsAt == canonicalEnd;
  }

  static List<String>? _strictMemberIds(Object? value) {
    if (value is! List) return null;
    final result = <String>[];
    final seen = <String>{};
    for (final raw in value) {
      if (raw is! String) return null;
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) return null;
      result.add(id);
    }
    result.sort();
    return List<String>.unmodifiable(result);
  }

  static int? _strictVersionValue(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncate()) {
      return value.toInt();
    }
    return null;
  }

  static int? _strictColorValue(Object? value) {
    final parsed = _strictVersionValue(value);
    if (parsed == null || parsed < 0 || parsed > 0xffffffff) return null;
    return parsed;
  }

  static InvitePreview _invitePreviewFromRpcResult(Object? result) {
    // `preview_invite` returns jsonb, i.e. one JSON object.  Unlike table RPC
    // rows, a one-element array is not a valid response and must fail closed.
    final row = _strictInvitePreviewMap(result);
    if (row == null || row['valid'] is! bool) {
      throw const ScheduleCapabilityException('초대 미리보기 응답을 확인할 수 없습니다.');
    }
    final valid = row['valid'] as bool;
    if (!valid) {
      const invalidKeys = <String>{'valid', 'reason'};
      if (row.length != invalidKeys.length ||
          row.keys.toSet().difference(invalidKeys).isNotEmpty ||
          row['reason'] is! String) {
        throw const ScheduleCapabilityException('초대 미리보기 응답을 확인할 수 없습니다.');
      }
      switch (row['reason']) {
        case 'invalid_or_expired':
          throw const InviteUnavailableException.invalidOrExpired();
        case 'rate_limited':
          throw const InviteRateLimitedException();
        default:
          throw const ScheduleCapabilityException('초대 미리보기 응답을 확인할 수 없습니다.');
      }
    }
    const expectedKeys = <String>{
      'valid',
      'group_id',
      'group_name',
      'group_description',
      'group_timezone',
      'expires_at',
      'already_member',
    };
    if (row.length != expectedKeys.length ||
        row.keys.toSet().difference(expectedKeys).isNotEmpty ||
        !expectedKeys.every(row.containsKey) ||
        row['group_id'] is! String ||
        row['group_name'] is! String ||
        row['group_description'] is! String ||
        row['group_timezone'] is! String ||
        row['expires_at'] is! String ||
        row['already_member'] is! bool) {
      throw const ScheduleCapabilityException('초대 미리보기 응답을 확인할 수 없습니다.');
    }
    final groupId = row['group_id'] as String;
    final groupName = row['group_name'] as String;
    final groupDescription = row['group_description'] as String;
    final timezone = row['group_timezone'] as String;
    final alreadyMember = row['already_member'] as bool;
    final expiresAt = parseStrictExplicitOffsetTimestamp(row['expires_at']);
    if (!_inviteUuidPattern.hasMatch(groupId) ||
        groupId != groupId.trim() ||
        groupName.trim().isEmpty ||
        groupName != groupName.trim() ||
        groupDescription != groupDescription.trim() ||
        timezone.trim().isEmpty ||
        timezone != timezone.trim() ||
        !isValidIanaTimezone(timezone) ||
        expiresAt == null ||
        (!alreadyMember && !expiresAt.isAfter(DateTime.now().toUtc()))) {
      throw const ScheduleCapabilityException('초대 미리보기 응답을 확인할 수 없습니다.');
    }
    return InvitePreview(
      groupId: groupId,
      groupName: groupName,
      groupDescription: groupDescription,
      groupTimezone: timezone,
      expiresAt: expiresAt,
      alreadyMember: alreadyMember,
    );
  }

  static bool _isInviteRateLimitError(Object error) {
    return error is PostgrestException && error.code == '429';
  }

  static Map<String, dynamic>? _strictInvitePreviewMap(Object? result) {
    if (result is Map<String, dynamic>) return result;
    if (result is Map && result.keys.every((key) => key is String)) {
      return Map<String, dynamic>.from(result);
    }
    return null;
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

  static void _validateRemoteRangeShape(EventRange range, int limit) {
    if (limit < 1 || limit > 200) {
      throw const ScheduleValidationException('일정 페이지 크기를 확인해 주세요.');
    }
    validateIanaTimezone(range.viewTimezone);
    final localStart = utcToWallTimePrecise(range.startUtc, range.viewTimezone);
    final localEnd = utcToWallTimePrecise(range.endUtc, range.viewTimezone);
    bool isMidnight(DateTime value) =>
        value.hour == 0 &&
        value.minute == 0 &&
        value.second == 0 &&
        value.millisecond == 0 &&
        value.microsecond == 0;
    if (!isMidnight(localStart) || !isMidnight(localEnd)) {
      throw const ScheduleValidationException('일정 범위는 현지 자정 경계여야 합니다.');
    }
    final span = calendarDateSpan(
      range.startUtc,
      range.endUtc,
      range.viewTimezone,
    );
    if (span < 1 || span > 366) {
      throw const ScheduleValidationException('일정 범위는 366일 이내여야 합니다.');
    }
  }

  EventRangePage _eventRangePageFromRpcResult(
    Object? result, {
    required String expectedGroupId,
    required EventRange range,
    required EventRangeCursor? cursor,
    required int limit,
    required String? participantId,
  }) {
    try {
      if (result is! Map || result.keys.any((key) => key is! String)) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      final envelope = result.cast<String, dynamic>();
      const expectedEnvelopeKeys = <String>{
        'events',
        'next_cursor',
        'has_more',
      };
      if (envelope.length != expectedEnvelopeKeys.length ||
          envelope.keys.toSet().difference(expectedEnvelopeKeys).isNotEmpty ||
          !expectedEnvelopeKeys.every(envelope.containsKey) ||
          envelope['events'] is! List ||
          envelope['has_more'] is! bool) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      final rawEvents = envelope['events'] as List;
      if (rawEvents.length > limit) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      final rawNextCursor = envelope['next_cursor'];
      if (rawNextCursor != null && rawNextCursor is! String) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      final nextCursor = rawNextCursor == null
          ? null
          : EventRangeCursor.decode(rawNextCursor as String);
      final hasMore = envelope['has_more'] as bool;
      if (hasMore != (nextCursor != null)) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      // A true continuation flag is meaningful only when the server returned
      // a complete requested page. Accepting a short page with has_more=true
      // can make the client repeat a cursor forever or silently skip rows.
      if (hasMore && rawEvents.length != limit) {
        throw const FormatException('일정 페이지 응답을 확인해 주세요.');
      }
      final events = <PlannerEvent>[];
      final seenIds = <String>{};
      for (final raw in rawEvents) {
        if (raw is! Map || raw.keys.any((key) => key is! String)) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        final row = raw.cast<String, dynamic>();
        if (!_hasCompleteEventFields(row, strictLifecycleTimestamps: true)) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        final memberIds = _strictMemberIds(row['member_ids']);
        if (memberIds == null) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        final event = _eventFromRow(row, memberIds: memberIds);
        if (event.groupId != expectedGroupId ||
            event.isDeleted ||
            !seenIds.add(event.identityKey) ||
            !eventOverlapsCalendarRange(event, range) ||
            (participantId != null &&
                !event.memberIds.contains(participantId))) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        if (events.isNotEmpty &&
            LocalScheduleRepository._compareEventRangeRows(
                  events.last,
                  event,
                ) >=
                0) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        if (cursor != null &&
            !LocalScheduleRepository._isAfterEventRangeCursor(event, cursor)) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
        events.add(event);
      }
      if (nextCursor != null) {
        if (events.isEmpty ||
            nextCursor.startsAtUtc != events.last.startAt.toUtc() ||
            nextCursor.eventId != events.last.id ||
            (events.last.occurrenceKey == 'single'
                ? !(nextCursor.occurrenceKey.isEmpty ||
                      nextCursor.occurrenceKey == 'single')
                : nextCursor.occurrenceKey != events.last.occurrenceKey)) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
      }
      return EventRangePage(
        events: events,
        nextCursor: nextCursor,
        hasMore: hasMore,
      );
    } on ScheduleConflictException {
      rethrow;
    } on FormatException {
      throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
    } catch (_) {
      throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
    }
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

  PlannerEvent _eventFromRow(
    Map<String, dynamic> row, {
    List<String>? memberIds,
  }) {
    final ownerId = '${row['created_by']}';
    final parsedMemberIds = memberIds ?? _legacyMemberIds(row, ownerId);
    final startsAt = _strictDateTimeValue(row['starts_at']);
    final endsAt = _strictDateTimeValue(row['ends_at']);
    if (startsAt == null || endsAt == null) {
      throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
    }
    RecurrenceRule? recurrence;
    if (row.containsKey('recurrence_rule') && row['recurrence_rule'] != null) {
      try {
        recurrence = RecurrenceRule.fromJson(row['recurrence_rule']);
      } on FormatException {
        throw const ScheduleConflictException('반복 규칙 응답을 확인할 수 없습니다.');
      }
    }
    final occurrenceKey = row['occurrence_key'] is String
        ? row['occurrence_key'] as String
        : 'single';
    final occurrenceIndex = _strictVersionValue(row['occurrence_index']) ?? 0;
    final occurrenceVersion =
        _strictVersionValue(row['occurrence_version']) ??
        _strictVersionValue(row['version']) ??
        1;
    return PlannerEvent(
      id: '${row['id']}',
      seriesId: row['series_id'] is String
          ? row['series_id'] as String
          : '${row['id']}',
      groupId: '${row['group_id']}',
      title: '${row['title'] ?? ''}',
      note: '${row['description'] ?? ''}',
      startAt: startsAt,
      endAt: endsAt,
      allDay: row['is_all_day'] == true,
      ownerId: ownerId,
      memberIds: parsedMemberIds,
      colorValue: _colorValue(row['color_value'], 0xff477b76),
      timezone: '${row['timezone'] ?? 'UTC'}',
      version: _intValue(row['version'], 1),
      allDayStartDate: _parseDate(row['all_day_start']),
      allDayEndDate: _parseDate(row['all_day_end']),
      updatedAt: _strictDateTimeValue(row['updated_at']) ?? startsAt,
      deletedAt: row['deleted_at'] == null
          ? null
          : _strictDateTimeValue(row['deleted_at']),
      occurrenceKey: occurrenceKey,
      occurrenceIndex: occurrenceIndex,
      occurrenceVersion: occurrenceVersion,
      isOccurrence: row['is_occurrence'] == true,
      scheduledStartsAt: row['scheduled_starts_at'] == null
          ? startsAt
          : _strictDateTimeValue(row['scheduled_starts_at']),
      scheduledEndsAt: row['scheduled_ends_at'] == null
          ? endsAt
          : _strictDateTimeValue(row['scheduled_ends_at']),
      recurrenceRule: recurrence,
    );
  }

  static List<String> _legacyMemberIds(
    Map<String, dynamic> row,
    String ownerId,
  ) {
    if (row.containsKey('member_ids')) {
      final parsed = _strictMemberIds(row['member_ids']);
      if (parsed == null) throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
      return parsed;
    }
    final embedded = row['event_members'];
    if (embedded is List) {
      final ids = <String>[];
      final seen = <String>{};
      for (final item in embedded) {
        final raw = item is Map ? item['user_id'] : item;
        if (raw is! String) {
          throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
        }
        final id = raw.trim();
        if (id.isEmpty || !seen.add(id)) {
          throw StateError('일정 멤버 응답을 확인할 수 없습니다.');
        }
        ids.add(id);
      }
      ids.sort();
      return List<String>.unmodifiable(ids);
    }
    // Old event rows had no child projection.  Keep their creator-only
    // interpretation, while explicit `member_ids: []` remains an empty set.
    return List<String>.unmodifiable(<String>[ownerId]);
  }

  static String? _stringValue(Object? value) => value == null ? null : '$value';

  static DateTime? _dateTimeValue(Object? value) =>
      value == null ? null : DateTime.tryParse('$value')?.toUtc();

  /// Parses a wire timestamp only when its offset/UTC marker is explicit.
  /// DateTime.tryParse accepts timezone-less strings in the host's local
  /// timezone, which would make an RPC response vary by device location.
  static DateTime? _strictDateTimeValue(Object? value) {
    return parseStrictExplicitOffsetTimestamp(value);
  }

  /// Lifecycle columns on the v2 JSON projection are wire timestamps, not
  /// already-typed Dart values. Require the explicit offset/Z shape there so
  /// `_eventFromRow` cannot silently reinterpret a timezone-less value in the
  /// device timezone (or fall back to a different timestamp). Legacy table
  /// and realtime adapters keep their permissive parser for compatibility.
  static DateTime? _lifecycleTimestamp(Object? value, {required bool strict}) {
    if (strict && value is! String) return null;
    return strict ? _strictDateTimeValue(value) : _dateTimeValue(value);
  }

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
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    final year = int.tryParse(value.substring(0, 4));
    final month = int.tryParse(value.substring(5, 7));
    final day = int.tryParse(value.substring(8, 10));
    if (year == null || month == null || day == null) return null;
    final candidate = DateTime.utc(year, month, day);
    if (candidate.year != year ||
        candidate.month != month ||
        candidate.day != day) {
      return null;
    }
    return DateTime(year, month, day);
  }

  static String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
