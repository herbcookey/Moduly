import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/repositories/auth_repository.dart';

void main() {
  test('네이티브 인증 콜백이 사용자 지정 URI 스킴을 유지한다', () {
    for (final baseUri in <Uri>[
      Uri.parse('https://planner.example.test/login'),
      Uri.parse('http://localhost:3000/login'),
      Uri.parse('file:///tmp/flutter/index.html'),
    ]) {
      expect(
        resolveAuthCallbackRedirect(isWeb: false, baseUri: baseUri),
        authCallbackRedirect,
      );
    }
    expect(authCallbackRedirectForPlatform(isWeb: false), authCallbackRedirect);
  });

  test('웹 인증 콜백이 현재 출처와 고정 경로를 사용한다', () {
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

  test('포트를 생략한 웹 HTTPS 콜백에 :0을 출력하지 않는다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('https://planner.example.test/login'),
      ),
      'https://planner.example.test/auth-callback',
    );
  });

  test('웹 HTTPS의 명시적 표준 포트를 기본 포트로 정규화한다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('https://planner.example.test:443/login'),
      ),
      'https://planner.example.test/auth-callback',
    );
  });

  test('웹 인증 콜백이 로컬 HTTP 출처를 지원한다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('http://localhost:3000/login?next=home'),
      ),
      'http://localhost:3000/auth-callback',
    );
  });

  test('포트를 생략한 웹 HTTP 콜백에 :0을 출력하지 않는다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('http://planner.example.test/login'),
      ),
      'http://planner.example.test/auth-callback',
    );
  });

  test('웹 HTTP의 명시적 표준 포트를 기본 포트로 정규화한다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('http://planner.example.test:80/login'),
      ),
      'http://planner.example.test/auth-callback',
    );
  });

  test('웹 해석기가 브라우저 출처 없이 사용자 지정 스킴을 만들지 않는다', () {
    expect(
      resolveAuthCallbackRedirect(
        isWeb: true,
        baseUri: Uri.parse('file:///tmp/flutter/index.html'),
      ),
      authCallbackPath,
    );
  });

  test('클라이언트 환경 템플릿에 공개 AppConfig 키만 포함된다', () {
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

  test('macOS가 네이티브 콜백 스킴을 등록한다', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>CFBundleURLTypes</key>'));
    expect(plist, contains('<string>moduly</string>'));
  });

  test('플랫폼 콜백과 샌드박스 설정이 일치한다', () {
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

  test('README가 웹 리디렉션과 데스크톱 설치 프로그램 제한을 설명한다', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('http://localhost:3000/auth-callback'));
    expect(readme, contains('flutter run -d chrome --web-port 3000'));
    expect(readme, contains('SPA 대체 경로'));
    expect(readme, contains('com.apple.security.network.client'));
    expect(readme, contains('Windows'));
    expect(readme, contains('Linux'));
    expect(readme, contains('MSIX'));
    expect(readme, contains('x-scheme-handler/moduly'));
  });

  test('직접 데모 로그인이 비밀번호 최소 길이 6자를 적용한다', () async {
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
  });

  test('직접 데모 가입이 이름을 최대 120자로 제한한다', () async {
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
