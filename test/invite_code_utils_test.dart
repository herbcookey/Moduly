import 'package:flutter_test/flutter_test.dart';
import 'package:moduly/core/invite_code_utils.dart';

void main() {
  test('formats a short invite code in readable groups', () {
    expect(formatInviteCode('7k9mw3pxq2rt'), '7K9M-W3PX-Q2RT');
  });

  test('normalizes separators and case for new invite codes', () {
    expect(normalizeInviteCode(' 7k9m-w3px q2rt '), '7K9MW3PXQ2RT');
  });

  test('keeps legacy hexadecimal invite codes compatible', () {
    const legacy = 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789';
    expect(normalizeInviteCode(legacy), legacy.toLowerCase());
    expect(formatInviteCode(legacy), legacy);
  });
}
