import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/reminder_planner.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../models/notification_models.dart';
import 'schedule_repository.dart';

const _notificationCapabilityValues = <String>{
  'client_local_scheduler',
  'push_configured',
  'push_unconfigured',
  'disabled',
};

final _notificationUuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

Map<String, dynamic> _strictNotificationObject(Object? value, String message) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw ScheduleConflictException(message);
  }
  return Map<String, dynamic>.from(value);
}

void _strictNotificationKeys(
  Map<String, dynamic> value,
  Set<String> expected,
  String message,
) {
  if (value.length != expected.length ||
      value.keys.toSet().difference(expected).isNotEmpty ||
      !expected.every(value.containsKey)) {
    throw ScheduleConflictException(message);
  }
}

String _strictNotificationCapability(Object? value, String message) {
  if (value is! String || !_notificationCapabilityValues.contains(value)) {
    throw ScheduleConflictException(message);
  }
  return value;
}

String _strictNotificationUuid(Object? value, String message) {
  if (value is! String ||
      value.trim() != value ||
      !_notificationUuidPattern.hasMatch(value)) {
    throw ScheduleConflictException(message);
  }
  return value;
}

/// 원하는 알림 설정과 제한된 전체 그룹 후보 프로젝션의 읽기/쓰기 경계다. 인터페이스는
/// 추가형이며 기존 ScheduleRepository 테스트 대역은 이를 구현하지 않는다.
abstract interface class NotificationRepository {
  NotificationCapabilityState get capability;

  Future<UserNotificationSettings> settingsForUser(String userId);

  Future<UserNotificationSettings> saveSettings(
    UserNotificationSettings settings, {
    int? expectedVersion,
  });

  Future<List<EventNotificationPreference>> preferencesForUser(String userId);

  /// 논리 일정 하나의 시리즈 전체 설정을 읽는다. 기본 구현은 이전 어댑터가 사용자
  /// 목록을 제공할 수 있으면 이를 필터링하여 소스 호환성을 유지한다.
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async => (await preferencesForUser(
    userId,
  )).where((value) => value.eventId == eventId).toList(growable: false);

  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference preference, {
    int? expectedVersion,
  });

  Future<void> deleteEventPreference({
    required String userId,
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  });

  Future<ReminderCandidatePage> reminderCandidatesForUser({
    required String userId,
    required DateTime fireAtStart,
    required DateTime fireAtEnd,
    ReminderCandidateCursor? cursor,
    int limit = reminderPageLimit,
  });
}

/// 데모 및 단위 테스트에서 사용하는 메모리/로컬 어댑터다. 전체 일정 스트림을 읽는
/// 대신 제한된 `eventsForRange` 페이지를 통해 원격 참여자 프로젝션을 재현한다.
class LocalNotificationRepository implements NotificationRepository {
  LocalNotificationRepository(
    this.schedule, {
    Map<String, UserNotificationSettings>? initialSettings,
    Map<String, EventNotificationPreference>? initialPreferences,
  }) : _settings = <String, UserNotificationSettings>{...?initialSettings},
       _preferences = <String, EventNotificationPreference>{
         ...?initialPreferences,
       };

  final ScheduleRepository schedule;
  final Map<String, UserNotificationSettings> _settings;
  final Map<String, EventNotificationPreference> _preferences;

  @override
  NotificationCapabilityState get capability =>
      NotificationCapabilityState.available;

  @override
  Future<UserNotificationSettings> settingsForUser(String userId) async {
    _requireUser(userId);
    return _settings[userId] ?? UserNotificationSettings(userId: userId);
  }

  @override
  Future<UserNotificationSettings> saveSettings(
    UserNotificationSettings settings, {
    int? expectedVersion,
  }) async {
    _requireUser(settings.userId);
    final previous = _settings[settings.userId];
    final currentVersion = previous?.version ?? 0;
    _checkVersion(currentVersion, expectedVersion ?? settings.version);
    final changed =
        previous == null ||
        previous.enabled != settings.enabled ||
        previous.localEnabled != settings.localEnabled ||
        previous.pushEnabled != settings.pushEnabled;
    final next = settings.copyWith(
      version: previous == null
          ? 1
          : (changed ? previous.version + 1 : previous.version),
      updatedAt: previous == null || changed
          ? DateTime.now().toUtc()
          : previous.updatedAt,
    );
    _settings[settings.userId] = next;
    return next;
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForUser(
    String userId,
  ) async {
    _requireUser(userId);
    return List<EventNotificationPreference>.unmodifiable(
      _preferences.values.where((value) => value.userId == userId),
    );
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async => (await preferencesForUser(
    userId,
  )).where((value) => value.eventId == eventId).toList(growable: false);

  @override
  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference preference, {
    int? expectedVersion,
  }) async {
    _requireUser(preference.userId);
    final key = _preferenceKey(
      preference.userId,
      preference.eventId,
      preference.channel,
    );
    final previous = _preferences[key];
    final currentVersion = previous?.version ?? 0;
    _checkVersion(currentVersion, expectedVersion ?? preference.version);
    final changed =
        previous == null ||
        previous.enabled != preference.enabled ||
        previous.timedLeadSeconds != preference.timedLeadSeconds ||
        previous.allDayDaysBefore != preference.allDayDaysBefore ||
        previous.eventVersion != preference.eventVersion;
    final next = preference.copyWith(
      id: previous?.id ?? preference.id,
      version: previous == null
          ? 1
          : (changed ? previous.version + 1 : previous.version),
      updatedAt: previous == null || changed
          ? DateTime.now().toUtc()
          : previous.updatedAt,
    );
    _preferences[key] = next;
    return next;
  }

  @override
  Future<void> deleteEventPreference({
    required String userId,
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  }) async {
    _requireUser(userId);
    final key = _preferenceKey(userId, eventId, channel);
    final previous = _preferences[key];
    _checkVersion(previous?.version ?? 0, expectedVersion);
    _preferences.remove(key);
  }

  @override
  Future<ReminderCandidatePage> reminderCandidatesForUser({
    required String userId,
    required DateTime fireAtStart,
    required DateTime fireAtEnd,
    ReminderCandidateCursor? cursor,
    int limit = reminderPageLimit,
  }) async {
    _requireUser(userId);
    _validateCandidateRange(fireAtStart, fireAtEnd, limit);
    final settings = await settingsForUser(userId);
    if (!settings.localDesired) return ReminderCandidatePage.empty();
    final preferences = await preferencesForUser(userId);
    if (preferences
        .where(
          (value) =>
              value.enabled && value.channel == NotificationChannel.local,
        )
        .isEmpty) {
      return ReminderCandidatePage.empty();
    }
    final bounded = schedule;
    if (bounded is! BoundedEventRangeReadCapability) {
      return ReminderCandidatePage.empty(
        capability: NotificationCapabilityState.unconfigured,
      );
    }
    final boundedCapability = bounded as BoundedEventRangeReadCapability;
    final maxTimedLead = preferences
        .where(
          (value) =>
              value.enabled && value.channel == NotificationChannel.local,
        )
        .map((value) => value.timedLeadSeconds)
        .fold<int>(0, (left, right) => left > right ? left : right);
    final maxAllDayDays = preferences
        .where(
          (value) =>
              value.enabled && value.channel == NotificationChannel.local,
        )
        .map((value) => value.allDayDaysBefore)
        .fold<int>(0, (left, right) => left > right ? left : right);
    final lookBehind =
        Duration(
              seconds: maxTimedLead,
            ).compareTo(Duration(days: maxAllDayDays)) >=
            0
        ? Duration(seconds: maxTimedLead)
        : Duration(days: maxAllDayDays);
    final start = fireAtStart.toUtc().subtract(lookBehind);
    final end = fireAtEnd.toUtc().add(const Duration(days: 1));
    final groups = await schedule.groupsForUser(userId);
    final eventsByIdentity = <String, PlannerEvent>{};
    for (final group in groups) {
      if (group.id.trim().isEmpty) continue;
      // 원격 범위 RPC는 현지 자정 경계와 최대 366일의 민간력 날짜를 허용한다.
      // 넓은 과거 조회 창은 그룹 시간대에 따라 나눈다.
      final localStart = civilDateOnly(utcToWallTime(start, group.timezone));
      final localEnd = civilDateAdd(
        civilDateOnly(utcToWallTime(end, group.timezone)),
        1,
      );
      var chunkStart = localStart;
      while (chunkStart.isBefore(localEnd)) {
        final chunkEnd = civilDateAdd(
          chunkStart,
          (localEnd.difference(chunkStart).inDays).clamp(1, 366),
        );
        final range = EventRange(
          startUtc: wallTimeToUtc(chunkStart, group.timezone),
          endUtc: wallTimeToUtc(chunkEnd, group.timezone),
          viewTimezone: group.timezone,
        );
        EventRangeCursor? pageCursor;
        var pages = 0;
        while (true) {
          if (++pages > reminderPageCap) {
            throw const ScheduleConflictException('알림 후보 범위가 너무 큽니다.');
          }
          final page = await boundedCapability.eventsForRange(
            userId: userId,
            groupId: group.id,
            range: range,
            cursor: pageCursor,
            limit: reminderPageLimit,
            participantId: userId,
          );
          for (final event in page.events) {
            if (event.memberIds.contains(userId) && !event.isDeleted) {
              eventsByIdentity[event.identityKey] = event;
            }
          }
          if (!page.hasMore) break;
          pageCursor = page.nextCursor;
          if (pageCursor == null) {
            throw const ScheduleConflictException('알림 후보 페이지를 확인할 수 없습니다.');
          }
        }
        chunkStart = chunkEnd;
      }
    }
    final planned = ReminderPlanner.plan(
      userId: userId,
      events: eventsByIdentity.values,
      settings: settings,
      preferences: preferences,
      nowUtc: fireAtStart,
      horizon: fireAtEnd.toUtc().difference(fireAtStart.toUtc()),
      maxReminders: reminderPlanningLimit,
    );
    final byKey = <String, ReminderCandidate>{};
    final preferenceByEvent = <String, EventNotificationPreference>{
      for (final value in preferences)
        if (value.channel == NotificationChannel.local && value.enabled)
          value.eventId: value,
    };
    for (final item in planned) {
      final event = eventsByIdentity.values
          .where(
            (candidate) =>
                candidate.identityKey ==
                '${item.identity.eventId}|${item.occurrenceKey}',
          )
          .firstOrNull;
      if (event == null) continue;
      final pref =
          preferenceByEvent[event.seriesId] ?? preferenceByEvent[event.id];
      if (pref == null) continue;
      final candidate = ReminderCandidate(
        eventId: event.id,
        groupId: event.groupId,
        occurrenceKey: event.occurrenceKey,
        occurrenceIndex: event.occurrenceIndex,
        fireAt: item.fireAt,
        startsAt: event.startAt,
        endsAt: event.endAt,
        timezone: event.timezone,
        isAllDay: event.allDay,
        allDayStartDate: event.allDayStartDate,
        allDayEndDate: event.allDayEndDate,
        title: event.title,
        settingId: pref.id,
        settingVersion: pref.version,
        eventVersion: event.version,
        occurrenceVersion: event.occurrenceVersion,
        channel: NotificationChannel.local,
      );
      byKey['${candidate.fireAt.microsecondsSinceEpoch}|${candidate.eventId}|${candidate.occurrenceKey}'] =
          candidate;
    }
    final rows = byKey.values.toList()..sort(_compareCandidate);
    final after = cursor == null
        ? rows
        : rows.where((row) => _isAfterCandidate(row, cursor)).toList();
    final hasMore = after.length > limit;
    final pageRows = after.take(limit).toList(growable: false);
    final next = hasMore && pageRows.isNotEmpty
        ? ReminderCandidateCursor(
            fireAt: pageRows.last.fireAt,
            eventId: pageRows.last.eventId,
            occurrenceKey: pageRows.last.occurrenceKey,
            channel: pageRows.last.channel,
          )
        : null;
    return ReminderCandidatePage(
      candidates: pageRows,
      nextCursor: next,
      hasMore: hasMore,
    );
  }

  static int _compareCandidate(
    ReminderCandidate left,
    ReminderCandidate right,
  ) {
    final fire = left.fireAt.compareTo(right.fireAt);
    if (fire != 0) return fire;
    final event = left.eventId.compareTo(right.eventId);
    if (event != 0) return event;
    final occurrence = left.occurrenceKey.compareTo(right.occurrenceKey);
    if (occurrence != 0) return occurrence;
    return left.channel.wireName.compareTo(right.channel.wireName);
  }

  static bool _isAfterCandidate(
    ReminderCandidate candidate,
    ReminderCandidateCursor cursor,
  ) {
    final fire = candidate.fireAt.compareTo(cursor.fireAt);
    if (fire != 0) return fire > 0;
    final event = candidate.eventId.compareTo(cursor.eventId);
    if (event != 0) return event > 0;
    final occurrence = candidate.occurrenceKey.compareTo(cursor.occurrenceKey);
    if (occurrence != 0) return occurrence > 0;
    return candidate.channel.wireName.compareTo(cursor.channel.wireName) > 0;
  }

  static void _validateCandidateRange(DateTime start, DateTime end, int limit) {
    if (!start.isUtc ||
        !end.isUtc ||
        !end.isAfter(start) ||
        end.difference(start) > reminderPlanningHorizon ||
        limit < 1 ||
        limit > reminderPageLimit) {
      throw const ScheduleValidationException('알림 후보 범위를 확인해 주세요.');
    }
  }

  static void _requireUser(String userId) {
    if (userId.trim().isEmpty || userId != userId.trim()) {
      throw const ScheduleValidationException('로그인 세션을 확인해 주세요.');
    }
  }

  static String _preferenceKey(
    String userId,
    String eventId,
    NotificationChannel channel,
  ) => '$userId|$eventId|${channel.wireName}';

  static void _checkVersion(int current, int? expected) {
    if (expected != null && current != expected) {
      throw const ScheduleConflictException('알림 설정이 다른 기기에서 변경되었습니다.');
    }
  }
}

/// 프로덕션 원격 어댑터다. 푸시 기기/송신함은 여기서 의도적으로 노출하지 않는다.
/// 이 범위에서는 사용자 로컬 희망 설정과 제한된 로컬 후보 RPC만 읽고 쓴다.
class SupabaseNotificationRepository implements NotificationRepository {
  SupabaseNotificationRepository(this.client);

  final SupabaseClient client;

  @override
  NotificationCapabilityState get capability =>
      NotificationCapabilityState.available;

  String _requireCurrentUser(String userId) {
    if (userId.trim().isEmpty || userId != userId.trim()) {
      throw const ScheduleValidationException('로그인 세션을 확인해 주세요.');
    }
    final current = client.auth.currentUser?.id;
    if (current == null || current != userId) {
      throw const ScheduleAuthorizationException('로그인 세션을 확인해 주세요.');
    }
    return current;
  }

  @override
  Future<UserNotificationSettings> settingsForUser(String userId) async {
    _requireCurrentUser(userId);
    final result = await client.rpc<dynamic>('get_notification_preferences');
    final raw = _strictNotificationObject(result, '알림 설정 응답을 확인할 수 없습니다.');
    const expected = <String>{
      'committed',
      'changed',
      'version',
      'local_enabled',
      'push_enabled',
      'capability_local',
      'capability_push',
    };
    _strictNotificationKeys(raw, expected, '알림 설정 응답을 확인할 수 없습니다.');
    if (raw['committed'] != true ||
        raw['changed'] is! bool ||
        raw['version'] is! int ||
        (raw['version'] as int) < 0 ||
        raw['local_enabled'] is! bool ||
        raw['push_enabled'] is! bool ||
        raw['capability_local'] is! String ||
        raw['capability_push'] is! String) {
      throw const ScheduleConflictException('알림 설정 응답을 확인할 수 없습니다.');
    }
    final localCapability = _strictNotificationCapability(
      raw['capability_local'],
      '알림 설정 로컬 기능 상태를 확인할 수 없습니다.',
    );
    final pushCapability = _strictNotificationCapability(
      raw['capability_push'],
      '알림 설정 푸시 기능 상태를 확인할 수 없습니다.',
    );
    if ((raw['local_enabled'] as bool) !=
            (localCapability == 'client_local_scheduler') ||
        ((raw['push_enabled'] as bool) && pushCapability == 'disabled') ||
        (!(raw['push_enabled'] as bool) && pushCapability != 'disabled')) {
      throw const ScheduleConflictException('알림 설정 기능 상태를 확인할 수 없습니다.');
    }
    return UserNotificationSettings(
      userId: userId,
      // 원격 스키마에는 로컬 계정 전환이 하나 있다. UI 기능 표시에 사용할 별도
      // 로컬/푸시 프로젝션은 유지하면서 모델의 전체 제어 플래그를 local_enabled와 맞춘다.
      enabled: raw['local_enabled'] as bool,
      localEnabled: raw['local_enabled'] as bool,
      pushEnabled: raw['push_enabled'] as bool,
      version: raw['version'] as int,
    );
  }

  @override
  Future<UserNotificationSettings> saveSettings(
    UserNotificationSettings settings, {
    int? expectedVersion,
  }) async {
    _requireCurrentUser(settings.userId);
    final expected = expectedVersion ?? settings.version;
    final result = await client.rpc<dynamic>(
      'set_notification_preferences',
      params: <String, dynamic>{
        'p_local_enabled': settings.enabled && settings.localEnabled,
        // 푸시는 독립적으로 원하는 채널이다. 로컬 전체 제어가 꺼져 있어도 계정 의도를
        // 유지한다. 호출자가 처음 푸시를 켜려고 할 때 서버가 기능을 검증한다.
        'p_push_enabled': settings.pushEnabled,
        'p_expected_version': expected,
      },
    );
    final raw = _strictNotificationObject(result, '알림 설정 응답을 확인할 수 없습니다.');
    const expectedKeys = <String>{
      'committed',
      'changed',
      'version',
      'local_enabled',
      'push_enabled',
      'cancelled_jobs',
      'capability_local',
      'capability_push',
    };
    _strictNotificationKeys(raw, expectedKeys, '알림 설정 응답을 확인할 수 없습니다.');
    if (raw['committed'] != true ||
        raw['changed'] is! bool ||
        raw['version'] is! int ||
        (raw['version'] as int) < 1 ||
        raw['local_enabled'] is! bool ||
        raw['push_enabled'] is! bool ||
        raw['cancelled_jobs'] is! int ||
        (raw['cancelled_jobs'] as int) < 0) {
      throw const ScheduleConflictException('알림 설정 응답을 확인할 수 없습니다.');
    }
    final localCapability = _strictNotificationCapability(
      raw['capability_local'],
      '알림 설정 로컬 기능 상태를 확인할 수 없습니다.',
    );
    final pushCapability = _strictNotificationCapability(
      raw['capability_push'],
      '알림 설정 푸시 기능 상태를 확인할 수 없습니다.',
    );
    if ((raw['local_enabled'] as bool) !=
            (localCapability == 'client_local_scheduler') ||
        ((raw['push_enabled'] as bool) && pushCapability == 'disabled') ||
        (!(raw['push_enabled'] as bool) && pushCapability != 'disabled')) {
      throw const ScheduleConflictException('알림 설정 기능 상태를 확인할 수 없습니다.');
    }
    return UserNotificationSettings(
      userId: settings.userId,
      enabled: raw['local_enabled'] as bool,
      localEnabled: raw['local_enabled'] as bool,
      pushEnabled: raw['push_enabled'] as bool,
      version: raw['version'] as int,
    );
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForUser(
    String userId,
  ) async {
    _requireCurrentUser(userId);
    // 인증된 RPC는 의도적으로 한 번에 일정 하나만 노출한다. 이 메서드는 로컬 동등성을
    // 위해 남겨 둔다. 원격 호출자는 현재 편집 중인 일정에 preferencesForEvent를 사용해야 한다.
    return const <EventNotificationPreference>[];
  }

  @override
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async {
    _requireCurrentUser(userId);
    final result = await client.rpc<dynamic>(
      'get_event_reminder',
      params: <String, dynamic>{'p_event_id': eventId},
    );
    final raw = _strictNotificationObject(result, '일정 알림 설정 응답을 확인할 수 없습니다.');
    const expectedEnvelope = <String>{
      'committed',
      'changed',
      'event_id',
      'event_version',
      'settings',
      'capabilities',
    };
    _strictNotificationKeys(raw, expectedEnvelope, '일정 알림 설정 응답을 확인할 수 없습니다.');
    if (raw['committed'] != true ||
        raw['changed'] is! bool ||
        raw['event_id'] != eventId ||
        raw['event_version'] is! int ||
        (raw['event_version'] as int) < 1 ||
        raw['settings'] is! List) {
      throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
    }
    final capabilities = _strictNotificationObject(
      raw['capabilities'],
      '일정 알림 기능 상태를 확인할 수 없습니다.',
    );
    _strictNotificationKeys(capabilities, const <String>{
      'local',
      'push',
    }, '일정 알림 기능 상태를 확인할 수 없습니다.');
    final localCapability = _strictNotificationCapability(
      capabilities['local'],
      '일정 알림 로컬 기능 상태를 확인할 수 없습니다.',
    );
    final pushCapability = _strictNotificationCapability(
      capabilities['push'],
      '일정 알림 푸시 기능 상태를 확인할 수 없습니다.',
    );
    // 조회 RPC는 행이 없어도 기능을 보고한다. 이 봉투에는 두 문자열과 연결할 설정값이
    // 없지만, 위 검증을 유지하면 위조된 기능이 저장소 경계를 넘지 못한다.
    // 또한 향후 기능을 포함하는 상태 모델에서 사용할 수 있도록 값을 유지한다.
    if (localCapability == 'push_configured' ||
        localCapability == 'push_unconfigured' ||
        pushCapability == 'client_local_scheduler') {
      throw const ScheduleConflictException('일정 알림 기능 상태를 확인할 수 없습니다.');
    }
    final rows = raw['settings'] as List;
    if (rows.length > NotificationChannel.values.length) {
      throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
    }
    final output = <EventNotificationPreference>[];
    final seenChannels = <NotificationChannel>{};
    for (final item in rows) {
      final value = _strictNotificationObject(item, '일정 알림 설정 응답을 확인할 수 없습니다.');
      const keys = <String>{
        'id',
        'channel',
        'enabled',
        'lead_seconds',
        'all_day_days_before',
        'all_day_local_time',
        'version',
        'created_at',
        'updated_at',
      };
      _strictNotificationKeys(value, keys, '일정 알림 설정 응답을 확인할 수 없습니다.');
      if (value['all_day_local_time'] != '09:00:00' ||
          value['id'] is! String ||
          (value['id'] as String).trim().isEmpty ||
          value['enabled'] is! bool ||
          value['lead_seconds'] is! int ||
          (value['lead_seconds'] as int) < 0 ||
          (value['lead_seconds'] as int) > 7 * 24 * 60 * 60 ||
          value['all_day_days_before'] is! int ||
          (value['all_day_days_before'] as int) < 0 ||
          (value['all_day_days_before'] as int) > 366 ||
          value['version'] is! int ||
          (value['version'] as int) < 1 ||
          value['channel'] is! String) {
        throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
      }
      _strictNotificationUuid(value['id'], '일정 알림 설정 응답을 확인할 수 없습니다.');
      late final NotificationChannel channel;
      try {
        channel = NotificationChannelWire.parse(value['channel']);
      } on FormatException {
        throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
      }
      if (!seenChannels.add(channel)) {
        throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
      }
      final created = parseStrictExplicitOffsetTimestamp(value['created_at']);
      final updated = parseStrictExplicitOffsetTimestamp(value['updated_at']);
      if (created == null || updated == null) {
        throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
      }
      try {
        output.add(
          EventNotificationPreference(
            id: value['id'] as String,
            userId: userId,
            eventId: eventId,
            channel: channel,
            enabled: value['enabled'] as bool,
            timedLeadSeconds: value['lead_seconds'] as int,
            allDayDaysBefore: value['all_day_days_before'] as int,
            version: value['version'] as int,
            eventVersion: raw['event_version'] as int,
            updatedAt: updated,
          ),
        );
      } on FormatException {
        throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
      }
    }
    return List<EventNotificationPreference>.unmodifiable(output);
  }

  @override
  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference preference, {
    int? expectedVersion,
  }) async {
    _requireCurrentUser(preference.userId);
    final result = await client.rpc<dynamic>(
      'set_event_reminder',
      params: <String, dynamic>{
        'p_event_id': preference.eventId,
        'p_channel': preference.channel.wireName,
        'p_enabled': preference.enabled,
        'p_lead_seconds': preference.timedLeadSeconds,
        'p_all_day_days_before': preference.allDayDaysBefore,
        'p_expected_event_version': preference.eventVersion,
        'p_expected_setting_version': expectedVersion ?? preference.version,
      },
    );
    final raw = _strictNotificationObject(result, '일정 알림 설정 응답을 확인할 수 없습니다.');
    const expectedKeys = <String>{
      'committed',
      'changed',
      'event_id',
      'channel',
      'enabled',
      'lead_seconds',
      'all_day_days_before',
      'all_day_local_time',
      'setting_version',
      'event_version',
      'queued_jobs',
      'cancelled_jobs',
      'skipped_past',
      'capability',
    };
    _strictNotificationKeys(raw, expectedKeys, '일정 알림 설정 응답을 확인할 수 없습니다.');
    if (raw['committed'] != true ||
        raw['changed'] is! bool ||
        raw['event_id'] != preference.eventId ||
        raw['channel'] != preference.channel.wireName ||
        raw['enabled'] is! bool ||
        raw['lead_seconds'] is! int ||
        (raw['lead_seconds'] as int) < 0 ||
        (raw['lead_seconds'] as int) > 7 * 24 * 60 * 60 ||
        raw['all_day_days_before'] is! int ||
        (raw['all_day_days_before'] as int) < 0 ||
        (raw['all_day_days_before'] as int) > 366 ||
        raw['all_day_local_time'] != '09:00:00' ||
        raw['setting_version'] is! int ||
        (raw['setting_version'] as int) < 1 ||
        raw['event_version'] is! int ||
        (raw['event_version'] as int) < 1 ||
        raw['queued_jobs'] is! int ||
        (raw['queued_jobs'] as int) < 0 ||
        raw['cancelled_jobs'] is! int ||
        (raw['cancelled_jobs'] as int) < 0 ||
        raw['skipped_past'] is! int ||
        (raw['skipped_past'] as int) < 0) {
      throw const ScheduleConflictException('일정 알림 설정 응답을 확인할 수 없습니다.');
    }
    final capability = _strictNotificationCapability(
      raw['capability'],
      '일정 알림 기능 상태를 확인할 수 없습니다.',
    );
    if (preference.channel == NotificationChannel.local) {
      if (capability != 'client_local_scheduler' && capability != 'disabled') {
        throw const ScheduleConflictException('일정 알림 기능 상태를 확인할 수 없습니다.');
      }
    } else if (capability == 'client_local_scheduler') {
      throw const ScheduleConflictException('일정 알림 기능 상태를 확인할 수 없습니다.');
    }
    return preference.copyWith(
      enabled: raw['enabled'] as bool,
      timedLeadSeconds: raw['lead_seconds'] as int,
      allDayDaysBefore: raw['all_day_days_before'] as int,
      version: raw['setting_version'] as int,
      eventVersion: raw['event_version'] as int,
    );
  }

  @override
  Future<void> deleteEventPreference({
    required String userId,
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  }) async {
    _requireCurrentUser(userId);
    final settings = await preferencesForEvent(
      userId: userId,
      eventId: eventId,
    );
    final current = settings
        .where((value) => value.channel == channel)
        .firstOrNull;
    if (current == null) return;
    await saveEventPreference(
      current.copyWith(enabled: false),
      expectedVersion: expectedVersion ?? current.version,
    );
  }

  @override
  Future<ReminderCandidatePage> reminderCandidatesForUser({
    required String userId,
    required DateTime fireAtStart,
    required DateTime fireAtEnd,
    ReminderCandidateCursor? cursor,
    int limit = reminderPageLimit,
  }) async {
    _requireCurrentUser(userId);
    LocalNotificationRepository._validateCandidateRange(
      fireAtStart,
      fireAtEnd,
      limit,
    );
    final result = await client.rpc<dynamic>(
      'reminder_candidates_for_user',
      params: <String, dynamic>{
        'p_fire_at_start': fireAtStart.toUtc().toIso8601String(),
        'p_fire_at_end': fireAtEnd.toUtc().toIso8601String(),
        'p_limit': limit,
        'p_cursor': cursor?.encode(),
      },
    );
    return _parseCandidatePage(result, limit: limit, cursor: cursor);
  }

  static ReminderCandidatePage _parseCandidatePage(
    Object? result, {
    required int limit,
    required ReminderCandidateCursor? cursor,
  }) {
    if (result is! Map || result.keys.any((key) => key is! String)) {
      throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
    }
    final raw = Map<String, dynamic>.from(result);
    const expected = <String>{
      'candidates',
      'next_cursor',
      'has_more',
      'capability',
    };
    if (raw.length != expected.length ||
        raw.keys.toSet().difference(expected).isNotEmpty ||
        !expected.every(raw.containsKey) ||
        raw['candidates'] is! List ||
        raw['has_more'] is! bool ||
        raw['capability'] is! String) {
      throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
    }
    final rows = raw['candidates'] as List;
    if (rows.length > limit) {
      throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
    }
    final cursorRaw = raw['next_cursor'];
    if (cursorRaw != null && cursorRaw is! String) {
      throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
    }
    final next = cursorRaw == null
        ? null
        : ReminderCandidateCursor.decode(cursorRaw as String);
    final hasMore = raw['has_more'] as bool;
    if (hasMore != (next != null) || (hasMore && rows.length != limit)) {
      throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
    }
    final candidates = <ReminderCandidate>[];
    ReminderCandidate? previous;
    for (final item in rows) {
      late final ReminderCandidate candidate;
      try {
        candidate = ReminderCandidate.fromJson(item);
      } on FormatException {
        // 전송/모델 파싱 오류는 저장소의 형식 지정 경계 안에 둔다. 호출자가 잘못된
        // 원격 JSON과 다른 유효하지 않은 RPC 처리 결과를 구분할 필요가 없어야 한다.
        throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
      }
      if (candidate.channel != NotificationChannel.local ||
          (previous != null && _compareCandidate(previous, candidate) >= 0) ||
          (cursor != null && !_isAfterCandidate(candidate, cursor))) {
        throw const ScheduleConflictException('알림 후보 응답을 확인할 수 없습니다.');
      }
      previous = candidate;
      candidates.add(candidate);
    }
    if (next != null &&
        previous != null &&
        (next.fireAt != previous.fireAt ||
            next.eventId != previous.eventId ||
            next.occurrenceKey != previous.occurrenceKey ||
            next.channel != previous.channel)) {
      throw const ScheduleConflictException('알림 후보 커서를 확인할 수 없습니다.');
    }
    final capability = switch (raw['capability']) {
      'client_local_scheduler' ||
      'available' => NotificationCapabilityState.available,
      'unconfigured' => NotificationCapabilityState.unconfigured,
      'unsupported' => NotificationCapabilityState.unsupported,
      'disabled' => NotificationCapabilityState.disabled,
      _ => throw const ScheduleConflictException('알림 후보 기능 상태를 확인할 수 없습니다.'),
    };
    return ReminderCandidatePage(
      candidates: candidates,
      nextCursor: next,
      hasMore: hasMore,
      capability: capability,
    );
  }

  static int _compareCandidate(
    ReminderCandidate left,
    ReminderCandidate right,
  ) {
    final fire = left.fireAt.compareTo(right.fireAt);
    if (fire != 0) return fire;
    final event = left.eventId.compareTo(right.eventId);
    if (event != 0) return event;
    final occurrence = left.occurrenceKey.compareTo(right.occurrenceKey);
    if (occurrence != 0) return occurrence;
    return left.channel.wireName.compareTo(right.channel.wireName);
  }

  static bool _isAfterCandidate(
    ReminderCandidate candidate,
    ReminderCandidateCursor cursor,
  ) {
    final fire = candidate.fireAt.compareTo(cursor.fireAt);
    if (fire != 0) return fire > 0;
    final event = candidate.eventId.compareTo(cursor.eventId);
    if (event != 0) return event > 0;
    final occurrence = candidate.occurrenceKey.compareTo(cursor.occurrenceKey);
    if (occurrence != 0) return occurrence > 0;
    return candidate.channel.wireName.compareTo(cursor.channel.wireName) > 0;
  }
}

/// 설정 때문에 차단된 프로덕션 어댑터다. 상태/UI에 이를 명확히 표시하고 알림이
/// 예약된 것처럼 절대 가장하지 않는다.
class ConfigurationBlockedNotificationRepository
    implements NotificationRepository {
  ConfigurationBlockedNotificationRepository(this.message);

  final String message;

  @override
  NotificationCapabilityState get capability =>
      NotificationCapabilityState.unconfigured;

  ScheduleCapabilityException get _error =>
      ScheduleCapabilityException(message);

  @override
  Future<UserNotificationSettings> settingsForUser(String userId) async =>
      UserNotificationSettings(userId: userId);

  @override
  Future<UserNotificationSettings> saveSettings(
    UserNotificationSettings settings, {
    int? expectedVersion,
  }) => Future<UserNotificationSettings>.error(_error);

  @override
  Future<List<EventNotificationPreference>> preferencesForUser(
    String userId,
  ) async => const <EventNotificationPreference>[];

  @override
  Future<List<EventNotificationPreference>> preferencesForEvent({
    required String userId,
    required String eventId,
  }) async => const <EventNotificationPreference>[];

  @override
  Future<EventNotificationPreference> saveEventPreference(
    EventNotificationPreference preference, {
    int? expectedVersion,
  }) => Future<EventNotificationPreference>.error(_error);

  @override
  Future<void> deleteEventPreference({
    required String userId,
    required String eventId,
    required NotificationChannel channel,
    int? expectedVersion,
  }) => Future<void>.error(_error);

  @override
  Future<ReminderCandidatePage> reminderCandidatesForUser({
    required String userId,
    required DateTime fireAtStart,
    required DateTime fireAtEnd,
    ReminderCandidateCursor? cursor,
    int limit = reminderPageLimit,
  }) async => ReminderCandidatePage.empty(
    capability: NotificationCapabilityState.unconfigured,
  );
}
