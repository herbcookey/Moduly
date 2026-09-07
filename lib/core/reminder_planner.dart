import 'package:flutter/foundation.dart';

import '../models/app_models.dart';
import '../models/notification_models.dart';
import 'notification_identity.dart';
import 'timezone_utils.dart';

/// One bounded reminder ready for ID allocation and a native scheduler.
@immutable
class PlannedReminder {
  const PlannedReminder({
    required this.identity,
    required this.groupId,
    required this.eventId,
    required this.occurrenceKey,
    required this.fireAt,
    required this.title,
    required this.timezone,
    required this.payload,
  });

  final ReminderIdentity identity;
  final String groupId;
  final String eventId;
  final String occurrenceKey;
  final DateTime fireAt;
  final String title;
  final String timezone;
  final NotificationPayload payload;

  NotificationScheduleRequest withId(int id) => NotificationScheduleRequest(
    notificationId: id,
    fireAt: fireAt,
    title: title,
    payload: payload,
    timezone: timezone,
  );
}

/// Pure local parity planner.  It accepts already-authorized event rows and
/// never performs an unbounded repository read.  The Supabase candidate RPC
/// can feed [fromCandidates] when the server has materialized the same
/// occurrence/fire-at semantics.
class ReminderPlanner {
  const ReminderPlanner._();

  static List<PlannedReminder> plan({
    required String userId,
    required Iterable<PlannerEvent> events,
    required UserNotificationSettings settings,
    required Iterable<EventNotificationPreference> preferences,
    DateTime? nowUtc,
    Duration horizon = reminderPlanningHorizon,
    int maxReminders = reminderPlanningLimit,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    _validateWindow(now, horizon, maxReminders);
    if (!settings.localDesired) return const <PlannedReminder>[];
    final prefByEvent = <String, EventNotificationPreference>{};
    for (final preference in preferences) {
      if (preference.userId != userId ||
          preference.channel != NotificationChannel.local ||
          !preference.enabled) {
        continue;
      }
      // A duplicate preference is ambiguous and must not cause duplicate
      // scheduling. Keep the highest version; equal versions use the stable
      // lexical id so local and remote adapters agree.
      final previous = prefByEvent[preference.eventId];
      if (previous == null ||
          preference.version > previous.version ||
          (preference.version == previous.version &&
              preference.id.compareTo(previous.id) < 0)) {
        prefByEvent[preference.eventId] = preference;
      }
    }
    final byIdentity = <String, PlannedReminder>{};
    for (final event in events) {
      if (event.isDeleted || !event.memberIds.contains(userId)) continue;
      final preference = prefByEvent[event.seriesId] ?? prefByEvent[event.id];
      if (preference == null) continue;
      final fireAt = fireAtFor(event, preference);
      if (fireAt == null ||
          fireAt.isBefore(now) ||
          !fireAt.isBefore(now.add(horizon))) {
        continue;
      }
      final unit = event.allDay
          ? NotificationOffsetUnit.calendarDays
          : NotificationOffsetUnit.seconds;
      final value = preference.offsetFor(allDay: event.allDay);
      final identity = ReminderIdentity(
        userId: userId,
        eventId: event.seriesId,
        occurrenceKey: event.occurrenceKey,
        offsetValue: value,
        offsetUnit: unit,
        channel: NotificationChannel.local,
      );
      final planned = PlannedReminder(
        identity: identity,
        groupId: event.groupId,
        eventId: event.id,
        occurrenceKey: event.occurrenceKey,
        fireAt: fireAt,
        title: event.title,
        timezone: event.timezone,
        payload: NotificationPayload(
          eventId: event.id,
          groupId: event.groupId,
          occurrenceKey: event.occurrenceKey,
        ),
      );
      final key = identity.stableKey;
      final existing = byIdentity[key];
      if (existing == null || _comparePlanned(planned, existing) < 0) {
        byIdentity[key] = planned;
      }
    }
    final output = byIdentity.values.toList()..sort(_comparePlanned);
    return List<PlannedReminder>.unmodifiable(output.take(maxReminders));
  }

  /// Converts trusted candidate rows returned by the all-group RPC to native
  /// requests. The candidate's fire-at is authoritative; offset is derived
  /// only for the stable identity and collision registry key.
  static List<PlannedReminder> fromCandidates({
    required String userId,
    required Iterable<ReminderCandidate> candidates,
    DateTime? nowUtc,
    Duration horizon = reminderPlanningHorizon,
    int maxReminders = reminderPlanningLimit,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    _validateWindow(now, horizon, maxReminders);
    final byIdentity = <String, PlannedReminder>{};
    for (final candidate in candidates) {
      if (candidate.channel != NotificationChannel.local ||
          candidate.fireAt.isBefore(now) ||
          !candidate.fireAt.isBefore(now.add(horizon))) {
        continue;
      }
      final isAllDay = candidate.isAllDay;
      final unit = isAllDay
          ? NotificationOffsetUnit.calendarDays
          : NotificationOffsetUnit.seconds;
      final offset = _candidateOffset(candidate);
      final identity = ReminderIdentity(
        userId: userId,
        eventId: candidate.eventId,
        occurrenceKey: candidate.occurrenceKey,
        offsetValue: offset,
        offsetUnit: unit,
        channel: candidate.channel,
      );
      final planned = PlannedReminder(
        identity: identity,
        groupId: candidate.groupId,
        eventId: candidate.eventId,
        occurrenceKey: candidate.occurrenceKey,
        fireAt: candidate.fireAt,
        title: candidate.title,
        timezone: candidate.timezone,
        payload: NotificationPayload(
          eventId: candidate.eventId,
          groupId: candidate.groupId,
          occurrenceKey: candidate.occurrenceKey,
        ),
      );
      final existing = byIdentity[identity.stableKey];
      if (existing == null || _comparePlanned(planned, existing) < 0) {
        byIdentity[identity.stableKey] = planned;
      }
    }
    final output = byIdentity.values.toList()..sort(_comparePlanned);
    return List<PlannedReminder>.unmodifiable(output.take(maxReminders));
  }

  static DateTime? fireAtFor(
    PlannerEvent event,
    EventNotificationPreference preference,
  ) {
    if (event.allDay) {
      final startDate = civilDateOnly(
        event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
      );
      final reminderDate = civilDateAdd(
        startDate,
        -preference.allDayDaysBefore,
      );
      final wall = DateTime.utc(
        reminderDate.year,
        reminderDate.month,
        reminderDate.day,
        9,
      );
      return wallTimeToUtc(wall, event.timezone);
    }
    return event.startAt.toUtc().subtract(
      Duration(seconds: preference.timedLeadSeconds),
    );
  }

  static int _candidateOffset(ReminderCandidate candidate) {
    if (!candidate.isAllDay) {
      final seconds = candidate.startsAt.difference(candidate.fireAt).inSeconds;
      return seconds < 0 ? 0 : seconds;
    }
    final startDate = civilDateOnly(
      candidate.allDayStartDate ??
          utcToWallTime(candidate.startsAt, candidate.timezone),
    );
    final fireWall = utcToWallTime(candidate.fireAt, candidate.timezone);
    final fireDate = civilDateOnly(fireWall);
    return startDate.difference(fireDate).inDays.clamp(0, 366);
  }

  static int _comparePlanned(PlannedReminder left, PlannedReminder right) {
    final byFire = left.fireAt.compareTo(right.fireAt);
    if (byFire != 0) return byFire;
    final byEvent = left.eventId.compareTo(right.eventId);
    if (byEvent != 0) return byEvent;
    final byOccurrence = left.occurrenceKey.compareTo(right.occurrenceKey);
    if (byOccurrence != 0) return byOccurrence;
    return left.identity.channel.wireName.compareTo(
      right.identity.channel.wireName,
    );
  }

  static void _validateWindow(
    DateTime now,
    Duration horizon,
    int maxReminders,
  ) {
    if (!now.isUtc ||
        horizon <= Duration.zero ||
        horizon > const Duration(days: 366) ||
        maxReminders < 1 ||
        maxReminders > reminderPlanningLimit) {
      throw ArgumentError('알림 계획 범위를 확인해 주세요.');
    }
  }
}
