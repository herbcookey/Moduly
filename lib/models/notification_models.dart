import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/timezone_utils.dart';
import 'app_models.dart';

/// The local reminder contract is deliberately finite.  The platform
/// adapters may have a smaller effective limit (iOS currently keeps a
/// headroom below its pending-request quota), but they must never turn this
/// bounded planner into an unbounded scheduler.
const Duration reminderPlanningHorizon = Duration(days: 60);
const int reminderPlanningLimit = 48;
const int reminderPageLimit = 100;
const int reminderPageCap = 100;

/// Channels are kept separate even though the first production slice only
/// enables the local channel.  A push value in persisted preferences is
/// retained as a typed, disabled capability rather than reported as success.
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

/// Timed offsets are elapsed seconds before an instant.  All-day offsets are
/// civil calendar days before the event's local start date.
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

/// OS authorization and product capability are intentionally represented as
/// different axes.  For example, an Android user may be authorized while the
/// server push source remains unconfigured.
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

/// A user-wide switch.  It is opt-in by default; event settings are retained
/// while this switch or an OS permission is off so re-enabling can restore the
/// same desired reminders.
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

  /// Push is a separate desired channel. The local account master must not
  /// erase a user's push intent while local reminders are switched off.
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

/// Event settings are series-wide.  For a recurring projection the event id
/// is the logical series anchor and [occurrenceKey] is never persisted in the
/// preference row.  This keeps one desired setting from silently diverging
/// across future occurrences.
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
    // The public row wire does not carry the event's optimistic-lock
    // version (the RPC envelope supplies it), while local snapshots include
    // it for parity. Accept exactly one of those two shapes; unknown fields
    // remain rejected.
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

/// One server/local candidate.  The server candidate already carries the
/// calculated [fireAt] so the client can use the same sorted keyset for all
/// groups; the local adapter computes the field through [ReminderPlanner]
/// from the same event projection.
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
      // Candidate rows come from the authenticated RPC and use PostgreSQL
      // UUID columns for both resource identifiers.  Keep constructors
      // permissive for local/demo projections, but make the wire parser
      // reject an accidental legacy slug before it can reach the scheduler.
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

/// Keyset cursor for the all-group candidate RPC.  It is intentionally not
/// interchangeable with [EventRangeCursor]: fire-at, not event start, is the
/// primary ordering field.
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

  /// False means a bounded page cap/transport error prevented a complete
  /// authoritative set; callers must not cancel IDs that were not observed.
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

/// A strict, token-free deep-link payload.  Event title/note/member data is
/// deliberately absent; the destination must re-read authoritative data after
/// validating the user's session and group membership.
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

/// Data passed to the native scheduler.  [notificationId] is allocated by
/// [NotificationIdAllocator], never generated by the platform adapter.
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
