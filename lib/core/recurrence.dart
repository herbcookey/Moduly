import 'package:flutter/foundation.dart';

import '../models/app_models.dart';
import 'timezone_utils.dart';

/// 반복 시리즈에서 구체화된 하나의 프로젝션이다. 기준 일정 ID는 유지하면서
/// 전역적으로 안정적인 순번 키를 노출한다.
@immutable
class RecurrenceOccurrence {
  const RecurrenceOccurrence({required this.event, required this.ordinal});

  final PlannerEvent event;
  final int ordinal;
}

/// 반복 규칙의 순번 0이 사용하는 첫 현지 날짜다. 월간 규칙에서
/// 기준 달의 대상 날짜가 이미 지났으면 다음 달의 첫 유효한 날짜를 쓴다.
/// [RecurrenceRule.interval]은 순번 0을 더 늦추지 않고 그 뒤 발생분 사이에만
/// 적용된다. 반환값은 시간대 시각이 아닌 날짜 튜플이다.
DateTime recurrenceFirstOccurrenceDate(DateTime anchor, RecurrenceRule rule) {
  final anchorDate = dateOnly(anchor);
  if (rule.frequency != RecurrenceFrequency.monthly) return anchorDate;

  final anchorWall = DateTime.utc(
    anchorDate.year,
    anchorDate.month,
    anchorDate.day,
  );
  final firstMonth = _firstMonthlyOccurrenceMonth(anchorWall, rule.monthlyDay!);
  final firstWall = _monthlyOccurrenceWall(
    anchorWall,
    rule.monthlyDay!,
    firstMonth,
  );
  return DateTime(firstWall.year, firstWall.month, firstWall.day);
}

/// 제한된 달력 범위에 걸쳐 시리즈를 확장한다. 탐색 계산은 날짜/월/주 오프셋을
/// 산술적으로 구하므로 수년 전에 시작한 시리즈의 모든 과거 발생분을 순회할 필요가
/// 없다. [maxOccurrences]는 잘못되었거나 끝나지 않는 규칙에 적용하는 방어적인
/// 페이지 독립 상한이다.
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
      // 모델의 날짜 전용 메타데이터는 소스 호환성을 유지한다. 이 메타데이터에는 시간대
      // 의미가 없지만, 위의 모든 계산은 UTC 태그가 붙은 민간력 튜플로 수행한다.
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
      // 긴 일정에 대비해 산술 탐색 지점보다 한 간격 앞도 포함한다.
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
          // 긴 일정은 여전히 겹칠 수 있으므로 후보 하나를 더 확인하고, 시작 시각이
          // 종료 경계를 넘으면 중단한다.
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

/// 딥 링크에서 사용하는 산술 지점 조회다. 요청된 순번을 직접 계산하므로 아주
/// 오래전에 시작한 시리즈나 제한된 페이지 확장 상한을 훨씬 넘는 순번에도 정확하다.
PlannerEvent? recurringOccurrenceAtIndex(
  PlannerEvent series,
  int ordinal, {
  int ordinalOffset = 0,
}) {
  // PostgreSQL 구체화기는 날짜를 만들기 전에 날짜 계산을 의도적으로 부호 있는 int32
  // 오프셋으로 제한한다. 키 자체는 유효한 부호 있는 bigint 발생 식별자일 수 있으므로,
  // 지점 조회에서는 이 계산 범위 밖의 순번을 누락된 발생분으로 처리해야 한다.
  // 거대한 탐색값 때문에 Duration/DateTime이 예외를 던지게 해서는 안 된다.
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
      final firstMonth = _firstMonthlyOccurrenceMonth(
        anchorWall,
        rule.monthlyDay!,
      );
      wall = _monthlyOccurrenceWall(
        anchorWall,
        rule.monthlyDay!,
        firstMonth + localOrdinal * rule.interval,
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
  final firstMonth = _firstMonthlyOccurrenceMonth(anchorWall, day);
  final seekDate = civilDateOnly(
    rangeStartWall,
  ).subtract(Duration(days: _wallDurationDays(wallDuration)));
  final seekMonth = seekDate.year * 12 + seekDate.month - 1;
  var index = seekMonth <= firstMonth
      ? 0
      : ((seekMonth - firstMonth) / rule.interval).floor();
  if (index > 0) index--;
  for (var generated = 0; generated < maxOccurrences; generated++, index++) {
    final wall = _monthlyOccurrenceWall(
      anchorWall,
      day,
      firstMonth + index * rule.interval,
    );
    if (wall.isAfter(rangeEndWall)) break;
    if (wall.isBefore(anchorWall)) continue;
    addCandidate(wall, index);
    if (!_withinRule(rule, wall, index) && rule.end != RecurrenceEnd.never) {
      break;
    }
  }
}

int _firstMonthlyOccurrenceMonth(DateTime anchorWall, int monthlyDay) {
  final anchorMonth = anchorWall.year * 12 + anchorWall.month - 1;
  final candidate = _monthlyOccurrenceWall(anchorWall, monthlyDay, anchorMonth);
  return candidate.isBefore(anchorWall) ? anchorMonth + 1 : anchorMonth;
}

DateTime _monthlyOccurrenceWall(
  DateTime anchorWall,
  int monthlyDay,
  int monthValue,
) {
  final year = monthValue ~/ 12;
  final month = monthValue % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  return DateTime.utc(
    year,
    month,
    monthlyDay > lastDay ? lastDay : monthlyDay,
    anchorWall.hour,
    anchorWall.minute,
    anchorWall.second,
    anchorWall.millisecond,
    anchorWall.microsecond,
  );
}

int _compareOccurrences(PlannerEvent left, PlannerEvent right) {
  final byStart = left.startAt.toUtc().compareTo(right.startAt.toUtc());
  if (byStart != 0) return byStart;
  final byId = left.id.compareTo(right.id);
  if (byId != 0) return byId;
  return left.occurrenceKey.compareTo(right.occurrenceKey);
}
