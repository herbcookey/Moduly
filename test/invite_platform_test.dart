import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'package:moduly/platform/invite_link_source.dart';
import 'package:moduly/platform/invite_share_service.dart';

class _RecordingShareInvoker {
  ShareParams? last;

  Future<ShareResult> share(ShareParams params) async {
    last = params;
    return const ShareResult('selected', ShareResultStatus.success);
  }
}

void main() {
  test('browser location seam selects package:web for JS and WASM builds', () {
    final source = File('lib/platform/browser_location_source.dart');
    final webSource = File('lib/platform/browser_location_source_web.dart');
    expect(source.existsSync(), isTrue);
    expect(webSource.existsSync(), isTrue);
    expect(
      source.readAsStringSync(),
      contains(
        "if (dart.library.js_interop) 'browser_location_source_web.dart'",
      ),
    );
    expect(webSource.readAsStringSync(), contains("package:web/web.dart"));
  });

  test(
    'bootstrap initializes auth before attaching links and keeps cold/auth links',
    () async {
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final cold = Uri.parse('moduly://invite/2345ABCDEFGH');
      final authCallback = Uri.parse('moduly://auth-callback?code=opaque');
      final events = <String>[];
      final source = InviteLinkSource(
        linkStream: links.stream,
        initialLink: () async {
          events.add('cold-read');
          return cold;
        },
      );
      addTearDown(source.dispose);
      final received = <Uri>[];
      final subscription = source.stream.listen(received.add);
      addTearDown(subscription.cancel);

      await initializeBeforeInviteSource(
        initialize: () async {
          events.add('supabase-init');
          await Future<void>.delayed(Duration.zero);
        },
        startInviteSource: () {
          events.add('invite-start');
          source.start();
        },
      );
      await pumpEventQueue();

      links
        ..add(authCallback)
        ..add(Uri.parse('moduly://invite/89ABCDEFGHJK'))
        ..add(Uri.parse('moduly://invite/89ABCDEFGHJK'));
      await pumpEventQueue();

      expect(events, <String>['supabase-init', 'invite-start', 'cold-read']);
      expect(received, <Uri>[
        cold,
        authCallback,
        Uri.parse('moduly://invite/89ABCDEFGHJK'),
      ]);
    },
  );

  test(
    'early link source buffers cold URI and de-duplicates stream delivery',
    () async {
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final cold = Uri.parse('moduly://invite/2345ABCDEFGH');
      final source = InviteLinkSource(
        linkStream: links.stream,
        initialLink: () async => cold,
      );
      addTearDown(source.dispose);

      source.start();
      await pumpEventQueue();
      expect(source.takeBuffered(), <Uri>[cold]);

      final received = <Uri>[];
      final subscription = source.stream.listen(received.add);
      addTearDown(subscription.cancel);
      links
        ..add(cold)
        ..add(Uri.parse('moduly://invite/89ABCDEFGHJK'));
      await pumpEventQueue();

      expect(received, <Uri>[Uri.parse('moduly://invite/89ABCDEFGHJK')]);
    },
  );

  test('share adapter uses text and keeps the iPad anchor', () async {
    final platform = _RecordingShareInvoker();
    final service = SharePlusInviteShareService(invoker: platform.share);
    final origin = const Rect.fromLTWH(12, 24, 80, 48);

    final result = await service.shareInvite(
      code: '2345-ABCD-EFGH',
      link: Uri.parse('https://planner.example/invite/2345ABCDEFGH'),
      sharePositionOrigin: origin,
    );

    expect(result.status, ShareResultStatus.success);
    expect(platform.last?.uri, isNull);
    expect(platform.last?.text, contains('2345-ABCD-EFGH'));
    expect(
      platform.last?.text,
      contains('https://planner.example/invite/2345ABCDEFGH'),
    );
    expect(platform.last?.sharePositionOrigin, origin);
  });

  test('share adapter keeps an honest code-only fallback', () async {
    final platform = _RecordingShareInvoker();
    final service = SharePlusInviteShareService(invoker: platform.share);

    await service.shareInvite(code: '2345-ABCD-EFGH');

    expect(platform.last?.uri, isNull);
    expect(platform.last?.text, 'Moduly 그룹 초대 코드\n2345-ABCD-EFGH');
  });
}
