import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/members_screen.dart';
import 'package:moduly/screens/group_management_dialogs.dart';
import 'package:moduly/screens/timezone_picker.dart';
import 'package:moduly/state/app_state.dart';

PlannerGroup _group() => const PlannerGroup(
  id: 'group-1',
  name: '원본 그룹',
  description: '설명',
  timezone: 'Asia/Seoul',
  version: 7,
  ownerId: 'owner-1',
);

PlannerMember _member(String id, String name, {bool active = true}) =>
    PlannerMember(
      id: id,
      name: name,
      email: '$id@example.com',
      isActive: active,
    );

ThemeData _testTheme() => ThemeData(
  useMaterial3: true,
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
  ),
);

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _listTileWithTitle(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is ListTile &&
      widget.title is Text &&
      (widget.title! as Text).data == title,
);

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: _testTheme(),
  builder: (context, built) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(textScale)),
      child: built ?? child,
    );
  },
  home: child,
);

class _UiAuth extends AuthRepository {
  _UiAuth() : super();

  @override
  PlannerUser? get currentUser => null;
}

class _EditConflictRepository extends LocalScheduleRepository {
  _EditConflictRepository(this._owner, this._group);

  final PlannerUser _owner;
  PlannerGroup _group;
  var updateAttempts = 0;
  final List<int> updateVersions = <int>[];

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async {
    return userId == _owner.id
        ? <PlannerGroup>[_group]
        : const <PlannerGroup>[];
  }

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async {
    return <PlannerMember>[
      PlannerMember(
        id: _owner.id,
        name: 'Owner',
        email: _owner.email,
        isOwner: true,
      ),
    ];
  }

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(String userId, String groupId) {
    // 컨트롤러는 동기적인 채널 설정 실패를 구독 없는 오프라인 스트림으로
    // 취급한다. 그러면 이 테스트가 버전 복구에 집중하고 다시 불러오는 사이에
    // 스트림이 남는 일을 피할 수 있다.
    return _ThrowingStream<List<PlannerEvent>>();
  }

  @override
  Stream<PlannerGroup?> watchGroupLifecycle(String userId, String groupId) {
    return _ThrowingStream<PlannerGroup?>();
  }

  @override
  Future<PlannerGroup> updateGroupIfVersion({
    required String actorId,
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async {
    updateAttempts += 1;
    updateVersions.add(expectedVersion);
    if (updateAttempts == 1) {
      _group = _group.copyWith(version: expectedVersion + 1);
      throw const ScheduleConflictException('최신 그룹 정보가 있어요. 다시 확인해 주세요.');
    }
    _group = _group.copyWith(
      name: name,
      description: description,
      timezone: timezone,
      version: expectedVersion + 1,
    );
    return _group;
  }
}

class _ThrowingStream<T> extends Stream<T> {
  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw StateError('테스트 채널 설정에 실패했습니다');
}

void main() {
  testWidgets('시간대 선택기가 정확한 IANA 이름을 반환한다', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: IanaTimezoneField(
            value: 'Asia/Seoul',
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(IanaTimezoneField));
    await tester.pumpAndSettle();
    expect(find.text('시간대 선택'), findsOneWidget);
    final search = _fieldWithLabel('도시/지역 검색');
    await tester.enterText(search, 'America/New_York');
    await tester.pump();
    expect(find.textContaining('America/New_York'), findsWidgets);
    await tester.tap(_listTileWithTitle('America/New_York'));
    await tester.pumpAndSettle();
    expect(selected, 'America/New_York');
  });

  testWidgets('큰 텍스트와 키보드 인셋에서도 시간대 선택기를 스크롤할 수 있다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme(),
        builder: (context, built) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(2),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
          child: built ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: IanaTimezoneField(value: 'Asia/Seoul', onChanged: (_) {}),
        ),
      ),
    );
    await tester.tap(find.byType(IanaTimezoneField));
    await tester.pumpAndSettle();
    expect(find.text('시간대 선택'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('편집 대화상자가 버전 충돌 후 초안을 보존한다', (tester) async {
    var attempts = 0;
    String? submittedName;
    String? submittedTimezone;
    await tester.pumpWidget(
      _app(
        EditGroupDialog(
          group: _group(),
          onSubmit: (name, description, timezone) async {
            attempts += 1;
            submittedName = name;
            submittedTimezone = timezone;
            if (attempts == 1) {
              throw const ScheduleConflictException(
                '최신 그룹 정보가 있어요. 다시 확인해 주세요.',
              );
            }
          },
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(_fieldWithLabel('그룹 이름'), '새 그룹 이름');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(IanaTimezoneField));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('도시/지역 검색'), 'America/New_York');
    await tester.pump();
    await tester.tap(_listTileWithTitle('America/New_York'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pump();

    expect(find.text('최신 그룹 정보가 있어요. 다시 확인해 주세요.'), findsOneWidget);
    expect(find.text('새 그룹 이름'), findsOneWidget);
    expect(find.text('America/New_York'), findsOneWidget);
    expect(submittedName, '새 그룹 이름');
    expect(submittedTimezone, 'America/New_York');
  });

  testWidgets('멤버 편집이 다시 불러온 선택 그룹 버전으로 재시도한다', (tester) async {
    const user = PlannerUser(id: 'owner-ui', email: 'owner-ui@example.com');
    const initial = PlannerGroup(
      id: 'ui-group',
      name: '원본 그룹',
      description: '설명',
      timezone: 'UTC',
      version: 4,
      ownerId: 'owner-ui',
    );
    final repository = _EditConflictRepository(user, initial);
    // 부트스트랩은 로그아웃 상태로 둔다. 아래에서 테스트가 인증된 플래너
    // 컨텍스트를 명시적으로 설치하므로 백그라운드 로드가 대화상자의 버전
    // 재시도 검증과 경합하지 않는다.
    final auth = _UiAuth();
    final controller = PlannerController(auth: auth, repository: repository);
    // ProviderScope가 재정의된 컨트롤러를 소유하고 테스트 종료 시 해제한다.
    addTearDown(auth.dispose);
    // 여기서는 의도적으로 부트스트랩을 기다리지 않는다. 화면을 펌프하기 전에
    // 테스트가 선택된 그룹을 동기적으로 설치한다.
    controller.user = user;
    controller.groups = <PlannerGroup>[initial];
    controller.selectedGroup = initial;
    controller.members = <PlannerMember>[
      PlannerMember(
        id: user.id,
        name: 'Owner',
        email: user.email,
        isOwner: true,
      ),
    ];
    controller.isLoading = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          plannerControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: MembersScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('그룹 정보 편집'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('그룹 이름'), '수정한 그룹');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('그룹 정보 편집'), findsOneWidget);
    expect(find.text('수정한 그룹'), findsOneWidget);
    expect(repository.updateVersions, <int>[4]);
    expect(controller.selectedGroup?.version, 5);

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(repository.updateVersions, <int>[4, 5]);
    expect(find.text('그룹 정보 편집'), findsNothing);
  });

  testWidgets('이전 대화상자가 제공된 활성 대상만 표시하고 두 번째 확인을 요구한다', (tester) async {
    String? transferred;
    final candidates = <PlannerMember>[
      _member('active-1', '활성 멤버'),
      _member('active-2', '두 번째 멤버'),
    ];
    await tester.pumpWidget(
      _app(
        TransferGroupDialog(
          candidates: candidates,
          onSubmit: (memberId) async => transferred = memberId,
        ),
      ),
    );
    expect(find.text('활성 멤버'), findsOneWidget);
    await tester.tap(_listTileWithTitle('활성 멤버'));
    await tester.pump();
    final next = find.widgetWithText(FilledButton, '다음');
    expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    await tester.tap(next);
    await tester.pump();
    expect(find.text('소유권 이전을 확인할까요?'), findsOneWidget);
    expect(find.text('활성 멤버님에게 소유권을 이전합니다.'), findsOneWidget);
    await tester.tap(find.text('소유권 이전'));
    await tester.pumpAndSettle();
    expect(transferred, 'active-1');
  });

  testWidgets('이전 충돌 시 재시도할 수 있도록 대상 확인 창을 유지한다', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        TransferGroupDialog(
          candidates: <PlannerMember>[_member('active-1', '활성 멤버')],
          onSubmit: (_) async {
            attempts += 1;
            if (attempts == 1) {
              throw const ScheduleConflictException(
                '최신 그룹 정보가 있어요. 다시 확인해 주세요.',
              );
            }
          },
        ),
      ),
    );

    await tester.tap(_listTileWithTitle('활성 멤버'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '다음'));
    await tester.pump();
    await tester.tap(find.text('소유권 이전'));
    await tester.pump();

    expect(find.text('소유권 이전을 확인할까요?'), findsOneWidget);
    expect(find.text('활성 멤버님에게 소유권을 이전합니다.'), findsOneWidget);
    expect(find.text('최신 그룹 정보가 있어요. 다시 확인해 주세요.'), findsOneWidget);
    await tester.tap(find.text('소유권 이전'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('소유권 이전을 확인할까요?'), findsNothing);
  });

  testWidgets('보관 대화상자가 정확한 이름을 요구하고 중복 제출을 막는다', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        ArchiveGroupDialog(
          groupName: '보관할 그룹',
          onSubmit: () async {
            calls += 1;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          },
        ),
      ),
    );
    final archive = find.widgetWithText(FilledButton, '그룹 보관');
    expect(tester.widget<FilledButton>(archive).onPressed, isNull);
    await tester.enterText(_fieldWithLabel('그룹 이름 확인'), '다른 이름');
    expect(tester.widget<FilledButton>(archive).onPressed, isNull);
    expect(find.text('그룹 이름을 정확히 입력해 주세요.'), findsNothing);
    await tester.enterText(_fieldWithLabel('그룹 이름 확인'), '보관할 그룹');
    await tester.pump();
    await tester.tap(archive);
    await tester.tap(archive);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('대화상자 컨트롤이 의미 정보와 48px 터치 영역을 제공한다', (tester) async {
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: IanaTimezoneField(value: 'Asia/Seoul', onChanged: (_) {}),
        ),
      ),
    );
    final semanticsHandle = tester.ensureSemantics();
    await tester.pump();
    final field = find.bySemanticsLabel('시간대 (IANA): Asia/Seoul');
    final node = tester.getSemantics(field);
    expect(node.label, contains('시간대 (IANA): Asia/Seoul'));
    expect(node.flagsCollection.isButton, isTrue);
    expect(tester.getSize(field).height, greaterThanOrEqualTo(48));
    await tester.tap(field);
    await tester.pumpAndSettle();
    final cancel = find.widgetWithText(TextButton, '취소');
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
    await tester.tap(cancel);
    semanticsHandle.dispose();
  });
}
