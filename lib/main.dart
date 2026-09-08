import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart' as url_strategy;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app.dart';
import 'core/config/app_config.dart';
import 'platform/invite_link_source.dart';
import 'platform/notification_bindings.dart';
import 'screens/runtime_configuration_error_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use clean `/invite/<token>` and `/auth-callback` paths in the browser.
  // Hosting must rewrite those paths to web/index.html (see README); native
  // platforms simply ignore this web-only URL strategy.
  if (kIsWeb) url_strategy.usePathUrlStrategy();
  tzdata.initializeTimeZones();
  // AppLinks is also used internally by Supabase for auth callbacks.  Create
  // our passive source now, but attach its stream only after Supabase has
  // established the auth observer.  The source's post-init getInitialLink
  // probe recovers a native cold invite without racing auth callback setup.
  final inviteLinkSource = InviteLinkSource();
  final config = AppConfig.fromEnvironment();
  final releaseConfigurationError = AppConfigPolicy.releaseConfigurationError(
    config,
    isRelease: kReleaseMode,
  );
  // 디버그/프로필에서는 설정 없이 미리보기를 지원하지만, 릴리스에서는
  // 조용히 로컬 데모로 전환하면 안 된다. 아래에서 유효한 설정을 초기화한다.
  // 준비 상태는 실제 원격 SDK 초기화 성공만 뜻한다. 로컬 미리보기 허용 여부는
  // 별도 공급자가 결정하므로 설정이 없다는 이유로 연결 완료로 표시하지 않는다.
  var supabaseReady = false;
  String? supabaseError;
  try {
    await initializeBeforeInviteSource(
      initialize: () async {
        if (!config.hasSupabase || releaseConfigurationError != null) return;
        await Supabase.initialize(
          url: config.supabaseUrl,
          publishableKey: config.supabasePublishableKey,
        );
        supabaseReady = true;
      },
      startInviteSource: inviteLinkSource.start,
    );
  } catch (error) {
    // 미리보기는 계속 사용할 수 있게 하되, 연결된 세션인 것처럼 보이지
    // 않도록 설정 오류를 설정 화면에 표시한다.
    supabaseError = 'Supabase 연결을 시작하지 못했습니다 (${error.runtimeType}).';
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
      child: NotificationPlatformScope(
        child: InviteLinkBinding(
          source: inviteLinkSource,
          config: config,
          isRelease: kReleaseMode,
          child: const RuntimeConfigurationGate(child: ModulyApp()),
        ),
      ),
    ),
  );
}
