import 'package:flutter_test/flutter_test.dart';
import 'package:moduly/core/invite_code_utils.dart';

void main() {
  test('짧은 초대 코드를 읽기 쉬운 묶음으로 표시한다', () {
    expect(formatInviteCode('7k9mw3pxq2rt'), '7K9M-W3PX-Q2RT');
  });

  test('새 초대 코드의 구분자와 대소문자를 정규화한다', () {
    expect(normalizeInviteCode(' 7k9m-w3px q2rt '), '7K9MW3PXQ2RT');
  });

  test('기존 16진수 초대 코드와의 호환성을 유지한다', () {
    const legacy = 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789';
    expect(normalizeInviteCode(legacy), legacy.toLowerCase());
    expect(formatInviteCode(legacy), legacy);
  });
}
