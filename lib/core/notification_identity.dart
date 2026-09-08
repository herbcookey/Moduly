import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/notification_models.dart';

/// 알림 식별자는 표시 텍스트와 무관하다. 따라서 제목/메모를 바꿔도 알림이 하나 더
/// 남지 않으며, 간격/채널이 바뀌면 새 키를 받고 이전 키는 취소할 수 있다.
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

  /// 길이 정보를 붙인 필드는 모호한 연결(`ab|c`와 `a|bc`)을 피하고 이 다이제스트에
  /// 사용자 표시 내용이 포함되지 않게 한다.
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

/// 영속성은 의도적으로 추상화한다. 플랫폼은 작은 영구 키-값 저장소를 사용할 수 있고
/// 테스트/로컬 데모는 메모리를 사용한다. 할당기는 항상 사용자를 기준으로 행 범위를
/// 제한하며 제목/메모/토큰 자료는 저장하지 않는다.
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

/// 충돌 해결 결과를 저장하는 안정적인 양의 31비트 플랫폼 ID다. 선형 탐색은 주어진
/// 레지스트리 스냅샷에서 결정론적으로 동작하며, 손상되거나 악의적인 레지스트리가
/// 무한 루프를 만들지 못하도록 엄격한 상한을 둔다.
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
            // 영구 저장소가 전체 복사본을 받아들인 뒤에만 소유권을 공개한다.
            // 쓰기가 실패하면 캐시와 레지스트리를 모두 변경하지 않는다.
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

  /// 숫자 ID가 [ids]에 있는 할당기 항목만 유지한다.
  ///
  /// 할당기 관점에서 이 작업은 트랜잭션 방식이다. 레지스트리가 새 맵을 받아들인
  /// 뒤에만 메모리 스냅샷을 교체한다. 호출자는 신뢰할 수 있는 조정이 오래된
  /// 플랫폼 요청을 모두 성공적으로 취소한 뒤에만 이를 호출해야 한다. 알 수 없는
  /// ID는 만들지 않으므로 네이티브 대기 요청이 소유권 정보를 오염시키지 않는다.
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
    // 영속화 작업 하나가 실패해도 이후 재시도를 망치지 않도록 대기열 끝은 완료된
    // 상태로 유지한다. 사용자별 대기열은 같은 충돌 버킷에서 경합하는 직접
    // 호출자도 순차 처리한다.
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
