import 'package:flutter/foundation.dart';

import '../models/app_models.dart';
import 'timezone_utils.dart';

/// One materialized projection of a recurring series.  The projection keeps
/// its anchor event id while exposing a globally stable ordinal key.
@immutable
class RecurrenceOccurrence {
  const RecurrenceOccurrence({required this.event, required this.ordinal});

  final PlannerEvent event;
  final int ordinal;
}

/// Expands a series over a bounded calendar range.  The seek calculations are
/// arithmetic (date/month/week offsets) so a series anchored years ago does
/// not require walking every historical occurrence.  [maxOccurrences] is a
/// defensive page-independent cap for malformed/never-ending rules.
List<PlannerEvent> expandRecurringEvent(
  PlannerEvent series,
  EventRange range, {
  int maxOccurrences = 5000,
  int ordinalOffset = 0,
}) {
  final rule = series.recurrenceRule;
  if (rule == null || maxOccurrences < 1) return const <PlannerEvent>[];
  final timezone = validateIanaTimezone(series.timezone);
  final anchorWall = series.allDay
      ? civilDateOnly(
          series.allDayStartDate ?? utcToWallTime(series.startAt, timezone),
        )
      : utcToCivilWallTimePrecise(series.startAt, timezone);
  final rangeStartWall = utcToCivilWallTimePrecise(range.startUtc, timezone);
  final rangeEndWall = utcToCivilWallTimePrecise(range.endUtc, timezone);
  final wallDuration = series.allDay
      ? Duration(
          days: civilDateOnly(
            series.allDayEndDate ?? utcToWallTime(series.endAt, timezone),
          ).difference(civilDateOnly(anchorWall)).inDays,
        )
      : utcToCivilWallTimePrecise(
          series.endAt,
          timezone,
        ).difference(anchorWall);
  if (wallDuration <= Duration.zero) return const <PlannerEvent>[];

  final output = <PlannerEvent>[];
  void addCandidate(DateTime wallStart, int localOrdinal) {
    final ordinal = ordinalOffset + localOrdinal;
    if (output.length >= maxOccurrences ||
        !_withinRule(rule, wallStart, localOrdinal)) {
      return;
    }
    final wallEnd = wallStart.add(wallDuration);
    final startsAt = wallTimeToUtc(wallStart, timezone);
    final endsAt = wallTimeToUtc(wallEnd, timezone);
    final candidate = series.copyWith(
      startAt: startsAt,
      endAt: endsAt,
      scheduledStartsAt: startsAt,
      scheduledEndsAt: endsAt,
      occurrenceKey: occurrenceKeyForIndex(ordinal),
      occurrenceIndex: ordinal,
      occurrenceVersion: series.recurrenceRule == null
          ? series.occurrenceVersion
          : 0,
      isOccurrence: true,
      // Keep the model's date-only metadata source-compatible (the metadata
      // has no timezone semantics), while all arithmetic above remains on
      // UTC-tagged civil tuples.
      allDayStartDate: series.allDay ? dateOnly(wallStart) : null,
      allDayEndDate: series.allDay ? dateOnly(wallEnd) : null,
      clearAllDayDates: !series.allDay,
    );
    if (eventOverlapsCalendarRange(candidate, range)) output.add(candidate);
  }

  switch (rule.frequency) {
    case RecurrenceFrequency.daily:
      final anchorDate = civilDateOnly(anchorWall);
      final firstDate = civilDateOnly(
        rangeStartWall,
      ).subtract(Duration(days: _wallDurationDays(wallDuration)));
      final dayDelta = firstDate.difference(anchorDate).inDays;
      var index = dayDelta <= 0 ? 0 : (dayDelta / rule.interval).floor();
      if (index < 0) index = 0;
      // Include one interval before the arithmetic seek for long events.
      if (index > 0 &&
          anchorDate
              .add(Duration(days: index * rule.interval))
              .isAfter(firstDate)) {
        index--;
      }
      for (
        var generated = 0;
        generated < maxOccurrences;
        generated++, index++
      ) {
        final date = anchorDate.add(Duration(days: index * rule.interval));
        final wall = DateTime.utc(
          date.year,
          date.month,
          date.day,
          anchorWall.hour,
          anchorWall.minute,
          anchorWall.second,
          anchorWall.millisecond,
          anchorWall.microsecond,
        );
        if (wall.isAfter(rangeEndWall) &&
            !wall.add(wallDuration).isBefore(rangeStartWall)) {
          // A long event may still overlap; continue one candidate and then
          // stop once its start is beyond the end boundary.
          addCandidate(wall, index);
          break;
        }
        if (wall.isAfter(rangeEndWall)) break;
        addCandidate(wall, index);
        if (!_withinRule(rule, wall, index) &&
            rule.end != RecurrenceEnd.never) {
          break;
        }
      }
    case RecurrenceFrequency.weekly:
      _expandWeekly(
        series: series,
        rule: rule,
        anchorWall: anchorWall,
        rangeStartWall: rangeStartWall,
        rangeEndWall: rangeEndWall,
        wallDuration: wallDuration,
        addCandidate: addCandidate,
        maxOccurrences: maxOccurrences,
      );
    case RecurrenceFrequency.monthly:
      _expandMonthly(
        series: series,
        rule: rule,
        anchorWall: anchorWall,
        rangeStartWall: rangeStartWall,
        rangeEndWall: rangeEndWall,
        wallDuration: wallDuration,
        addCandidate: addCandidate,
        maxOccurrences: maxOccurrences,
      );
  }
  output.sort(_compareOccurrences);
  return List<PlannerEvent>.unmodifiable(output);
}

/// Arithmetic point lookup used by deep links.  It computes the requested
/// ordinal directly and therefore remains correct for a series anchored far in
/// the past (or an ordinal well beyond the bounded page expansion cap).
PlannerEvent? recurringOccurrenceAtIndex(
  PlannerEvent series,
  int ordinal, {
  int ordinalOffset = 0,
}) {
  // PostgreSQL's materializer intentionally bounds date arithmetic to a
  // signed int32 offset before constructing a date. A key can still be a
  // valid signed-bigint occurrence identity, so point reads must treat an
  // ordinal outside this arithmetic domain as a missing occurrence instead
  // of allowing Duration/DateTime to throw on an enormous seek.
  if (ordinal < 0 ||
      ordinalOffset < 0 ||
      ordinal > 2147483647 ||
      ordinalOffset > 2147483647) {
    return null;
  }
  try {
    return _recurringOccurrenceAtIndex(
      series,
      ordinal,
      ordinalOffset: ordinalOffset,
    );
  } on RangeError {
    return null;
  } on ArgumentError {
    return null;
  }
}

PlannerEvent? _recurringOccurrenceAtIndex(
  PlannerEvent series,
  int ordinal, {
  required int ordinalOffset,
}) {
  final rule = series.recurrenceRule;
  if (rule == null || ordinal < ordinalOffset) return null;
  final localOrdinal = ordinal - ordinalOffset;
  final timezone = validateIanaTimezone(series.timezone);
  final anchorWall = series.allDay
      ? civilDateOnly(
          series.allDayStartDate ?? utcToWallTime(series.startAt, timezone),
        )
      : utcToCivilWallTimePrecise(series.startAt, timezone);
  final wallDuration = series.allDay
      ? Duration(
          days: civilDateOnly(
            series.allDayEndDate ?? utcToWallTime(series.endAt, timezone),
          ).difference(civilDateOnly(anchorWall)).inDays,
        )
      : utcToCivilWallTimePrecise(
          series.endAt,
          timezone,
        ).difference(anchorWall);
  if (wallDuration <= Duration.zero ||
      !_withinRule(rule, anchorWall, localOrdinal)) {
    return null;
  }
  DateTime wall;
  switch (rule.frequency) {
    case RecurrenceFrequency.daily:
      wall = anchorWall.add(Duration(days: localOrdinal * rule.interval));
    case RecurrenceFrequency.weekly:
      final firstWeekCount = rule.weekdays
          .where((day) => day >= anchorWall.weekday)
          .length;
      final anchorDate = civilDateOnly(anchorWall);
      final anchorMonday = anchorDate.subtract(
        Duration(days: anchorDate.weekday - 1),
      );
      late final int weekIndex;
      late final int weekday;
      if (localOrdinal < firstWeekCount) {
        weekIndex = 0;
        weekday = rule.weekdays
            .where((day) => day >= anchorDate.weekday)
            .elementAt(localOrdinal);
      } else {
        final remaining = localOrdinal - firstWeekCount;
        weekIndex = 1 + remaining ~/ rule.weekdays.length;
        weekday = rule.weekdays[remaining % rule.weekdays.length];
      }
      final date = anchorMonday.add(
        Duration(days: weekIndex * rule.interval * 7 + weekday - 1),
      );
      wall = DateTime.utc(
        date.year,
        date.month,
        date.day,
        anchorWall.hour,
        anchorWall.minute,
        anchorWall.second,
        anchorWall.millisecond,
        anchorWall.microsecond,
      );
    case RecurrenceFrequency.monthly:
      final monthValue =
          anchorWall.year * 12 +
          anchorWall.month -
          1 +
          localOrdinal * rule.interval;
      final year = monthValue ~/ 12;
      final month = monthValue % 12 + 1;
      final lastDay = DateTime.utc(year, month + 1, 0).day;
      final day = rule.monthlyDay! > lastDay ? lastDay : rule.monthlyDay!;
      wall = DateTime.utc(
        year,
        month,
        day,
        anchorWall.hour,
        anchorWall.minute,
        anchorWall.second,
        anchorWall.millisecond,
        anchorWall.microsecond,
      );
  }
  if (wall.isBefore(anchorWall) || !_withinRule(rule, wall, localOrdinal)) {
    return null;
  }
  final startsAt = wallTimeToUtc(wall, timezone);
  final endsAt = wallTimeToUtc(wall.add(wallDuration), timezone);
  return series.copyWith(
    startAt: startsAt,
    endAt: endsAt,
    scheduledStartsAt: startsAt,
    scheduledEndsAt: endsAt,
    occurrenceKey: occurrenceKeyForIndex(ordinal),
    occurrenceIndex: ordinal,
    occurrenceVersion: series.recurrenceRule == null
        ? series.occurrenceVersion
        : 0,
    isOccurrence: true,
    allDayStartDate: series.allDay ? dateOnly(wall) : null,
    allDayEndDate: series.allDay ? dateOnly(wall.add(wallDuration)) : null,
    clearAllDayDates: !series.allDay,
  );
}

int _wallDurationDays(Duration value) {
  if (value <= Duration.zero) return 0;
  return value.inDays +
      (value.inMicroseconds % Duration.microsecondsPerDay == 0 ? 0 : 1);
}

bool _withinRule(RecurrenceRule rule, DateTime wall, int ordinal) {
  if (rule.end == RecurrenceEnd.count &&
      (rule.count == null || ordinal >= rule.count!)) {
    return false;
  }
  if (rule.end == RecurrenceEnd.until &&
      (rule.untilDate == null ||
          civilDateOnly(wall).isAfter(civilDateOnly(rule.untilDate!)))) {
    return false;
  }
  return true;
}

void _expandWeekly({
  required PlannerEvent series,
  required RecurrenceRule rule,
  required DateTime anchorWall,
  required DateTime rangeStartWall,
  required DateTime rangeEndWall,
  required Duration wallDuration,
  required void Function(DateTime, int) addCandidate,
  required int maxOccurrences,
}) {
  final anchorDate = civilDateOnly(anchorWall);
  final anchorMonday = anchorDate.subtract(
    Duration(days: anchorDate.weekday - 1),
  );
  final rangeDate = civilDateOnly(
    rangeStartWall,
  ).subtract(Duration(days: _wallDurationDays(wallDuration)));
  final rangeMonday = rangeDate.subtract(Duration(days: rangeDate.weekday - 1));
  final weekDelta = rangeMonday.difference(anchorMonday).inDays ~/ 7;
  var weekIndex = weekDelta <= 0 ? 0 : (weekDelta / rule.interval).floor();
  if (weekIndex > 0) weekIndex--;
  final firstWeekCount = rule.weekdays
      .where((day) => day >= anchorDate.weekday)
      .length;
  for (
    var generatedWeeks = 0;
    generatedWeeks < maxOccurrences;
    generatedWeeks++, weekIndex++
  ) {
    final weekStart = anchorMonday.add(
      Duration(days: weekIndex * rule.interval * 7),
    );
    for (final weekday in rule.weekdays) {
      final wall = weekStart.add(Duration(days: weekday - 1));
      if (weekIndex == 0 && wall.isBefore(anchorDate)) continue;
      final ordinal = weekIndex == 0
          ? rule.weekdays
                    .where((day) => day >= anchorDate.weekday && day <= weekday)
                    .length -
                1
          : firstWeekCount +
                (weekIndex - 1) * rule.weekdays.length +
                rule.weekdays.where((day) => day <= weekday).length -
                1;
      if (wall.isBefore(anchorDate) || wall.isAfter(rangeEndWall)) continue;
      addCandidate(
        DateTime.utc(
          wall.year,
          wall.month,
          wall.day,
          anchorWall.hour,
          anchorWall.minute,
          anchorWall.second,
          anchorWall.millisecond,
          anchorWall.microsecond,
        ),
        ordinal,
      );
      if (!_withinRule(rule, wall, ordinal) &&
          rule.end != RecurrenceEnd.never) {
        return;
      }
    }
    if (weekStart.isAfter(rangeEndWall)) break;
  }
}

void _expandMonthly({
  required PlannerEvent series,
  required RecurrenceRule rule,
  required DateTime anchorWall,
  required DateTime rangeStartWall,
  required DateTime rangeEndWall,
  required Duration wallDuration,
  required void Function(DateTime, int) addCandidate,
  required int maxOccurrences,
}) {
  final day = rule.monthlyDay!;
  final anchorMonth = anchorWall.year * 12 + anchorWall.month - 1;
  final seekDate = civilDateOnly(
    rangeStartWall,
  ).subtract(Duration(days: _wallDurationDays(wallDuration)));
  final seekMonth = seekDate.year * 12 + seekDate.month - 1;
  var index = seekMonth <= anchorMonth
      ? 0
      : ((seekMonth - anchorMonth) / rule.interval).floor();
  if (index > 0) index--;
  for (var generated = 0; generated < maxOccurrences; generated++, index++) {
    final monthValue = anchorMonth + index * rule.interval;
    final year = monthValue ~/ 12;
    final month = monthValue % 12 + 1;
    final lastDay = DateTime.utc(year, month + 1, 0).day;
    final wall = DateTime.utc(
      year,
      month,
      day > lastDay ? lastDay : day,
      anchorWall.hour,
      anchorWall.minute,
      anchorWall.second,
      anchorWall.millisecond,
      anchorWall.microsecond,
    );
    if (wall.isAfter(rangeEndWall)) break;
    if (wall.isBefore(anchorWall)) continue;
    addCandidate(wall, index);
    if (!_withinRule(rule, wall, index) && rule.end != RecurrenceEnd.never) {
      break;
    }
  }
}

int _compareOccurrences(PlannerEvent left, PlannerEvent right) {
  final byStart = left.startAt.toUtc().compareTo(right.startAt.toUtc());
  if (byStart != 0) return byStart;
  final byId = left.id.compareTo(right.id);
  if (byId != 0) return byId;
  return left.occurrenceKey.compareTo(right.occurrenceKey);
}
