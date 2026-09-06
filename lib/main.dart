import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app.dart';
import 'core/config/app_config.dart';
import 'screens/runtime_configuration_error_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final config = AppConfig.fromEnvironment();
  final releaseConfigurationError = AppConfigPolicy.releaseConfigurationError(
    config,
    isRelease: kReleaseMode,
  );
  // 디버그/프로필에서는 설정 없이 미리보기를 지원하지만, 릴리스에서는
  // 조용히 로컬 데모로 전환하면 안 된다. 아래에서 유효한 설정을 초기화한다.
  var supabaseReady = !config.hasSupabase && releaseConfigurationError == null;
  String? supabaseError;
  if (config.hasSupabase && releaseConfigurationError == null) {
    try {
      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.supabasePublishableKey,
      );
      supabaseReady = true;
    } catch (error) {
      // 미리보기는 계속 사용할 수 있게 하되, 연결된 세션인 것처럼 보이지
      // 않도록 설정 오류를 설정 화면에 표시한다.
      supabaseError = 'Supabase 연결을 시작하지 못했습니다 (${error.runtimeType}).';
    }
  }
  final releaseError =
      releaseConfigurationError ??
      (kReleaseMode && supabaseError != null
          ? '서비스 연결을 시작하지 못했습니다. 앱 설정과 Supabase 배포 상태를 확인한 뒤 다시 빌드해 주세요.'
          : null);
  runApp(
    ProviderScope(
      overrides: <Override>[
        appConfigProvider.overrideWithValue(config),
        supabaseReadyProvider.overrideWithValue(supabaseReady),
        supabaseInitializationErrorProvider.overrideWithValue(supabaseError),
        releaseConfigurationErrorProvider.overrideWithValue(releaseError),
      ],
      child: const RuntimeConfigurationGate(child: ModulyApp()),
    ),
  );
}
