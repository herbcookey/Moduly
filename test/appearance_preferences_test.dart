import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/appearance_preferences.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
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

class _Store implements AppearancePreferencesStore {
  AppearancePreferences? value;
  Object? loadError;
  Completer<AppearancePreferences?>? loadGate;
  Completer<void>? firstSaveGate;
  int activeSaves = 0;
  int maxActiveSaves = 0;
  final List<AppearancePreferences> saved = <AppearancePreferences>[];

  @override
  Future<AppearancePreferences?> load() async {
    final error = loadError;
    if (error != null) throw error;
    final gate = loadGate;
    if (gate != null) return gate.future;
    return value;
  }

  @override
  Future<void> save(AppearancePreferences preferences) async {
    activeSaves += 1;
    maxActiveSaves = activeSaves > maxActiveSaves
        ? activeSaves
        : maxActiveSaves;
    final gate = firstSaveGate;
    if (gate != null) {
      firstSaveGate = null;
      await gate.future;
    }
    saved.add(preferences);
    value = preferences;
    activeSaves -= 1;
  }
}

class _StringStore implements AppearancePreferencesStringStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

PlannerController _controller(_Auth auth, AppearancePreferencesStore store) =>
    PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
      appearancePreferencesStore: store,
    );

void main() {
  test('SharedPreferences 화면 설정 형식이 왕복되고 잘못된 값은 기본값으로 복구된다', () async {
    final strings = _StringStore();
    final store = SharedPreferencesAppearancePreferencesStore(store: strings);
    const expected = AppearancePreferences(darkMode: true, textScale: 1.1);

    await store.save(expected);
    expect(await store.load(), expected);

    strings.values[SharedPreferencesAppearancePreferencesStore.storageKey] =
        '{malformed';
    expect(await store.load(), isNull);
    strings.values[SharedPreferencesAppearancePreferencesStore.storageKey] =
        jsonEncode(<String, Object>{
          'v': 1,
          'dark_mode': true,
          'text_scale': 8,
        });
    expect(await store.load(), isNull);
  });

  test('화면 설정을 저장하고 새 컨트롤러에서 복원한다', () async {
    final store = _Store();
    final firstAuth = _Auth();
    final first = _controller(firstAuth, store);
    await first.appearancePreferencesReady;

    first.toggleDarkMode(true);
    first.setTextScale(1.25);
    await first.settleAppearancePreferences();
    expect(store.value?.darkMode, isTrue);
    expect(store.value?.textScale, 1.25);
    first.dispose();
    firstAuth.dispose();

    final secondAuth = _Auth();
    final second = _controller(secondAuth, store);
    await second.appearancePreferencesReady;
    expect(second.darkMode, isTrue);
    expect(second.textScale, 1.25);
    second.dispose();
    secondAuth.dispose();
  });

  test('앱 provider가 영구 화면 설정 저장소를 PlannerController에 주입한다', () async {
    final store = _Store()
      ..value = const AppearancePreferences(darkMode: true, textScale: 1.1);
    final auth = _Auth();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(auth),
        scheduleRepositoryProvider.overrideWithValue(LocalScheduleRepository()),
        appearancePreferencesStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(() {
      container.dispose();
      auth.dispose();
    });

    final controller = container.read(plannerControllerProvider);
    await controller.appearancePreferencesReady;

    expect(controller.darkMode, isTrue);
    expect(controller.textScale, 1.1);
  });

  test('늦은 화면 설정 로드가 사용자의 새 변경을 덮지 않는다', () async {
    final store = _Store();
    final loadGate = Completer<AppearancePreferences?>();
    store.loadGate = loadGate;
    final auth = _Auth();
    final controller = _controller(auth, store);

    controller.toggleDarkMode(true);
    controller.setTextScale(1.25);
    loadGate.complete(
      const AppearancePreferences(darkMode: false, textScale: 0.9),
    );
    await controller.appearancePreferencesReady;
    await controller.settleAppearancePreferences();

    expect(controller.darkMode, isTrue);
    expect(controller.textScale, 1.25);
    expect(store.value?.darkMode, isTrue);
    expect(store.value?.textScale, 1.25);
    controller.dispose();
    auth.dispose();
  });

  test('로드 중 한 설정만 바꿔도 수정하지 않은 저장값을 병합해 보존한다', () async {
    final store = _Store();
    final loadGate = Completer<AppearancePreferences?>();
    store.loadGate = loadGate;
    final auth = _Auth();
    final controller = _controller(auth, store);

    controller.toggleDarkMode(false);
    await Future<void>.delayed(Duration.zero);
    expect(
      store.saved,
      isEmpty,
      reason: '초기 읽기가 끝나기 전에 기본 textScale로 저장값을 덮어쓰면 안 됩니다.',
    );
    loadGate.complete(
      const AppearancePreferences(darkMode: true, textScale: 1.25),
    );
    await controller.appearancePreferencesReady;
    await controller.settleAppearancePreferences();

    expect(controller.darkMode, isFalse);
    expect(controller.textScale, 1.25);
    expect(store.value, const AppearancePreferences(textScale: 1.25));
    expect(store.saved, const <AppearancePreferences>[
      AppearancePreferences(textScale: 1.25),
    ]);
    controller.dispose();
    auth.dispose();
  });

  test('로드 중 글자 크기만 바꾸면 저장된 화면 모드를 함께 보존한다', () async {
    final store = _Store();
    final loadGate = Completer<AppearancePreferences?>();
    store.loadGate = loadGate;
    final auth = _Auth();
    final controller = _controller(auth, store);

    controller.setTextScale(1.1);
    loadGate.complete(
      const AppearancePreferences(darkMode: true, textScale: 0.9),
    );
    await controller.appearancePreferencesReady;
    await controller.settleAppearancePreferences();

    expect(controller.darkMode, isTrue);
    expect(controller.textScale, 1.1);
    expect(store.saved, const <AppearancePreferences>[
      AppearancePreferences(darkMode: true, textScale: 1.1),
    ]);
    controller.dispose();
    auth.dispose();
  });

  test('초기 읽기 실패 시 부분 기본값을 쓰지 않고 재시도 후 한 번만 병합 저장한다', () async {
    final store = _Store()
      ..value = const AppearancePreferences(darkMode: true, textScale: 1.25)
      ..loadError = StateError('preferences unavailable');
    final auth = _Auth();
    final controller = _controller(auth, store);

    controller.toggleDarkMode(false);
    await controller.appearancePreferencesReady;
    await controller.settleAppearancePreferences();

    expect(store.saved, isEmpty);
    expect(
      store.value,
      const AppearancePreferences(darkMode: true, textScale: 1.25),
    );
    expect(controller.appearancePreferencesError, '화면 설정을 불러오지 못했어요.');

    store.loadError = null;
    await controller.retryAppearancePreferencesLoad();
    await controller.settleAppearancePreferences();

    expect(controller.darkMode, isFalse);
    expect(controller.textScale, 1.25);
    expect(store.saved, const <AppearancePreferences>[
      AppearancePreferences(textScale: 1.25),
    ]);
    expect(controller.appearancePreferencesError, isNull);
    controller.dispose();
    auth.dispose();
  });

  test('읽기 실패가 표시된 뒤 설정을 바꿔도 오류와 재시도 경로를 유지한다', () async {
    final store = _Store()..loadError = StateError('preferences unavailable');
    final auth = _Auth();
    final controller = _controller(auth, store);
    await controller.appearancePreferencesReady;
    expect(controller.appearancePreferencesError, '화면 설정을 불러오지 못했어요.');

    controller.setTextScale(1.25);
    await controller.settleAppearancePreferences();

    expect(controller.textScale, 1.25);
    expect(controller.appearancePreferencesError, '화면 설정을 불러오지 못했어요.');
    expect(store.saved, isEmpty);
    controller.dispose();
    auth.dispose();
  });

  test('연속 화면 설정 저장을 직렬화하고 마지막 값을 보존한다', () async {
    final saveGate = Completer<void>();
    final store = _Store()..firstSaveGate = saveGate;
    final auth = _Auth();
    final controller = _controller(auth, store);
    await controller.appearancePreferencesReady;

    controller.setTextScale(0.9);
    controller.setTextScale(1.1);
    controller.setTextScale(1.25);
    await Future<void>.delayed(Duration.zero);
    expect(store.activeSaves, 1);
    saveGate.complete();
    await controller.settleAppearancePreferences();

    expect(store.maxActiveSaves, 1);
    expect(store.saved.last.textScale, 1.25);
    controller.dispose();
    auth.dispose();
  });
}
