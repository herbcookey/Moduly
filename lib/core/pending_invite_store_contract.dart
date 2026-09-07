/// Ephemeral persistence boundary for a pending invite intent.
///
/// The store contains only the bearer token and an expiry timestamp.  It is
/// never used for query parameters, logs, or analytics.  Native callers use
/// the in-memory implementation; web callers use sessionStorage through the
/// conditional factory in `pending_invite_store.dart`.
class PendingInviteRecord {
  const PendingInviteRecord({required this.token, this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}

abstract class PendingInviteStore {
  Future<String?> read();

  Future<void> write(String token, DateTime expiresAt);

  Future<void> clear();

  /// Newer stores preserve the original deadline across a controller reload.
  /// Legacy test doubles implementing only [read] continue to work with a
  /// null deadline; the controller applies its bounded fallback TTL.
  Future<PendingInviteRecord?> readRecord() async {
    final token = await read();
    return token == null ? null : PendingInviteRecord(token: token);
  }
}

/// Deterministic fallback for native platforms and tests.  The value is held
/// only for this store instance and is dropped when the controller is
/// disposed.
class MemoryPendingInviteStore implements PendingInviteStore {
  String? _token;
  DateTime? _expiresAt;

  @override
  Future<String?> read() async {
    return (await readRecord())?.token;
  }

  @override
  Future<PendingInviteRecord?> readRecord() async {
    final token = _token;
    final expiresAt = _expiresAt;
    if (token == null || expiresAt == null) return null;
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      await clear();
      return null;
    }
    return PendingInviteRecord(token: token, expiresAt: expiresAt);
  }

  @override
  Future<void> write(String token, DateTime expiresAt) async {
    _token = token;
    _expiresAt = expiresAt.toUtc();
  }

  @override
  Future<void> clear() async {
    _token = null;
    _expiresAt = null;
  }
}
