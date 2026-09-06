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
  test('debug and profile policy allows the local preview without config', () {
    const config = AppConfig(supabaseUrl: '', supabasePublishableKey: '');

    expect(config.hasSupabase, isFalse);
    expect(
      AppConfigPolicy.releaseConfigurationError(config, isRelease: false),
      isNull,
    );
  });

  test('release policy reports every missing public Supabase value', () {
    const config = AppConfig(supabaseUrl: '', supabasePublishableKey: '');

    final message = AppConfigPolicy.releaseConfigurationError(
      config,
      isRelease: true,
    );

    expect(message, contains('SUPABASE_URL'));
    expect(message, contains('SUPABASE_PUBLISHABLE_KEY'));
    expect(message, isNot(contains('service_role')));
  });

  test('release policy accepts a complete public configuration', () {
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

  test('release provider graph never selects demo repositories', () {
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

  testWidgets('release configuration gate hides the demo child', (
    tester,
  ) async {
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
