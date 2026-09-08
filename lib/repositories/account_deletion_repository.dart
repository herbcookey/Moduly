import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String accountDeletionFunctionName = 'delete-account';
const String accountDeletionConfirmation = '계정 삭제';

enum AccountDeletionErrorCode {
  confirmationRequired,
  sessionExpired,
  network,
  capability,
  protocol,
  generic,
}

/// 제공자나 서버 내부 정보가 포함되지 않은 사용자용 오류다.
class AccountDeletionException implements Exception {
  const AccountDeletionException(
    this.message, {
    this.code = AccountDeletionErrorCode.generic,
  });

  final String message;
  final AccountDeletionErrorCode code;

  /// UI에는 허용 목록에 있는 이 문구만 표시하며 [message]에 담긴 임의의
  /// 제공자 세부 정보는 표시하지 않는다.
  String get safeMessage => switch (code) {
    AccountDeletionErrorCode.confirmationRequired => '확인 문구를 정확히 입력해 주세요.',
    AccountDeletionErrorCode.sessionExpired =>
      '로그인이 만료되었습니다. 다시 로그인한 뒤 시도해 주세요.',
    AccountDeletionErrorCode.network => '네트워크를 확인한 뒤 다시 시도해 주세요.',
    // 기능 세부 정보는 빌드/설정 어댑터에서 올 수 있다. 원시 공급자, URL, 세션 진단
    // 정보를 UI에 절대 되풀이하지 않는다.
    AccountDeletionErrorCode.capability => '계정 삭제는 연결된 서버에서만 사용할 수 있어요.',
    AccountDeletionErrorCode.protocol => '서버 응답을 확인하지 못했어요. 잠시 후 다시 시도해 주세요.',
    AccountDeletionErrorCode.generic => '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
  };

  @override
  String toString() => message;
}

/// 로컬/설정 어댑터는 이 작업을 실제로 제공할 수 없다. 일반 실패와 분리하면 계정이
/// 삭제된 것처럼 가장하지 않고 UI에서 현재 기능을 설명할 수 있다.
class AccountDeletionCapabilityException extends AccountDeletionException {
  const AccountDeletionCapabilityException([super.message = _defaultMessage])
    : super(code: AccountDeletionErrorCode.capability);

  static const String _defaultMessage = '계정 삭제는 연결된 서버에서만 사용할 수 있어요.';
}

@immutable
class AccountDeletionGroupImpact {
  const AccountDeletionGroupImpact({
    required this.id,
    required this.name,
    required this.timezone,
    required this.version,
    required this.status,
    required this.memberCount,
    required this.membershipCount,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String timezone;
  final int version;
  final String status;
  final int memberCount;
  final int membershipCount;
  final DateTime? deletedAt;

  bool get isArchived => status == 'archived';

  factory AccountDeletionGroupImpact.fromJson(Object? value) {
    if (value is! Map) _invalid();
    final map = value.cast<Object?, Object?>();
    final id = _requiredString(map['id']);
    final name = _requiredString(map['name']);
    final timezone = _requiredString(map['timezone']);
    final status = _requiredString(map['status']);
    final version = _requiredNonNegativeInt(map['version']);
    final memberCount = _requiredNonNegativeInt(map['member_count']);
    final membershipCount = _requiredNonNegativeInt(map['membership_count']);
    final deletedValue = map['deleted_at'];
    DateTime? deletedAt;
    if (deletedValue != null) {
      if (deletedValue is! String) _invalid();
      deletedAt = DateTime.tryParse(deletedValue)?.toUtc();
      if (deletedAt == null) _invalid();
    }
    if (status != 'active' && status != 'archived') _invalid();
    // 상태와 소프트 삭제 표시는 같은 수명 주기 상태를 보는 두 관점이다. 서로
    // 모순되는 페이로드는 영향을 표시하기 전에 거부한다.
    if ((status == 'active') != (deletedAt == null)) _invalid();
    if (memberCount > membershipCount) _invalid();
    return AccountDeletionGroupImpact(
      id: id,
      name: name,
      timezone: timezone,
      version: version,
      status: status,
      memberCount: memberCount,
      membershipCount: membershipCount,
      deletedAt: deletedAt,
    );
  }
}

@immutable
class AccountDeletionImpact {
  const AccountDeletionImpact({
    this.ownedGroups = const <AccountDeletionGroupImpact>[],
    this.activeOwnedGroups = const <AccountDeletionGroupImpact>[],
    this.archivedOwnedGroups = const <AccountDeletionGroupImpact>[],
    this.groups = 0,
    this.events = 0,
    this.invites = 0,
    this.memberships = 0,
  });

  final List<AccountDeletionGroupImpact> ownedGroups;
  final List<AccountDeletionGroupImpact> activeOwnedGroups;
  final List<AccountDeletionGroupImpact> archivedOwnedGroups;
  final int groups;
  final int events;
  final int invites;
  final int memberships;

  bool get hasActiveOwnedGroups => activeOwnedGroups.isNotEmpty;

  // 형용사를 앞에 두는 UI 통합에서 사용하는 읽기 쉬운 별칭이다.
  List<AccountDeletionGroupImpact> get ownedActiveGroups => activeOwnedGroups;
  List<AccountDeletionGroupImpact> get ownedArchivedGroups =>
      archivedOwnedGroups;
  int get groupCount => groups;
  int get eventCount => events;
  int get inviteCount => invites;
  int get membershipCount => memberships;

  /// 유효한 빈 요약은 이전 `Future<void> deleteAccount` API를 노출하는 레거시 테스트
  /// 어댑터에서만 사용한다. 원격 Edge 응답은 항상 전체 요약을 담아야 한다([fromJson] 참고).
  static const empty = AccountDeletionImpact(
    ownedGroups: <AccountDeletionGroupImpact>[],
    activeOwnedGroups: <AccountDeletionGroupImpact>[],
    archivedOwnedGroups: <AccountDeletionGroupImpact>[],
    groups: 0,
    events: 0,
    invites: 0,
    memberships: 0,
  );

  factory AccountDeletionImpact.fromJson(Object? value) {
    if (value is! Map) _invalid();
    final map = value.cast<Object?, Object?>();
    final owned = _groupList(map['owned_groups']);
    final active = _groupList(map['active_owned_groups']);
    final archived = _groupList(map['archived_owned_groups']);
    final groups = _requiredNonNegativeInt(map['groups']);
    final events = _requiredNonNegativeInt(map['events']);
    final invites = _requiredNonNegativeInt(map['invites']);
    final memberships = _requiredNonNegativeInt(map['memberships']);
    // 서버는 같은 소유 집합을 세 가지 뷰로 반환한다. 불일치를 거부하면 사용자가
    // 확인하기 전에 오래되었거나 잘못된 페이로드를 잡을 수 있다.
    if (owned.length != active.length + archived.length) _invalid();
    if (groups != owned.length) _invalid();
    final ownedIds = owned.map((group) => group.id).toSet();
    final activeIds = active.map((group) => group.id).toSet();
    final archivedIds = archived.map((group) => group.id).toSet();
    final unionIds = <String>{...activeIds, ...archivedIds};
    if (ownedIds.length != owned.length ||
        activeIds.length != active.length ||
        archivedIds.length != archived.length ||
        !activeIds.every(ownedIds.contains) ||
        !archivedIds.every(ownedIds.contains) ||
        activeIds.intersection(archivedIds).isNotEmpty ||
        unionIds.length != ownedIds.length ||
        !unionIds.containsAll(ownedIds) ||
        !ownedIds.containsAll(unionIds) ||
        active.any((group) => group.isArchived) ||
        archived.any((group) => !group.isArchived)) {
      _invalid();
    }
    // 각 파티션은 같은 표준 행을 반복해 직렬화한 것이다. ID/수명 주기 표시만 비교하면
    // 한 뷰의 오래된 이름, 시간대, 버전, 개수가 확인 UI에 도달할 수 있다. 모든 활성/
    // 보관 레코드는 정규화된 삭제 타임스탬프를 포함해 클라이언트에 보이는 모든 필드가
    // 해당 소유 레코드와 같아야 한다.
    final ownedById = <String, AccountDeletionGroupImpact>{
      for (final group in owned) group.id: group,
    };
    for (final partitionGroup in <AccountDeletionGroupImpact>[
      ...active,
      ...archived,
    ]) {
      final canonical = ownedById[partitionGroup.id];
      if (canonical == null || !_sameGroupImpact(canonical, partitionGroup)) {
        _invalid();
      }
    }
    return AccountDeletionImpact(
      ownedGroups: List.unmodifiable(owned),
      activeOwnedGroups: List.unmodifiable(active),
      archivedOwnedGroups: List.unmodifiable(archived),
      groups: groups,
      events: events,
      invites: invites,
      memberships: memberships,
    );
  }
}

@immutable
class AccountDeletionResult {
  const AccountDeletionResult({
    required this.deleted,
    this.summary = AccountDeletionImpact.empty,
  });

  final bool deleted;
  final AccountDeletionImpact summary;

  factory AccountDeletionResult.fromJson(Object? value) {
    if (value is! Map) _invalid();
    final map = value.cast<Object?, Object?>();
    if (map['deleted'] != true) _invalid();
    return AccountDeletionResult(
      deleted: true,
      summary: AccountDeletionImpact.fromJson(map['summary']),
    );
  }

  static AccountDeletionResult parse(Object? value) =>
      AccountDeletionResult.fromJson(value);
}

Never _invalid() => throw const AccountDeletionException(
  '서버 응답 형식이 올바르지 않습니다.',
  code: AccountDeletionErrorCode.protocol,
);

String _requiredString(Object? value) {
  if (value is! String || value.trim().isEmpty) _invalid();
  return value;
}

int _requiredNonNegativeInt(Object? value) {
  final number = value is num ? value : int.tryParse('$value');
  if (number is! num || number < 0 || number % 1 != 0) _invalid();
  return number.toInt();
}

List<AccountDeletionGroupImpact> _groupList(Object? value) {
  if (value is! List) _invalid();
  return value.map(AccountDeletionGroupImpact.fromJson).toList(growable: false);
}

bool _sameGroupImpact(
  AccountDeletionGroupImpact left,
  AccountDeletionGroupImpact right,
) {
  final leftDeletedAt = left.deletedAt?.toUtc();
  final rightDeletedAt = right.deletedAt?.toUtc();
  return left.id == right.id &&
      left.name == right.name &&
      left.timezone == right.timezone &&
      left.version == right.version &&
      left.status == right.status &&
      left.memberCount == right.memberCount &&
      left.membershipCount == right.membershipCount &&
      (leftDeletedAt?.microsecondsSinceEpoch ==
          rightDeletedAt?.microsecondsSinceEpoch);
}

Object? _decodeJsonBody(Object? value) {
  if (value is String) {
    try {
      return jsonDecode(value);
    } catch (_) {
      _invalid();
    }
  }
  return value;
}

abstract class AccountDeletionRepository {
  const AccountDeletionRepository();

  bool get isRemote;

  /// 확인 전에 서버 소유 그룹과 연쇄 삭제 개수를 반환한다. 레거시 기본값은 의도적으로
  /// 기능 오류다. 프로덕션 및 새 어댑터는 형식이 지정된 RPC 사전 점검으로 이 메서드를
  /// 재정의해야 한다.
  Future<AccountDeletionImpact> preflight() async {
    throw const AccountDeletionCapabilityException();
  }

  Future<AccountDeletionImpact> accountDeletionPreflight() => preflight();

  /// 기존 테스트 대역과의 소스 호환성을 위해 유지한 이전 작업이다. 구현은 원래 API인
  /// `void` 또는 [AccountDeletionResult]를 반환할 수 있다. 기본 타입을 `dynamic`으로
  /// 두어 둘 다 소스 호환성을 유지하면서 새 호출자가 Supabase 어댑터의 형식 지정
  /// 결과를 직접 사용할 수 있게 한다.
  Future<dynamic> deleteAccount({required String confirmation});

  /// Edge `{deleted: true, summary}` 응답의 형식 지정 결과 계약이다. 레거시
  /// `Future<void>` 어댑터는 계정 삭제를 사실대로 확인할 수 없으므로 이 연결부는
  /// 성공을 꾸며 내지 않고 실패 시 차단한다. 맵은 엄격한 결과 계약으로 파싱된
  /// 경우에만 허용한다.
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) async {
    final value = await deleteAccount(confirmation: confirmation);
    if (value is AccountDeletionResult) return value;
    if (value is Map) return AccountDeletionResult.fromJson(value);
    throw const AccountDeletionCapabilityException(
      '계정 삭제 결과 형식을 지원하지 않는 저장소입니다.',
    );
  }

  Future<AccountDeletionResult> deleteAccountResult({
    required String confirmation,
  }) => deleteAccountWithResult(confirmation: confirmation);
}

/// 운영용 어댑터다. 서비스/비밀 키는 이곳에서 절대 사용할 수 없다.
/// 공개 Supabase 클라이언트가 인증된 Edge Function을 호출하고, 함수가
/// 사용자의 JWT를 검증한 뒤 서버에서 권한 있는 Auth 삭제를 수행한다.
class SupabaseAccountDeletionRepository extends AccountDeletionRepository {
  const SupabaseAccountDeletionRepository(this._client);

  final SupabaseClient _client;

  @override
  bool get isRemote => true;

  void _requireConfirmationAndSession(String confirmation) {
    if (confirmation != accountDeletionConfirmation) {
      throw const AccountDeletionException(
        '확인 문구를 정확히 입력해 주세요.',
        code: AccountDeletionErrorCode.confirmationRequired,
      );
    }
    final session = _client.auth.currentSession;
    if (session == null || session.accessToken.trim().isEmpty) {
      throw const AccountDeletionException(
        '로그인이 만료되었습니다. 다시 로그인한 뒤 시도해 주세요.',
        code: AccountDeletionErrorCode.sessionExpired,
      );
    }
  }

  @override
  Future<AccountDeletionImpact> preflight() async {
    final session = _client.auth.currentSession;
    if (session == null || session.accessToken.trim().isEmpty) {
      throw const AccountDeletionException(
        '로그인이 만료되었습니다. 다시 로그인한 뒤 시도해 주세요.',
        code: AccountDeletionErrorCode.sessionExpired,
      );
    }
    try {
      final response = await _client.rpc<dynamic>('account_deletion_preflight');
      return AccountDeletionImpact.fromJson(_decodeRpcValue(response));
    } on AccountDeletionException {
      rethrow;
    } on PostgrestException catch (error) {
      if (error.code == '28000' || error.code == '401') {
        throw const AccountDeletionException(
          '로그인이 만료되었습니다. 다시 로그인한 뒤 시도해 주세요.',
          code: AccountDeletionErrorCode.sessionExpired,
        );
      }
      throw const AccountDeletionException(
        '삭제 영향을 확인하지 못했어요. 다시 시도해 주세요.',
        code: AccountDeletionErrorCode.generic,
      );
    } catch (_) {
      throw const AccountDeletionException(
        '네트워크를 확인한 뒤 다시 시도해 주세요.',
        code: AccountDeletionErrorCode.network,
      );
    }
  }

  @override
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) async {
    _requireConfirmationAndSession(confirmation);
    try {
      final response = await _client.functions.invoke(
        accountDeletionFunctionName,
        body: <String, String>{'confirmation': confirmation},
      );
      if (response.status < 200 || response.status >= 300) {
        throw const AccountDeletionException(
          '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
          code: AccountDeletionErrorCode.generic,
        );
      }
      return AccountDeletionResult.fromJson(_decodeJsonBody(response.data));
    } on AccountDeletionException {
      rethrow;
    } on FunctionException catch (error) {
      if (error.status == 401 || error.status == 403) {
        throw const AccountDeletionException(
          '로그인이 만료되었습니다. 다시 로그인한 뒤 시도해 주세요.',
          code: AccountDeletionErrorCode.sessionExpired,
        );
      }
      throw const AccountDeletionException(
        '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
        code: AccountDeletionErrorCode.generic,
      );
    } catch (_) {
      throw const AccountDeletionException(
        '네트워크를 확인한 뒤 다시 시도해 주세요.',
        code: AccountDeletionErrorCode.network,
      );
    }
  }

  @override
  Future<AccountDeletionResult> deleteAccount({
    required String confirmation,
  }) async {
    return deleteAccountWithResult(confirmation: confirmation);
  }
}

Object? _decodeRpcValue(Object? value) {
  if (value is List) {
    if (value.length != 1) _invalid();
    return value.single;
  }
  return value;
}

/// 어떤 로컬 어댑터도 Auth 계정을 삭제하거나 사실에 맞는 연쇄 삭제 요약을 만들 수 없다.
/// 따라서 거짓 성공 대신 명시적인 기능 오류를 노출한다.
class LocalAccountDeletionRepository extends AccountDeletionRepository {
  LocalAccountDeletionRepository();

  @override
  bool get isRemote => false;

  bool get deleted => false;

  @override
  Future<AccountDeletionImpact> preflight() async {
    throw const AccountDeletionCapabilityException();
  }

  @override
  Future<void> deleteAccount({required String confirmation}) =>
      Future<void>.error(const AccountDeletionCapabilityException());

  @override
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) async {
    throw const AccountDeletionCapabilityException();
  }
}

/// 릴리스/설정 차단 빌드에서 사용한다. 로컬 데이터를 만들지 않으며 계정 삭제가
/// 성공했다고 절대 주장하지 않는다.
class ConfigurationBlockedAccountDeletionRepository
    extends AccountDeletionRepository {
  ConfigurationBlockedAccountDeletionRepository(this.message);

  final String message;

  @override
  bool get isRemote => false;

  AccountDeletionCapabilityException _error() =>
      AccountDeletionCapabilityException(message);

  @override
  Future<AccountDeletionImpact> preflight() =>
      Future<AccountDeletionImpact>.error(_error());

  @override
  Future<void> deleteAccount({required String confirmation}) =>
      Future<void>.error(_error());

  @override
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) => Future<AccountDeletionResult>.error(_error());
}
