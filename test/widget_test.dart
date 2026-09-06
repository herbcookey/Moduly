// 기본 Flutter 위젯 테스트다.
//
// 테스트에서 위젯과 상호작용하려면 flutter_test 패키지의 WidgetTester
// 유틸리티를 사용한다. 예를 들어 탭과 스크롤 동작을 보내거나, 위젯 트리에서
// 자식 위젯을 찾고 텍스트를 읽으며 위젯 속성 값이 올바른지 확인할 수 있다.

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:moduly/app.dart';

void main() {
  testWidgets('로그인 화면을 렌더링한다', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    expect(find.text('로그인'), findsOneWidget);
    expect(find.text('새 계정 만들기'), findsOneWidget);
  });
}
