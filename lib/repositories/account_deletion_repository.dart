import 'package:supabase_flutter/supabase_flutter.dart';

const String accountDeletionFunctionName = 'delete-account';
const String accountDeletionConfirmation = '계정 삭제';

enum AccountDeletionErrorCode {
  confirmationRequired,
  sessionExpired,
  network,
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
    AccountDeletionErrorCode.generic => '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
  };

  @override
  String toString() => message;
}

abstract class AccountDeletionRepository {
  const AccountDeletionRepository();

  bool get isRemote;

  Future<void> deleteAccount({required String confirmation});
}

/// 운영용 어댑터다. 서비스/비밀 키는 이곳에서 절대 사용할 수 없다.
/// 공개 Supabase 클라이언트가 인증된 Edge Function을 호출하고, 함수가
/// 사용자의 JWT를 검증한 뒤 서버에서 권한 있는 Auth 삭제를 수행한다.
class SupabaseAccountDeletionRepository extends AccountDeletionRepository {
  const SupabaseAccountDeletionRepository(this._client);

  final SupabaseClient _client;

  @override
  bool get isRemote => true;

  @override
  Future<void> deleteAccount({required String confirmation}) async {
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
}

/// 결정적인 로컬 미리보기 어댑터다. 원격 계정을 삭제하는 척하지 않고,
/// 네트워크 없이 데모 흐름에서 확인, 중복 제출, 성공, 로그아웃 UI만
/// 실행해 볼 수 있게 한다.
class LocalAccountDeletionRepository extends AccountDeletionRepository {
  LocalAccountDeletionRepository();

  bool _deleted = false;

  @override
  bool get isRemote => false;

  bool get deleted => _deleted;

  @override
  Future<void> deleteAccount({required String confirmation}) async {
    if (confirmation != accountDeletionConfirmation) {
      throw const AccountDeletionException(
        '확인 문구를 정확히 입력해 주세요.',
        code: AccountDeletionErrorCode.confirmationRequired,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // 모바일 클라이언트가 재개되거나 다시 시도될 때의 성공 후 동작과
    // 맞도록 로컬 데모의 재시도를 멱등적으로 처리한다.
    _deleted = true;
  }
}
