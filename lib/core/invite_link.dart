import 'package:flutter/foundation.dart';

import 'config/app_config.dart';
import 'invite_code_utils.dart';

/// 앱이 인식하는 두 링크 유형이다. 웹 링크는 항상 설정된 앱 출처에서 만들고,
/// 사용자 정의 네이티브 스킴은 `invite` 호스트에만 허용한다.
enum InviteLinkSource { web, native }

final RegExp _invalidUriCharacterPattern = RegExp(r'[\s\u0000-\u001f\u007f]');

/// 의도적으로 일반화한 파서 오류다. 전달자 토큰을 예외, 로그, 분석 이벤트,
/// URL 쿼리에 절대 되풀이해서는 안 된다.
class InviteLinkFormatException implements Exception {
  const InviteLinkFormatException([this.message = '초대 링크를 확인해 주세요.']);

  final String message;

  @override
  String toString() => message;
}

/// 공유 링크 호출자가 사용하는 설정 오류다. 파서도 같은 검증 결과를 사용하지만
/// 토큰이 없는 고정 메시지만 노출한다.
class InviteLinkConfigurationException implements Exception {
  const InviteLinkConfigurationException([
    this.message = '초대 링크 주소 설정을 확인해 주세요.',
  ]);

  final String message;

  @override
  String toString() => message;
}

@immutable
class ParsedInviteLink {
  const ParsedInviteLink({required this.token, required this.source});

  /// 표준 단축 코드(대문자) 또는 레거시 토큰(소문자)이다. 원시 URI와 모든 표시
  /// 형식은 의도적으로 보관하지 않는다.
  final String token;
  final InviteLinkSource source;

  @override
  bool operator ==(Object other) =>
      other is ParsedInviteLink &&
      other.token == token &&
      other.source == source;

  @override
  int get hashCode => Object.hash(token, source);
}

@immutable
class InviteBaseUrlValidation {
  const InviteBaseUrlValidation._({required this.uri, required this.message});

  const InviteBaseUrlValidation.valid(Uri uri)
    : this._(uri: uri, message: null);

  const InviteBaseUrlValidation.invalid(String message)
    : this._(uri: null, message: message);

  final Uri? uri;
  final String? message;
  bool get isValid => uri != null;
}

/// 초대 링크에 사용할 앱 출처를 검증하고 표준화한다.
///
/// 릴리스 빌드는 반드시 HTTPS를 사용해야 한다. 테스트/디버그 빌드는 루프백
/// 호스트에 한해서만 HTTP를 선택할 수 있으며, 임의의 평문 출처는 계속 금지한다.
InviteBaseUrlValidation validateInviteBaseUrl(
  String raw, {
  // 빌드 모드가 안전한 기본값이다. 테스트에서는 호출자가 정책을 주입할 수 있지만,
  // 프로덕션 호출자가 이 인수를 생략해 디버그의 로컬호스트 HTTP 허용 정책을
  // 실수로 물려받을 수는 없다.
  bool isRelease = kReleaseMode,
  bool allowLocalhostHttp = true,
}) {
  final value = raw.trim();
  if (value.isEmpty ||
      value != raw ||
      value.contains('%') ||
      value.contains(_invalidUriCharacterPattern)) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  Uri uri;
  try {
    uri = Uri.parse(value);
  } catch (_) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final isLoopback =
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
  final https = scheme == 'https';
  final localHttp =
      scheme == 'http' && allowLocalhostHttp && !isRelease && isLoopback;
  if ((!https && !localHttp) || host.isEmpty || uri.userInfo.isNotEmpty) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  if (uri.hasQuery || uri.hasFragment || uri.path.contains('%')) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  // 웹 하위 경로에 배포할 수 있도록 기본 경로를 지원하지만, 빌더와 파서가 정확히
  // 일치하도록 기본 경로 자체도 표준 형식이어야 한다.
  if (uri.pathSegments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains(RegExp(r'[\s\u0000-\u001f\u007f]')),
  )) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  final canonicalPath = uri.path == '/'
      ? ''
      : uri.path.replaceFirst(RegExp(r'/+$'), '');
  final canonical = Uri(
    scheme: scheme,
    userInfo: '',
    host: host,
    port: uri.hasPort ? uri.port : null,
    path: canonicalPath,
  );
  // 빌더와 파서의 왕복 변환 결과를 바이트 단위까지 예측 가능하게 유지한다.
  // 비 ASCII 경로는 [Uri]에서 퍼센트 인코딩되고, 입력 시 인코딩된 경로
  // 조각으로 간주되어 거부된다.
  if (canonical.toString().contains('%')) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  return InviteBaseUrlValidation.valid(canonical);
}

/// 전달자 초대 링크용 엄격한 파서/빌더다.
class InviteLinkParser {
  const InviteLinkParser._();

  static ParsedInviteLink? tryParse(
    Uri uri, {
    required AppConfig config,
    Uri? currentOrigin,
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) {
    try {
      if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
        return null;
      }
      final rawUri = uri.toString();
      if (rawUri.contains('%') ||
          rawUri.contains(_invalidUriCharacterPattern) ||
          uri.path.contains(_invalidUriCharacterPattern)) {
        return null;
      }
      if (uri.scheme.toLowerCase() == 'moduly') {
        if (uri.host.toLowerCase() != 'invite' || uri.hasPort) return null;
        if (uri.path.isEmpty || !uri.path.startsWith('/')) return null;
        if (uri.path.endsWith('/') || uri.pathSegments.length != 1) {
          return null;
        }
        final token = normalizeStrictInviteToken(uri.pathSegments.single);
        if (token == null) return null;
        return ParsedInviteLink(token: token, source: InviteLinkSource.native);
      }
      final baseValidation = validateInviteBaseUrl(
        config.inviteBaseUrl,
        isRelease: isRelease,
        allowLocalhostHttp: allowLocalhostHttp,
      );
      final base = baseValidation.uri;
      if (base == null || uri.scheme.toLowerCase() != base.scheme) return null;
      if (uri.host.toLowerCase() != base.host.toLowerCase() ||
          uri.port != base.port ||
          uri.userInfo.isNotEmpty) {
        return null;
      }
      final baseSegments = base.pathSegments;
      final pathSegments = uri.pathSegments;
      if (uri.path.endsWith('/') ||
          pathSegments.length != baseSegments.length + 2 ||
          !listEquals(
            pathSegments.take(baseSegments.length).toList(),
            baseSegments,
          ) ||
          pathSegments[baseSegments.length] != 'invite') {
        return null;
      }
      final token = normalizeStrictInviteToken(pathSegments.last);
      if (token == null) return null;
      // [currentOrigin]은 의도적으로 참고만 한다. 값이 제공되더라도 설정된 것과
      // 동일한 출처로 해석되어야 하며 허용 범위를 넓혀서는 안 된다.
      if (currentOrigin != null &&
          (currentOrigin.scheme.toLowerCase() != base.scheme ||
              currentOrigin.host.toLowerCase() != base.host.toLowerCase() ||
              currentOrigin.port != base.port)) {
        return null;
      }
      return ParsedInviteLink(token: token, source: InviteLinkSource.web);
    } catch (_) {
      return null;
    }
  }

  static ParsedInviteLink parse(
    Uri uri, {
    required AppConfig config,
    Uri? currentOrigin,
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) {
    final parsed = tryParse(
      uri,
      config: config,
      currentOrigin: currentOrigin,
      isRelease: isRelease,
      allowLocalhostHttp: allowLocalhostHttp,
    );
    if (parsed == null) throw const InviteLinkFormatException();
    return parsed;
  }

  static Uri? build(
    String token, {
    required AppConfig config,
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) {
    final normalized = normalizeStrictInviteToken(token);
    if (normalized == null) return null;
    final validation = validateInviteBaseUrl(
      config.inviteBaseUrl,
      isRelease: isRelease,
      allowLocalhostHttp: allowLocalhostHttp,
    );
    final base = validation.uri;
    if (base == null) return null;
    final path = [...base.pathSegments, 'invite', normalized].join('/');
    return Uri(
      scheme: base.scheme,
      userInfo: '',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/$path',
    );
  }
}

/// 최상위 별칭을 제공하여 호출자가 파서 인스턴스를 보관하지 않아도 테스트와
/// 플랫폼 입력 코드에서 순수 파서를 편리하게 사용할 수 있게 한다.
ParsedInviteLink? tryParseInviteLink(
  Uri uri, {
  required AppConfig config,
  Uri? currentOrigin,
  required bool isRelease,
  bool allowLocalhostHttp = true,
}) => InviteLinkParser.tryParse(
  uri,
  config: config,
  currentOrigin: currentOrigin,
  isRelease: isRelease,
  allowLocalhostHttp: allowLocalhostHttp,
);

ParsedInviteLink parseInviteLink(
  Uri uri, {
  required AppConfig config,
  Uri? currentOrigin,
  required bool isRelease,
  bool allowLocalhostHttp = true,
}) => InviteLinkParser.parse(
  uri,
  config: config,
  currentOrigin: currentOrigin,
  isRelease: isRelease,
  allowLocalhostHttp: allowLocalhostHttp,
);

Uri? buildInviteLink(
  String token, {
  required AppConfig config,
  required bool isRelease,
  bool allowLocalhostHttp = true,
}) => InviteLinkParser.build(
  token,
  config: config,
  isRelease: isRelease,
  allowLocalhostHttp: allowLocalhostHttp,
);
