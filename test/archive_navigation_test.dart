import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:moduly/app.dart';
import 'package:moduly/screens/group_picker_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/screens/members_screen.dart';

void main() {
  testWidgets('그룹 보관 완료 후 그룹 선택 화면으로 안전하게 이동한다', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ModulyApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('데모 값 채우기'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('우리 가족'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.tap(find.text('멤버').last);
    await tester.pumpAndSettle();
    expect(find.byType(MembersScreen), findsOneWidget);

    await tester.tap(find.text('그룹 보관'));
    await tester.pumpAndSettle();
    expect(find.text('그룹을 보관할까요?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '우리 가족');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '그룹 보관'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupPickerScreen), findsOneWidget);
    expect(find.text('아직 그룹이 없어요'), findsOneWidget);
    expect(find.byType(MembersScreen), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
