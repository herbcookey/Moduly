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

  test('builds and parses the configured canonical web link', () {
    final uri = InviteLinkParser.build(token, config: config, isRelease: false);
    expect(uri?.toString(), 'https://planner.example.test/invite/$token');
    expect(
      InviteLinkParser.parse(uri!, config: config, isRelease: false),
      const ParsedInviteLink(token: token, source: InviteLinkSource.web),
    );
  });

  test('accepts native invite scheme with one strict token segment', () {
    final parsed = InviteLinkParser.parse(
      Uri.parse('moduly://invite/$token'),
      config: config,
      isRelease: false,
    );
    expect(parsed.token, token);
    expect(parsed.source, InviteLinkSource.native);
  });

  test(
    'normalizes lower-case short and legacy tokens at the link boundary',
    () {
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
    },
  );

  test('rejects path/query/origin abuse without echoing a token', () {
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

  test(
    'rejects encoded slash, malformed percent, controls, and wrong current origin',
    () {
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
              InviteLinkParser.tryParse(
                    uri,
                    config: config,
                    isRelease: false,
                  ) ==
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
    },
  );

  test(
    'base URL validator rejects encoded, credentialed, and whitespace origins',
    () {
      for (final raw in <String>[
        'https://planner.example.test/%2F',
        'https://user:pass@planner.example.test',
        'https://planner.example.test/path with-space',
        'https://planner.example.test/path?x=1',
        'https://planner.example.test/path#fragment',
      ]) {
        expect(validateInviteBaseUrl(raw).isValid, isFalse, reason: raw);
      }
    },
  );

  test('keeps a configured deployment path exact', () {
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

  test('disables arbitrary or release plaintext base URLs', () {
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
