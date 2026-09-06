import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/app.dart';
import 'package:moduly/screens/auth_screens.dart';

void main() {
  testWidgets('privacy policy and terms are reachable while signed out', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(LoginScreen)));
    expect(find.text('개인정보처리방침'), findsOneWidget);
    expect(find.text('이용약관'), findsOneWidget);

    router.go('/privacy-policy');
    await tester.pumpAndSettle();
    expect(find.text('개인정보처리방침'), findsWidgets);
    expect(find.textContaining('법률 자문이 아닙니다'), findsWidgets);

    router.go('/terms-of-service');
    await tester.pumpAndSettle();
    expect(find.text('이용약관'), findsWidgets);
    expect(find.textContaining('법률 자문이 아닙니다'), findsWidgets);
  });

  testWidgets('settings exposes the same legal document links', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('개인정보처리방침'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('개인정보처리방침'), findsOneWidget);
    expect(find.text('이용약관'), findsOneWidget);
  });
}
