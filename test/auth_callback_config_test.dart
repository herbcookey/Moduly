import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/repositories/auth_repository.dart';

void main() {
  test('native auth callback stays on the custom URI scheme', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: false,
        baseUri: Uri.parse('https://planner.example.test/login'),
      ),
      authCallbackRedirect,
    );
    expect(authCallbackRedirectForPlatform(isWeb: false), authCallbackRedirect);
  });

  test('web auth callback uses the current origin and fixed path', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse(
          'https://planner.example.test:8443/planner/#/login?next=home',
        ),
      ),
      'https://planner.example.test:8443/auth-callback',
    );
  });

  test('web auth callback supports local HTTP origins', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('http://localhost:3000/login?next=home'),
      ),
      'http://localhost:3000/auth-callback',
    );
  });

  test('web resolver never emits a custom scheme without a browser origin', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('file:///tmp/flutter/index.html'),
      ),
      authCallbackPath,
    );
  });

  test('client env template contains only public AppConfig keys', () {
    final source = File('.env.example').readAsStringSync();
    final assignments = source
        .split('\n')
        .map((line) => line.trim())
        .where((line) => RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(line))
        .map((line) => line.substring(0, line.indexOf('=')))
        .toSet();

    expect(assignments, <String>{
      'SUPABASE_URL',
      'SUPABASE_PUBLISHABLE_KEY',
      'INVITE_BASE_URL',
    });
    expect(source, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
    expect(source, isNot(contains('DATABASE_URL')));
    expect(source, isNot(contains('DB_PASSWORD')));
    expect(source, isNot(contains('SUPABASE_SECRET_KEY')));
  });

  test('macOS registers the native callback scheme', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>CFBundleURLTypes</key>'));
    expect(plist, contains('<string>moduly</string>'));
  });

  test('platform callback and sandbox settings stay aligned', () {
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      androidManifest,
      contains('android:name="flutter_deeplinking_enabled"'),
    );
    expect(androidManifest, contains('android:value="false"'));

    final iosPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
      iosPlist,
      contains('<key>FlutterDeepLinkingEnabled</key>\n\t<false/>'),
    );

    final macosRelease = File(
      'macos/Runner/Release.entitlements',
    ).readAsStringSync();
    final macosDebug = File(
      'macos/Runner/DebugProfile.entitlements',
    ).readAsStringSync();
    for (final entitlements in <String>[macosRelease, macosDebug]) {
      expect(
        entitlements,
        contains('<key>com.apple.security.network.client</key>'),
      );
      expect(entitlements, contains('<true/>'));
    }

    final macosAppInfo = File(
      'macos/Runner/Configs/AppInfo.xcconfig',
    ).readAsStringSync();
    expect(
      macosAppInfo,
      contains('PRODUCT_BUNDLE_IDENTIFIER = com.herbcookey.moduly'),
    );
    final macosProject = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      macosProject,
      contains(
        'PRODUCT_BUNDLE_IDENTIFIER = com.herbcookey.moduly.RunnerTests;',
      ),
    );
    expect(macosProject, isNot(contains('com.example.moduly')));

    final linuxCmake = File('linux/CMakeLists.txt').readAsStringSync();
    expect(linuxCmake, contains('set(APPLICATION_ID "com.herbcookey.moduly")'));
    final linuxRunner = File(
      'linux/runner/my_application.cc',
    ).readAsStringSync();
    expect(
      linuxRunner,
      contains(
        'G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN',
      ),
    );
    expect(linuxRunner, contains('return FALSE;'));
    expect(linuxRunner, isNot(contains('G_APPLICATION_NON_UNIQUE')));
  });

  test('README documents web redirects and desktop installer limits', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('http://localhost:3000/auth-callback'));
    expect(readme, contains('flutter run -d chrome --web-port 3000'));
    expect(readme, contains('SPA fallback'));
    expect(readme, contains('com.apple.security.network.client'));
    expect(readme, contains('Windows'));
    expect(readme, contains('Linux'));
    expect(readme, contains('MSIX'));
    expect(readme, contains('x-scheme-handler/moduly'));
  });

  test(
    'direct demo sign-in enforces the six-character password minimum',
    () async {
      final auth = AuthRepository();
      addTearDown(auth.dispose);

      await expectLater(
        auth.signIn('demo@example.com', '12345'),
        throwsA(isA<AuthException>()),
      );
      expect(
        (await auth.signIn('demo@example.com', '123456')).email,
        'demo@example.com',
      );
    },
  );

  test('direct demo sign-up enforces the 120-character name maximum', () async {
    final auth = AuthRepository();
    addTearDown(auth.dispose);
    final tooLongName = List<String>.filled(121, 'n').join();
    final acceptedName = List<String>.filled(120, 'n').join();

    await expectLater(
      auth.signUp('new@example.com', '123456', tooLongName),
      throwsA(isA<AuthException>()),
    );
    expect(
      (await auth.signUp(
        'new@example.com',
        '123456',
        acceptedName,
      )).isAuthenticated,
      isTrue,
    );
  });
}
