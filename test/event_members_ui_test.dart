import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/event_editor_screen.dart';
import 'package:moduly/screens/home_screen.dart';
import 'package:moduly/state/app_state.dart';

const _creator = PlannerUser(
  id: 'creator',
  email: 'creator@example.com',
  displayName: '작성자',
);
const _group = PlannerGroup(
  id: 'group-1',
  name: '테스트 그룹',
  timezone: 'UTC',
  ownerId: 'creator',
);

PlannerMember _member(
  String id,
  String name, {
  bool isOwner = false,
  bool isActive = true,
}) => PlannerMember(
  id: id,
  name: name,
  email: '$id@example.com',
  isOwner: isOwner,
  isActive: isActive,
);

class _TestAuth extends AuthRepository {
  _TestAuth() : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();

  @override
  PlannerUser? get currentUser => null;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _CaptureRepository extends LocalScheduleRepository {
  EventDraft? createdDraft;
  PlannerEvent? updatedEvent;
  PlannerEvent? replacementSource;
  PlannerEvent? replacedEvent;
  bool rejectStaleWrites = false;
  int? remoteVersion;
  int updateCalls = 0;
  int replaceCalls = 0;
  int? lastUpdateExpectedVersion;
  int? lastReplacementExpectedVersion;

  @override
  Future<PlannerEvent> createEvent(
    String userId,
    String groupId,
    EventDraft draft,
  ) async {
    createdDraft = draft;
    final event = PlannerEvent(
      id: 'created-event',
      groupId: groupId,
      title: draft.title,
      note: draft.note,
      startAt: draft.startAt,
      endAt: draft.endAt,
      allDay: draft.allDay,
      ownerId: userId,
      memberIds: draft.memberIds,
      colorValue: draft.colorValue,
      timezone: draft.timezone,
      allDayStartDate: draft.allDayStartDate,
      allDayEndDate: draft.allDayEndDate,
    );
    return event;
  }

  @override
  Future<PlannerEvent> updateEvent(
    PlannerEvent event, {
    required int expectedVersion,
    String? actorId,
  }) async {
    updateCalls += 1;
    lastUpdateExpectedVersion = expectedVersion;
    if (rejectStaleWrites &&
        remoteVersion != null &&
        expectedVersion != remoteVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    updatedEvent = event.copyWith(version: expectedVersion + 1);
    return updatedEvent!;
  }

  @override
  Future<PlannerEvent> replaceEventMembers(
    String eventId, {
    required Iterable<String> memberIds,
    required int expectedVersion,
    String? actorId,
  }) async {
    replaceCalls += 1;
    lastReplacementExpectedVersion = expectedVersion;
    if (rejectStaleWrites &&
        remoteVersion != null &&
        expectedVersion != remoteVersion) {
      throw const ScheduleConflictException(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
      );
    }
    final source = replacementSource;
    if (source == null || source.id != eventId) {
      throw StateError('replacement source is missing');
    }
    replacedEvent = source.copyWith(
      memberIds: memberIds.toList(growable: false),
      version: expectedVersion + 1,
    );
    return replacedEvent!;
  }
}

PlannerController _controller({
  required _TestAuth auth,
  required _CaptureRepository repository,
  required PlannerUser user,
  required PlannerGroup group,
  required List<PlannerMember> members,
  List<PlannerEvent> events = const <PlannerEvent>[],
}) {
  final controller = PlannerController(auth: auth, repository: repository);
  controller.user = user;
  controller.groups = <PlannerGroup>[group];
  controller.selectedGroup = group;
  controller.members = members;
  controller.events = events;
  controller.isLoading = false;
  controller.authFlowState = AuthFlowState.signedIn;
  return controller;
}

Widget _app(PlannerController controller, Widget child) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
  ],
  child: MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: child,
  ),
);

Widget _routedApp(PlannerController controller, GoRouter router) =>
    ProviderScope(
      overrides: <Override>[
        plannerControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(
          useMaterial3: true,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
          ),
        ),
      ),
    );

GoRouter _eventTestRouter({required String initialLocation}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: '/home',
      builder: (context, state) => const Scaffold(body: Text('홈')),
    ),
    GoRoute(
      path: '/event/:eventId',
      builder: (context, state) =>
          EventEditorScreen(eventId: state.pathParameters['eventId']),
    ),
  ],
);

PlannerEvent _event({
  String id = 'event-1',
  String ownerId = 'creator',
  List<String> memberIds = const <String>['creator'],
  String title = '참여자 일정',
}) => PlannerEvent(
  id: id,
  groupId: _group.id,
  title: title,
  startAt: DateTime.utc(2026, 8, 10, 9),
  endAt: DateTime.utc(2026, 8, 10, 10),
  ownerId: ownerId,
  memberIds: memberIds,
  timezone: _group.timezone,
);

Finder _memberTile(String name) => find.widgetWithText(CheckboxListTile, name);

void _useConstrainedViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _scrollIntoEditorViewport(
  WidgetTester tester,
  Finder target,
) async {
  final list = find.byType(ListView).first;
  final viewport = tester.getRect(list);
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (target.evaluate().isNotEmpty) {
      final rect = tester.getRect(target);
      if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) return;
    }
    await tester.drag(list, const Offset(0, -180));
    await tester.pump();
  }
  fail('Target did not become visible in the editor viewport.');
}

Widget _largeText(Widget child) => MediaQuery(
  data: const MediaQueryData(
    textScaler: TextScaler.linear(2),
    viewInsets: EdgeInsets.only(bottom: 300),
  ),
  child: child,
);

void main() {
  testWidgets('create editor selects participants and saves their IDs', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[
        _member(_creator.id, '작성자', isOwner: true),
        _member('member-b', '멤버 B'),
      ],
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller, const EventEditorScreen()));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, '새 일정');
    final newMemberTile = _memberTile('멤버 B');
    await _scrollIntoEditorViewport(tester, newMemberTile);
    await tester.tap(newMemberTile);
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(repository.createdDraft, isNotNull);
    expect(
      repository.createdDraft!.memberIds,
      containsAll(<String>[_creator.id, 'member-b']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('creator edit preselects and saves changed participants', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final existing = _event();
    repository.replacementSource = existing;
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[
        _member(_creator.id, '작성자', isOwner: true),
        _member('member-b', '멤버 B'),
      ],
      events: <PlannerEvent>[existing],
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller, const EventEditorScreen(eventId: 'event-1')),
    );
    await tester.pump();
    await _scrollIntoEditorViewport(tester, _memberTile('작성자'));
    expect(tester.widget<CheckboxListTile>(_memberTile('작성자')).value, isTrue);
    expect(tester.widget<CheckboxListTile>(_memberTile('멤버 B')).value, isFalse);
    await tester.tap(_memberTile('멤버 B'));
    await tester.tap(find.widgetWithText(TextButton, '저장'));
    await tester.pumpAndSettle();

    expect(repository.updatedEvent, isNotNull);
    expect(repository.updatedEvent!.memberIds, contains('member-b'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'creator body draft keeps its base version across a realtime update',
    (tester) async {
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final existing = _event(title: '처음 제목');
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: _creator,
        group: _group,
        members: <PlannerMember>[_member(_creator.id, '작성자', isOwner: true)],
        events: <PlannerEvent>[existing],
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _app(controller, const EventEditorScreen(eventId: 'event-1')),
      );
      await tester.pump();
      final titleField = find.byType(TextField).first;
      await tester.enterText(titleField, '내가 입력한 제목');
      final titleController = tester.widget<TextField>(titleField).controller!;

      final remote = existing.copyWith(title: '원격 제목', version: 2);
      controller.events = <PlannerEvent>[remote];
      controller.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<TextField>(titleField).controller?.text,
        '내가 입력한 제목',
      );

      repository
        ..remoteVersion = remote.version
        ..rejectStaleWrites = true;
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pumpAndSettle();

      expect(repository.lastUpdateExpectedVersion, existing.version);
      expect(repository.updatedEvent, isNull);
      expect(repository.updateCalls, 1);
      expect(controller.errorMessage, '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.');
      final conflictText = find.text(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
        skipOffstage: false,
      );
      await _scrollIntoEditorViewport(tester, conflictText);
      expect(conflictText, findsOneWidget);
      expect(titleController.text, '내가 입력한 제목');
      expect(controller.events.single.title, '원격 제목');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'group owner participant draft keeps its base version across a realtime update',
    (tester) async {
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final groupOwner = PlannerUser(
        id: 'group-owner',
        email: 'group-owner@example.com',
        displayName: '그룹 소유자',
      );
      final group = _group.copyWith(ownerId: groupOwner.id);
      final existing = _event(memberIds: const <String>['creator']);
      repository.replacementSource = existing;
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: groupOwner,
        group: group,
        members: <PlannerMember>[
          _member(groupOwner.id, '그룹 소유자', isOwner: true),
          _member(_creator.id, '작성자'),
          _member('member-b', '멤버 B'),
          _member('member-c', '멤버 C'),
        ],
        events: <PlannerEvent>[existing],
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _app(controller, const EventEditorScreen(eventId: 'event-1')),
      );
      await tester.pump();
      final memberTile = _memberTile('멤버 B');
      await _scrollIntoEditorViewport(tester, memberTile);
      await tester.tap(memberTile);

      final remote = existing.copyWith(
        memberIds: const <String>['creator', 'member-c'],
        version: 2,
      );
      controller.events = <PlannerEvent>[remote];
      controller.notifyListeners();
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(memberTile).value, isTrue);

      repository
        ..remoteVersion = remote.version
        ..rejectStaleWrites = true;
      final ownerSave = find.widgetWithText(FilledButton, '참여자 저장하기');
      await _scrollIntoEditorViewport(tester, ownerSave);
      await tester.tap(ownerSave);
      await tester.pumpAndSettle();

      expect(repository.lastReplacementExpectedVersion, existing.version);
      expect(repository.replacedEvent, isNull);
      expect(repository.replaceCalls, 1);
      final conflictText = find.text(
        '다른 사람이 이 일정을 변경했습니다. 최신 내용을 불러왔어요.',
        skipOffstage: false,
      );
      await _scrollIntoEditorViewport(tester, conflictText);
      expect(conflictText, findsOneWidget);
      await _scrollIntoEditorViewport(tester, memberTile);
      expect(tester.widget<CheckboxListTile>(memberTile).value, isTrue);
      expect(controller.events.single.memberIds, remote.memberIds);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing edit target becomes a terminal view instead of a create form',
    (tester) async {
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final existing = _event(title: '기존 일정');
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: _creator,
        group: _group,
        members: <PlannerMember>[_member(_creator.id, '작성자', isOwner: true)],
        events: <PlannerEvent>[existing],
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _app(controller, const EventEditorScreen(eventId: 'event-1')),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, '내가 수정한 초안');

      controller.events = const <PlannerEvent>[];
      controller.notifyListeners();
      await tester.pump();

      expect(find.text('일정을 찾을 수 없어요.'), findsOneWidget);
      expect(find.text('내가 수정한 초안', skipOffstage: false), findsNothing);
      expect(find.widgetWithText(TextButton, '저장'), findsNothing);
      expect(find.widgetWithText(FilledButton, '일정 저장하기'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '돌아가기'), findsOneWidget);
      expect(repository.createdDraft, isNull);
      expect(repository.updatedEvent, isNull);
      expect(repository.replacedEvent, isNull);

      await tester.tap(find.widgetWithText(OutlinedButton, '돌아가기'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initial missing edit deep link is terminal and accessible', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[_member(_creator.id, '작성자', isOwner: true)],
      events: const <PlannerEvent>[],
    );
    addTearDown(auth.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(controller, const EventEditorScreen(eventId: 'missing-event')),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '일정을 찾을 수 없어요.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, '저장'), findsNothing);
    expect(find.widgetWithText(FilledButton, '일정 저장하기'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '돌아가기'), findsOneWidget);
    expect(repository.createdDraft, isNull);
    await tester.tap(find.widgetWithText(OutlinedButton, '돌아가기'));
    await tester.pump();
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('root missing edit deep link falls back to home', (tester) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[_member(_creator.id, '작성자', isOwner: true)],
      events: const <PlannerEvent>[],
    );
    final router = _eventTestRouter(initialLocation: '/event/missing-event');
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      auth.dispose();
      router.dispose();
    });

    await tester.pumpWidget(_routedApp(controller, router));
    await tester.pumpAndSettle();

    final back = find.widgetWithText(OutlinedButton, '돌아가기');
    expect(back, findsOneWidget);
    expect(tester.getSize(back).height, greaterThanOrEqualTo(48));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '돌아가기',
      ),
      findsOneWidget,
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    semantics.dispose();

    expect(find.text('홈'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed missing edit route still pops normally', (tester) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[_member(_creator.id, '작성자', isOwner: true)],
      events: const <PlannerEvent>[],
    );
    final router = _eventTestRouter(initialLocation: '/home');
    addTearDown(() {
      auth.dispose();
      router.dispose();
    });

    await tester.pumpWidget(_routedApp(controller, router));
    await tester.pumpAndSettle();
    unawaited(router.push('/event/missing-event'));
    await tester.pumpAndSettle();
    expect(find.text('일정을 찾을 수 없어요.'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '돌아가기'));
    await tester.pumpAndSettle();

    expect(find.text('홈'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stale participant stays neutral until event refresh removes it',
    (tester) async {
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final existing = _event(memberIds: const <String>['member-b']);
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: _creator,
        group: _group,
        members: <PlannerMember>[
          _member(_creator.id, '작성자', isOwner: true),
          _member('member-b', '멤버 B'),
        ],
        events: <PlannerEvent>[existing],
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _app(controller, const EventEditorScreen(eventId: 'event-1')),
      );
      await tester.pump();
      await _scrollIntoEditorViewport(tester, _memberTile('멤버 B'));

      controller.members = <PlannerMember>[
        _member(_creator.id, '작성자', isOwner: true),
      ];
      controller.notifyListeners();
      await tester.pump();
      await _scrollIntoEditorViewport(tester, _memberTile('이전 멤버'));
      expect(find.widgetWithText(CheckboxListTile, '이전 멤버'), findsOneWidget);

      controller.events = <PlannerEvent>[
        existing.copyWith(
          memberIds: const <String>[],
          version: existing.version + 1,
        ),
      ];
      controller.notifyListeners();
      await tester.pump();
      expect(find.widgetWithText(CheckboxListTile, '이전 멤버'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group owner can save participants but not event body', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final groupOwner = PlannerUser(
      id: 'group-owner',
      email: 'group-owner@example.com',
      displayName: '그룹 소유자',
    );
    final group = _group.copyWith(ownerId: groupOwner.id);
    final existing = _event(ownerId: _creator.id);
    repository.replacementSource = existing;
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: groupOwner,
      group: group,
      members: <PlannerMember>[
        _member(groupOwner.id, '그룹 소유자', isOwner: true),
        _member(_creator.id, '작성자'),
        _member('member-b', '멤버 B'),
      ],
      events: <PlannerEvent>[existing],
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller, const EventEditorScreen(eventId: 'event-1')),
    );
    await tester.pump();
    expect(find.text('참여자만 변경할 수 있어요.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).readOnly,
      isTrue,
    );
    final ownerMemberTile = _memberTile('멤버 B');
    await _scrollIntoEditorViewport(tester, ownerMemberTile);
    await tester.tap(ownerMemberTile);
    final ownerSave = find.widgetWithText(FilledButton, '참여자 저장하기');
    await _scrollIntoEditorViewport(tester, ownerSave);
    await tester.tap(ownerSave);
    await tester.pumpAndSettle();

    expect(repository.replacedEvent, isNotNull);
    expect(repository.replacedEvent!.memberIds, contains('member-b'));
    expect(repository.updatedEvent, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary participant remains read-only', (tester) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final participant = PlannerUser(
      id: 'member-b',
      email: 'member-b@example.com',
      displayName: '멤버 B',
    );
    final existing = _event(memberIds: const <String>['creator', 'member-b']);
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: participant,
      group: _group,
      members: <PlannerMember>[
        _member(_creator.id, '작성자', isOwner: true),
        _member(participant.id, '멤버 B'),
      ],
      events: <PlannerEvent>[existing],
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller, const EventEditorScreen(eventId: 'event-1')),
    );
    await tester.pump();

    expect(find.text('일정 보기'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '저장'), findsNothing);
    expect(find.text('참여자 저장하기'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).readOnly,
      isTrue,
    );
    await _scrollIntoEditorViewport(tester, _memberTile('멤버 B'));
    expect(
      tester.widget<CheckboxListTile>(_memberTile('멤버 B')).onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('home filter and card use participant assignments', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final event = _event(
      memberIds: const <String>['member-b'],
      title: '참여자 필터 일정',
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[
        _member(_creator.id, '작성자', isOwner: true),
        _member('member-b', '멤버 B'),
      ],
      events: <PlannerEvent>[event],
    );
    controller.selectedDay = DateTime(2026, 8, 10);
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller, const HomeScreen()));
    await tester.pump();
    expect(find.text('참여자 필터 일정'), findsOneWidget);
    expect(find.text('모든 참여자'), findsOneWidget);

    await tester.tap(find.text('모든 참여자'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('멤버 B').last);
    await tester.pump();
    expect(controller.selectedMemberId, 'member-b');
    expect(find.text('참여자 필터 일정'), findsOneWidget);

    controller.setMemberFilter(_creator.id);
    await tester.pump();
    expect(find.text('참여자 필터 일정'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'card names active participants and uses neutral stale fallback',
    (tester) async {
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final event = _event(
        memberIds: const <String>['member-a', 'member-b', 'member-c', 'stale'],
        title: '참여자 카드',
      );
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: _creator,
        group: _group,
        members: <PlannerMember>[
          _member('member-a', '멤버 A'),
          _member('member-b', '멤버 B'),
          _member('member-c', '멤버 C'),
        ],
        events: <PlannerEvent>[event],
      );
      controller.selectedDay = DateTime(2026, 8, 10);
      final semantics = tester.ensureSemantics();
      addTearDown(auth.dispose);

      await tester.pumpWidget(_app(controller, const HomeScreen()));
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data?.contains('멤버 A') == true,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data?.contains('이전 멤버') == true,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == '참여자 멤버 A, 멤버 B 외 1명, 이전 멤버',
        ),
        findsOneWidget,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('card hides inactive member identity behind neutral fallback', (
    tester,
  ) async {
    final auth = _TestAuth();
    final repository = _CaptureRepository();
    final event = _event(
      memberIds: const <String>['inactive-member'],
      title: '비활성 참여자 일정',
    );
    final controller = _controller(
      auth: auth,
      repository: repository,
      user: _creator,
      group: _group,
      members: <PlannerMember>[
        _member(
          'inactive-member',
          '비공개 멤버',
        ).copyWith(isActive: false, removedAt: DateTime.utc(2026, 8, 10)),
      ],
      events: <PlannerEvent>[event],
    );
    controller.selectedDay = DateTime(2026, 8, 10);
    final semantics = tester.ensureSemantics();
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(controller, const HomeScreen()));
    await tester.pump();

    expect(find.text('비공개 멤버'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data?.contains('이전 멤버') == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '참여자 이전 멤버',
      ),
      findsOneWidget,
    );
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'participant controls and save remain reachable at 2x text with keyboard inset',
    (tester) async {
      _useConstrainedViewport(tester);
      final semantics = tester.ensureSemantics();
      final auth = _TestAuth();
      final repository = _CaptureRepository();
      final controller = _controller(
        auth: auth,
        repository: repository,
        user: _creator,
        group: _group,
        members: <PlannerMember>[
          _member(_creator.id, '작성자', isOwner: true),
          _member('member-b', '멤버 B'),
        ],
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _largeText(_app(controller, const EventEditorScreen())),
      );
      await tester.pump();
      final participantTile = _memberTile('멤버 B');
      await _scrollIntoEditorViewport(tester, participantTile);
      final participantRect = tester.getRect(participantTile);
      expect(participantRect.top, greaterThanOrEqualTo(0));
      expect(
        participantRect.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      expect(tester.getSize(participantTile).height, greaterThanOrEqualTo(48));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '참여자 멤버 B',
        ),
        findsOneWidget,
      );
      await tester.tap(participantTile);

      final save = find.widgetWithText(FilledButton, '일정 저장하기');
      await _scrollIntoEditorViewport(tester, save);
      final saveRect = tester.getRect(save);
      expect(saveRect.top, greaterThanOrEqualTo(0));
      expect(
        saveRect.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
