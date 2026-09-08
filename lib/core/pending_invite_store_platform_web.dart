import 'dart:convert';

import 'package:web/web.dart' as web;

import 'pending_invite_store_contract.dart';

const _storageKey = 'moduly.pending_invite.v1';

class WebSessionPendingInviteStore implements PendingInviteStore {
  web.Storage get _storage => web.window.sessionStorage;

  @override
  Future<String?> read() async {
    return (await readRecord())?.token;
  }

  @override
  Future<PendingInviteRecord?> readRecord() async {
    String? raw;
    try {
      raw = _storage.getItem(_storageKey);
      if (raw == null) return null;
    } catch (_) {
      // 비공개 브라우징이나 샌드박스 아이프레임에서는 저장소를 사용하지 못할 수 있다.
      // 메모리 내 컨트롤러 상태로 앱을 계속 사용할 수 있게 한다.
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded['token'] is! String ||
          decoded['expires_at'] is! String) {
        await clear();
        return null;
      }
      final expiresAt = DateTime.tryParse(decoded['expires_at'] as String);
      final token = decoded['token'] as String;
      if (expiresAt == null || !expiresAt.isUtc || token.isEmpty) {
        await clear();
        return null;
      }
      if (!expiresAt.isAfter(DateTime.now().toUtc())) {
        await clear();
        return null;
      }
      return PendingInviteRecord(token: token, expiresAt: expiresAt);
    } catch (_) {
      // 잘못된 레코드가 sessionStorage에 남아 컨트롤러를 시작할 때마다 복원에
      // 실패해서는 안 된다. 삭제는 가능한 범위에서 수행하며, 비공개 브라우징에서는 저장소
      // API가 여전히 접근을 거부할 수 있다.
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(String token, DateTime expiresAt) async {
    try {
      _storage.setItem(
        _storageKey,
        jsonEncode(<String, String>{
          'token': token,
          'expires_at': expiresAt.toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      // 세션 영속화는 가능한 범위에서 수행한다. 현재 탭의 활성 의도는 여전히 컨트롤러가 소유한다.
    }
  }

  @override
  Future<void> clear() async {
    try {
      _storage.removeItem(_storageKey);
    } catch (_) {
      // 가능한 범위에서 처리하며, 사용자에게 표시되는 오류에는 토큰이 없어야 한다.
    }
  }
}

PendingInviteStore createPlatformPendingInviteStore() =>
    WebSessionPendingInviteStore();
