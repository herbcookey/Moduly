import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class AppearancePreferences {
  const AppearancePreferences({
    this.darkMode = false,
    this.textScale = defaultTextScale,
  });

  static const double minTextScale = 0.9;
  static const double maxTextScale = 1.25;
  static const double defaultTextScale = 1;

  final bool darkMode;
  final double textScale;

  @override
  bool operator ==(Object other) =>
      other is AppearancePreferences &&
      other.darkMode == darkMode &&
      other.textScale == textScale;

  @override
  int get hashCode => Object.hash(darkMode, textScale);
}

abstract interface class AppearancePreferencesStore {
  Future<AppearancePreferences?> load();

  Future<void> save(AppearancePreferences preferences);
}

abstract interface class AppearancePreferencesStringStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SharedPreferencesAsyncAppearanceStringStore
    implements AppearancePreferencesStringStore {
  factory SharedPreferencesAsyncAppearanceStringStore({
    SharedPreferencesAsync? preferences,
  }) => SharedPreferencesAsyncAppearanceStringStore._(preferences);

  SharedPreferencesAsyncAppearanceStringStore._(this._preferences);

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get preferences =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => preferences.getString(key);

  @override
  Future<void> write(String key, String value) =>
      preferences.setString(key, value);
}

/// 직접 생성한 컨트롤러와 테스트의 기본 저장소다. 앱 공급자는 아래의 영구 구현을
/// 명시적으로 주입하므로 테스트끼리 플랫폼 환경설정을 공유하지 않는다.
class MemoryAppearancePreferencesStore implements AppearancePreferencesStore {
  AppearancePreferences? value;

  @override
  Future<AppearancePreferences?> load() async => value;

  @override
  Future<void> save(AppearancePreferences preferences) async {
    value = preferences;
  }
}

/// 화면 설정 두 값을 하나의 버전 JSON으로 기록해 부분 저장 상태를 만들지 않는다.
/// 캐시 없는 SharedPreferences 비동기 API를 사용해 다른 엔진/격리 실행의 오래된
/// 값을 읽지 않는다.
class SharedPreferencesAppearancePreferencesStore
    implements AppearancePreferencesStore {
  SharedPreferencesAppearancePreferencesStore({
    AppearancePreferencesStringStore? store,
    SharedPreferencesAsync? preferences,
  }) : store =
           store ??
           SharedPreferencesAsyncAppearanceStringStore(
             preferences: preferences,
           ) {
    if (store != null && preferences != null) {
      throw ArgumentError('store와 preferences를 동시에 제공할 수 없습니다');
    }
  }

  static const String storageKey = 'moduly_appearance_preferences_v1';
  static const int schemaVersion = 1;

  final AppearancePreferencesStringStore store;

  @override
  Future<AppearancePreferences?> load() async {
    final encoded = await store.read(storageKey);
    if (encoded == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      return null;
    }
    final raw = decoded.cast<String, dynamic>();
    if (raw.length != 3 ||
        raw['v'] != schemaVersion ||
        raw['dark_mode'] is! bool ||
        raw['text_scale'] is! num) {
      return null;
    }
    final scale = (raw['text_scale'] as num).toDouble();
    if (!scale.isFinite ||
        scale < AppearancePreferences.minTextScale ||
        scale > AppearancePreferences.maxTextScale) {
      return null;
    }
    return AppearancePreferences(
      darkMode: raw['dark_mode'] as bool,
      textScale: scale,
    );
  }

  @override
  Future<void> save(AppearancePreferences value) {
    final scale = value.textScale;
    if (!scale.isFinite ||
        scale < AppearancePreferences.minTextScale ||
        scale > AppearancePreferences.maxTextScale) {
      throw const FormatException('화면 설정을 확인해 주세요.');
    }
    return store.write(
      storageKey,
      jsonEncode(<String, Object>{
        'v': schemaVersion,
        'dark_mode': value.darkMode,
        'text_scale': scale,
      }),
    );
  }
}
