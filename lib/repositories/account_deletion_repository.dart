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
    // Capability details can originate from a build/configuration adapter.
    // Never echo raw provider, URL, or session diagnostics into the UI.
    AccountDeletionErrorCode.capability => '계정 삭제는 연결된 서버에서만 사용할 수 있어요.',
    AccountDeletionErrorCode.protocol => '서버 응답을 확인하지 못했어요. 잠시 후 다시 시도해 주세요.',
    AccountDeletionErrorCode.generic => '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
  };

  @override
  String toString() => message;
}

/// The local/configuration adapter cannot truthfully provide this operation.
/// Keeping this separate from a generic failure lets the UI explain what the
/// current capability is without pretending that an account was deleted.
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
    // Status and the soft-delete marker are two views of the same lifecycle
    // state. Reject contradictory payloads before displaying an impact.
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

  // Readable aliases used by UI integrations that prefer the adjective first.
  List<AccountDeletionGroupImpact> get ownedActiveGroups => activeOwnedGroups;
  List<AccountDeletionGroupImpact> get ownedArchivedGroups =>
      archivedOwnedGroups;
  int get groupCount => groups;
  int get eventCount => events;
  int get inviteCount => invites;
  int get membershipCount => memberships;

  /// A valid empty summary is used only by legacy test adapters that expose
  /// the old `Future<void> deleteAccount` API. Remote Edge responses must
  /// always carry a full summary (see [fromJson]).
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
    // The server returns these three views of the same owned set. Rejecting a
    // mismatch catches stale/malformed payloads before the user confirms.
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
    // Each partition is a repeated serialization of the same canonical row.
    // Matching only IDs/lifecycle markers would allow a stale name, timezone,
    // version, or count from one view to reach the confirmation UI.  Require
    // every active/archived record to equal the corresponding owned record on
    // all client-visible fields (including the normalized deleted timestamp).
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

  /// Returns the server-owned groups and cascade counts before confirmation.
  /// The legacy default is intentionally a capability error. Production and
  /// new adapters must override this method with the typed RPC preflight.
  Future<AccountDeletionImpact> preflight() async {
    throw const AccountDeletionCapabilityException();
  }

  Future<AccountDeletionImpact> accountDeletionPreflight() => preflight();

  /// Legacy operation retained for source compatibility with existing fakes.
  /// Implementations may return `void` (the original API) or an
  /// [AccountDeletionResult]. The base type is dynamic so both remain source
  /// compatible while new callers can use the typed result from the Supabase
  /// adapter directly.
  Future<dynamic> deleteAccount({required String confirmation});

  /// Typed result contract for the Edge `{deleted: true, summary}` response.
  /// A legacy `Future<void>` adapter cannot truthfully establish that the
  /// account was deleted, so this bridge fails closed instead of fabricating
  /// success. A map is accepted only when parsed by the strict result
  /// contract.
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

/// No local adapter can delete an Auth account or produce a truthful cascade
/// summary. It therefore exposes an explicit capability error instead of a
/// fake success.
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

/// Used by release/configuration-blocked builds. It never creates local data
/// and never claims that an account deletion succeeded.
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
