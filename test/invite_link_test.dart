import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/core/invite_link.dart';

void main() {
  const config = AppConfig(
    supabaseUrl: '',
    supabasePublishableKey: '',
    inviteBaseUrl: 'https://planner.example.test',
  );
  const token = '7K9MW3PXQ2RT';

  test('설정된 정규 웹 링크를 만들고 파싱한다', () {
    final uri = InviteLinkParser.build(token, config: config, isRelease: false);
    expect(uri?.toString(), 'https://planner.example.test/invite/$token');
    expect(
      InviteLinkParser.parse(uri!, config: config, isRelease: false),
      const ParsedInviteLink(token: token, source: InviteLinkSource.web),
    );
  });

  test('엄격한 토큰 세그먼트 하나가 있는 네이티브 초대 스킴을 허용한다', () {
    final parsed = InviteLinkParser.parse(
      Uri.parse('moduly://invite/$token'),
      config: config,
      isRelease: false,
    );
    expect(parsed.token, token);
    expect(parsed.source, InviteLinkSource.native);
  });

  test('링크 경계에서 소문자 짧은 토큰과 기존 토큰을 정규화한다', () {
    expect(
      InviteLinkParser.parse(
        Uri.parse('https://planner.example.test/invite/7k9mw3pxq2rt'),
        config: config,
        isRelease: false,
      ).token,
      token,
    );
    const legacy = 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789';
    expect(
      InviteLinkParser.parse(
        Uri.parse('https://planner.example.test/invite/$legacy'),
        config: config,
        isRelease: false,
      ).token,
      legacy.toLowerCase(),
    );
  });

  test('토큰을 되돌려 주지 않고 경로, 검색어, 출처 악용을 거부한다', () {
    final values = <Uri>[
      Uri.parse('https://planner.example.test/invite/$token/'),
      Uri.parse('https://planner.example.test/invite/$token/extra'),
      Uri.parse('https://planner.example.test/invite/$token?x=1'),
      Uri.parse('https://planner.example.test/invite/$token#x'),
      Uri.parse('https://other.example.test/invite/$token'),
      Uri.parse('https://planner.example.test/Invite/$token'),
      Uri.parse('https://planner.example.test/invite/7K9M-W3PX-Q2RT'),
      Uri.parse('moduly://other/$token'),
    ];
    for (final uri in values) {
      expect(
        InviteLinkParser.tryParse(uri, config: config, isRelease: false),
        isNull,
        reason: uri.toString(),
      );
    }
    expect(
      () => InviteLinkParser.parse(
        Uri.parse('https://planner.example.test/invite/$token?x=1'),
        config: config,
        isRelease: false,
      ),
      throwsA(isA<InviteLinkFormatException>()),
    );
  });

  test('인코딩된 슬래시, 잘못된 퍼센트, 제어 문자, 잘못된 현재 출처를 거부한다', () {
    final values = <String>[
      'https://planner.example.test/invite/$token%2Frest',
      'https://planner.example.test/invite/$token%',
      'https://planner.example.test/invite/$token%ZZ',
      'https://planner.example.test/invite/$token%0A',
      'https://planner.example.test/invite/$token?x=%ZZ',
    ];
    for (final raw in values) {
      final uri = Uri.tryParse(raw);
      expect(
        uri == null ||
            InviteLinkParser.tryParse(uri, config: config, isRelease: false) ==
                null,
        isTrue,
        reason: raw,
      );
    }
    expect(
      InviteLinkParser.tryParse(
        Uri.parse('https://planner.example.test/invite/$token'),
        config: config,
        currentOrigin: Uri.parse('https://other.example.test'),
        isRelease: false,
      ),
      isNull,
    );
  });

  test('기본 URL 검사기가 인코딩, 인증 정보, 공백이 있는 출처를 거부한다', () {
    for (final raw in <String>[
      'https://planner.example.test/%2F',
      'https://user:pass@planner.example.test',
      'https://planner.example.test/path with-space',
      'https://planner.example.test/path?x=1',
      'https://planner.example.test/path#fragment',
    ]) {
      expect(validateInviteBaseUrl(raw).isValid, isFalse, reason: raw);
    }
  });

  test('설정된 배포 경로를 정확히 유지한다', () {
    const nested = AppConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      inviteBaseUrl: 'https://planner.example.test/app',
    );
    final valid = Uri.parse('https://planner.example.test/app/invite/$token');
    expect(
      InviteLinkParser.tryParse(valid, config: nested, isRelease: false),
      isNotNull,
    );
    for (final wrongRoot in <String>[
      'https://planner.example.test/invite/$token',
      'https://planner.example.test/app/app/invite/$token',
    ]) {
      expect(
        InviteLinkParser.tryParse(
          Uri.parse(wrongRoot),
          config: nested,
          isRelease: false,
        ),
        isNull,
        reason: wrongRoot,
      );
    }
  });

  test('임의 또는 릴리스 평문 기본 URL을 비활성화한다', () {
    const invalid = AppConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      inviteBaseUrl: 'http://planner.example.test',
    );
    expect(
      InviteLinkParser.build(token, config: invalid, isRelease: false),
      isNull,
    );
    const localhost = AppConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      inviteBaseUrl: 'http://localhost:8080',
    );
    expect(
      InviteLinkParser.build(
        token,
        config: localhost,
        isRelease: false,
      )?.toString(),
      'http://localhost:8080/invite/$token',
    );
    expect(
      InviteLinkParser.build(
        token,
        config: const AppConfig(
          supabaseUrl: '',
          supabasePublishableKey: '',
          inviteBaseUrl: 'http://localhost:8080',
        ),
        isRelease: true,
      ),
      isNull,
    );
  });
}
