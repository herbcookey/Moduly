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
  Future<AccountDeletionImpact> preflight() async {
    return AccountDeletionImpact.empty;
  }

  @override
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) async {
    calls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final error = failure;
    if (error != null) throw error;
    return const AccountDeletionResult(
      deleted: true,
      summary: AccountDeletionImpact.empty,
    );
  }

  @override
  Future<AccountDeletionResult> deleteAccount({required String confirmation}) =>
      deleteAccountWithResult(confirmation: confirmation);
}

class _LegacyVoidAccountDeletionRepository extends AccountDeletionRepository {
  @override
  bool get isRemote => true;

  @override
  Future<void> deleteAccount({required String confirmation}) async {}
}

class _TypedAccountDeletionRepository extends AccountDeletionRepository {
  _TypedAccountDeletionRepository({
    required this.impact,
    this.result = const AccountDeletionResult(
      deleted: true,
      summary: AccountDeletionImpact.empty,
    ),
    this.resultFailure,
  });

  final AccountDeletionImpact impact;
  final AccountDeletionResult result;
  final Object? resultFailure;
  int calls = 0;

  @override
  bool get isRemote => true;

  @override
  Future<AccountDeletionImpact> preflight() async {
    return impact;
  }

  @override
  Future<AccountDeletionResult> deleteAccountWithResult({
    required String confirmation,
  }) async {
    calls += 1;
    final error = resultFailure;
    if (error != null) throw error;
    return result;
  }

  @override
  Future<AccountDeletionResult> deleteAccount({required String confirmation}) =>
      deleteAccountWithResult(confirmation: confirmation);
}

AccountDeletionGroupImpact _group({
  required String id,
  required String status,
  DateTime? deletedAt,
  int memberCount = 1,
  int membershipCount = 1,
}) {
  return AccountDeletionGroupImpact(
    id: id,
    name: id,
    timezone: 'Asia/Seoul',
    version: 1,
    status: status,
    memberCount: memberCount,
    membershipCount: membershipCount,
    deletedAt: deletedAt,
  );
}

Map<String, Object?> _impactJson({
  List<Map<String, Object?>>? owned,
  List<Map<String, Object?>>? active,
  List<Map<String, Object?>>? archived,
  int? groups,
}) {
  return <String, Object?>{
    'owned_groups': owned ?? <Map<String, Object?>>[],
    'active_owned_groups': active ?? <Map<String, Object?>>[],
    'archived_owned_groups': archived ?? <Map<String, Object?>>[],
    'groups': groups ?? (owned?.length ?? 0),
    'events': 0,
    'invites': 0,
    'memberships': 0,
  };
}

void main() {
  test(
    'local deletion is capability blocked and never reports success',
    () async {
      final repository = LocalAccountDeletionRepository();

      expect(
        repository.deleteAccount(confirmation: '삭제'),
        throwsA(isA<AccountDeletionCapabilityException>()),
      );
      expect(
        repository.deleteAccount(confirmation: accountDeletionConfirmation),
        throwsA(isA<AccountDeletionCapabilityException>()),
      );

      expect(repository.deleted, isFalse);
    },
  );

  test(
    'legacy void result fails closed instead of fabricating success',
    () async {
      await expectLater(
        _LegacyVoidAccountDeletionRepository().deleteAccountWithResult(
          confirmation: accountDeletionConfirmation,
        ),
        throwsA(isA<AccountDeletionCapabilityException>()),
      );
    },
  );

  test('impact parser validates owned partitions and lifecycle markers', () {
    final archivedAt = DateTime.utc(2026, 1, 1);
    final active = <String, Object?>{
      'id': 'active',
      'name': '활성',
      'timezone': 'Asia/Seoul',
      'version': 2,
      'status': 'active',
      'deleted_at': null,
      'member_count': 1,
      'membership_count': 2,
    };
    final archived = <String, Object?>{
      'id': 'archived',
      'name': '보관',
      'timezone': 'Asia/Seoul',
      'version': 3,
      'status': 'archived',
      'deleted_at': archivedAt.toIso8601String(),
      'member_count': 0,
      'membership_count': 2,
    };
    final parsed = AccountDeletionImpact.fromJson(
      _impactJson(
        owned: <Map<String, Object?>>[active, archived],
        active: <Map<String, Object?>>[active],
        archived: <Map<String, Object?>>[archived],
      ),
    );
    expect(parsed.groups, 2);
    expect(parsed.activeOwnedGroups.single.id, 'active');
    expect(parsed.archivedOwnedGroups.single.isArchived, isTrue);

    void expectMalformed(Map<String, Object?> payload) {
      expect(
        () => AccountDeletionImpact.fromJson(payload),
        throwsA(isA<AccountDeletionException>()),
      );
    }

    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[active, active],
        active: <Map<String, Object?>>[active],
        groups: 2,
      ),
    );
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[active],
        active: <Map<String, Object?>>[active],
        archived: <Map<String, Object?>>[active],
      ),
    );
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[active, archived],
        active: <Map<String, Object?>>[active],
        archived: <Map<String, Object?>>[],
      ),
    );
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[active],
        active: <Map<String, Object?>>[
          <String, Object?>{
            ...active,
            'deleted_at': archivedAt.toIso8601String(),
          },
        ],
      ),
    );
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[archived],
        archived: <Map<String, Object?>>[
          <String, Object?>{...archived, 'deleted_at': null},
        ],
      ),
    );
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[
          <String, Object?>{
            ...active,
            'member_count': 3,
            'membership_count': 1,
          },
        ],
        active: <Map<String, Object?>>[
          <String, Object?>{
            ...active,
            'member_count': 3,
            'membership_count': 1,
          },
        ],
      ),
    );
    // Partition rows must match the owned canonical record on every field,
    // not just id/status.  A stale projection must fail closed before the
    // destructive confirmation step.
    for (final mismatch in <String, Object?>{
      'name': 'renamed elsewhere',
      'timezone': 'UTC',
      'version': 99,
      'member_count': 0,
      'membership_count': 3,
    }.entries) {
      expectMalformed(
        _impactJson(
          owned: <Map<String, Object?>>[active],
          active: <Map<String, Object?>>[
            <String, Object?>{...active, mismatch.key: mismatch.value},
          ],
        ),
      );
    }
    expectMalformed(
      _impactJson(
        owned: <Map<String, Object?>>[archived],
        archived: <Map<String, Object?>>[
          <String, Object?>{
            ...archived,
            'deleted_at': archivedAt
                .add(const Duration(seconds: 1))
                .toIso8601String(),
          },
        ],
      ),
    );
  });

  testWidgets(
    'capability-blocked repositories disable deletion with clear guidance',
    (tester) async {
      final repository = ConfigurationBlockedAccountDeletionRepository(
        'raw configuration detail must stay hidden',
      );
      await tester.pumpWidget(
        MaterialApp(home: AccountDeletionScreen(repository: repository)),
      );
      await tester.pumpAndSettle();

      expect(find.text('계정 삭제는 연결된 서버에서만 사용할 수 있어요.'), findsOneWidget);
      expect(
        find.text('raw configuration detail must stay hidden'),
        findsNothing,
      );
      final deleteButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '계정 영구 삭제'),
      );
      expect(deleteButton.onPressed, isNull);
    },
  );

  testWidgets(
    'typed preflight renders active/archived impact and result summary',
    (tester) async {
      final archivedAt = DateTime.utc(2026, 1, 1);
      final active = _group(id: 'active', status: 'active', memberCount: 2);
      final archived = _group(
        id: 'archived',
        status: 'archived',
        deletedAt: archivedAt,
        memberCount: 0,
      );
      final impact = AccountDeletionImpact(
        ownedGroups: <AccountDeletionGroupImpact>[active, archived],
        activeOwnedGroups: <AccountDeletionGroupImpact>[active],
        archivedOwnedGroups: <AccountDeletionGroupImpact>[archived],
        groups: 2,
        events: 4,
        invites: 3,
        memberships: 5,
      );
      final repository = _TypedAccountDeletionRepository(
        impact: impact,
        result: AccountDeletionResult(deleted: true, summary: impact),
      );
      await tester.pumpWidget(
        MaterialApp(home: AccountDeletionScreen(repository: repository)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('active'), findsOneWidget);
      expect(find.text('보관된 소유 그룹 1개도 함께 삭제됩니다.'), findsOneWidget);
      expect(find.text('그룹 2개 · 일정 4개 · 초대 코드 3개 · 멤버십 5개'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        accountDeletionConfirmation,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
      await tester.pumpAndSettle();

      expect(repository.calls, 1);
      expect(find.text('계정이 삭제되었습니다. 안전하게 로그아웃했어요.'), findsOneWidget);
      expect(find.text('연결된 데이터 2개 그룹도 모두 삭제했어요.'), findsOneWidget);
    },
  );

  testWidgets('malformed typed result is rejected without provider details', (
    tester,
  ) async {
    final repository = _TypedAccountDeletionRepository(
      impact: AccountDeletionImpact.empty,
      resultFailure: const AccountDeletionException(
        'provider-secret',
        code: AccountDeletionErrorCode.protocol,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: AccountDeletionScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), accountDeletionConfirmation);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
    await tester.pumpAndSettle();

    expect(find.text('provider-secret'), findsNothing);
    expect(find.text('서버 응답을 확인하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.text('계정이 삭제되었습니다. 안전하게 로그아웃했어요.'), findsNothing);
  });

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
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
      await tester.pump();
      expect(find.text('확인 문구를 정확히 입력해 주세요.'), findsOneWidget);
      expect(repository.calls, 0);

      await tester.enterText(
        find.byType(TextField),
        accountDeletionConfirmation,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
      await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '계정 영구 삭제'));
    await tester.pumpAndSettle();

    expect(find.text('provider-internal-secret'), findsNothing);
    expect(find.text('계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });
}
