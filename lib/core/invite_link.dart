import 'package:flutter/foundation.dart';

import 'config/app_config.dart';
import 'invite_code_utils.dart';

/// The two link families understood by the app.  A web link is always built
/// from the configured application origin; the custom native scheme is only
/// accepted for the `invite` host.
enum InviteLinkSource { web, native }

final RegExp _invalidUriCharacterPattern = RegExp(r'[\s\u0000-\u001f\u007f]');

/// Deliberately generic parser error.  A bearer token must never be echoed in
/// an exception, log, analytics event, or URL query.
class InviteLinkFormatException implements Exception {
  const InviteLinkFormatException([this.message = '초대 링크를 확인해 주세요.']);

  final String message;

  @override
  String toString() => message;
}

/// Configuration error used by share-link callers.  The parser uses the same
/// validation result but exposes only a stable, token-free message.
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

  /// Canonical short-code (uppercase) or legacy token (lowercase).  The raw
  /// URI and any display form are intentionally not retained.
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

/// Validates and canonicalizes an application origin used for invite links.
///
/// Release builds are required to use HTTPS.  Tests/debug builds may opt into
/// HTTP only for loopback hosts; arbitrary plaintext origins remain disabled.
InviteBaseUrlValidation validateInviteBaseUrl(
  String raw, {
  // The build mode is the safe default. Callers can still inject a policy in
  // tests, but a production caller cannot accidentally inherit debug's
  // localhost-HTTP allowance by omitting this argument.
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
  // A base path is supported for deployments below a web sub-path, but it
  // must itself be canonical so builder/parser matching remains exact.
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
  // Keep builder/parser round-tripping byte-for-byte predictable.  A
  // non-ASCII path would be percent-encoded by [Uri] and subsequently be
  // rejected as an encoded path segment at intake.
  if (canonical.toString().contains('%')) {
    return const InviteBaseUrlValidation.invalid('초대 링크 주소 설정을 확인해 주세요.');
  }
  return InviteBaseUrlValidation.valid(canonical);
}

/// Strict parser/builder for bearer invite links.
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
      // [currentOrigin] is intentionally advisory: when supplied, it must
      // still resolve to the same configured origin, never broaden it.
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

/// Top-level aliases make the pure parser convenient for tests and platform
/// intake code without requiring callers to retain a parser instance.
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
