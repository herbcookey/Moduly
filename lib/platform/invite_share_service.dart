import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// A narrow seam around share_plus so the one-shot invite dialog can be
/// tested without opening a platform share sheet.
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
    // Share text rather than passing `uri` alongside `text`: share_plus
    // intentionally rejects that combination.  This also gives desktop and
    // web a useful code-only fallback when no HTTPS origin is configured.
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
