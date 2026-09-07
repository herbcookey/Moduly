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
      // Storage can be unavailable in private browsing or sandboxed iframes.
      // Keep the app usable with the in-memory controller state.
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
      // A malformed record must not remain in sessionStorage and repeatedly
      // fail hydration on every controller startup.  Clearing is best effort;
      // storage APIs may still reject access in private browsing.
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
      // Session persistence is best effort.  The controller still owns the
      // live intent for the current tab.
    }
  }

  @override
  Future<void> clear() async {
    try {
      _storage.removeItem(_storageKey);
    } catch (_) {
      // Best effort; no user-facing error should contain the token.
    }
  }
}

PendingInviteStore createPlatformPendingInviteStore() =>
    WebSessionPendingInviteStore();
