import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/repositories/account_deletion_repository.dart';
import 'package:moduly/screens/account_deletion_screen.dart';

class _FakeAccountDeletionRepository extends AccountDeletionRepository {
  _FakeAccountDeletionRepository({this.failure});

  final Object? failure;
  int calls = 0;

  @override
  bool get isRemote => true;

  @override
  Future<void> deleteAccount({required String confirmation}) async {
    calls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final error = failure;
    if (error != null) throw error;
  }
}

void main() {
  test(
    'local deletion requires the exact confirmation and is idempotent',
    () async {
      final repository = LocalAccountDeletionRepository();

      expect(
        repository.deleteAccount(confirmation: '삭제'),
        throwsA(isA<AccountDeletionException>()),
      );
      await repository.deleteAccount(confirmation: accountDeletionConfirmation);
      await repository.deleteAccount(confirmation: accountDeletionConfirmation);

      expect(repository.deleted, isTrue);
    },
  );

  testWidgets(
    'confirmation prevents accidental deletion and duplicate submit',
    (tester) async {
      final repository = _FakeAccountDeletionRepository();
      var deletedCallbacks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountDeletionScreen(
            repository: repository,
            onDeleted: () async => deletedCallbacks += 1,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '삭제');
      await tester.tap(find.text('계정 영구 삭제'));
      await tester.pump();
      expect(find.text('확인 문구를 정확히 입력해 주세요.'), findsOneWidget);
      expect(repository.calls, 0);

      await tester.enterText(
        find.byType(TextField),
        accountDeletionConfirmation,
      );
      await tester.tap(find.text('계정 영구 삭제'));
      await tester.tap(find.text('계정 영구 삭제'));
      await tester.pumpAndSettle();

      expect(repository.calls, 1);
      expect(deletedCallbacks, 1);
      expect(find.text('계정이 삭제되었습니다. 안전하게 로그아웃했어요.'), findsOneWidget);
    },
  );

  testWidgets('server errors are shown without exposing provider details', (
    tester,
  ) async {
    final repository = _FakeAccountDeletionRepository(
      failure: const AccountDeletionException('provider-internal-secret'),
    );
    await tester.pumpWidget(
      MaterialApp(home: AccountDeletionScreen(repository: repository)),
    );
    await tester.enterText(find.byType(TextField), accountDeletionConfirmation);
    await tester.tap(find.text('계정 영구 삭제'));
    await tester.pumpAndSettle();

    expect(find.text('provider-internal-secret'), findsNothing);
    expect(find.text('계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });
}
