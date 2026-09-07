import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/notification_models.dart';

/// A notification identity is independent of presentation text.  Changing a
/// title/note therefore does not leave a second notification behind, while a
/// changed offset/channel gets a new key and the old key can be cancelled.
class ReminderIdentity {
  const ReminderIdentity({
    required this.userId,
    required this.eventId,
    required this.occurrenceKey,
    required this.offsetValue,
    required this.offsetUnit,
    required this.channel,
  });

  final String userId;
  final String eventId;
  final String occurrenceKey;
  final int offsetValue;
  final NotificationOffsetUnit offsetUnit;
  final NotificationChannel channel;

  /// Length-framed fields avoid ambiguous concatenations (`ab|c` vs `a|bc`)
  /// and keep this digest free of user-visible content.
  String get framedKey => <String>[
    'v1',
    _frame(userId),
    _frame(eventId),
    _frame(occurrenceKey),
    _frame(offsetUnit.wireName),
    _frame(offsetValue.toString()),
    _frame(channel.wireName),
  ].join();

  String get stableKey => framedKey;

  Map<String, Object> toJson() => <String, Object>{
    'v': 1,
    'user_id': userId,
    'event_id': eventId,
    'occurrence_key': occurrenceKey,
    'offset_unit': offsetUnit.wireName,
    'offset_value': offsetValue,
    'channel': channel.wireName,
  };

  static String _frame(String value) => '${value.length}:$value;';

  @override
  bool operator ==(Object other) =>
      other is ReminderIdentity && other.framedKey == framedKey;

  @override
  int get hashCode => framedKey.hashCode;
}

class NotificationIdEntry {
  const NotificationIdEntry({required this.id, required this.key});

  final int id;
  final String key;
}

/// Persistence is intentionally abstract.  A platform may back this with a
/// small durable key-value store, while tests/local demo use memory.  The
/// allocator always scopes rows by user and never stores title/note/token
/// material.
abstract interface class NotificationIdRegistry {
  Future<Map<int, String>> load(String userId);
  Future<void> save(String userId, Map<int, String> entries);
}

class InMemoryNotificationIdRegistry implements NotificationIdRegistry {
  final Map<String, Map<int, String>> _entries = <String, Map<int, String>>{};

  @override
  Future<Map<int, String>> load(String userId) async =>
      Map<int, String>.unmodifiable(_entries[userId] ?? const <int, String>{});

  @override
  Future<void> save(String userId, Map<int, String> entries) async {
    _entries[userId] = Map<int, String>.from(entries);
  }
}

/// Stable positive 31-bit platform IDs with persisted collision resolution.
/// The linear probe is deterministic for a given registry snapshot and keeps
/// a hard cap so a corrupt/hostile registry cannot create an unbounded loop.
class NotificationIdAllocator {
  NotificationIdAllocator({
    NotificationIdRegistry? registry,
    this.maxProbe = 4096,
  }) : registry = registry ?? InMemoryNotificationIdRegistry() {
    if (maxProbe < 1 || maxProbe > 1 << 20) {
      throw ArgumentError.value(maxProbe, 'maxProbe');
    }
  }

  static const int maxPositive31Bit = 0x7fffffff;
  final NotificationIdRegistry registry;
  final int maxProbe;
  final Map<String, Map<int, String>> _loaded = <String, Map<int, String>>{};
  final Map<String, Future<void>> _userQueues = <String, Future<void>>{};

  Future<int> idFor(ReminderIdentity identity) =>
      _serializedForUser(identity.userId, (normalizedUserId) async {
        final entries = await _entriesForUnlocked(normalizedUserId);
        final key = identity.stableKey;
        for (final entry in entries.entries) {
          if (entry.value == key) return entry.key;
        }
        final digest = sha256.convert(utf8.encode(key)).bytes;
        var candidate = 0;
        for (var i = 0; i < 4 && i < digest.length; i++) {
          candidate = (candidate << 8) | digest[i];
        }
        candidate &= maxPositive31Bit;
        if (candidate == 0) candidate = 1;
        final nextEntries = Map<int, String>.from(entries);
        for (var probe = 0; probe < maxProbe; probe++) {
          final id = ((candidate - 1 + probe) % maxPositive31Bit) + 1;
          final owner = nextEntries[id];
          if (owner == null || owner == key) {
            nextEntries[id] = key;
            // Publish ownership only after durable storage accepts the complete
            // copy. A failed write leaves both cache and registry unchanged.
            await registry.save(normalizedUserId, nextEntries);
            _loaded[normalizedUserId] = nextEntries;
            return id;
          }
        }
        throw StateError('알림 식별자를 할당할 수 없습니다.');
      });

  Future<List<NotificationIdEntry>> entriesFor(String userId) =>
      _serializedForUser(userId, (normalizedUserId) async {
        final entries = await _entriesForUnlocked(normalizedUserId);
        return List<NotificationIdEntry>.unmodifiable(
          entries.entries.map(
            (entry) => NotificationIdEntry(id: entry.key, key: entry.value),
          ),
        );
      });

  Future<void> forget(String userId, ReminderIdentity identity) =>
      _serializedForUser(userId, (normalizedUserId) async {
        if (identity.userId != normalizedUserId) {
          throw const FormatException('사용자 식별자를 확인해 주세요.');
        }
        final entries = await _entriesForUnlocked(normalizedUserId);
        final key = identity.stableKey;
        final retained = Map<int, String>.from(entries)
          ..removeWhere((_, value) => value == key);
        if (retained.length == entries.length) return;
        await registry.save(normalizedUserId, retained);
        _loaded[normalizedUserId] = retained;
      });

  Future<void> clearUser(String userId) =>
      _serializedForUser(userId, (normalizedUserId) async {
        await registry.save(normalizedUserId, const <int, String>{});
        _loaded.remove(normalizedUserId);
      });

  /// Retains only allocator entries whose numeric IDs are in [ids].
  ///
  /// The operation is transactional from the allocator's point of view: the
  /// in-memory snapshot is replaced only after the registry accepts the new
  /// map. Callers should invoke this only after an authoritative reconcile
  /// has successfully cancelled every stale platform request. Unknown IDs
  /// are not created, so native pending requests do not pollute ownership.
  Future<void> retainIds(String userId, Iterable<int> ids) =>
      _serializedForUser(userId, (normalizedUserId) async {
        final keep = ids.toSet();
        if (keep.any(
          (id) => id < 1 || id > NotificationIdAllocator.maxPositive31Bit,
        )) {
          throw const FormatException('알림 식별자를 확인해 주세요.');
        }
        final entries = await _entriesForUnlocked(normalizedUserId);
        final retained = <int, String>{
          for (final entry in entries.entries)
            if (keep.contains(entry.key)) entry.key: entry.value,
        };
        if (retained.length == entries.length) return;
        await registry.save(normalizedUserId, retained);
        _loaded[normalizedUserId] = retained;
      });

  Future<T> _serializedForUser<T>(
    String userId,
    Future<T> Function(String normalizedUserId) operation,
  ) {
    final normalized = userId.trim();
    if (normalized.isEmpty || normalized != userId) {
      return Future<T>.error(const FormatException('사용자 식별자를 확인해 주세요.'));
    }
    final previous = _userQueues[normalized] ?? Future<void>.value();
    final next = previous.then<T>(
      (_) => operation(normalized),
      onError: (Object _, StackTrace _) => operation(normalized),
    );
    // Keep queue tails resolved so one failed persistence operation does not
    // poison later retries. Per-user queues also serialize direct callers
    // that race on the same collision bucket.
    _userQueues[normalized] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<Map<int, String>> _entriesForUnlocked(String normalized) async {
    final cached = _loaded[normalized];
    if (cached != null) return cached;
    final loaded = await registry.load(normalized);
    final copy = Map<int, String>.from(loaded);
    for (final entry in copy.entries) {
      if (entry.key < 1 ||
          entry.key > maxPositive31Bit ||
          entry.value.isEmpty) {
        throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
      }
    }
    _loaded[normalized] = copy;
    return copy;
  }
}
