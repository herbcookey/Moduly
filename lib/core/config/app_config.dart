import '../invite_link.dart';

/// `--dart-define`으로 전달하는 런타임 설정이다.
///
/// 앱은 의도적으로 Supabase 공개(anon) 키만 받는다. service-role 키는
/// 모바일 바이너리에 절대 포함해서는 안 된다.
class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    this.inviteBaseUrl = '',
  });

  final String supabaseUrl;
  final String supabasePublishableKey;

  /// 공유 가능한 초대 링크를 만들 때 사용하는 공개 출처다.
  /// [supabaseUrl]과는 의도적으로 분리된다. Supabase 프로젝트 URL은 앱이나
  /// 딥 링크의 출처가 아니라 API 엔드포인트이기 때문이다. 값은
  /// `--dart-define=INVITE_BASE_URL=...`로 제공하며 로컬/데모 빌드에서는 생략할 수 있다.
  final String inviteBaseUrl;

  factory AppConfig.fromEnvironment() => const AppConfig(
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    inviteBaseUrl: String.fromEnvironment('INVITE_BASE_URL'),
  );

  bool get hasSupabase =>
      supabaseUrl.trim().isNotEmpty && supabasePublishableKey.trim().isNotEmpty;

  /// 원시 설정값의 존재 여부다. 모든 호출자(빌더, 파서, UI 정책)가 하나의
  /// 표준 검증기를 공유하도록 URI/스킴/호스트 검증은 `invite_link.dart`에 둔다.
  bool get hasInviteBaseUrl => inviteBaseUrl.trim().isNotEmpty;

  /// 설정된 출처를 개발/테스트 빌드의 공유 링크에 사용할 수 있는지 나타낸다.
  /// 프로덕션 호출자는 HTTPS를 강제하도록 `isRelease: true`와 함께
  /// [inviteLinksEnabledFor]를 사용해야 한다.
  bool get inviteLinksEnabled => validateInviteBaseUrl(inviteBaseUrl).isValid;

  String? get inviteLinkConfigurationError =>
      validateInviteBaseUrl(inviteBaseUrl).message;

  bool inviteLinksEnabledFor({
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) => validateInviteBaseUrl(
    inviteBaseUrl,
    isRelease: isRelease,
    allowLocalhostHttp: allowLocalhostHttp,
  ).isValid;

  String? inviteLinkConfigurationErrorFor({
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) => validateInviteBaseUrl(
    inviteBaseUrl,
    isRelease: isRelease,
    allowLocalhostHttp: allowLocalhostHttp,
  ).message;

  /// 사용할 수 있는 공개 Supabase 설정이 없는 릴리스 빌드에서 안전하고
  /// 조치 가능한 메시지를 반환한다. 비밀 값은 절대 포함하지 않는다.
  String? get missingConfigurationMessage {
    final missing = <String>[];
    if (supabaseUrl.trim().isEmpty) missing.add('SUPABASE_URL');
    if (supabasePublishableKey.trim().isEmpty) {
      missing.add('SUPABASE_PUBLISHABLE_KEY');
    }
    if (missing.isEmpty) return null;
    return '서비스 설정이 완료되지 않았습니다. ${missing.join(' 및 ')}를 '
        '설정한 뒤 앱을 다시 빌드해 주세요.';
  }
}

/// [kReleaseMode]와 분리한 순수 런타임 정책이므로 릴리스와 미리보기 입력을
/// 모두 테스트할 수 있다. 디버그/프로필 빌드는 Supabase 값이 없을 때
/// 의도적으로 로컬 데모를 허용한다.
class AppConfigPolicy {
  const AppConfigPolicy._();

  static String? releaseConfigurationError(
    AppConfig config, {
    required bool isRelease,
  }) {
    if (!isRelease) return null;
    return config.missingConfigurationMessage;
  }
}

/// 릴리스 빌드가 메모리 기반 데모 저장소를 사용하지 못하도록 차단될 때
/// 데이터 제공자가 발생시키는 오류다.
class RuntimeConfigurationException implements Exception {
  const RuntimeConfigurationException(this.message);

  final String message;

  @override
  String toString() => message;
}
