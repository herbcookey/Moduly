import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// 일회성 초대 대화상자를 플랫폼 공유 시트 없이 테스트할 수 있게 share_plus를 감싸는
/// 좁은 접점이다.
abstract interface class InviteShareService {
  Future<ShareResult> shareInvite({
    required String code,
    Uri? link,
    Rect? sharePositionOrigin,
  });
}

typedef InviteShareInvoker = Future<ShareResult> Function(ShareParams params);

final inviteShareServiceProvider = Provider<InviteShareService>(
  (ref) => SharePlusInviteShareService(),
);

class SharePlusInviteShareService implements InviteShareService {
  factory SharePlusInviteShareService({
    SharePlus? sharePlus,
    InviteShareInvoker? invoker,
  }) => SharePlusInviteShareService._(sharePlus ?? SharePlus.instance, invoker);

  SharePlusInviteShareService._(this._sharePlus, this._invoker);

  final SharePlus _sharePlus;
  final InviteShareInvoker? _invoker;

  @override
  Future<ShareResult> shareInvite({
    required String code,
    Uri? link,
    Rect? sharePositionOrigin,
  }) {
    // `text`와 함께 `uri`를 넘기지 말고 텍스트를 공유한다. share_plus가 이 조합을
    // 의도적으로 거부하기 때문이다. HTTPS 출처가 설정되지 않았을 때 데스크톱과
    // 웹에도 유용한 코드 전용 대체 동작을 제공한다.
    final body = link == null
        ? 'Moduly 그룹 초대 코드\n$code'
        : 'Moduly 그룹 초대\n$code\n$link';
    final params = ShareParams(
      text: body,
      title: 'Moduly 그룹 초대',
      subject: 'Moduly 그룹 초대',
      sharePositionOrigin: sharePositionOrigin,
    );
    return (_invoker ?? _sharePlus.share)(params);
  }
}
