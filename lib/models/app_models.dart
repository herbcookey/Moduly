import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 서버 기반 일정 검색 계약이 강제하는 범위다. 검색어는 UTF-16 코드 단위가 아니라
/// Unicode 스칼라 값(`String.runes`)으로 세어 이모지와 보조 평면 문자가
/// 로컬 및 원격 어댑터에서 같은 의미를 갖게 한다.
const int eventSearchMinScalars = 2;
const int eventSearchMaxScalars = 100;
const int eventSearchMaxUtf8Bytes = 400;
const int eventSearchDefaultPageSize = 50;

/// 일정 검색어 하나의 공백을 정리하고 검증한다. 빈 입력은 의도적으로 허용하며
/// 기간/필터 전용 검색을 뜻한다. 비어 있지 않은 검색어는 Unicode 스칼라 값 2~100개,
/// UTF-8 기준 최대 400바이트여야 한다. 잘못된 입력이 네트워크 요청으로 이어지지 않도록
/// 저장소는 로컬 작업이나 RPC 전에 이 도우미를 호출한다.
String normalizeEventSearchQuery(String query) {
  final normalized = query.trim();
  if (normalized.isEmpty) return normalized;
  final scalarCount = normalized.runes.length;
  if (scalarCount < eventSearchMinScalars ||
      scalarCount > eventSearchMaxScalars ||
      utf8.encode(normalized).length > eventSearchMaxUtf8Bytes) {
    throw const FormatException('검색어는 2~100자(UTF-8 400바이트 이내)로 입력해 주세요.');
  }
  return normalized;
}

/// 저장소/컨트롤러가 사용하는 예외 문구를 노출하지 않고 텍스트 필드를 검증할 때
/// 유용한 공개 조건 함수다.
bool isValidEventSearchQuery(String query) {
  try {
    normalizeEventSearchQuery(query);
    return true;
  } on FormatException {
    return false;
  }
}

/// Supabase 일정 행과 v1 범위 커서가 사용하는 명시적 오프셋 포함 ISO-8601
/// 타임스탬프 형식을 파싱한다. Dart의 [DateTime.parse]는 존재할 수 없는 캘린더/시각
/// 구성 요소(예: 2월 30일)를 정규화하므로 UTC 시각을 만들기 전에 전송 값을 구성
/// 요소별로 검증한다. Postgres는 소수점 이하 최대 6자리와 함께 `Z` 또는
/// `+/-HH:MM` 오프셋을 출력하며 이 형식들을 계속 지원한다.
DateTime? parseStrictExplicitOffsetTimestamp(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  final second = int.tryParse(match.group(6)!);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null ||
      month < 1 ||
      month > 12 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  final calendar = DateTime.utc(year, month, day);
  if (calendar.year != year || calendar.month != month || calendar.day != day) {
    return null;
  }
  final fraction = match.group(7) ?? '';
  final micros = fraction.isEmpty ? 0 : int.parse(fraction.padRight(6, '0'));
  final base = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    micros ~/ 1000,
    micros % 1000,
  );
  final zone = match.group(8)!;
  if (zone == 'Z') return base;
  final offsetHour = int.parse(zone.substring(1, 3));
  final offsetMinute = int.parse(zone.substring(4, 6));
  if (offsetHour > 23 || offsetMinute > 59) return null;
  final sign = zone.codeUnitAt(0) == 45 ? -1 : 1;
  return base.subtract(
    Duration(minutes: sign * (offsetHour * 60 + offsetMinute)),
  );
}

/// 방어적으로 중복을 제거한 참여자 목록을 하나의 표준 사전식 순서로 반환한다.
/// 저장소는 모든 ID가 일정 그룹의 활성 멤버십에 속하는지 권한을 확인한다. 모델
/// 경계에서 정렬하면 호출자나 전송 계층이 다른 행 순서를 반환해도 로컬, RPC,
/// 실시간 하위 프로젝션이 같게 유지된다.
List<String> canonicalEventMemberIds(Iterable<String> memberIds) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in memberIds) {
    final id = raw.trim();
    if (id.isEmpty) {
      throw const FormatException('일정 멤버를 확인해 주세요.');
    }
    if (seen.add(id)) result.add(id);
  }
  result.sort();
  return List<String>.unmodifiable(result);
}

/// v2 전송 형식 계약이 저장하는 유일한 반복 주기다.
enum RecurrenceFrequency { daily, weekly, monthly }

extension RecurrenceFrequencyWire on RecurrenceFrequency {
  String get wireName => switch (this) {
    RecurrenceFrequency.daily => 'daily',
    RecurrenceFrequency.weekly => 'weekly',
    RecurrenceFrequency.monthly => 'monthly',
  };

  static RecurrenceFrequency parse(Object? value) => switch (value) {
    'daily' => RecurrenceFrequency.daily,
    'weekly' => RecurrenceFrequency.weekly,
    'monthly' => RecurrenceFrequency.monthly,
    _ => throw const FormatException('반복 규칙을 확인해 주세요.'),
  };
}

enum RecurrenceEnd { never, count, until }

extension RecurrenceEndWire on RecurrenceEnd {
  String get wireName => switch (this) {
    RecurrenceEnd.never => 'never',
    RecurrenceEnd.count => 'count',
    RecurrenceEnd.until => 'until',
  };

  static RecurrenceEnd parse(Object? value) => switch (value) {
    'never' => RecurrenceEnd.never,
    'count' => RecurrenceEnd.count,
    'until' => RecurrenceEnd.until,
    _ => throw const FormatException('반복 종료 조건을 확인해 주세요.'),
  };
}

/// 반복 발생 항목 변경에 사용하는 범위다. `this`는 Dart 키워드이므로 대신
/// `thisOccurrence`라는 이름을 쓰며 전송 값은 정확히 `this`다.
enum EventEditScope { thisOccurrence, future, all }

extension EventEditScopeWire on EventEditScope {
  String get wireName => switch (this) {
    EventEditScope.thisOccurrence => 'this',
    EventEditScope.future => 'future',
    EventEditScope.all => 'all',
  };

  static EventEditScope parse(Object? value) => switch (value) {
    'this' => EventEditScope.thisOccurrence,
    'future' => EventEditScope.future,
    'all' => EventEditScope.all,
    _ => throw const FormatException('일정 변경 범위를 확인해 주세요.'),
  };
}

DateTime? _strictDateOnly(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final year = int.tryParse(value.substring(0, 4));
  final month = int.tryParse(value.substring(5, 7));
  final day = int.tryParse(value.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  final result = DateTime.utc(year, month, day);
  return result.year == year && result.month == month && result.day == day
      ? DateTime(year, month, day)
      : null;
}

int _strictIntegral(Object? value) {
  if (value is int) return value;
  throw const FormatException('반복 규칙을 확인해 주세요.');
}

/// 검증된 불변 반복 규칙이다. JSON 표현은 의도적으로 엄격하게 유지한다. 알 수 없는
/// 필드를 추가하거나 잘못된 종료 모드에서 종료 전용 필드를 사용하면 조용히 무시하지
/// 않고 거부한다.
@immutable
class RecurrenceRule {
  RecurrenceRule({
    required this.frequency,
    this.interval = 1,
    Iterable<int> weekdays = const <int>[],
    this.end = RecurrenceEnd.never,
    this.count,
    DateTime? untilDate,
    this.monthlyDay,
  }) : weekdays = _validateWeekdays(frequency, weekdays),
       untilDate = untilDate == null
           ? null
           : DateTime(untilDate.year, untilDate.month, untilDate.day) {
    if (untilDate != null &&
        (untilDate.hour != 0 ||
            untilDate.minute != 0 ||
            untilDate.second != 0 ||
            untilDate.millisecond != 0 ||
            untilDate.microsecond != 0)) {
      throw const FormatException('반복 종료 날짜를 확인해 주세요.');
    }
    if (interval < 1 || interval > 999) {
      throw const FormatException('반복 간격을 확인해 주세요.');
    }
    if (frequency == RecurrenceFrequency.monthly &&
        (monthlyDay == null || monthlyDay! < 1 || monthlyDay! > 31)) {
      throw const FormatException('반복 날짜를 확인해 주세요.');
    }
    if (frequency != RecurrenceFrequency.monthly && monthlyDay != null) {
      throw const FormatException('반복 규칙을 확인해 주세요.');
    }
    switch (end) {
      case RecurrenceEnd.never:
        if (count != null || this.untilDate != null) {
          throw const FormatException('반복 종료 조건을 확인해 주세요.');
        }
      case RecurrenceEnd.count:
        if (count == null ||
            count! < 1 ||
            count! > 1000000 ||
            this.untilDate != null) {
          throw const FormatException('반복 횟수를 확인해 주세요.');
        }
      case RecurrenceEnd.until:
        if (this.untilDate == null || count != null) {
          throw const FormatException('반복 종료 날짜를 확인해 주세요.');
        }
    }
  }

  final RecurrenceFrequency frequency;
  final int interval;
  final List<int> weekdays;
  final RecurrenceEnd end;
  final int? count;
  final DateTime? untilDate;
  final int? monthlyDay;

  static List<int> _validateWeekdays(
    RecurrenceFrequency frequency,
    Iterable<int> values,
  ) {
    final supplied = values.toList(growable: false);
    if (supplied.any((value) => value < 1 || value > 7)) {
      throw const FormatException('반복 요일을 확인해 주세요.');
    }
    for (var index = 1; index < supplied.length; index++) {
      if (supplied[index - 1] >= supplied[index]) {
        throw const FormatException('반복 요일은 중복 없이 오름차순이어야 합니다.');
      }
    }
    final result = supplied.toList(growable: true);
    if (frequency == RecurrenceFrequency.weekly && result.isEmpty) {
      throw const FormatException('주간 반복 요일을 선택해 주세요.');
    }
    if (frequency != RecurrenceFrequency.weekly && result.isNotEmpty) {
      throw const FormatException('반복 요일은 주간 반복에서만 사용할 수 있습니다.');
    }
    return List<int>.unmodifiable(result);
  }

  factory RecurrenceRule.fromJson(Object? input) {
    if (input is! Map || input.keys.any((key) => key is! String)) {
      throw const FormatException('반복 규칙을 확인해 주세요.');
    }
    final raw = input.cast<String, dynamic>();
    const keys = <String>{
      'frequency',
      'interval',
      'weekdays',
      'end',
      'count',
      'until_date',
      'monthly_day',
    };
    if (raw.length != keys.length ||
        raw.keys.toSet().difference(keys).isNotEmpty) {
      throw const FormatException('반복 규칙을 확인해 주세요.');
    }
    final frequency = RecurrenceFrequencyWire.parse(raw['frequency']);
    final interval = _strictIntegral(raw['interval']);
    final end = RecurrenceEndWire.parse(raw['end']);
    final weekdaysRaw = raw['weekdays'];
    if (weekdaysRaw is! List || weekdaysRaw.any((value) => value is! int)) {
      throw const FormatException('반복 요일을 확인해 주세요.');
    }
    final count = raw['count'] == null ? null : _strictIntegral(raw['count']);
    final untilDate = raw['until_date'] == null
        ? null
        : _strictDateOnly(raw['until_date']);
    if (raw['until_date'] != null && untilDate == null) {
      throw const FormatException('반복 종료 날짜를 확인해 주세요.');
    }
    final monthlyDay = raw['monthly_day'] == null
        ? null
        : _strictIntegral(raw['monthly_day']);
    return RecurrenceRule(
      frequency: frequency,
      interval: interval,
      weekdays: weekdaysRaw.cast<int>(),
      end: end,
      count: count,
      untilDate: untilDate,
      monthlyDay: monthlyDay,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'frequency': frequency.wireName,
    'interval': interval,
    'weekdays': weekdays,
    'end': end.wireName,
    'count': count,
    'until_date': untilDate == null ? null : _dateOnlyString(untilDate!),
    'monthly_day': monthlyDay,
  };

  RecurrenceRule copyWith({
    RecurrenceFrequency? frequency,
    int? interval,
    Iterable<int>? weekdays,
    RecurrenceEnd? end,
    int? count,
    DateTime? untilDate,
    int? monthlyDay,
    bool clearCount = false,
    bool clearUntilDate = false,
    bool clearMonthlyDay = false,
  }) {
    return RecurrenceRule(
      frequency: frequency ?? this.frequency,
      interval: interval ?? this.interval,
      weekdays: weekdays ?? this.weekdays,
      end: end ?? this.end,
      count: clearCount ? null : (count ?? this.count),
      untilDate: clearUntilDate ? null : (untilDate ?? this.untilDate),
      monthlyDay: clearMonthlyDay ? null : (monthlyDay ?? this.monthlyDay),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecurrenceRule &&
      other.frequency == frequency &&
      other.interval == interval &&
      listEquals(other.weekdays, weekdays) &&
      other.end == end &&
      other.count == count &&
      other.untilDate == untilDate &&
      other.monthlyDay == monthlyDay;

  @override
  int get hashCode => Object.hash(
    frequency,
    interval,
    Object.hashAll(weekdays),
    end,
    count,
    untilDate,
    monthlyDay,
  );
}

/// 빌더에서 사용하기 편한 값 객체다. 의도적으로 [RecurrenceRule]의 검증을
/// 우회하지 않으며 [toRule]이 유일한 변환 경계다.
@immutable
class RecurrenceRuleDraft {
  RecurrenceRuleDraft({
    required this.frequency,
    this.interval = 1,
    Iterable<int> weekdays = const <int>[],
    this.end = RecurrenceEnd.never,
    this.count,
    this.untilDate,
    this.monthlyDay,
  }) : weekdays = List<int>.unmodifiable(weekdays);

  final RecurrenceFrequency frequency;
  final int interval;
  final List<int> weekdays;
  final RecurrenceEnd end;
  final int? count;
  final DateTime? untilDate;
  final int? monthlyDay;

  RecurrenceRule toRule() => RecurrenceRule(
    frequency: frequency,
    interval: interval,
    weekdays: weekdays,
    end: end,
    count: count,
    untilDate: untilDate,
    monthlyDay: monthlyDay,
  );
}

String _dateOnlyString(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

/// PostgreSQL 반복 순번은 부호 있는 `bigint`다. 전송 키는 고정 너비의 10진수로
/// 유지하되, 데이터베이스가 표현할 수 없는 20자리 키를 허용하지 않고 bigint의
/// 부호 있는 최댓값을 넘는 값은 거부한다.
final BigInt maxOccurrenceOrdinal = BigInt.parse('9223372036854775807');

String occurrenceKeyForIndex(int index) {
  if (index < 0 || BigInt.from(index) > maxOccurrenceOrdinal) {
    throw const FormatException('반복 일정 식별자를 확인해 주세요.');
  }
  return 'o${index.toString().padLeft(20, '0')}';
}

final RegExp _occurrenceKeyPattern = RegExp(r'^o\d{20}$');

int? occurrenceIndexFromKey(Object? key) {
  if (key == 'single') return null;
  if (key is! String || !_occurrenceKeyPattern.hasMatch(key)) return null;
  final value = BigInt.tryParse(key.substring(1));
  if (value == null || value < BigInt.zero || value > maxOccurrenceOrdinal) {
    return null;
  }
  // 허용된 모든 순번은 지원되는 Flutter VM의 Dart 부호 있는 64비트 정수 범위 안에
  // 있으므로 이 변환에서 값이 잘리거나 래핑될 수 없다.
  return value.toInt();
}

bool isValidOccurrenceKey(Object? key) {
  if (key == 'single') return true;
  if (key is! String || !_occurrenceKeyPattern.hasMatch(key)) return false;
  final ordinal = BigInt.tryParse(key.substring(1));
  return ordinal != null &&
      ordinal >= BigInt.zero &&
      ordinal <= maxOccurrenceOrdinal;
}

@immutable
class RecurrenceMutationReceipt {
  RecurrenceMutationReceipt({
    required this.groupId,
    required this.eventId,
    required this.occurrenceKey,
    required this.seriesVersion,
    required this.occurrenceVersion,
    required this.scope,
    this.committed = true,
    this.changed = true,
  }) {
    if (groupId.trim().isEmpty ||
        eventId.trim().isEmpty ||
        !isValidOccurrenceKey(occurrenceKey) ||
        seriesVersion < 0 ||
        occurrenceVersion < 0 ||
        !committed) {
      throw FormatException('일정 변경 응답을 확인해 주세요.');
    }
  }

  final String groupId;
  final String eventId;
  final String occurrenceKey;
  final int seriesVersion;
  final int occurrenceVersion;
  final EventEditScope scope;
  final bool committed;
  final bool changed;

  factory RecurrenceMutationReceipt.fromJson(Object? input) {
    if (input is! Map || input.keys.any((key) => key is! String)) {
      throw const FormatException('일정 변경 응답을 확인해 주세요.');
    }
    final raw = input.cast<String, dynamic>();
    const keys = <String>{
      'group_id',
      'event_id',
      'occurrence_key',
      'series_version',
      'occurrence_version',
      'scope',
      'committed',
      'changed',
    };
    if (raw.length != keys.length ||
        raw.keys.toSet().difference(keys).isNotEmpty ||
        !keys.every(raw.containsKey) ||
        raw['group_id'] is! String ||
        raw['event_id'] is! String ||
        raw['occurrence_key'] is! String ||
        raw['committed'] != true ||
        raw['changed'] is! bool) {
      throw const FormatException('일정 변경 응답을 확인해 주세요.');
    }
    return RecurrenceMutationReceipt(
      groupId: raw['group_id'] as String,
      eventId: raw['event_id'] as String,
      occurrenceKey: raw['occurrence_key'] as String,
      seriesVersion: _strictIntegral(raw['series_version']),
      occurrenceVersion: _strictIntegral(raw['occurrence_version']),
      scope: EventEditScopeWire.parse(raw['scope']),
      committed: raw['committed'] as bool,
      changed: raw['changed'] as bool,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'group_id': groupId,
    'event_id': eventId,
    'occurrence_key': occurrenceKey,
    'series_version': seriesVersion,
    'occurrence_version': occurrenceVersion,
    'scope': scope.wireName,
    'committed': committed,
    'changed': changed,
  };
}

@immutable
class PlannerUser {
  const PlannerUser({required this.id, required this.email, this.displayName});

  final String id;
  final String email;
  final String? displayName;
}

@immutable
class PlannerGroup {
  const PlannerGroup({
    required this.id,
    required this.name,
    this.description = '',
    this.timezone = 'UTC',
    this.version = 1,
    this.colorValue = 0xff476a6f,
    this.ownerId,
    this.archivedAt,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String description;
  final String timezone;
  final int version;
  final int colorValue;

  /// 데이터베이스에 기록된 불변 소유자다. 이전/로컬 픽스처는 이 필드를 생략하고
  /// 활성 멤버 목록에서 소유권을 유도할 수 있다.
  final String? ownerId;

  /// 선택적인 수명 주기 표시다. 현재 프로덕션 스키마는 보관된 그룹에
  /// `deleted_at`을 사용하지만 일부 클라이언트는 이 상태를 `archivedAt`으로 노출한다.
  /// 둘 다 유지하면 모델을 확장 가능하게 두면서 어느 페이로드 형식도 허용할 수 있다.
  final DateTime? archivedAt;
  final DateTime? deletedAt;

  bool get isArchived => archivedAt != null || deletedAt != null;
  bool get isDeleted => deletedAt != null;

  PlannerGroup copyWith({
    String? id,
    String? name,
    String? description,
    String? timezone,
    int? version,
    int? colorValue,
    String? ownerId,
    DateTime? archivedAt,
    DateTime? deletedAt,
    bool clearOwnerId = false,
    bool clearArchivedAt = false,
    bool clearDeletedAt = false,
  }) {
    return PlannerGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      timezone: timezone ?? this.timezone,
      version: version ?? this.version,
      colorValue: colorValue ?? this.colorValue,
      ownerId: clearOwnerId ? null : (ownerId ?? this.ownerId),
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlannerGroup &&
        other.id == id &&
        other.name == name &&
        other.description == description &&
        other.timezone == timezone &&
        other.version == version &&
        other.colorValue == colorValue &&
        other.ownerId == ownerId &&
        other.archivedAt == archivedAt &&
        other.deletedAt == deletedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    timezone,
    version,
    colorValue,
    ownerId,
    archivedAt,
    deletedAt,
  );
}

@immutable
class PlannerMember {
  const PlannerMember({
    required this.id,
    required this.name,
    required this.email,
    this.isOwner = false,
    this.isActive = true,
    this.removedAt,
    this.avatarColor = 0xff476a6f,
  });

  final String id;
  final String name;
  final String email;
  final bool isOwner;
  final bool isActive;
  final DateTime? removedAt;
  final int avatarColor;

  PlannerMember copyWith({
    String? id,
    String? name,
    String? email,
    bool? isOwner,
    bool? isActive,
    DateTime? removedAt,
    int? avatarColor,
    bool clearRemovedAt = false,
  }) {
    return PlannerMember(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      isOwner: isOwner ?? this.isOwner,
      isActive: isActive ?? this.isActive,
      removedAt: clearRemovedAt ? null : (removedAt ?? this.removedAt),
      avatarColor: avatarColor ?? this.avatarColor,
    );
  }
}

@immutable
class InviteCode {
  const InviteCode({
    required this.id,
    required this.groupId,
    required this.expiresAt,
    required this.maxUses,
    required this.usesCount,
    required this.version,
    this.token,
    this.revokedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? expiresAt,
       updatedAt = updatedAt ?? expiresAt;

  final String id;
  final String groupId;
  final DateTime expiresAt;
  final int maxUses;
  final int usesCount;
  final int version;

  /// 평문은 생성 RPC에서 한 번만 반환하며 행에는 저장하지 않는다.
  final String? token;
  final DateTime? revokedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isRevoked => revokedAt != null;

  /// 만료 시각을 포함한다. 정확히 `now`인 토큰은 더는 사용할 수 없다. 이 경계를
  /// 데이터베이스 조건자와 같게 유지하면 만료 시점 주변의 로컬 미리보기/수락
  /// 경합을 피할 수 있다.
  bool get isExpired => !expiresAt.isAfter(DateTime.now().toUtc());
  bool get isExhausted => usesCount >= maxUses;
}

/// `preview_invite(p_token)`가 반환하는 최소한으로 정제된 미리보기다.
///
/// 서버는 사용 횟수, 취소 플래그, 토큰 자료와 기타 초대 메타데이터를 의도적으로 생략한다.
/// 잘못되었거나 만료, 취소, 소진, 보관된 응답은 일부만 채운 모델 대신 저장소
/// 예외로 나타낸다.
@immutable
class InvitePreview {
  const InvitePreview({
    required this.groupId,
    required this.groupName,
    required this.groupDescription,
    required this.groupTimezone,
    required this.expiresAt,
    required this.alreadyMember,
  });

  final String groupId;
  final String groupName;
  final String groupDescription;
  final String groupTimezone;
  final DateTime expiresAt;
  final bool alreadyMember;

  bool get isExpired => !expiresAt.isAfter(DateTime.now().toUtc());
  bool get isJoinable => !alreadyMember && !isExpired;

  InvitePreview copyWith({
    String? groupId,
    String? groupName,
    String? groupDescription,
    String? groupTimezone,
    DateTime? expiresAt,
    bool? alreadyMember,
  }) {
    return InvitePreview(
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      groupDescription: groupDescription ?? this.groupDescription,
      groupTimezone: groupTimezone ?? this.groupTimezone,
      expiresAt: expiresAt ?? this.expiresAt,
      alreadyMember: alreadyMember ?? this.alreadyMember,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is InvitePreview &&
        other.groupId == groupId &&
        other.groupName == groupName &&
        other.groupDescription == groupDescription &&
        other.groupTimezone == groupTimezone &&
        other.expiresAt == expiresAt &&
        other.alreadyMember == alreadyMember;
  }

  @override
  int get hashCode => Object.hash(
    groupId,
    groupName,
    groupDescription,
    groupTimezone,
    expiresAt,
    alreadyMember,
  );
}

/// 대기 중인 초대 의도 하나의 UI용 수명 주기다. 이 열거형/스냅샷은 Bearer 토큰을
/// 절대 노출하지 않으며 토큰은 컨트롤러 내부에만 둔다.
enum PendingInviteState {
  none,
  captured,
  loading,
  ready,
  accepting,
  succeeded,
  error,
}

@immutable
class PendingInviteSnapshot {
  const PendingInviteSnapshot({
    required this.state,
    required this.preview,
    required this.error,
    required this.generation,
    required this.returnRoute,
    required this.expiresAt,
  });

  final PendingInviteState state;
  final InvitePreview? preview;
  final String? error;
  final int generation;
  final String? returnRoute;
  final DateTime? expiresAt;

  bool get hasPendingIntent =>
      state != PendingInviteState.none && expiresAt != null;
  bool get canRetry => state == PendingInviteState.error && hasPendingIntent;

  @override
  bool operator ==(Object other) {
    return other is PendingInviteSnapshot &&
        other.state == state &&
        other.preview == preview &&
        other.error == error &&
        other.generation == generation &&
        other.returnRoute == returnRoute &&
        other.expiresAt == expiresAt;
  }

  @override
  int get hashCode =>
      Object.hash(state, preview, error, generation, returnRoute, expiresAt);
}

@immutable
class PlannerEvent {
  PlannerEvent({
    required this.id,
    required this.groupId,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.ownerId,
    this.note = '',
    this.allDay = false,
    List<String> memberIds = const <String>[],
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
    this.version = 1,
    DateTime? updatedAt,
    this.deletedAt,
    String? seriesId,
    this.occurrenceKey = 'single',
    this.occurrenceIndex = 0,
    DateTime? scheduledStartsAt,
    DateTime? scheduledEndsAt,
    int? occurrenceVersion,
    this.isOccurrence = false,
    this.recurrenceRule,
  }) : _memberIds = canonicalEventMemberIds(memberIds),
       updatedAt = updatedAt ?? startAt,
       seriesId = seriesId ?? id,
       scheduledStartsAt = scheduledStartsAt ?? startAt,
       scheduledEndsAt = scheduledEndsAt ?? endAt,
       occurrenceVersion = occurrenceVersion ?? version {
    if (!isValidOccurrenceKey(occurrenceKey)) {
      throw const FormatException('반복 일정 식별자를 확인해 주세요.');
    }
    if (occurrenceIndex < 0 ||
        BigInt.from(occurrenceIndex) > maxOccurrenceOrdinal) {
      throw const FormatException('반복 일정 순서를 확인해 주세요.');
    }
  }

  final String id;
  final String groupId;
  final String title;
  final String note;
  final DateTime startAt; // UTC로 저장하고 화면에 표시할 때 현지 시간으로 변환한다.
  final DateTime endAt; // 종일 일정에서는 UTC 날짜 범위의 끝(미포함) 경계다.
  final bool allDay;
  final String ownerId;
  // 비공개 불변 스냅샷을 유지한다. 호출자가 생성자에 전달한 목록을 보관하고
  // 변경해도 일정 상태를 바꿀 수 없다.
  final List<String> _memberIds;

  /// 결정론적인 앱 순서로 정렬된 배정 사용자다.
  ///
  /// 반환하는 뷰는 의도적으로 변경할 수 없다. 변경 가능한 공개 필드 대신 이 게터를
  /// 사용하면 기존 생성자 형태를 유지하면서 ChangeNotifier 가드를 우회해 일정
  /// 상태를 바꾸지 못하게 할 수 있다.
  List<String> get memberIds => List<String>.unmodifiable(_memberIds);
  final int colorValue;
  final String timezone;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  /// 시리즈 식별자다. 단일 일정은 기존 `id`를 사용해 소스 호환성을 유지하고 반복
  /// 프로젝션은 하나의 기준 ID를 공유한다.
  final String seriesId;
  final String occurrenceKey;
  final int occurrenceIndex;

  /// 재정의 전 발생 항목의 예약 시각(UTC)이다.
  final DateTime? scheduledStartsAt;
  final DateTime? scheduledEndsAt;
  final int occurrenceVersion;
  final bool isOccurrence;
  final RecurrenceRule? recurrenceRule;

  String get identityKey => '$seriesId|$occurrenceKey';

  bool get isDeleted => deletedAt != null;

  PlannerEvent copyWith({
    String? id,
    String? groupId,
    String? title,
    String? note,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    String? ownerId,
    List<String>? memberIds,
    int? colorValue,
    String? timezone,
    DateTime? allDayStartDate,
    DateTime? allDayEndDate,
    int? version,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    bool clearAllDayDates = false,
    String? seriesId,
    String? occurrenceKey,
    int? occurrenceIndex,
    DateTime? scheduledStartsAt,
    DateTime? scheduledEndsAt,
    int? occurrenceVersion,
    bool? isOccurrence,
    RecurrenceRule? recurrenceRule,
    bool clearScheduledStartsAt = false,
    bool clearRecurrenceRule = false,
  }) {
    return PlannerEvent(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      title: title ?? this.title,
      note: note ?? this.note,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      ownerId: ownerId ?? this.ownerId,
      memberIds: memberIds ?? this.memberIds,
      colorValue: colorValue ?? this.colorValue,
      timezone: timezone ?? this.timezone,
      allDayStartDate: clearAllDayDates
          ? null
          : (allDayStartDate ?? this.allDayStartDate),
      allDayEndDate: clearAllDayDates
          ? null
          : (allDayEndDate ?? this.allDayEndDate),
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      seriesId: seriesId ?? this.seriesId,
      occurrenceKey: occurrenceKey ?? this.occurrenceKey,
      occurrenceIndex: occurrenceIndex ?? this.occurrenceIndex,
      scheduledStartsAt: clearScheduledStartsAt
          ? null
          : (scheduledStartsAt ?? this.scheduledStartsAt),
      scheduledEndsAt: clearScheduledStartsAt
          ? null
          : (scheduledEndsAt ?? this.scheduledEndsAt),
      occurrenceVersion: occurrenceVersion ?? this.occurrenceVersion,
      isOccurrence: isOccurrence ?? this.isOccurrence,
      recurrenceRule: clearRecurrenceRule
          ? null
          : (recurrenceRule ?? this.recurrenceRule),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlannerEvent &&
        other.id == id &&
        other.groupId == groupId &&
        other.title == title &&
        other.note == note &&
        other.startAt == startAt &&
        other.endAt == endAt &&
        other.allDay == allDay &&
        other.ownerId == ownerId &&
        listEquals(other.memberIds, memberIds) &&
        other.colorValue == colorValue &&
        other.timezone == timezone &&
        other.allDayStartDate == allDayStartDate &&
        other.allDayEndDate == allDayEndDate &&
        other.version == version &&
        other.updatedAt == updatedAt &&
        other.deletedAt == deletedAt &&
        other.seriesId == seriesId &&
        other.occurrenceKey == occurrenceKey &&
        other.occurrenceIndex == occurrenceIndex &&
        other.scheduledStartsAt == scheduledStartsAt &&
        other.scheduledEndsAt == scheduledEndsAt &&
        other.occurrenceVersion == occurrenceVersion &&
        other.isOccurrence == isOccurrence &&
        other.recurrenceRule == recurrenceRule;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    groupId,
    title,
    note,
    startAt,
    endAt,
    allDay,
    ownerId,
    Object.hashAll(memberIds),
    colorValue,
    timezone,
    allDayStartDate,
    allDayEndDate,
    version,
    updatedAt,
    deletedAt,
    seriesId,
    occurrenceKey,
    occurrenceIndex,
    scheduledStartsAt,
    scheduledEndsAt,
    occurrenceVersion,
    isOccurrence,
    recurrenceRule,
  ]);
}

/// 일정 저장소가 커밋한 결과를 호출자에게 손실 없이 전달한다.
///
/// 단일 행 쓰기와 반복 범위 쓰기는 서버 계약 자체가 다르다. 전자는 검증된 일정
/// 스냅샷을, 후자는 커밋 영수증을 반환하므로 하나를 nullable 필드로 뭉개지 않고
/// 봉인된 두 결과로 표현한다.
@immutable
sealed class EventSaveResult {
  const EventSaveResult();
}

@immutable
final class EventSaveSnapshot extends EventSaveResult {
  const EventSaveSnapshot(this.event);

  final PlannerEvent event;
}

@immutable
final class EventSaveReceipt extends EventSaveResult {
  const EventSaveReceipt(this.receipt);

  final RecurrenceMutationReceipt receipt;
}

@immutable
class EventDraft {
  EventDraft({
    required this.title,
    required this.startAt,
    required this.endAt,
    this.note = '',
    this.allDay = false,
    List<String>? memberIds,
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
    this.recurrence,
  }) : hasExplicitMemberIds = memberIds != null,
       _memberIds = canonicalEventMemberIds(memberIds ?? const <String>[]);

  final String title;
  final String note;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;

  /// 호출자가 참여자 필드를 제공했는지 여부다. 공개 [memberIds] 게터는 의도적으로
  /// `null`이 아니며 불변으로 유지된다. 이 비트는 생략된 생성 필드(저장소가 작성자를
  /// 기본값으로 설정)와 명시적인 빈 배정을 구분한다.
  final bool hasExplicitMemberIds;
  final List<String> _memberIds;
  List<String> get memberIds => List<String>.unmodifiable(_memberIds);
  final int colorValue;
  final String timezone;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;
  final RecurrenceRule? recurrence;
  RecurrenceRule? get recurrenceRule => recurrence;

  EventDraft copyWith({
    String? title,
    String? note,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    List<String>? memberIds,
    int? colorValue,
    String? timezone,
    DateTime? allDayStartDate,
    DateTime? allDayEndDate,
    bool clearAllDayDates = false,
    RecurrenceRule? recurrence,
    bool clearRecurrence = false,
  }) {
    final nextHasExplicitMemberIds = memberIds != null || hasExplicitMemberIds;
    return EventDraft(
      title: title ?? this.title,
      note: note ?? this.note,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      memberIds: nextHasExplicitMemberIds
          ? (memberIds ?? this.memberIds)
          : null,
      colorValue: colorValue ?? this.colorValue,
      timezone: timezone ?? this.timezone,
      allDayStartDate: clearAllDayDates
          ? null
          : (allDayStartDate ?? this.allDayStartDate),
      allDayEndDate: clearAllDayDates
          ? null
          : (allDayEndDate ?? this.allDayEndDate),
      recurrence: clearRecurrence ? null : (recurrence ?? this.recurrence),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is EventDraft &&
        other.title == title &&
        other.note == note &&
        other.startAt == startAt &&
        other.endAt == endAt &&
        other.allDay == allDay &&
        other.hasExplicitMemberIds == hasExplicitMemberIds &&
        listEquals(other.memberIds, memberIds) &&
        other.colorValue == colorValue &&
        other.timezone == timezone &&
        other.allDayStartDate == allDayStartDate &&
        other.allDayEndDate == allDayEndDate &&
        other.recurrence == recurrence;
  }

  @override
  int get hashCode => Object.hash(
    title,
    note,
    startAt,
    endAt,
    allDay,
    hasExplicitMemberIds,
    Object.hashAll(memberIds),
    colorValue,
    timezone,
    allDayStartDate,
    allDayEndDate,
    recurrence,
  );
}

/// 플래너가 지원하는 캘린더 프로젝션이다. 모델을 위젯 계층 밖에 두어 저장소/상태
/// 계약이 Flutter 화면을 가져오지 않고 같은 모드 용어를 공유할 수 있게 한다.
enum CalendarViewMode { day, month, agenda }

/// 제한된 일정 읽기에 사용하는 시작 포함, 종료 미포함 UTC 구간이다. 달력 호출자는
/// 현지 자정 시각으로 이를 만들고 저장소는 사용 전에 IANA 데이터베이스를 기준으로
/// 시간대를 검증한다.
@immutable
class EventRange {
  EventRange({
    required DateTime startUtc,
    required DateTime endUtc,
    required String viewTimezone,
  }) : startUtc = startUtc.toUtc(),
       endUtc = endUtc.toUtc(),
       viewTimezone = viewTimezone {
    if (viewTimezone.isEmpty || viewTimezone.trim() != viewTimezone) {
      throw const FormatException('시간대를 확인해 주세요.');
    }
    if (!this.endUtc.isAfter(this.startUtc)) {
      throw const FormatException('일정 범위를 확인해 주세요.');
    }
  }

  final DateTime startUtc;
  final DateTime endUtc;
  final String viewTimezone;

  Duration get duration => endUtc.difference(startUtc);

  @override
  bool operator ==(Object other) {
    return other is EventRange &&
        other.startUtc == startUtc &&
        other.endUtc == endUtc &&
        other.viewTimezone == viewTimezone;
  }

  @override
  int get hashCode => Object.hash(startUtc, endUtc, viewTimezone);

  @override
  String toString() =>
      'EventRange($startUtc, $endUtc, timezone: $viewTimezone)';
}

/// 제한된 범위 RPC가 반환하는 엄격한 키 집합 튜플이다. 빈 발생 키는 레거시 v1
/// 페이로드를 유지한다. 구체화된 모든 발생분은 v2를 사용하며 완전한
/// `(starts_at,event_id,occurrence_key)` 튜플을 포함한다.
@immutable
class EventRangeCursor {
  EventRangeCursor({
    required DateTime startsAtUtc,
    required String eventId,
    this.occurrenceKey = '',
  }) : startsAtUtc = startsAtUtc.toUtc(),
       eventId = eventId {
    if (eventId.isEmpty || eventId.trim() != eventId) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
    if (occurrenceKey.trim() != occurrenceKey ||
        (occurrenceKey.isNotEmpty && !isValidOccurrenceKey(occurrenceKey))) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
  }

  final DateTime startsAtUtc;
  final String eventId;
  final String occurrenceKey;

  String encode() {
    final isV2 = occurrenceKey.isNotEmpty;
    if (isV2 && !isValidOccurrenceKey(occurrenceKey)) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
    final payload = isV2
        ? <String, Object>{
            'v': 2,
            'starts_at': startsAtUtc.toIso8601String(),
            'event_id': eventId,
            'occurrence_key': occurrenceKey,
          }
        : <String, Object>{
            'v': 1,
            'starts_at': startsAtUtc.toIso8601String(),
            'event_id': eventId,
          };
    return base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
  }

  String toToken() => encode();

  static EventRangeCursor decode(String token) {
    if (token.isEmpty ||
        token.trim() != token ||
        token.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(token)));
      final raw = jsonDecode(decoded);
      if (raw is! Map || raw.keys.any((key) => key is! String)) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final payload = raw.cast<String, dynamic>();
      final startsAtRaw = payload['starts_at'];
      final version = payload['v'];
      if (version is! int || (version != 1 && version != 2)) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final expectedKeys = version == 1
          ? const <String>{'v', 'starts_at', 'event_id'}
          : const <String>{'v', 'starts_at', 'event_id', 'occurrence_key'};
      if (payload.length != expectedKeys.length ||
          payload.keys.toSet().difference(expectedKeys).isNotEmpty ||
          !expectedKeys.every(payload.containsKey) ||
          startsAtRaw is! String ||
          payload['event_id'] is! String) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final startsAt = parseStrictExplicitOffsetTimestamp(startsAtRaw);
      if (startsAt == null) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final eventId = payload['event_id'] as String;
      final occurrenceKey = version == 1 ? '' : payload['occurrence_key'];
      if (version == 2 && !isValidOccurrenceKey(occurrenceKey)) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      return EventRangeCursor(
        startsAtUtc: startsAt,
        eventId: eventId,
        occurrenceKey: occurrenceKey as String? ?? '',
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
  }

  static EventRangeCursor fromToken(String token) => decode(token);

  @override
  bool operator ==(Object other) {
    return other is EventRangeCursor &&
        other.startsAtUtc == startsAtUtc &&
        other.eventId == eventId &&
        other.occurrenceKey == occurrenceKey;
  }

  @override
  int get hashCode => Object.hash(startsAtUtc, eventId, occurrenceKey);

  @override
  String toString() =>
      'EventRangeCursor($startsAtUtc, $eventId, $occurrenceKey)';
}

/// 제한된 일정 범위 읽기가 반환하는 불변 페이지다.
@immutable
class EventRangePage {
  EventRangePage({
    required Iterable<PlannerEvent> events,
    required this.nextCursor,
    required this.hasMore,
  }) : events = List<PlannerEvent>.unmodifiable(events) {
    if (hasMore != (nextCursor != null)) {
      throw const FormatException('일정 페이지 응답을 확인해 주세요.');
    }
  }

  final List<PlannerEvent> events;
  final EventRangeCursor? nextCursor;
  final bool hasMore;

  static EventRangePage empty() => EventRangePage(
    events: const <PlannerEvent>[],
    nextCursor: null,
    hasMore: false,
  );

  @override
  bool operator ==(Object other) {
    return other is EventRangePage &&
        listEquals(other.events, events) &&
        other.nextCursor == nextCursor &&
        other.hasMore == hasMore;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(events), nextCursor, hasMore);
}
