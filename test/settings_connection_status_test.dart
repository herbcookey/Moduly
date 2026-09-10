import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/appearance_preferences.dart';
import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/settings_screen.dart';
import 'package:moduly/state/app_state.dart';

class _Auth extends AuthRepository {
  _Auth() : super();

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

class _FailingAppearanceStore implements AppearancePreferencesStore {
  bool failLoads = false;
  bool failWrites = true;
  AppearancePreferences? value;

  @override
  Future<AppearancePreferences?> load() async {
    if (failLoads) throw StateError('preferences unavailable');
    return value;
  }

  @override
  Future<void> save(AppearancePreferences preferences) async {
    if (failWrites) throw StateError('disk full');
    value = preferences;
  }
}

PlannerController _controller(
  _Auth auth, {
  bool busy = false,
  bool syncError = false,
  AppearancePreferencesStore? appearancePreferencesStore,
}) {
  final controller = PlannerController(
    auth: auth,
    repository: LocalScheduleRepository(),
    appearancePreferencesStore: appearancePreferencesStore,
  );
  controller.user = const PlannerUser(
    id: 'settings-user',
    email: 'settings@example.com',
    displayName: 'Settings User',
  );
  controller.isLoading = false;
  controller.isSaving = busy;
  controller.isOffline = syncError;
  return controller;
}

Widget _app({
  required PlannerController controller,
  required AppConfig config,
  required bool supabaseReady,
  String? supabaseError,
}) => ProviderScope(
  overrides: <Override>[
    plannerControllerProvider.overrideWith((ref) => controller),
    appConfigProvider.overrideWithValue(config),
    supabaseReadyProvider.overrideWithValue(supabaseReady),
    supabaseInitializationErrorProvider.overrideWithValue(supabaseError),
  ],
  child: const MaterialApp(home: SettingsScreen()),
);

void main() {
  const remoteConfig = AppConfig(
    supabaseUrl: 'https://example.supabase.co',
    supabasePublishableKey: 'sb_publishable_test',
  );

  testWidgets('서버 설정이 없으면 원격 동기화 대신 로컬 미리보기로 표시한다', (tester) async {
    final auth = _Auth();
    final controller = _controller(auth);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(
        controller: controller,
        config: const AppConfig(supabaseUrl: '', supabasePublishableKey: ''),
        supabaseReady: false,
      ),
    );

    expect(find.text('로컬 미리보기', skipOffstage: false), findsOneWidget);
    expect(find.text('동기화 중', skipOffstage: false), findsNothing);
    expect(find.text('모든 멤버와 최신 상태를 유지해요.', skipOffstage: false), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(find.text('Moduly · 1.0.0'), findsOneWidget);
    expect(find.text('Moduly · 초기 버전'), findsNothing);
  });

  testWidgets('원격 연결이 준비된 유휴 상태는 동기화 완료로 표시한다', (tester) async {
    final auth = _Auth();
    final controller = _controller(auth);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller: controller, config: remoteConfig, supabaseReady: true),
    );

    expect(find.text('동기화됨', skipOffstage: false), findsOneWidget);
    expect(find.text('동기화 중', skipOffstage: false), findsNothing);
  });

  testWidgets('실제 원격 작업 중에만 동기화 중으로 표시한다', (tester) async {
    final auth = _Auth();
    final controller = _controller(auth, busy: true);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller: controller, config: remoteConfig, supabaseReady: true),
    );

    expect(find.text('동기화 중', skipOffstage: false), findsOneWidget);
    expect(find.text('동기화됨', skipOffstage: false), findsNothing);
  });

  testWidgets('조회 오류를 오프라인 저장 약속이 아닌 동기화 문제로 표시한다', (tester) async {
    final auth = _Auth();
    final controller = _controller(auth, syncError: true);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      _app(controller: controller, config: remoteConfig, supabaseReady: true),
    );

    expect(find.text('동기화 문제', skipOffstage: false), findsOneWidget);
    expect(find.text('오프라인 모드', skipOffstage: false), findsNothing);
    expect(find.text('연결되면 변경사항을 동기화해요.', skipOffstage: false), findsNothing);
  });

  testWidgets('화면 설정 저장 실패를 알리고 사용자가 다시 저장할 수 있다', (tester) async {
    final auth = _Auth();
    final store = _FailingAppearanceStore();
    final controller = _controller(auth, appearancePreferencesStore: store);
    addTearDown(auth.dispose);
    await controller.appearancePreferencesReady;
    await tester.pumpWidget(
      _app(
        controller: controller,
        config: const AppConfig(supabaseUrl: '', supabasePublishableKey: ''),
        supabaseReady: false,
      ),
    );

    controller.toggleDarkMode(true);
    await controller.settleAppearancePreferences();
    await tester.pump();

    expect(find.text('화면 설정을 저장하지 못했어요.', skipOffstage: false), findsOneWidget);
    expect(find.text('다시 저장', skipOffstage: false), findsOneWidget);

    store.failWrites = false;
    await tester.tap(find.text('다시 저장', skipOffstage: false));
    await controller.settleAppearancePreferences();
    await tester.pump();

    expect(find.text('화면 설정을 저장하지 못했어요.', skipOffstage: false), findsNothing);
    expect(store.value?.darkMode, isTrue);
  });

  testWidgets('화면 설정 읽기 실패를 알리고 기존 값을 안전하게 다시 불러온다', (tester) async {
    final auth = _Auth();
    final store = _FailingAppearanceStore()
      ..failLoads = true
      ..failWrites = false
      ..value = const AppearancePreferences(darkMode: true, textScale: 1.25);
    final controller = _controller(auth, appearancePreferencesStore: store);
    addTearDown(auth.dispose);
    await controller.appearancePreferencesReady;
    await tester.pumpWidget(
      _app(
        controller: controller,
        config: const AppConfig(supabaseUrl: '', supabasePublishableKey: ''),
        supabaseReady: false,
      ),
    );

    expect(find.text('화면 설정을 불러오지 못했어요.', skipOffstage: false), findsOneWidget);
    expect(find.text('다시 불러오기', skipOffstage: false), findsOneWidget);

    store.failLoads = false;
    await tester.tap(find.text('다시 불러오기', skipOffstage: false));
    await tester.pumpAndSettle();

    expect(find.text('화면 설정을 불러오지 못했어요.', skipOffstage: false), findsNothing);
    expect(controller.darkMode, isTrue);
    expect(controller.textScale, 1.25);
  });
}
