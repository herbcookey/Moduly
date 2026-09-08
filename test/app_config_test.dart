import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/runtime_configuration_error_screen.dart';
import 'package:moduly/state/app_state.dart';

void main() {
  test('디버그 및 프로필 정책이 설정 없는 로컬 미리보기를 허용한다', () {
    const config = AppConfig(supabaseUrl: '', supabasePublishableKey: '');

    expect(config.hasSupabase, isFalse);
    expect(
      AppConfigPolicy.releaseConfigurationError(config, isRelease: false),
      isNull,
    );
  });

  test('릴리스 정책이 누락된 모든 공개 Supabase 값을 보고한다', () {
    const config = AppConfig(supabaseUrl: '', supabasePublishableKey: '');

    final message = AppConfigPolicy.releaseConfigurationError(
      config,
      isRelease: true,
    );

    expect(message, contains('SUPABASE_URL'));
    expect(message, contains('SUPABASE_PUBLISHABLE_KEY'));
    expect(message, isNot(contains('service_role')));
  });

  test('릴리스 정책이 완전한 공개 설정을 허용한다', () {
    const config = AppConfig(
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'sb_publishable_test',
    );

    expect(config.hasSupabase, isTrue);
    expect(
      AppConfigPolicy.releaseConfigurationError(config, isRelease: true),
      isNull,
    );
  });

  test('릴리스 공급자 그래프가 데모 저장소를 선택하지 않는다', () {
    final container = ProviderContainer(
      overrides: <Override>[
        appConfigProvider.overrideWithValue(
          const AppConfig(supabaseUrl: '', supabasePublishableKey: ''),
        ),
        supabaseReadyProvider.overrideWithValue(false),
        releaseConfigurationErrorProvider.overrideWithValue(
          '서비스 설정이 완료되지 않았습니다.',
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(localDemoAllowedProvider), isFalse);
    expect(
      container.read(authRepositoryProvider),
      isA<ConfigurationBlockedAuthRepository>(),
    );
    expect(
      container.read(scheduleRepositoryProvider),
      isA<ConfigurationBlockedScheduleRepository>(),
    );
    expect(
      container
          .read(authRepositoryProvider)
          .signIn('demo@example.com', 'planner'),
      throwsA(isA<AuthException>()),
    );
    expect(
      container.read(scheduleRepositoryProvider).groupsForUser('demo-user'),
      throwsA(isA<RuntimeConfigurationException>()),
    );
  });

  testWidgets('릴리스 설정 게이트가 데모 하위 위젯을 숨긴다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          releaseConfigurationErrorProvider.overrideWithValue(
            '서비스 설정이 완료되지 않았습니다.',
          ),
        ],
        child: const RuntimeConfigurationGate(child: Text('데모 화면')),
      ),
    );

    expect(find.text('서비스를 시작할 수 없어요'), findsOneWidget);
    expect(find.text('서비스 설정이 완료되지 않았습니다.'), findsOneWidget);
    expect(find.text('데모 화면'), findsNothing);
  });
}
