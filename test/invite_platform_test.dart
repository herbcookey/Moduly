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
  test('브라우저 위치 이음새가 JS 및 WASM 빌드에서 package:web을 선택한다', () {
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

  test('부트스트랩이 링크 연결 전에 인증을 초기화하고 콜드/인증 링크를 유지한다', () async {
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
  });

  test('초기 링크 소스가 콜드 URI를 버퍼링하고 스트림 전달의 중복을 제거한다', () async {
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
  });

  test('공유 어댑터가 텍스트를 사용하고 iPad 앵커를 유지한다', () async {
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

  test('공유 어댑터가 정확한 코드 전용 대체 경로를 유지한다', () async {
    final platform = _RecordingShareInvoker();
    final service = SharePlusInviteShareService(invoker: platform.share);

    await service.shareInvite(code: '2345-ABCD-EFGH');

    expect(platform.last?.uri, isNull);
    expect(platform.last?.text, 'Moduly 그룹 초대 코드\n2345-ABCD-EFGH');
  });
}
