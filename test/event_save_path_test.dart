import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/state/app_state.dart';

const _user = PlannerUser(id: 'user-1', email: 'user@example.com');
const _group = PlannerGroup(
  id: 'group-1',
  name: 'Group',
  timezone: 'America/Los_Angeles',
);

class _CurrentAuth extends AuthRepository {
  _CurrentAuth({this._currentUser = _user}) : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();
  final PlannerUser? _currentUser;

  @override
  PlannerUser? get currentUser => _currentUser;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _SilentCreateRepository extends LocalScheduleRepository {
  PlannerEvent? created;
  PlannerEvent? updated;

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    created = PlannerEvent(
      id: 'created-1',
      groupId: groupId,
      title: draft.title,
      startAt: draft.startAt,
      endAt: draft.endAt,
      ownerId: userId,
      timezone: draft.timezone,
      allDay: draft.allDay,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
    );
    // 실시간 전달이 지연되거나 사용할 수 없는 상황에서 성공한 삽입을
    // 재현한다. 컨트롤러는 이때도 반환된 일정을 노출해야 한다.
    return created!;
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    updated = event.copyWith(version: expectedVersion + 1);
    return updated!;
  }
}

class _MemberFailureRepository extends LocalScheduleRepository {
  bool watchStarted = false;

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) {
    return Future<List<PlannerMember>>.error(
      StateError('profiles lookup failed'),
    );
  }

  @override
  Stream<List<PlannerEvent>> watchEvents(String groupId) {
    watchStarted = true;
    return Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);
  }
}

void main() {
  test(
    'saveEvent reports a missing group instead of silently succeeding',
    () async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        controller.saveEvent(
          draft: EventDraft(
            title: 'Not saved',
            startAt: DateTime.utc(2026, 8, 14, 16),
            endAt: DateTime.utc(2026, 8, 14, 17),
          ),
        ),
        throwsA(
          isA<ScheduleValidationException>().having(
            (error) => error.message,
            'message',
            '일정을 저장하려면 로그인하고 그룹을 선택해 주세요.',
          ),
        ),
      );
      expect(repository.created, isNull);
      expect(controller.errorMessage, '일정을 저장하려면 로그인하고 그룹을 선택해 주세요.');
      expect(controller.isSaving, isFalse);
    },
  );

  test(
    'saveEvent upserts the create result before realtime delivery',
    () async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth();
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      controller.user = _user;
      controller.selectedGroup = _group;

      await controller.saveEvent(
        draft: EventDraft(
          title: 'Created remotely',
          startAt: DateTime.utc(2026, 8, 14, 16),
          endAt: DateTime.utc(2026, 8, 14, 17),
        ),
      );

      expect(repository.created, isNotNull);
      expect(
        controller.events.map((event) => event.id),
        contains(repository.created!.id),
      );
    },
  );

  test('saveEvent upserts the versioned update result', () async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    controller.user = _user;
    controller.selectedGroup = _group;
    final existing = PlannerEvent(
      id: 'event-1',
      groupId: _group.id,
      title: 'Before',
      startAt: DateTime.utc(2026, 8, 14, 16),
      endAt: DateTime.utc(2026, 8, 14, 17),
      ownerId: _user.id,
      version: 4,
      timezone: _group.timezone,
    );
    controller.events = <PlannerEvent>[existing];

    await controller.saveEvent(
      existing: existing,
      draft: EventDraft(
        title: 'After',
        startAt: DateTime.utc(2026, 8, 15, 16),
        endAt: DateTime.utc(2026, 8, 15, 17),
        timezone: _group.timezone,
      ),
    );

    expect(repository.updated?.title, 'After');
    expect(repository.updated?.version, 5);
    expect(controller.events.single.title, 'After');
    expect(controller.events.single.version, 5);
  });

  test('selectGroup starts events when member metadata fails', () async {
    final repository = _MemberFailureRepository();
    final auth = _CurrentAuth();
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    controller.user = _user;
    controller.groups = const <PlannerGroup>[_group];

    await controller.selectGroup(_group.id);
    await Future<void>.delayed(Duration.zero);

    expect(repository.watchStarted, isTrue);
    expect(controller.isOffline, isFalse);
    expect(controller.selectedGroup?.id, _group.id);
    expect(controller.errorMessage, '잠시 후 다시 시도해 주세요.');
  });

  testWidgets('editor renders a save error and stays on the form', (
    tester,
  ) async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    // Inject the controller directly so this widget test exercises the form
    // without depending on provider-created bootstrap timing.
    controller.user = _user;
    controller.isLoading = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: EventEditorScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextFormField).first, 'Not saved');
    final saveButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '저장'),
    );
    saveButton.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();

    expect(find.text('일정을 저장하려면 로그인하고 그룹을 선택해 주세요.'), findsOneWidget);
    expect(find.text('새 일정'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'editor round-trips legacy all-day dates without extending the end date',
    (tester) async {
      final repository = _SilentCreateRepository();
      final auth = _CurrentAuth(currentUser: null);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(auth.dispose);
      controller.user = _user;
      controller.selectedGroup = _group;
      final existing = PlannerEvent(
        id: 'legacy-all-day',
        groupId: _group.id,
        title: 'Legacy all-day',
        startAt: DateTime.utc(2026, 8, 10),
        endAt: DateTime.utc(2026, 8, 13),
        allDay: true,
        ownerId: _user.id,
        timezone: 'UTC',
      );
      controller.events = <PlannerEvent>[existing];

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: EventEditorScreen(eventId: 'legacy-all-day'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final updated = repository.updated;
      expect(updated, isNotNull);
      expect(updated!.allDay, isTrue);
      expect(updated.startAt, existing.startAt);
      expect(updated.endAt, existing.endAt);
      expect(updated.allDayStartDate, DateTime(2026, 8, 10));
      expect(updated.allDayEndDate, DateTime(2026, 8, 13));
    },
  );

  testWidgets('editor preserves all existing event member assignments', (
    tester,
  ) async {
    final repository = _SilentCreateRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    controller.user = _user;
    controller.selectedGroup = _group;
    final existing = PlannerEvent(
      id: 'multi-member-event',
      groupId: _group.id,
      title: 'Shared event',
      startAt: DateTime.utc(2026, 8, 10, 16),
      endAt: DateTime.utc(2026, 8, 10, 17),
      ownerId: _user.id,
      memberIds: const <String>['user-1', 'member-a', 'member-b'],
      timezone: 'UTC',
    );
    controller.events = <PlannerEvent>[existing];

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: EventEditorScreen(eventId: 'multi-member-event'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.updated?.memberIds, existing.memberIds);
  });

  testWidgets(
    'non-owner events open read-only without save or delete actions',
    (tester) async {
      final repository = LocalScheduleRepository();
      final auth = _CurrentAuth(currentUser: null);
      final controller = PlannerController(auth: auth, repository: repository);
      addTearDown(auth.dispose);
      controller.user = _user;
      controller.events = <PlannerEvent>[
        PlannerEvent(
          id: 'other-event',
          groupId: _group.id,
          title: 'Other member event',
          startAt: DateTime.utc(2026, 8, 14, 16),
          endAt: DateTime.utc(2026, 8, 14, 17),
          ownerId: 'other-user',
          timezone: _group.timezone,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            plannerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: EventEditorScreen(eventId: 'other-event'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('일정 보기'), findsOneWidget);
      expect(find.byTooltip('삭제'), findsNothing);
      expect(find.text('저장'), findsNothing);
      expect(find.text('일정 저장하기'), findsNothing);
      expect(find.text('이 일정은 작성자만 수정할 수 있어요.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        isTrue,
      );
    },
  );

  testWidgets('event color choices expose distinct Korean semantics labels', (
    tester,
  ) async {
    final repository = LocalScheduleRepository();
    final auth = _CurrentAuth(currentUser: null);
    final controller = PlannerController(auth: auth, repository: repository);
    addTearDown(auth.dispose);
    controller.user = _user;
    controller.selectedGroup = _group;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: EventEditorScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    for (final label in <String>[
      '청록색 일정 색상',
      '산호색 일정 색상',
      '보라색 일정 색상',
      '파란색 일정 색상',
      '황금색 일정 색상',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      expect(
        tester.getSize(find.bySemanticsLabel(label)),
        const Size(48, 48),
        reason: '$label must meet the minimum touch target',
      );
    }
    semantics.dispose();
  });
}
