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

  /// Public origin used when constructing shareable invite links.  This is
  /// deliberately independent from [supabaseUrl]: a Supabase project URL is
  /// an API endpoint, not an application/deep-link origin.  The value is
  /// supplied with `--dart-define=INVITE_BASE_URL=...` and may be omitted in
  /// local/demo builds.
  final String inviteBaseUrl;

  factory AppConfig.fromEnvironment() => const AppConfig(
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    inviteBaseUrl: String.fromEnvironment('INVITE_BASE_URL'),
  );

  bool get hasSupabase =>
      supabaseUrl.trim().isNotEmpty && supabasePublishableKey.trim().isNotEmpty;

  /// Raw configuration presence.  URI/scheme/host validation is kept in
  /// `invite_link.dart` so all callers (builder, parser, and UI policy) share
  /// exactly one canonical validator.
  bool get hasInviteBaseUrl => inviteBaseUrl.trim().isNotEmpty;

  /// Whether the configured origin can be used for share links in a
  /// development/test build.  Production callers should use
  /// [inviteLinksEnabledFor] with `isRelease: true` to enforce HTTPS.
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
