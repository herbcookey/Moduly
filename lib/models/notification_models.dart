import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/timezone_utils.dart';
import 'app_models.dart';

/// 로컬 알림 계약은 의도적으로 유한하다. 플랫폼 어댑터의 실제 한도는 더 작을 수
/// 있지만(iOS는 현재 대기 요청 할당량보다 여유를 둔다), 이 제한된 플래너를 제한 없는
/// 스케줄러로 바꾸어서는 안 된다.
const Duration reminderPlanningHorizon = Duration(days: 60);
const int reminderPlanningLimit = 48;
const int reminderPageLimit = 100;
const int reminderPageCap = 100;

/// 첫 프로덕션 단계에서 로컬 채널만 활성화하더라도 채널은 분리해 둔다. 저장된
/// 설정의 푸시 값은 성공으로 보고하지 않고 형식이 지정된 비활성 기능으로 유지한다.
enum NotificationChannel { local, push }

extension NotificationChannelWire on NotificationChannel {
  String get wireName => switch (this) {
    NotificationChannel.local => 'local',
    NotificationChannel.push => 'push',
  };

  static NotificationChannel parse(Object? value) => switch (value) {
    'local' => NotificationChannel.local,
    'push' => NotificationChannel.push,
    _ => throw const FormatException('알림 채널을 확인해 주세요.'),
  };
}

/// 시간 지정 간격은 해당 시각 전까지의 경과 초 단위다. 종일 일정 간격은 일정의
/// 현지 시작 날짜 이전의 민간력 날짜 단위다.
enum NotificationOffsetUnit { seconds, calendarDays }

extension NotificationOffsetUnitWire on NotificationOffsetUnit {
  String get wireName => switch (this) {
    NotificationOffsetUnit.seconds => 'seconds',
    NotificationOffsetUnit.calendarDays => 'calendar_days',
  };

  static NotificationOffsetUnit parse(Object? value) => switch (value) {
    'seconds' => NotificationOffsetUnit.seconds,
    'calendar_days' => NotificationOffsetUnit.calendarDays,
    _ => throw const FormatException('알림 간격 단위를 확인해 주세요.'),
  };
}

/// OS 권한과 제품 기능은 의도적으로 별도 축으로 표현한다. 예를 들어 Android 사용자는
/// 권한을 허용했지만 서버 푸시 소스는 설정되지 않았을 수 있다.
enum NotificationPermissionState {
  unsupported,
  unconfigured,
  disabled,
  notDetermined,
  denied,
  authorized,
  provisional,
}

enum NotificationCapabilityState {
  unsupported,
  unconfigured,
  disabled,
  available,
}

extension NotificationCapabilityStateWire on NotificationCapabilityState {
  String get wireName => switch (this) {
    NotificationCapabilityState.unsupported => 'unsupported',
    NotificationCapabilityState.unconfigured => 'unconfigured',
    NotificationCapabilityState.disabled => 'disabled',
    NotificationCapabilityState.available => 'available',
  };
}

/// 사용자 전체에 적용되는 스위치다. 기본값은 옵트인이다. 이 스위치나 OS 권한이 꺼진
/// 동안에도 일정 설정을 유지하여 다시 활성화할 때 원하던 알림을 복원할 수 있게 한다.
@immutable
class UserNotificationSettings {
  const UserNotificationSettings({
    required this.userId,
    this.enabled = false,
    this.localEnabled = false,
    this.pushEnabled = false,
    this.version = 0,
    this.updatedAt,
  });

  final String userId;
  final bool enabled;
  final bool localEnabled;
  final bool pushEnabled;
  final int version;
  final DateTime? updatedAt;

  bool get localDesired => enabled && localEnabled;

  /// 푸시는 별도로 원하는 채널이다. 로컬 알림이 꺼져 있어도 로컬 계정 전체 제어가
  /// 사용자의 푸시 의도를 지워서는 안 된다.
  bool get pushDesired => pushEnabled;

  UserNotificationSettings copyWith({
    String? userId,
    bool? enabled,
    bool? localEnabled,
    bool? pushEnabled,
    int? version,
    DateTime? updatedAt,
  }) => UserNotificationSettings(
    userId: userId ?? this.userId,
    enabled: enabled ?? this.enabled,
    localEnabled: localEnabled ?? this.localEnabled,
    pushEnabled: pushEnabled ?? this.pushEnabled,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory UserNotificationSettings.fromJson(Object? input) {
    final raw = _strictObject(input, '알림 설정을 확인해 주세요.');
    const keys = <String>{
      'user_id',
      'enabled',
      'local_enabled',
      'push_enabled',
      'version',
      'updated_at',
    };
    _strictKeys(raw, keys, '알림 설정을 확인해 주세요.');
    final id = _strictNonEmptyString(raw['user_id']);
    final version = _strictNonNegativeInt(raw['version']);
    final updated = raw['updated_at'] == null
        ? null
        : parseStrictExplicitOffsetTimestamp(raw['updated_at']);
    if (raw['updated_at'] != null && updated == null) {
      throw const FormatException('알림 설정을 확인해 주세요.');
    }
    return UserNotificationSettings(
      userId: id,
      enabled: _strictBool(raw['enabled']),
      localEnabled: _strictBool(raw['local_enabled']),
      pushEnabled: _strictBool(raw['push_enabled']),
      version: version,
      updatedAt: updated,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'user_id': userId,
    'enabled': enabled,
    'local_enabled': localEnabled,
    'push_enabled': pushEnabled,
    'version': version,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is UserNotificationSettings &&
      other.userId == userId &&
      other.enabled == enabled &&
      other.localEnabled == localEnabled &&
      other.pushEnabled == pushEnabled &&
      other.version == version &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    userId,
    enabled,
    localEnabled,
    pushEnabled,
    version,
    updatedAt,
  );
}

/// 일정 설정은 시리즈 전체에 적용된다. 반복 프로젝션에서 일정 ID는 논리 시리즈의
/// 기준점이며 [occurrenceKey]는 설정 행에 저장하지 않는다. 따라서 하나의 원하는
/// 설정이 향후 발생분마다 암묵적으로 달라지지 않는다.
@immutable
class EventNotificationPreference {
  EventNotificationPreference({
    required this.id,
    required this.userId,
    required this.eventId,
    required this.channel,
    this.enabled = false,
    this.timedLeadSeconds = 900,
    this.allDayDaysBefore = 0,
    this.version = 0,
    this.eventVersion = 1,
    this.updatedAt,
  }) {
    if (id.trim().isEmpty || userId.trim().isEmpty || eventId.trim().isEmpty) {
      throw const FormatException('일정 알림 설정을 확인해 주세요.');
    }
    if (timedLeadSeconds < 0 || timedLeadSeconds > 7 * 24 * 60 * 60) {
      throw const FormatException('알림 간격을 확인해 주세요.');
    }
    if (allDayDaysBefore < 0 || allDayDaysBefore > 366) {
      throw const FormatException('알림 날짜 간격을 확인해 주세요.');
    }
    if (version < 0 || eventVersion < 1) {
      throw const FormatException('알림 설정 버전을 확인해 주세요.');
    }
  }

  final String id;
  final String userId;
  final String eventId;
  final NotificationChannel channel;
  final bool enabled;
  final int timedLeadSeconds;
  final int allDayDaysBefore;
  final int version;
  final int eventVersion;
  final DateTime? updatedAt;

  int offsetFor({required bool allDay}) =>
      allDay ? allDayDaysBefore : timedLeadSeconds;

  EventNotificationPreference copyWith({
    String? id,
    String? userId,
    String? eventId,
    NotificationChannel? channel,
    bool? enabled,
    int? timedLeadSeconds,
    int? allDayDaysBefore,
    int? version,
    int? eventVersion,
    DateTime? updatedAt,
  }) => EventNotificationPreference(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    eventId: eventId ?? this.eventId,
    channel: channel ?? this.channel,
    enabled: enabled ?? this.enabled,
    timedLeadSeconds: timedLeadSeconds ?? this.timedLeadSeconds,
    allDayDaysBefore: allDayDaysBefore ?? this.allDayDaysBefore,
    version: version ?? this.version,
    eventVersion: eventVersion ?? this.eventVersion,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory EventNotificationPreference.fromJson(Object? input) {
    final raw = _strictObject(input, '일정 알림 설정을 확인해 주세요.');
    const baseKeys = <String>{
      'id',
      'user_id',
      'event_id',
      'channel',
      'enabled',
      'timed_lead_seconds',
      'all_day_days_before',
      'version',
      'updated_at',
    };
    // 공개 행 전송 형식에는 일정의 낙관적 잠금 버전이 없고 RPC 봉투가 제공한다.
    // 로컬 스냅샷에는 동등성을 위해 이를 포함한다. 이 두 형식만 정확히 허용하며
    // 알 수 없는 필드는 계속 거부한다.
    final keys = raw.containsKey('event_version')
        ? <String>{...baseKeys, 'event_version'}
        : baseKeys;
    _strictKeys(raw, keys, '일정 알림 설정을 확인해 주세요.');
    final updated = raw['updated_at'] == null
        ? null
        : parseStrictExplicitOffsetTimestamp(raw['updated_at']);
    if (raw['updated_at'] != null && updated == null) {
      throw const FormatException('일정 알림 설정을 확인해 주세요.');
    }
    return EventNotificationPreference(
      id: _strictNonEmptyString(raw['id']),
      userId: _strictNonEmptyString(raw['user_id']),
      eventId: _strictNonEmptyString(raw['event_id']),
      channel: NotificationChannelWire.parse(raw['channel']),
      enabled: _strictBool(raw['enabled']),
      timedLeadSeconds: _strictNonNegativeInt(raw['timed_lead_seconds']),
      allDayDaysBefore: _strictNonNegativeInt(raw['all_day_days_before']),
      version: _strictNonNegativeInt(raw['version']),
      updatedAt: updated,
      eventVersion: _strictPositiveInt(raw['event_version'] ?? 1),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'user_id': userId,
    'event_id': eventId,
    'channel': channel.wireName,
    'enabled': enabled,
    'timed_lead_seconds': timedLeadSeconds,
    'all_day_days_before': allDayDaysBefore,
    'version': version,
    'event_version': eventVersion,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is EventNotificationPreference &&
      other.id == id &&
      other.userId == userId &&
      other.eventId == eventId &&
      other.channel == channel &&
      other.enabled == enabled &&
      other.timedLeadSeconds == timedLeadSeconds &&
      other.allDayDaysBefore == allDayDaysBefore &&
      other.version == version &&
      other.eventVersion == eventVersion &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    eventId,
    channel,
    enabled,
    timedLeadSeconds,
    allDayDaysBefore,
    version,
    eventVersion,
    updatedAt,
  );
}

/// 서버/로컬 후보 하나다. 서버 후보에는 계산된 [fireAt]이 이미 있어 클라이언트가 모든
/// 그룹에 같은 정렬 키 집합을 사용할 수 있다. 로컬 어댑터는 같은 일정 프로젝션에서
/// [ReminderPlanner]를 통해 이 필드를 계산한다.
@immutable
class ReminderCandidate {
  ReminderCandidate({
    required this.eventId,
    required this.groupId,
    required this.occurrenceKey,
    required this.occurrenceIndex,
    required DateTime fireAt,
    required DateTime startsAt,
    required DateTime endsAt,
    required this.timezone,
    required this.isAllDay,
    DateTime? allDayStartDate,
    DateTime? allDayEndDate,
    required this.title,
    required this.settingId,
    required this.settingVersion,
    required this.eventVersion,
    required this.occurrenceVersion,
    this.channel = NotificationChannel.local,
    this.capability = 'client_local_scheduler',
    this.allDayLocalTime = '09:00:00',
  }) : fireAt = fireAt.toUtc(),
       startsAt = startsAt.toUtc(),
       endsAt = endsAt.toUtc(),
       allDayStartDate = allDayStartDate == null
           ? null
           : _civilDateOnly(allDayStartDate),
       allDayEndDate = allDayEndDate == null
           ? null
           : _civilDateOnly(allDayEndDate) {
    if (eventId.trim().isEmpty ||
        groupId.trim().isEmpty ||
        !isValidOccurrenceKey(occurrenceKey) ||
        occurrenceIndex < 0 ||
        timezone.trim().isEmpty ||
        title.trim().isEmpty ||
        settingId.trim().isEmpty ||
        settingVersion < 1 ||
        eventVersion < 1 ||
        occurrenceVersion < 0 ||
        !endsAt.isAfter(startsAt)) {
      throw const FormatException('알림 후보를 확인해 주세요.');
    }
    if (isAllDay != (allDayStartDate != null && allDayEndDate != null) ||
        (isAllDay && !allDayEndDate!.isAfter(allDayStartDate!))) {
      throw const FormatException('종일 알림 후보를 확인해 주세요.');
    }
  }

  final String eventId;
  final String groupId;
  final String occurrenceKey;
  final int occurrenceIndex;
  final DateTime fireAt;
  final DateTime startsAt;
  final DateTime endsAt;
  final String timezone;
  final bool isAllDay;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;
  final String title;
  final String settingId;
  final int settingVersion;
  final int eventVersion;
  final int occurrenceVersion;
  final NotificationChannel channel;
  final String capability;
  final String allDayLocalTime;

  factory ReminderCandidate.fromJson(Object? input) {
    final raw = _strictObject(input, '알림 후보를 확인해 주세요.');
    const keys = <String>{
      'event_id',
      'group_id',
      'occurrence_key',
      'occurrence_index',
      'fire_at',
      'starts_at',
      'ends_at',
      'timezone',
      'is_all_day',
      'all_day_start',
      'all_day_end',
      'title',
      'setting_id',
      'setting_version',
      'event_version',
      'occurrence_version',
      'channel',
      'capability',
      'all_day_local_time',
    };
    _strictKeys(raw, keys, '알림 후보를 확인해 주세요.');
    DateTime requiredInstant(String key) {
      final value = parseStrictExplicitOffsetTimestamp(raw[key]);
      if (value == null) throw const FormatException('알림 후보를 확인해 주세요.');
      return value;
    }

    DateTime? optionalDate(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
        throw const FormatException('알림 후보를 확인해 주세요.');
      }
      final parsed = DateTime.tryParse('${value}T00:00:00Z');
      if (parsed == null ||
          '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' !=
              value) {
        throw const FormatException('알림 후보를 확인해 주세요.');
      }
      return _civilDateOnly(parsed);
    }

    if (raw['channel'] != 'local') {
      throw const FormatException('알림 후보 채널을 확인해 주세요.');
    }

    return ReminderCandidate(
      // 후보 행은 인증된 RPC에서 오며 두 리소스 식별자 모두 PostgreSQL UUID 열을
      // 사용한다. 로컬/데모 프로젝션을 위해 생성자는 관대하게 유지하지만, 실수로
      // 들어온 기존 슬러그가 스케줄러에 도달하기 전에 전송 형식 파서에서 거부한다.
      eventId: _strictUuid(raw['event_id']),
      groupId: _strictUuid(raw['group_id']),
      occurrenceKey: _strictOccurrenceKey(raw['occurrence_key']),
      occurrenceIndex: _strictNonNegativeInt(raw['occurrence_index']),
      fireAt: requiredInstant('fire_at'),
      startsAt: requiredInstant('starts_at'),
      endsAt: requiredInstant('ends_at'),
      timezone: _strictTimezone(raw['timezone']),
      isAllDay: _strictBool(raw['is_all_day']),
      allDayStartDate: optionalDate('all_day_start'),
      allDayEndDate: optionalDate('all_day_end'),
      title: _strictNonEmptyString(raw['title']),
      settingId: _strictUuid(raw['setting_id']),
      settingVersion: _strictPositiveInt(raw['setting_version']),
      eventVersion: _strictPositiveInt(raw['event_version']),
      occurrenceVersion: _strictNonNegativeInt(raw['occurrence_version']),
      channel: NotificationChannelWire.parse(raw['channel']),
      capability: raw['capability'] == 'client_local_scheduler'
          ? 'client_local_scheduler'
          : (throw const FormatException('알림 후보 기능 상태를 확인해 주세요.')),
      allDayLocalTime: raw['all_day_local_time'] == '09:00:00'
          ? '09:00:00'
          : (throw const FormatException('종일 알림 시각을 확인해 주세요.')),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'event_id': eventId,
    'group_id': groupId,
    'occurrence_key': occurrenceKey,
    'occurrence_index': occurrenceIndex,
    'fire_at': fireAt.toIso8601String(),
    'starts_at': startsAt.toIso8601String(),
    'ends_at': endsAt.toIso8601String(),
    'timezone': timezone,
    'is_all_day': isAllDay,
    'all_day_start': allDayStartDate == null
        ? null
        : _dateOnlyWire(allDayStartDate!),
    'all_day_end': allDayEndDate == null ? null : _dateOnlyWire(allDayEndDate!),
    'title': title,
    'setting_id': settingId,
    'setting_version': settingVersion,
    'event_version': eventVersion,
    'occurrence_version': occurrenceVersion,
    'channel': channel.wireName,
    'capability': capability,
    'all_day_local_time': allDayLocalTime,
  };

  @override
  bool operator ==(Object other) =>
      other is ReminderCandidate &&
      other.eventId == eventId &&
      other.groupId == groupId &&
      other.occurrenceKey == occurrenceKey &&
      other.occurrenceIndex == occurrenceIndex &&
      other.fireAt == fireAt &&
      other.startsAt == startsAt &&
      other.endsAt == endsAt &&
      other.timezone == timezone &&
      other.isAllDay == isAllDay &&
      other.allDayStartDate == allDayStartDate &&
      other.allDayEndDate == allDayEndDate &&
      other.title == title &&
      other.settingId == settingId &&
      other.settingVersion == settingVersion &&
      other.eventVersion == eventVersion &&
      other.occurrenceVersion == occurrenceVersion &&
      other.channel == channel &&
      other.capability == capability &&
      other.allDayLocalTime == allDayLocalTime;

  @override
  int get hashCode => Object.hash(
    eventId,
    groupId,
    occurrenceKey,
    occurrenceIndex,
    fireAt,
    startsAt,
    endsAt,
    timezone,
    isAllDay,
    allDayStartDate,
    allDayEndDate,
    title,
    settingId,
    settingVersion,
    eventVersion,
    occurrenceVersion,
    channel,
    capability,
    allDayLocalTime,
  );
}

/// 전체 그룹 후보 RPC용 키 집합 커서다. 일정 시작이 아니라 알림 시각이 기본 정렬
/// 필드이므로 의도적으로 [EventRangeCursor]와 호환되지 않는다.
@immutable
class ReminderCandidateCursor {
  ReminderCandidateCursor({
    required DateTime fireAt,
    required this.eventId,
    required this.occurrenceKey,
    required this.channel,
  }) : fireAt = fireAt.toUtc() {
    if (eventId.trim().isEmpty || !isValidOccurrenceKey(occurrenceKey)) {
      throw const FormatException('알림 페이지 커서를 확인해 주세요.');
    }
  }

  final DateTime fireAt;
  final String eventId;
  final String occurrenceKey;
  final NotificationChannel channel;

  String encode() {
    if (channel != NotificationChannel.local) {
      throw const FormatException('알림 페이지 커서를 확인해 주세요.');
    }
    final payload = <String, Object>{
      'v': 1,
      'fire_at': fireAt.toIso8601String(),
      'event_id': eventId,
      'occurrence_key': occurrenceKey,
      'channel': channel.wireName,
    };
    return base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
  }

  static ReminderCandidateCursor decode(String token) {
    if (token.isEmpty ||
        token.trim() != token ||
        token.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
      throw const FormatException('알림 페이지 커서를 확인해 주세요.');
    }
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(token)));
      final value = jsonDecode(decoded);
      final raw = _strictObject(value, '알림 페이지 커서를 확인해 주세요.');
      const keys = <String>{
        'v',
        'fire_at',
        'event_id',
        'occurrence_key',
        'channel',
      };
      _strictKeys(raw, keys, '알림 페이지 커서를 확인해 주세요.');
      if (raw['v'] != 1 ||
          raw['fire_at'] is! String ||
          raw['event_id'] is! String ||
          raw['occurrence_key'] is! String ||
          raw['channel'] is! String) {
        throw const FormatException('알림 페이지 커서를 확인해 주세요.');
      }
      if (!_isUuid(raw['event_id'] as String)) {
        throw const FormatException('알림 페이지 커서를 확인해 주세요.');
      }
      if (raw['channel'] != 'local') {
        throw const FormatException('알림 페이지 커서를 확인해 주세요.');
      }
      final fireAt = parseStrictExplicitOffsetTimestamp(raw['fire_at']);
      if (fireAt == null) throw const FormatException('알림 페이지 커서를 확인해 주세요.');
      return ReminderCandidateCursor(
        fireAt: fireAt,
        eventId: raw['event_id'] as String,
        occurrenceKey: _strictOccurrenceKey(raw['occurrence_key']),
        channel: NotificationChannelWire.parse(raw['channel']),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('알림 페이지 커서를 확인해 주세요.');
    }
  }
}

@immutable
class ReminderCandidatePage {
  ReminderCandidatePage({
    required Iterable<ReminderCandidate> candidates,
    required this.nextCursor,
    required this.hasMore,
    this.capability = NotificationCapabilityState.available,
    this.complete = true,
  }) : candidates = List<ReminderCandidate>.unmodifiable(candidates) {
    if (hasMore != (nextCursor != null) ||
        (hasMore && this.candidates.isEmpty)) {
      throw const FormatException('알림 후보 페이지를 확인해 주세요.');
    }
  }

  final List<ReminderCandidate> candidates;
  final ReminderCandidateCursor? nextCursor;
  final bool hasMore;
  final NotificationCapabilityState capability;

  /// `false`는 제한된 페이지 상한/전송 오류 때문에 완전하고 신뢰할 수 있는 집합을
  /// 만들지 못했다는 뜻이다. 호출자는 관찰되지 않은 ID를 취소하면 안 된다.
  final bool complete;

  static ReminderCandidatePage empty({
    NotificationCapabilityState capability =
        NotificationCapabilityState.available,
  }) => ReminderCandidatePage(
    candidates: const <ReminderCandidate>[],
    nextCursor: null,
    hasMore: false,
    capability: capability,
  );
}

/// 엄격하고 토큰이 없는 딥 링크 페이로드다. 일정 제목/메모/멤버 데이터는 의도적으로
/// 제외한다. 목적지는 사용자 세션과 그룹 멤버십을 검증한 뒤 신뢰할 수 있는 데이터를
/// 다시 읽어야 한다.
@immutable
class NotificationPayload {
  const NotificationPayload({
    required this.eventId,
    required this.occurrenceKey,
    this.groupId,
    this.schemaVersion = 1,
    this.type = 'event_reminder',
  });

  final int schemaVersion;
  final String type;
  final String eventId;
  final String? groupId;
  final String occurrenceKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    'type': type,
    'event_id': eventId,
    if (groupId != null) 'group_id': groupId,
    'occurrence_key': occurrenceKey,
  };

  String encode() => jsonEncode(toJson());

  factory NotificationPayload.fromJson(Object? input) {
    final raw = _strictObject(input, '알림 링크를 확인해 주세요.');
    final hasGroup = raw.containsKey('group_id');
    final expected = hasGroup
        ? const <String>{
            'schema_version',
            'type',
            'event_id',
            'group_id',
            'occurrence_key',
          }
        : const <String>{
            'schema_version',
            'type',
            'event_id',
            'occurrence_key',
          };
    _strictKeys(raw, expected, '알림 링크를 확인해 주세요.');
    if (raw['schema_version'] != 1 ||
        raw['type'] != 'event_reminder' ||
        raw['event_id'] is! String ||
        raw['occurrence_key'] is! String) {
      throw const FormatException('알림 링크를 확인해 주세요.');
    }
    final eventId = raw['event_id'] as String;
    final groupId = raw['group_id'];
    if (!_isUuid(eventId) ||
        (hasGroup && (groupId is! String || !_isUuid(groupId)))) {
      throw const FormatException('알림 링크를 확인해 주세요.');
    }
    return NotificationPayload(
      eventId: eventId,
      groupId: groupId as String?,
      occurrenceKey: _strictOccurrenceKey(raw['occurrence_key']),
    );
  }

  static NotificationPayload decode(String encoded) {
    if (encoded.trim() != encoded || encoded.length > 4096) {
      throw const FormatException('알림 링크를 확인해 주세요.');
    }
    try {
      return NotificationPayload.fromJson(jsonDecode(encoded));
    } catch (error) {
      if (error is FormatException) rethrow;
      throw const FormatException('알림 링크를 확인해 주세요.');
    }
  }
}

/// 네이티브 스케줄러에 전달하는 데이터다. [notificationId]는
/// [NotificationIdAllocator]가 할당하며 플랫폼 어댑터가 생성하지 않는다.
@immutable
class NotificationScheduleRequest {
  const NotificationScheduleRequest({
    required this.notificationId,
    required this.fireAt,
    required this.title,
    required this.payload,
    required this.timezone,
  });

  final int notificationId;
  final DateTime fireAt;
  final String title;
  final NotificationPayload payload;
  final String timezone;
}

String _dateOnlyWire(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

DateTime _civilDateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

Map<String, dynamic> _strictObject(Object? value, String message) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException(message);
  }
  return Map<String, dynamic>.from(value);
}

void _strictKeys(
  Map<String, dynamic> value,
  Set<String> expected,
  String message,
) {
  if (value.length != expected.length ||
      value.keys.toSet().difference(expected).isNotEmpty ||
      !expected.every(value.containsKey)) {
    throw FormatException(message);
  }
}

String _strictNonEmptyString(Object? value) {
  if (value is! String || value.trim().isEmpty || value != value.trim()) {
    throw const FormatException('알림 값을 확인해 주세요.');
  }
  return value;
}

String _strictUuid(Object? value) {
  if (value is! String || value.trim() != value || !_isUuid(value)) {
    throw const FormatException('알림 식별자를 확인해 주세요.');
  }
  return value;
}

String _strictTimezone(Object? value) {
  if (value is! String || !isValidIanaTimezone(value)) {
    throw const FormatException('알림 시간대를 확인해 주세요.');
  }
  return value;
}

bool _strictBool(Object? value) {
  if (value is! bool) throw const FormatException('알림 값을 확인해 주세요.');
  return value;
}

int _strictPositiveInt(Object? value) {
  if (value is! int || value < 1) throw const FormatException('알림 값을 확인해 주세요.');
  return value;
}

int _strictNonNegativeInt(Object? value) {
  if (value is! int || value < 0) throw const FormatException('알림 값을 확인해 주세요.');
  return value;
}

String _strictOccurrenceKey(Object? value) {
  if (!isValidOccurrenceKey(value)) {
    throw const FormatException('알림 발생 식별자를 확인해 주세요.');
  }
  return value as String;
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
).hasMatch(value);
