import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notification_identity.dart';

/// Small async key/value seam used by the durable notification-ID registry.
/// Keeping it separate from [SharedPreferencesAsync] makes malformed-storage
/// and reload behavior testable without a native platform channel.
abstract interface class NotificationStringStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// Production [NotificationStringStore] backed by the non-cached async
/// SharedPreferences API. The registry serializes writes so two reconciliation
/// callbacks cannot interleave individual platform writes.
class SharedPreferencesAsyncStringStore implements NotificationStringStore {
  SharedPreferencesAsyncStringStore({SharedPreferencesAsync? preferences})
    : preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync preferences;

  @override
  Future<String?> read(String key) => preferences.getString(key);

  @override
  Future<void> write(String key, String value) =>
      preferences.setString(key, value);
}

/// Durable registry for the allocator's positive 31-bit IDs.
///
/// Values contain only a versioned list of `(numeric id, framed identity)`
/// entries. User namespaces are SHA-256 digests, so the preferences key does
/// not reveal an account identifier. Unknown/malformed storage fails closed
/// with [FormatException]; it is never silently treated as an empty registry.
class SharedPreferencesAsyncNotificationIdRegistry
    implements NotificationIdRegistry {
  SharedPreferencesAsyncNotificationIdRegistry({
    NotificationStringStore? store,
    SharedPreferencesAsync? preferences,
  }) : store =
           store ??
           SharedPreferencesAsyncStringStore(preferences: preferences) {
    if (store != null && preferences != null) {
      throw ArgumentError('store and preferences cannot both be supplied');
    }
  }

  static const String keyPrefix = 'moduly_notification_ids_v1_';
  static const int schemaVersion = 1;
  static const int maxEntries = 4096;
  static const int maxIdentityLength = 4096;
  static const int _framedFieldCount = 6;

  final NotificationStringStore store;
  Future<void> _writeQueue = Future<void>.value();

  /// Exposed for tests and diagnostics; it is a one-way digest and contains
  /// no raw user identifier.
  String storageKeyForUser(String userId) {
    final normalized = _normalizeUserId(userId);
    final digest = sha256.convert(utf8.encode(normalized)).toString();
    return '$keyPrefix$digest';
  }

  @override
  Future<Map<int, String>> load(String userId) {
    final key = storageKeyForUser(userId);
    return _serialized(() async {
      final raw = await _readSafely(key);
      if (raw == null) return const <int, String>{};
      return _decode(raw, expectedUserId: _normalizeUserId(userId));
    });
  }

  @override
  Future<void> save(String userId, Map<int, String> entries) {
    final normalizedUserId = _normalizeUserId(userId);
    final copy = _validateEntries(entries, expectedUserId: normalizedUserId);
    final encoded = jsonEncode(<String, Object>{
      'v': schemaVersion,
      'entries': copy.entries
          .map((entry) => <String, Object>{'id': entry.key, 'key': entry.value})
          .toList(growable: false),
    });
    return _serialized(
      () => store.write(storageKeyForUser(normalizedUserId), encoded),
    );
  }

  Future<String?> _readSafely(String key) async {
    try {
      return await store.read(key);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('알림 식별자 저장소를 읽을 수 없습니다.');
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    // Keep the queue itself error-free so one failed platform operation does
    // not prevent a later settings retry from reaching SharedPreferences.
    final result = _writeQueue.then<T>((_) => operation());
    _writeQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return result;
  }

  static String _normalizeUserId(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty || normalized != userId) {
      throw const FormatException('사용자 식별자를 확인해 주세요.');
    }
    return normalized;
  }

  Map<int, String> _decode(String encoded, {required String expectedUserId}) {
    if (encoded.length > maxEntries * (maxIdentityLength + 32)) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } catch (_) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    final raw = decoded.cast<String, dynamic>();
    if (raw.length != 2 ||
        raw['v'] != schemaVersion ||
        raw['entries'] is! List) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    final rows = raw['entries'] as List;
    if (rows.length > maxEntries) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    final entries = <int, String>{};
    final identities = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row.keys.any((key) => key is! String) ||
          row.length != 2 ||
          row['id'] is! int ||
          row['key'] is! String) {
        throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
      }
      final id = row['id'] as int;
      final identity = row['key'] as String;
      if (!_validId(id) ||
          !_validFramedIdentity(identity, expectedUserId: expectedUserId) ||
          !identities.add(identity) ||
          entries.containsKey(id)) {
        throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
      }
      entries[id] = identity;
    }
    return Map<int, String>.unmodifiable(entries);
  }

  Map<int, String> _validateEntries(
    Map<int, String> source, {
    required String expectedUserId,
  }) {
    if (source.length > maxEntries) {
      throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
    }
    final entries = <int, String>{};
    final identities = <String>{};
    for (final entry in source.entries) {
      if (!_validId(entry.key) ||
          !_validFramedIdentity(entry.value, expectedUserId: expectedUserId) ||
          !identities.add(entry.value)) {
        throw const FormatException('알림 식별자 저장소를 확인해 주세요.');
      }
      entries[entry.key] = entry.value;
    }
    final sorted = entries.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return <int, String>{for (final entry in sorted) entry.key: entry.value};
  }

  static bool _validId(int id) =>
      id >= 1 && id <= NotificationIdAllocator.maxPositive31Bit;

  static bool _validFramedIdentity(
    String value, {
    required String expectedUserId,
  }) {
    if (value.length > maxIdentityLength || !value.startsWith('v1')) {
      return false;
    }
    var offset = 2;
    final fields = <String>[];
    for (var index = 0; index < _framedFieldCount; index += 1) {
      final colon = value.indexOf(':', offset);
      if (colon <= offset) return false;
      final lengthText = value.substring(offset, colon);
      final length = int.tryParse(lengthText);
      if (length == null || length < 1 || length > maxIdentityLength) {
        return false;
      }
      final start = colon + 1;
      final end = start + length;
      if (end >= value.length || value.codeUnitAt(end) != 0x3b) {
        return false;
      }
      fields.add(value.substring(start, end));
      offset = end + 1;
    }
    if (offset != value.length ||
        fields.length != _framedFieldCount ||
        fields[0] != expectedUserId ||
        fields[1].isEmpty ||
        fields[2].isEmpty ||
        (fields[3] != 'seconds' && fields[3] != 'calendar_days') ||
        int.tryParse(fields[4]) == null ||
        (fields[5] != 'local' && fields[5] != 'push')) {
      return false;
    }
    return true;
  }
}
