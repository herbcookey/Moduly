const String inviteCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const int inviteCodeLength = 12;
const int legacyInviteCodeLength = 48;

final RegExp _shortInviteCodePattern = RegExp(
  '^[${RegExp.escape(inviteCodeAlphabet)}]{$inviteCodeLength}'
  r'$',
);
final RegExp _legacyInviteCodePattern = RegExp(r'^[0-9a-fA-F]{48}$');

/// Returns the canonical bearer-token form accepted by invite links.
///
/// Manual code entry remains intentionally more permissive through
/// [normalizeInviteCode], which strips display separators.  Link parsing must
/// call this strict helper instead so a path can never contain hidden
/// separators, whitespace, or an unsupported token shape.
String? normalizeStrictInviteToken(String value) {
  if (value.isEmpty || value.trim() != value) return null;
  if (value.contains(RegExp(r'[\s\u0000-\u001f\u007f]'))) return null;
  final upper = value.toUpperCase();
  if (_shortInviteCodePattern.hasMatch(upper)) return upper;
  if (_legacyInviteCodePattern.hasMatch(value)) return value.toLowerCase();
  return null;
}

bool isStrictInviteToken(String value) =>
    normalizeStrictInviteToken(value) != null;

/// 사용자 입력을 서버로 보낼 토큰으로 변환한다.
///
/// 구분자는 표시용일 뿐이다. 짧은 코드 도입 전에 발급된 48자리 16진수
/// 토큰도 유효하도록 소문자로 변환한다.
String normalizeInviteCode(String value) {
  final compact = value.trim().replaceAll(RegExp(r'[\s-]+'), '');
  if (RegExp(r'^[0-9a-fA-F]{48}$').hasMatch(compact)) {
    return compact.toLowerCase();
  }
  return compact.toUpperCase();
}

/// 새 짧은 토큰의 값을 바꾸지 않고 읽기 쉽도록 묶어 표시한다.
String formatInviteCode(String value) {
  final normalized = normalizeInviteCode(value);
  final isShortCode =
      normalized.length == inviteCodeLength &&
      normalized.split('').every(inviteCodeAlphabet.contains);
  if (!isShortCode) return value;
  return <String>[
    normalized.substring(0, 4),
    normalized.substring(4, 8),
    normalized.substring(8, 12),
  ].join('-');
}
