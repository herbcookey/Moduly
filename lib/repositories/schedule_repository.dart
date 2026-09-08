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

  /// 위치 인수 세 개를 사용하는 기존 생성 계약이다. 호출자가 선택한 시간대를
  /// 지원하는 구현은 아래 [TimezoneGroupCreationCapability]도 구현한다. 이 시그니처를
  /// 좁게 유지하면 기존 테스트/가짜 저장소를 변경하지 않고 계속 컴파일할 수 있다.
  Future<PlannerGroup> createGroup(
    String ownerId,
    String name,
    String description,
  );

  /// 낙관적 잠금 버전 검사 아래에서 선택된 그룹을 갱신한다. 행위자는 미리보기
  /// 어댑터용 로컬 권한 참고 정보다. Supabase 어댑터는 auth.uid에서 신원을 유도하며
  /// 이를 직렬화하지 않는다.
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

  /// 호출 사용자의 활성 멤버십을 제거한다. 소유자는 나가기 전에 소유권을 이전해야 한다.
  /// 구현은 상황에 맞게 로컬 인수 또는 auth.uid에서 행위자 신원을 유도한다.
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

  /// 그룹을 보관하고 새 최종 버전을 반환한다. 보관된 그룹은 멤버십/그룹 읽기에서
  /// 제외되며 복원할 수 없다.
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

/// 외부 구현을 위한 레거시 [ScheduleRepository] 생성 메서드를 유지하면서 호출자가
/// 선택한 정확한 IANA 시간대를 저장할 수 있는 저장소용 선택 기능이다.
abstract interface class TimezoneGroupCreationCapability {
  Future<PlannerGroup> createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  });
}

/// 요청자의 활성 멤버십 범위로 제한해야 하는 읽기에 컨트롤러가 사용하는 선택 기능이다.
/// 레거시 [watchEvents] 메서드는 이전 테스트 대역만을 위해 유지한다. 프로덕션 어댑터는
/// 이 인터페이스를 구현하며 [PlannerController]가 항상 이를 선택한다.
abstract interface class UserScopedEventReadCapability {
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId);
}

/// 원격 멤버십/그룹 무효화를 위한 선택적 수명 주기 스트림이다. `null` 또는 보관된
/// 값은 선택한 그룹을 더는 사용할 수 없다는 뜻이다.
abstract interface class GroupLifecycleCapability {
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId);
}

/// 제한된 달력 읽기를 위한 선택 기능이다. [ScheduleRepository]에 추가하는 방식으로
/// 유지하면 이전 테스트 대역 및 어댑터와의 호환성을 지키면서, 프로덕션 컨트롤러가
/// 그룹의 모든 일정을 내려받는 대신 실패 시 차단할 수 있다.
abstract interface class BoundedEventRangeReadCapability {
  /// 인증된 그룹 멤버를 위해 키셋 페이지 하나를 읽는다. [userId]는 로컬 컨텍스트
  /// 힌트일 뿐이다. 원격 어댑터는 auth.uid에서 신원을 유도하며 행위자/쿼리
  /// 매개변수로 절대 직렬화하면 안 된다.
  Future<EventRangePage> eventsForRange({
    required String userId,
    required String groupId,
    required EventRange range,
    EventRangeCursor? cursor,
    int limit = 100,
    String? participantId,
  });

  /// 상위 `events` 행의 변경 전용 신호를 내보낸다. 스트림은 처음에 전체 일정을
  /// 읽으면 안 된다. 호출자는 [eventsForRange]로 현재 범위를 가져오고 이 스트림은
  /// 무효화 용도로만 사용한다.
  Stream<void> watchEventInvalidations(String userId, String groupId);
}

/// 제한된 서버 기반 일정 검색을 위한 선택 기능이다. [ScheduleRepository]에 추가하는
/// 방식으로 유지하면 기존 어댑터 및 테스트 대역과 소스 호환성을 지키면서 프로덕션
/// 컨트롤러가 제한 없는 일정 다운로드로 대체하지 않고 실패 시 차단할 수 있다.
abstract interface class EventSearchCapability {
  /// 인증된 활성 그룹 멤버가 볼 수 있는 일정의 키셋 페이지 하나를 읽는다. [query]는
  /// 앞뒤 공백을 제거해 정규화하며 빈 검색어는 기간/필터 전용 검색에 유효하다. 원격
  /// 어댑터는 인증 세션에서 행위자 신원을 유도하며 [userId]를 절대 직렬화하면 안 된다.
  Future<EventRangePage> searchEvents({
    required String userId,
    required String groupId,
    required EventRange range,
    required String query,
    EventRangeCursor? cursor,
    int limit = eventSearchDefaultPageSize,
    String? creatorId,
    String? participantId,
  });
}

/// 딥 링크/상세 경로에서 사용하는 선택적 단건 조회다. 제한된 페이지와 분리하여 현재
/// 캘린더 범위 밖의 일정을 열어도 해당 범위의 페이지 구분 프로젝션을 오염시키지 않는다.
abstract interface class EventByIdReadCapability {
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  });
}

/// 추가형 발생분 지점 조회다. 이를 분리하면 [EventByIdReadCapability]을 구현하는 이전
/// 상세 경로 테스트 대역이 계속 컴파일되고 반복 경로는 정확한 발생 키를 사용할 수 있다.
abstract interface class EventOccurrenceReadCapability {
  Future<PlannerEvent?> eventOccurrenceByKey({
    required String userId,
    required String groupId,
    required String eventId,
    required String occurrenceKey,
  });
}

/// 기존 일정에 속한 참여자 행을 원자적으로 교체할 수 있는 저장소용 선택 기능이다.
/// 이전 어댑터와 테스트가 계속 컴파일되도록 기본 저장소에서는 의도적으로 이 메서드를
/// 요구하지 않는다. 사용자 지정 참여자 목록이 필요하지만 어댑터가 이 기능을 구현하지
/// 않았다면 호출자는 실패 시 차단해야 한다.
///
/// [actorId]는 로컬 권한 힌트일 뿐이다. Supabase 구현은 `auth.uid()`에서 행위자를
/// 유도하며 이 값을 전송하지 않는다. 또한 이 기능이 있으면 구현의 기존 생성/갱신
/// 메서드가 memberIds를 원자적으로 저장해야 한다.
abstract interface class EventMemberAssignmentCapability {
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  });
}

/// 반복 시리즈의 참여자 배정을 교체하는 인증된 기능이다. 반복 배정은 시리즈 전체에
/// 적용되며 일정 작성자를 유지해야 한다. 따라서 이 작업은 반복 RPC를 사용하고 기존
/// 일정 행 페이로드 대신 커밋된 처리 결과를 반환한다.
///
/// 추가형으로 유지하면 이전의 단일 일정 전용 어댑터 및 테스트 대역이 기존 참여자
/// RPC를 통해 실수로 반복 경로를 타지 않는다.
abstract interface class RecurringEventMemberAssignmentCapability {
  Future<RecurrenceMutationReceipt> replaceRecurringEventMembers({
    required PlannerEvent event,
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  });
}

/// 반복 시리즈 기능이다. 기존 어댑터/가짜 구현이 단일 일정 API를 유지하도록
/// [ScheduleRepository]에 추가하는 방식으로 둔다. 범위 쓰기는 커밋된 처리 결과를
/// 반환한다. 호출자는 낙관적 발생 프로젝션을 펼치는 대신 제한된 범위를 다시 가져와야 한다.
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

/// 초대 토큰 뒤의 민감하지 않은 그룹 프로젝션을 읽기 위한 선택적 인증 기능이다.
/// 토큰은 로컬 컨텍스트 참고 정보다. Supabase 어댑터는 auth.uid()에서 행위자를 유도하고
/// RPC에는 `p_token`만 보낸다.
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

/// 구조화된 권한/수명 주기 거부다. 상태는 이 표시를 사용해 신뢰할 수 있는 접근 권한
/// 상실 후 캐시된 비공개 범위를 지우고, 관련 없는 일시적 전송 실패에는 마지막으로
/// 정상인 행을 보존한다.
class ScheduleAuthorizationException extends ScheduleConflictException {
  const ScheduleAuthorizationException(super.message);
}

/// 저장소 구현이 변경 기능을 의도적으로 노출할 수 없을 때 발생한다. 성공한 무동작과
/// 구분되어 가짜 구현/설정 차단 어댑터가 사실에 맞게 동작하도록 한다.
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

/// 호출자가 토큰 존재, 취소, 사용량, 그룹 상태를 탐색하지 못하도록 모든 최종 초대
/// 상태를 의도적으로 하나의 공개 사유로 합친다.
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

/// 별도로 노출하는 유일한 초대 판정 상태는 서버 측 속도 제한이다. [retryAfter]는
/// 선택 사항이며 토큰 자료를 포함하지 않는다. 행위자 로컬 초대 미리보기/참여 예산을
/// 소진했을 때 발생한다. 긴 이름이 표준 API이고 아래 typedef는 이전 화면 및 테스트
/// 대역에서 사용한 원래 표기를 보존한다.
class InviteRateLimitedException implements Exception {
  const InviteRateLimitedException({this.retryAfter})
    : message = '초대 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.';

  final Duration? retryAfter;
  final String message;

  @override
  String toString() => message;
}

/// 기존 호출자를 위해 유지한 하위 호환 표기다. 하위 클래스 대신 typedef를 사용해
/// `isA<InviteRateLimitException>()`과 `isA<InviteRateLimitedException>()`이
/// 런타임에서 동등하게 유지된다.
typedef InviteRateLimitException = InviteRateLimitedException;

/// 참여 RPC가 멤버십을 커밋했지만 후속 그룹 프로젝션을 읽지 못했다. 멤버십은 이미
/// 서버에서 확정되었으므로 호출자는 전달자 토큰을 다시 시도하면 안 된다. 메시지는
/// 고정되어 있으며 전송 세부 정보나 초대 자료가 없다.
class InviteJoinCommittedException extends ScheduleConflictException {
  const InviteJoinCommittedException()
    : super('그룹 참여는 완료되었지만 정보를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.');
}

/// 생성 응답이 시작된 인증/그룹 컨텍스트가 무효화된 뒤 도착했다. 오래된 호출자에게
/// 반환하지 않고 원시 일회용 토큰을 의도적으로 버린다.
class InviteOperationStaleException extends ScheduleConflictException {
  const InviteOperationStaleException()
    : super('초대 코드 생성 결과가 더 이상 유효하지 않습니다. 다시 시도해 주세요.');
}

final RegExp _inviteUuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Supabase 무효화 채널 하나의 수명 주기 상태다. 이 객체를 콜백에서 포착하면
/// 실패했거나 폐기된 채널을 제거할 때 이를 대체한 새 채널을 지우거나 해제하지 않는다.
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
        EventSearchCapability,
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

  /// 기존 테스트 대역으로 사용하는 하위 클래스는 이 어댑터를 상속하면서 일부 메서드를
  /// 재정의할 수 있다. 제한된 읽기를 명시적으로 선택하지 않았다면 이전 전체 스트림
  /// 컨트롤러 경로를 유지한다. 구체적인 로컬 어댑터 자체는 프로덕션 지원 구현으로 남는다.
  bool get useBoundedEventRangeReads => runtimeType == LocalScheduleRepository;

  /// 변경 응답이 저장된 정확한 참여자 집합을 되돌려 줘야 하는지 나타낸다. 구체적인 로컬
  /// 어댑터와 설정 차단 어댑터는 엄격하다. 부분 테스트 대역으로 사용하는 이전 로컬
  /// 하위 클래스는 참여자 응답보다 먼저 만들어져 과거의 작성자 기본 정규화를 선택할 수 있다.
  /// 이 호환 비트는 멤버가 생략된 생성 응답에만 적용한다. 명시적인 참여자 목록에는 여전히
  /// [EventMemberAssignmentCapability]이 필요하며 레거시 어댑터가 조용히 허용하지 않는다.
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

  /// 행위자 범위 시간 단위 슬라이딩 원장에 실제 초대 시도 하나를 기록한다. 원장에는
  /// 의도적으로 타임스탬프만 들어가며 전달자 토큰은 속도 제한 상태의 일부가 되지 않는다.
  /// 한도에 도달하면 타임스탬프를 추가하지 않고 요청을 거부해 데이터베이스 RPC의 잠금
  /// 의미와 맞춘다.
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
    // 이 값은 전달자 토큰이므로 기본적으로 Random.secure를 사용한다. 주입한 결정론적
    // 생성원이 이 어댑터에 이미 있는 토큰과 충돌해도 제한된 재시도로 진행을 보장한다.
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
    // 요청자 가드를 스트림 변환 자체에 두어 실시간 방출마다 다시 평가한다.
    // 멤버십 비활성화와 보관은 모두 [watchEvents]를 통해 내보낸다. 동적 디스패치로
    // 기존 메서드를 호출하면 `watchEvents`만 재정의하는 기존 로컬 테스트 대역과의
    // 호환성도 유지된다.
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
  Future<EventRangePage> searchEvents({
    required String userId,
    required String groupId,
    required EventRange range,
    required String query,
    EventRangeCursor? cursor,
    int limit = eventSearchDefaultPageSize,
    String? creatorId,
    String? participantId,
  }) async {
    final normalizedQuery = normalizeEventSearchQuery(query);
    if (cursor != null &&
        (cursor.occurrenceKey.isEmpty ||
            !isValidOccurrenceKey(cursor.occurrenceKey))) {
      throw const ScheduleValidationException('지원하지 않는 검색 페이지 커서입니다.');
    }
    _validateSearchRequest(
      userId: userId,
      groupId: groupId,
      range: range,
      limit: limit,
      creatorId: creatorId,
      participantId: participantId,
    );
    final normalizedCreator = creatorId?.trim();
    final normalizedParticipant = participantId?.trim();
    final foldedQuery = normalizedQuery.toLowerCase();
    final candidates =
        _materializedEventsForRange(
              groupId: groupId,
              range: range,
              participantId: normalizedParticipant,
            )
            .where((event) {
              if (normalizedCreator != null &&
                  event.ownerId != normalizedCreator) {
                return false;
              }
              if (foldedQuery.isEmpty) return true;
              return event.title.toLowerCase().contains(foldedQuery) ||
                  event.note.toLowerCase().contains(foldedQuery);
            })
            .toList(growable: true);
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
            // 검색은 반복되지 않는 일정의 명시적 `single` 키를 포함해 항상 완전한
            // v2 튜플을 내보낸다.
            occurrenceKey: pageEvents.last.occurrenceKey,
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
      // 수동으로 초기화한 기존 테스트 대역은 이 메모리 어댑터에 등록하지 않고 자체
      // `groups` 목록을 통해 그룹을 노출할 수 있다. 알 수 없는 ID에 공개할 수명 주기
      // 사실은 없다. `null` 표시는 멤버십을 사용할 수 없게 된 알려진 그룹에만 사용한다.
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

  void _validateSearchRequest({
    required String userId,
    required String groupId,
    required EventRange range,
    required int limit,
    String? creatorId,
    String? participantId,
  }) {
    if (limit < 1 || limit > 100) {
      throw const ScheduleValidationException('검색 페이지 크기를 확인해 주세요.');
    }
    _validateBoundedRangeRequest(
      userId: userId,
      groupId: groupId,
      range: range,
      limit: limit,
      participantId: participantId,
    );
    if (creatorId != null) {
      final normalized = creatorId.trim();
      if (normalized.isEmpty || !_isActiveMember(groupId, normalized)) {
        throw const ScheduleAuthorizationException(
          '검색 작성자는 이 그룹의 활성 멤버여야 합니다.',
        );
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
    // v1 커서에는 의도적으로 발생 구성 요소가 없어 같은 기준점의 반복 프로젝션을
    // 재개할 수 없다. v2는 완전한 튜플을 정확히 비교한다.
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
    // 산술 일정 순회가 내보낸 신원을 추적한다. 발생 항목 재정의는 예약 시작이 제한된
    // 과거 조회 범위 밖이거나 수년 떨어져 있어도 실제 시작을 이 범위 안으로 옮길 수 있다.
    // 일정 순회가 원래 발생 항목을 먼저 찾도록 요구하지 말고 최종 겹침 필터 전에
    // 희소 재정의 인덱스에서 이런 행을 찾는다.
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
    // 멤버십 제거에는 현재 배정 의미를 적용한다. 비활성 사용자가 일정에 남아서는 안 되고,
    // 다시 가입해도 이전 행이 되살아나면 안 된다.
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
    // 하나의 동기 임계 구역에서 그룹 소유자와 모든 멤버십 역할을 갱신해 소유자가
    // 둘이거나 하나도 없는 상태가 절대 생기지 않게 한다.
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
    // 최종 보관은 과거 레코드를 삭제하지 않으면서 대기 중인 모든 초대 조회와 일정
    // 스트림도 비운다.
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
      // 수동 대체 입력을 위해 로컬 데모의 직접 작성 코드를 의도적으로 사용할 수 있게 한다.
      // 엄격한 공유 링크 빌더가 이 코드를 내보내지는 않는다.
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
    // 누락, 보관, 취소, 만료, 소진된 초대는 의도적으로 하나의 최종 사유로 합친다.
    // 이렇게 하면 로컬 구현이 Supabase 미리보기/참여 판정과 동등하게 동작하고 토큰/그룹
    // 존재 여부 탐색을 막는다.
    if (group == null || group.isArchived) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    final current = _members[group.id] ?? <PlannerMember>[];
    final existingIndex = current.indexWhere((member) => member.id == userId);
    // 이미 활성 멤버를 수락하는 동작은 멱등이다. 토큰이 만료/취소된 뒤에도 서버
    // 판정기가 이 참고 정보를 반환했을 수 있다. 초대 유효성이나 사용량 한도를 적용하기 전에
    // 활성 멤버십을 다시 확인하고 이 분기에서는 사용 횟수를 추가로 소비하지 않는다.
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
      // 다시 가입하면 기존 멤버십을 재활성화한다. 사용자가 필터링된 채 남지 않게 하고
      // 트랜잭션 방식의 Supabase RPC와 같은 동작을 한다.
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
      // 운영 조치가 끝난 뒤 진행 중인 편집기가 배정을 복원하지 못하도록 영향받은 일정의
      // 버전을 증가시킨다.
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
      // 호출자가 명시적 목록을 제공했어도 반복 시리즈의 표준 시리즈 전체 배정에는 항상
      // 작성자를 포함한다. 이는 생성 RPC의 작성자 불변 조건과 같다.
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
    // 첫 발생분이 생성 RPC의 유용한 결과다. 기반 목록에는 시리즈 기준점을 유지하고
    // 구체화된 행을 반환한다.
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
    // 시리즈 기준점인 단일 키는 전체 범위 변환/갱신으로만 편집할 수 있다.
    // 발생분별 편집에는 순번 키가 있어야 한다.
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
        // 발생분 버전은 `this` 재정의에만 의미가 있다. `future`/`all`은 상위 시리즈를
        // 대상으로 하므로 요청이 멱등 무동작이어도 범위 전체의 0을 반환한다.
        // 그러면 로컬 어댑터가 Supabase 파서가 강제하는 처리 결과 계약과 바이트
        // 단위로 호환된다.
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
              // 전체 범위 초안은 새 시리즈 기준점 또는 단일 시각이 된다. 편집 전
              // 예약 현지 타임스탬프를 유지하지 않는다.
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
          // 순번 0은 저장된 시리즈 기준점이다. 반복 구간만 제거하면 구체화 로직이
          // 아직 살아 있는 기준점으로 대체해 삭제된 첫 발생분을 되살린다. 희소 상태를
          // 지우기 전에 기준점 자체를 삭제 표시 처리하여 모든 읽기 경로를 삭제에 안전하게 한다.
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
      // 이전 `future` 편집이 이미 여러 구간을 만들었을 수 있다. 이 분할 바로 앞의
      // 구간을 닫는다. 원래 기준점만 줄이면 이전의 후속 구간이 새 경계를 지나
      // 계속 이어져 중복 발생분을 구체화한다.
      final lastIndex = segments.length - 1;
      final prior = segments[lastIndex];
      final oldRule = prior.template.recurrenceRule!;
      // `future` 편집/삭제는 원래 규칙이 `never`/`count`/`until` 중 무엇이든 대상 순번에서
      // 이전 구간을 닫는다. `never`/`until` 규칙을 그대로 두면 요청된 분할 뒤의 발생분이
      // 되살아난다.
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
    // 변경 가능한 일정 필드를 파싱하기 전에 호출자/그룹을 기준으로 권한을 확인한다.
    // 비활성 사용자/외부인 요청이 페이로드의 다른 형식이 올바른지 알아서는 안 되며,
    // 보관된 그룹은 최종 쓰기 보호 조건이다.
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
    // 빈 교체는 레거시 단일 일정에서 의도한 것이며 생성 시의 작성자 기본값과 다르다.
    // 반복 시리즈는 아래에서 검사하며 작성자 배정을 유지해야 한다.
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
      // 표준 현재 집합으로 교체하는 것은 멱등 무동작이다. 참여자 배정을 바꾸지 않은
      // 쓰기에 버전 전환이나 실시간 이벤트를 만들어 내지 않는다.
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
      // 레거시 행은 날짜 메타데이터를 생략할 수 있지만 UTC 시각은 일정 시간대에서 정확한
      // 현지 자정 경계여야 한다. 해당 시간대에서 날짜를 유도한 뒤 메타데이터를 표준화한다.
      // 양의 오프셋에서는 UTC 시각이 기기 날짜의 전날일 수 있다. 기존 로컬 어댑터는 UTC
      // 기본 종일 초안에 비 UTC DateTime 값을 허용했다. 이 좁은 레거시 입력 형식은
      // 유지하되 저장 시각을 날짜 메타데이터와 같은 UTC 자정으로 표준화한다. 이전 현지
      // 날짜 해석을 유지하면서 호출자의 로컬 시각을 저장하면 `all_day_start`와
      // `starts_at`이 서로 달라진다(예: KST 기기).
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
    // 명시적 메타데이터가 있는 행은 저장된 UTC 경계와 일치해야 한다. 메타데이터가 없는
    // 레거시 초안은 허용하고 현지 자정 UTC로 표준화하여 새 쓰기가 모호하지 않은 하나의
    // 표현을 갖게 한다.
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

  /// 현재 활성 멤버십을 기준으로 참여자 목록을 표준화하고 검증한다. [defaultCreatorId]는
  /// 새 일정 생성에만 사용한다. 제공되면 반환하는 표준 시리즈 배정에 작성자를 항상
  /// 포함한다. 기존 배정을 의도적으로 지우는 호출자는 이 인수를 생략한다.
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
      // 멤버십 정리는 현재 배정을 유지하는 작업이다. 삭제된 일정은 기록으로 유지되고
      // 원격 데이터베이스도 의도적으로 하위 행을 유지하므로, 이후 나가기/비활성화 때
      // 참여자 ID나 버전을 다시 쓰지 않는다.
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
      // 발생분 재정의는 로컬 어댑터에서 완전한 PlannerEvent 스냅샷이다. 상속한
      // 시리즈 배정과 상위 버전을 기준점/구간과 맞춘다. 그렇지 않으면 이번 발생분
      // 재정의가 비활성 참여자를 유지한 채 이후 참여자 필터가 적용된 구체화 과정을
      // 통과할 수 있다. 모든 행의 멤버를 event_members에서 유도하는 SQL 경로와 다르다.
      _syncSeriesOverrideMembers(
        groupId,
        updated.seriesId,
        updated.memberIds,
        version: updated.version,
        updatedAt: updated.updatedAt,
      );
    }
    // 모든 일정 행이 하나의 일관된 스냅샷으로 전달되도록 호출자가 이 도우미 뒤에
    // 멤버십/수명 주기 변경을 내보낸다.
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
    final firstOccurrenceDate = recurrenceFirstOccurrenceDate(anchorDate, rule);
    if (rule.end == RecurrenceEnd.until &&
        (rule.untilDate == null ||
            dateOnly(rule.untilDate!).isBefore(firstOccurrenceDate))) {
      throw const FormatException('반복 종료 날짜는 첫 반복 날짜와 같거나 이후여야 합니다.');
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
        // SQL은 시간 지정 반복의 최대 길이를 경과 UTC 초가 아니라 일정의 IANA 현지
        // 시각(`at time zone`)으로 검증한다. 시계 되돌림을 지나는 민간력 366일은 UTC에서
        // 366일+1시간이고 시계 앞당김을 지나면 366일-1시간이다. 모든 기기에서 이
        // 검사가 결정론적으로 동작하도록 UTC 태그가 붙은 민간력 튜플을 사용한다.
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
  Future<EventRangePage> searchEvents({
    required String userId,
    required String groupId,
    required EventRange range,
    required String query,
    EventRangeCursor? cursor,
    int limit = eventSearchDefaultPageSize,
    String? creatorId,
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
        EventSearchCapability,
        EventByIdReadCapability,
        EventOccurrenceReadCapability,
        InvitePreviewCapability {
  /// 인증 전용 기능이 사용하는 현재 인증 행위자다. 전송 테스트에서 서명된 JWT를
  /// 만들지 않고 일치하는 세션을 제공할 수 있도록 재정의 가능한 작은 접점으로 둔다.
  /// 프로덕션 코드는 항상 Supabase 인증 클라이언트를 읽는다.
  String? get currentSessionUserId => _client.auth.currentUser?.id;

  /// [lifecyclePollInterval]은 프로덕션에서 보수적인 기본값인 15초로 의도적으로
  /// 제한한다. 신뢰할 수 있는 재확인 경로를 테스트할 때는 더 짧은 시계 간격을
  /// 주입할 수 있다. 앱은 기본값을 사용하므로 멤버십/보관 취소에 실시간 행 알림만
  /// 의존하지 않는다.
  SupabaseScheduleRepository(
    this._client, {
    Duration lifecyclePollInterval = const Duration(seconds: 15),
  }) : _lifecyclePollInterval = lifecyclePollInterval {
    if (lifecyclePollInterval <= Duration.zero) {
      throw ArgumentError.value(
        lifecyclePollInterval,
        'lifecyclePollInterval',
        '0보다 커야 합니다',
      );
    }
  }
  final SupabaseClient _client;
  final Duration _lifecyclePollInterval;
  int _rangeInvalidationChannelCounter = 0;

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    // 기존 프로젝션 계약: select( 'id,name,description,timezone,version,memberships!inner(user_id,is_active)',
    // 제한된
    // 조인 프로젝션 select('id,name,description,timezone,version')은 활성 프로젝션에
    // 수명 주기/소유자 필드가 추가되어도 여기 계속 문서화한다.
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

  /// 기존 멤버 병합 경로가 사용하는 상위 일정 스트림 접점이다. 재정의 가능한
  /// 메서드로 두면 결정론적 테스트가 실제 WebSocket 없이 실시간 행을 제공할 수 있다.
  /// 프로덕션 호출자는 Supabase 스트림을 사용한다.
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
    // v2 RPC가 기본 프로덕션 달력 경로다. 인증 컨텍스트가 없거나 일치하지 않으면
    // 요청을 보내지 않는다. 로컬 사용자 ID는 라우팅 힌트일 뿐이며 현재 Supabase 세션과
    // 일치해야 한다.
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
  Future<EventRangePage> searchEvents({
    required String userId,
    required String groupId,
    required EventRange range,
    required String query,
    EventRangeCursor? cursor,
    int limit = eventSearchDefaultPageSize,
    String? creatorId,
    String? participantId,
  }) async {
    final normalizedQuery = normalizeEventSearchQuery(query);
    if (userId.trim().isEmpty || groupId.trim().isEmpty) {
      throw const ScheduleValidationException('로그인 세션과 그룹을 확인해 주세요.');
    }
    _validateRemoteSearchShape(range, limit);
    _requireCurrentRemoteUser(userId);
    if (cursor != null &&
        (cursor.occurrenceKey.isEmpty ||
            !isValidOccurrenceKey(cursor.occurrenceKey))) {
      throw const ScheduleValidationException('지원하지 않는 검색 페이지 커서입니다.');
    }
    final normalizedCreator = creatorId?.trim();
    final normalizedParticipant = participantId?.trim();
    if (creatorId != null && normalizedCreator!.isEmpty ||
        participantId != null && normalizedParticipant!.isEmpty) {
      throw const ScheduleValidationException('검색 멤버를 확인해 주세요.');
    }
    final result = await _client.rpc<dynamic>(
      'search_events_v1',
      params: <String, dynamic>{
        'p_group_id': groupId,
        'p_range_start': range.startUtc.toIso8601String(),
        'p_range_end': range.endUtc.toIso8601String(),
        'p_view_timezone': range.viewTimezone,
        'p_query': normalizedQuery,
        'p_limit': limit,
        'p_cursor': cursor?.encode(),
        'p_creator_id': normalizedCreator,
        'p_participant_id': normalizedParticipant,
      },
    );
    final page = _eventRangePageFromRpcResult(
      result,
      expectedGroupId: groupId,
      range: range,
      cursor: cursor,
      limit: limit,
      participantId: normalizedParticipant,
      strictRowKeys: true,
    );
    final foldedQuery = normalizedQuery.toLowerCase();
    for (final event in page.events) {
      if ((normalizedCreator != null && event.ownerId != normalizedCreator) ||
          (foldedQuery.isNotEmpty &&
              !event.title.toLowerCase().contains(foldedQuery) &&
              !event.note.toLowerCase().contains(foldedQuery))) {
        throw const ScheduleConflictException('검색 결과 응답을 확인할 수 없습니다.');
      }
      // 검색 커서는 항상 엄격한 v2 튜플이다. 범위 파서는 하위 호환성을 위해 v1
      // 커서를 허용하므로 호출자에게 페이지를 반환하기 전에 여기서 더 강한 검색
      // 계약을 적용한다.
      if (page.nextCursor != null && page.nextCursor!.occurrenceKey.isEmpty) {
        throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
      }
    }
    if (page.nextCursor != null && page.events.isEmpty) {
      throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
    }
    if (page.nextCursor != null && page.events.isNotEmpty) {
      final last = page.events.last;
      final next = page.nextCursor!;
      if (next.startsAtUtc != last.startAt.toUtc() ||
          next.eventId != last.id ||
          next.occurrenceKey != last.occurrenceKey) {
        throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
      }
    }
    return page;
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
        // 가능한 범위에서 정리한다. 다음 세대는 아래의 취소/재연결 플래그로 계속 보호한다.
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
      // 제거를 기다리기 전에 표시한다. SDK가 removeChannel의 일부로 `closed`를 동기적으로
      // 보고할 수 있으며, 그 콜백이 두 번째 재연결을 예약하거나 더 새 채널을
      // 제거해서는 안 된다.
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
            // 상위 일정 버전 변경은 기능 5의 참여자 신호다. 무효화 페이로드는 변경
            // 전용으로 유지하고 설명이나 참여자 행을 노출하지 않는다.
            select: const <String>['id', 'group_id', 'version', 'deleted_at'],
            callback: (_) {
              // 폐기된 SDK 채널도 대기열의 페이로드 하나를 전달하거나 스스로 다시
              // 참여할 수 있다. 현재 등록된 세대만 컨트롤러를 무효화할 수 있다.
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
            // 성공한 재구독 자체가 제한된 복구 신호다. 이전 소켓이 끊긴 동안 일정
            // 변경이 발생했을 수 있으므로 컨트롤러가 한 번 다시 가져오게 한다.
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
            // `active`를 지우기 전에 식별 정보를 포착한다. 이전 채널의 콜백이 더 새
            // 채널의 구독 상태를 재설정해서는 안 된다.
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
        // 한 번에 활성 채널 하나만 둔다. 제한된 재시도와 주기적 대체 동작으로 제한
        // 없는 재연결 루프나 중복 구독 없이 끊기거나 놓친 소켓을 복구한다.
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

  /// 상위 일정 스트림이 바뀔 때마다 불변 일정 스냅샷을 다시 만든다. 참여자 행은
  /// 의도적으로 실시간 발행이 없다. 모든 참여자 변경이 상위 일정 버전을
  /// 증가시키며, 이 신호가 일괄 하위 읽기를 예약한다.
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
          // 상위 실시간 프로젝션은 보통 event_members를 생략한다. 그래도 완전하고
          // 엄격히 검증된 일정 페이로드를 포함해야 한다. 그렇지 않으면 하위 배정 읽기가
          // 끝나기 전에 _eventFromRow가 잘못된 타임스탬프나 뒤집힌 범위를 정규화할 수 있다.
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
          // 성공한 하위 쿼리는 명시적인 빈 배정을 포함해 항상 맵 항목을 만든다.
          // 여기서 작성자를 꾸며 내지 않는다.
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
        // 하위 읽기/파싱 실패 시 마지막 성공 스냅샷을 유지한다. 빈 목록을 내보내면
        // 개인정보 보호 권한 철회처럼 보인다.
        if (!cancelled && token == generation && !controller.isClosed) {
          controller.addError(error, stack);
          // 하위 행은 실시간 발행의 일부가 아니므로, 그렇지 않으면 일시적인
          // REST 실패로 이 상위 스냅샷이 영구히 오래된 상태로 남는다. 잠시 후 정확한
          // 세대를 재시도한다. 더 새 상위 스냅샷이나 취소는 이 작업을 무효화한다.
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
          // 가능한 범위에서 취소하여 오래된 스트림이 더 새 그룹 선택을 막지 않게 한다.
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

  /// [eventRowsStream]과 짝을 이루는 하위 배정 읽기 접점이다. 구체적인 구현은 정렬된
  /// 일괄 조회 하나를 수행한다. 테스트 대역은 실시간 병합과 잘못된 행 처리를
  /// 실행하도록 이를 재정의할 수 있다.
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
    // 모든 멤버십 또는 그룹 신호와 제한된 타이머마다 멤버십 검사를 의도적으로 반복한다.
    // RLS로 필터링된 Supabase 스트림은 다른 클라이언트가 해당 멤버십을 비활성화해도 행을
    // 유지할 수 있다. 따라서 처음 검사에 성공했다고 스트림의 남은 수명 동안 권한이
    // 보장되는 것은 아니다.
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

  /// 현재 요청자/그룹 관계를 신뢰할 수 있게 확인한다. RLS가 허용할 때 `memberships`
  /// 조회는 비활성 행도 의도적으로 포함한다. Postgres Changes가 더는 RLS 정책을
  /// 만족하지 않는 갱신을 생략해도 스트림 콜백은 이 읽기를 실행한다.
  Future<PlannerGroup?> _readUsableGroup(String userId, String groupId) async {
    final Object? membership = await _client
        .from('memberships')
        .select('user_id,is_active,removed_at')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .maybeSingle();
    // 누락된 행이나 명시적인 비활성/제거 표시는 확정된 멤버십 상실이다. 일부만 있거나
    // 잘못된 행은 그렇지 않다. 모호한 응답을 개인정보 보호 삭제 표시로 바꾸지 말고 마지막으로
    // 알려진 상태를 유지한 채 재시도한다.
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
    // deleted_at이 `null`이 아닌 즉시 수명 주기 갱신은 최종 상태다. 이 표시를 유도할 때
    // 모델 대체 필드에 의존하지 않는다. 성공한 부재/보관 응답은 상실을 뜻하지만 잘못되거나
    // 일부만 있는 응답은 이후 재시도가 성공할 때까지 마지막으로 알려진 상태를 유지한다.
    if (!groupRow.containsKey('deleted_at') || !_hasGroupFields(groupRow)) {
      throw StateError('그룹 상태 응답을 확인할 수 없습니다.');
    }
    // 조회는 요청된 ID로 범위가 제한되지만 잘못된 어댑터나 다른 그룹 응답을 선택한
    // 수명 주기 행으로 허용해서는 안 된다. 불일치는 일시적인 잘못된 읽기로 처리하여
    // 호출자가 상태를 교체하지 않고 마지막으로 알려진 값을 유지한 채 재시도하게 한다.
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

  /// 일정, 멤버십, 그룹을 독립적으로 구독하는 요청자 범위 일정 스트림을 만든다. 모든
  /// 신호는 신뢰할 수 있는 REST 읽기만 예약한다. RLS 정책이 멤버십/그룹 갱신을
  /// Postgres Changes에서 완전히 숨기는 경우는 타이머가 처리한다.
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
          // 첫 멤버십/그룹 읽기가 끝나기 전에 일정 스트림이 초기 스냅샷을 전달할 수
          // 있다. 다음 일정 변경까지 달력을 영구히 비워 두지 말고 권한이 확인되면 버퍼에 담긴
          // 스냅샷을 다시 전달한다.
          controller.add(latestEvents!);
        }
      } catch (error, stack) {
        // 신뢰할 수 있는 읽기가 실패했다고 멤버십 상실이 증명된 것은 아니다. 마지막으로
        // 알려진 권한/일정 상태를 유지하고 제한된 타이머 또는 대기열에 든 실시간 신호가
        // 재시도하게 한다. 성공한 읽기에서 멤버십이 없거나 비활성으로 확인된 경우에만
        // 아래의 개인정보 보호 삭제용 빈 스냅샷을 내보낸다.
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
      // 채널 오류는 일시적인 전송 진단 정보이지 수명 주기 사실이 아니다. WebSocket이
      // 한 번 실패한 뒤 정상 그룹을 툼스톤 처리하지 말고, 마지막으로 알려진 일정 권한을
      // 보존하며 신뢰할 수 있는 타이머/실시간 재시도에 의존한다.
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
          // 실시간 구독 해제 실패가 스트림 컨트롤러를 누출하거나 선택 변경 완료를
          // 막아서는 안 된다.
        }
      }
    }

    Future<void> setup() async {
      if (setupStarted || cancelled) return;
      setupStarted = true;
      // 실시간 구독을 열기 전에 신뢰할 수 있는 대체 동작을 시작한다. 동기식
      // `.stream()`/`.listen()` 실패 때문에 감시자가 15초 개인정보 보호 재확인 루프 없이
      // 고립되어서는 안 된다.
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
      // 채널 설정이 실패해도 신뢰할 수 있는 읽기를 한 번 실행한다. 위 타이머는 계속
      // 활성 상태이므로 나중에 네트워크가 복구되면 상태를 복원할 수 있다.
      await checkAuthoritatively();
    }

    controller = StreamController<List<PlannerEvent>>(
      onListen: () => unawaited(setup()),
      onCancel: cancelAll,
    );
    return controller.stream;
  }

  /// 원격 클라이언트가 선택한 그룹을 보관하거나 요청자를 제거할 때 해당 그룹을
  /// 무효화하는 그룹 수명 주기 스트림을 만든다. [_watchRemoteEventsForUser]와 같은
  /// 멤버십/그룹 실시간 신호 및 주기적인 신뢰 가능 대체 동작을 사용한다. 이 스트림을
  /// 취소하면 Supabase 채널 세 개와 타이머를 모두 해제한다.
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
        // 읽기 오류는 확정된 멤버십/그룹 상실이 아니다. 마지막으로 알려진 수명 주기
        // 값을 유지하고 15초 폴링이 다시 시도하게 한다. 성공한 읽기에서 `null`을 반환할
        // 때만 툼스톤을 내보낸다.
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
      // 실시간 채널 오류는 전송 상태이지 선택한 그룹이 보관되었거나 이 멤버가
      // 제거되었다는 증명이 아니다. 주기적인 신뢰 가능 재확인은 계속 활성 상태이며
      // 수명 주기 상실 방출을 담당한다.
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
          // 취소는 가능한 범위에서 수행한다. 구독이 취소되면 Supabase가 각 스트림 채널을
          // 직접 닫는다.
        }
      }
    }

    Future<void> setup() async {
      if (setupStarted || cancelled) return;
      setupStarted = true;
      // WebSocket 설정과 별개로 개인정보 보호 대체 동작을 활성 상태로 유지한다. 동기식 스트림
      // 생성 실패가 발생해도 즉시 신뢰 가능한 읽기와 이후 15초 간격 재시도를 수행해야 한다.
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
              // 다른 멤버의 비활성화/제거도 선택한 그룹 명단을 갱신해야 한다. 신뢰할 수
              // 있는 읽기는 계속 요청자 범위로 제한되며 이 신호는 해당 읽기만 예약한다.
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
    // Supabase RPC는 auth.uid()에서 행위자를 유도한다. 결정론적 권한 테스트를 위해 로컬
    // 어댑터가 actorId를 허용하더라도 이 페이로드에는 의도적으로 넣지 않는다.
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
      // SQL RPC는 auth.uid()에서 행위자를 유도한다. 반환된 복합 행을 컨트롤러에
      // 노출하기 전에 여전히 호출자 소유인지 확인한다. 소유자 표시가 없거나 일치하지
      // 않으면 충돌이며 성공한 편집으로 처리하지 않는다.
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
    // 전송 데이터에서 유일한 행위자 출처는 auth.uid()다.
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
    // RPC는 보관된 복합 그룹 행을 반환한다. 정확한 대상, 최종 삭제 표시, 한 단계 버전
    // 전환을 요구한다. 스칼라나 다른 그룹의 행을 성공으로 해석해서는 안 된다.
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
    // 호출자가 제공한 ID는 오래된 세션 보호 조건일 뿐이다. RPC 매개변수로 보내지 않으며
    // 데이터베이스가 세션에서 auth.uid()를 유도한다.
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
    // 로컬 사용자 ID는 오래된 세션 보호 조건일 뿐이다. RPC는 auth.uid()에서 행위자를
    // 유도하므로 SDK 세션이 없거나 일치하지 않으면 전달자 토큰을 전송하기 전에
    // 실패 시 차단해야 한다.
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
      // RPC가 이미 멤버십을 삽입/재활성화했다. 이 프로젝션 읽기가 실패했다는 이유만으로
      // 호출자가 전달자 토큰을 다시 시도하게 하지 말고 고정된 새로 고침 오류를 노출한다.
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
    // 이전 직접 페이로드는 `'color_value': draft.colorValue`를 사용했다. RPC는 명시적인
    // p_color_value 인수에 같은 값을 유지한다.
    // 레거시 매핑: 'color_value': draft.colorValue.
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
        // NULL이면 생성 RPC가 작성자 기본값을 적용한다. 호출자가 배정되지 않은 일정을
        // 의도적으로 만들 수 있도록 명시적인 빈 목록은 []로 유지해야 한다.
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

  /// 생성 RPC가 처음 구체화한 발생분을 완전한 표준 응답으로 검증한다. 이 행이 원자적
  /// 일정/규칙/멤버 쓰기의 유일하게 신뢰할 수 있는 결과다. 일부만 있거나 일치하지 않는
  /// 행을 허용하면 컨트롤러에 안전하게 재시도할 수 없는 유령 시리즈가 남는다.
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
    // 처음 구체화된 행이 반드시 원시 일정 기준점인 것은 아니다. 월간 규칙은 의도적으로
    // 다른 날짜에 시작할 수 있고(예: 1월 15일 기준점에서 monthly_day=31이면 1월 31일
    // 반환), 시간대 변환으로 현지 시각 경계가 DST 전환을 넘을 수 있다. 입력 기준 시각과
    // 직접 비교하지 말고 로컬 어댑터와 같은 제한된 계산으로 표준 순번 0 프로젝션을
    // 재구성한다.
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
        // 전체 범위 RPC는 멤버 교체가 본문/규칙 쓰기와 원자적으로 이뤄지도록 완전한 참여자
        // 집합을 요구한다. 초안에서 멤버를 생략하면 일정의 현재 시리즈 배정을 보존한다.
        // NULL은 참여자 편집을 거부하고 서버가 기존 행을 상속하는 `this`/`future` 범위에만 쓴다.
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
    // 이전 직접 페이로드는 `'color_value': event.colorValue`를 사용했다. RPC는 명시적인
    // p_color_value 인수에 같은 값을 유지한다.
    // 기존 매핑: 'color_value': event.colorValue.
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
    // actorId는 의도적으로 무시한다. 권한은 호출자가 제공한 신원이 아니라 SECURITY
    // DEFINER RPC 안의 auth.uid()에 속한다.
    final result = await _client.rpc<dynamic>(
      'replace_event_members_if_version',
      params: <String, dynamic>{
        'p_event_id': eventId,
        'p_expected_version': expectedVersion,
        'p_member_ids': normalizedMemberIds,
      },
    );
    final updated = _eventFromRpcResult(result, expectedEventId: eventId);
    // 변경되지 않은 표준 집합에는 RPC가 멱등이며 예상 버전을 반환한다.
    // 변경된 집합은 정확히 한 번 증가한다.
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
    // `soft_delete_event_if_version`은 정확히 하나의 복합 행을 반환한다. 스칼라, 빈 본문,
    // 여러 행 응답의 임의 첫 행을 허용하지 않는다. 이를 성공으로 처리하면 서버 계약이
    // 실제로 모호한데도 호출자는 일정이 삭제되었다고 믿게 된다.
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
    // 구체화된 모든 행은 식별 열 세 개에 상위 일정 ID를 유지한다. 반복 프로젝션은
    // 항상 `single`이 아닌 순번 키와 유효한 규칙이 있는 발생분이다. 단일 프로젝션은
    // 유일하게 유효한 `single` 행이며 반복 규칙이 있으면 안 된다. 이 검사는 잘못된 행이
    // 충돌하는 복합 식별 정보 아래 병합되거나 잘못된 경로에서 편집되는 것을 막는다.
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

  /// 검색 행은 고정된 전송 형식 프로젝션이다. 검색 RPC 응답은 v1 RPC가 내보내는 완전한
  /// 발생 형식을 포함해야 한다. 발생 키가 `single`인 단일 행도 포함한다. 여기서 기준
  /// 일정 형식을 허용하면 엄격한 v2 키셋 페이지 구분에 필요한 튜플 구성 요소를 잃는다.
  /// 임의의/알 수 없는 키는 이 경계에서 거부한다.
  static bool _hasExactEventRowKeys(Map<String, dynamic> row) {
    const baseKeys = <String>{
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
      'member_ids',
    };
    const occurrenceKeys = <String>{
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
    final keys = row.keys.toSet();
    return keys.length == baseKeys.length + occurrenceKeys.length &&
        keys.containsAll(baseKeys) &&
        keys.containsAll(occurrenceKeys);
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
      // 시간 지정 행에는 이전 종일 편집의 오래된 날짜 전용 메타데이터가 있으면 안 된다.
      // 이 혼합을 유효하게 처리하면 잘못된 RPC 페이로드가 다른 시간 의미로 편집기에 들어간다.
      return start == null && end == null;
    }
    if (startDate == null || endDate == null || !endDate.isAfter(startDate)) {
      return false;
    }
    final timezone = row['timezone'];
    if (timezone is! String || !isValidIanaTimezone(timezone)) return false;
    // 종일 타임스탬프는 현지 날짜 경계의 정확한 UTC 시각이다. 이를 통해 날짜 범위를
    // 주장하면서 자정이 아닌 오프셋을 포함한 임의의 시간 지정 시각을 담은 행을 잡는다.
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
    // `preview_invite`는 jsonb, 즉 JSON 객체 하나를 반환한다. 테이블 RPC 행과 달리
    // 원소 하나짜리 배열은 유효한 응답이 아니며 실패 시 차단해야 한다.
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
    // 복합 RPC/결과와 수명 주기 읽기에는 이 필드들이 있어야 한다. 기본값으로 그룹을
    // 꾸며 내지 않고 일부만 있는 객체는 거부한다.
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

  static void _validateRemoteSearchShape(EventRange range, int limit) {
    if (limit < 1 || limit > 100) {
      throw const ScheduleValidationException('검색 페이지 크기를 확인해 주세요.');
    }
    _validateRemoteRangeShape(range, limit);
  }

  EventRangePage _eventRangePageFromRpcResult(
    Object? result, {
    required String expectedGroupId,
    required EventRange range,
    required EventRangeCursor? cursor,
    required int limit,
    required String? participantId,
    bool strictRowKeys = false,
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
      // `true` 연속 여부 플래그는 서버가 요청한 완전한 페이지를 반환했을 때만 의미가 있다.
      // 짧은 페이지에서 `has_more=true`를 허용하면 클라이언트가 커서를 영구히 반복하거나
      // 행을 조용히 건너뛸 수 있다.
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
        if (strictRowKeys && !_hasExactEventRowKeys(row)) {
          throw const FormatException('일정 페이지 응답을 확인해 주세요.');
        }
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

  /// 낙관적 그룹 RPC가 반환한 완전한 활성 그룹 행을 검증한다. 성공한 HTTP/RPC
  /// 응답만으로는 충분하지 않다. 비어 있거나 여러 개, 일부만 있거나 오래됨, 다른 그룹,
  /// 보관된 행은 허용하거나 더 넓은 RLS 쿼리로 다시 가져오지 않고 안전한 충돌로 바꾼다.
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
    // SQL 계약에서 이 열 이름은 deleted_at이다. 직접 작성한 어댑터에만 camelCase를
    // 허용하되 어느 쪽이든 명시적인 `null` 표시를 요구한다. 그래야 생략되거나 일부만 있는
    // 수명 주기 필드를 활성 그룹으로 잘못 판단하지 않는다.
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
    // 이전 일정 행에는 하위 프로젝션이 없었다. 작성자 전용 해석을 유지하되 명시적인
    // `member_ids: []`는 빈 집합으로 남긴다.
    return List<String>.unmodifiable(<String>[ownerId]);
  }

  static String? _stringValue(Object? value) => value == null ? null : '$value';

  static DateTime? _dateTimeValue(Object? value) =>
      value == null ? null : DateTime.tryParse('$value')?.toUtc();

  /// 오프셋/UTC 표시가 명시된 전송 타임스탬프만 파싱한다. DateTime.tryParse는 시간대가
  /// 없는 문자열을 호스트의 로컬 시간대로 허용하므로 RPC 응답이 기기 위치에 따라 달라진다.
  static DateTime? _strictDateTimeValue(Object? value) {
    return parseStrictExplicitOffsetTimestamp(value);
  }

  /// v2 JSON 프로젝션의 수명 주기 열은 이미 형식이 지정된 Dart 값이 아니라 전송
  /// 타임스탬프다. 여기서는 명시적인 오프셋/Z 형식을 요구하여 `_eventFromRow`가 시간대
  /// 없는 값을 기기 시간대로 조용히 재해석하거나 다른 타임스탬프로 대체하지 못하게 한다.
  /// 기존 테이블 및 실시간 어댑터는 호환성을 위해 관대한 파서를 유지한다.
  static DateTime? _lifecycleTimestamp(Object? value, {required bool strict}) {
    if (strict && value is! String) return null;
    return strict ? _strictDateTimeValue(value) : _dateTimeValue(value);
  }

  static int _intValue(Object? value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
  static int? _intValueNullable(Object? value) {
    if (value is int) return value;
    if (value is num) {
      // RPC 버전/개수 필드는 정수 계약 값이다. `toInt()`가 소수, NaN, 무한대 JSON
      // 숫자를 잘라 낙관적 동시성 검사를 우연히 통과하는 값으로 만들지 못하게 한다.
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
