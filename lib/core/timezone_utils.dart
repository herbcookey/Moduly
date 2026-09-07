import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_models.dart';

/// The default used by the preview UI and by legacy callers that predate
/// caller-selected group timezones.
const defaultPlannerTimezone = 'Asia/Seoul';

void _ensureTimezoneDatabase() {
  // `main.dart` initializes the database for normal app launches, but keeping
  // this lazy guard makes repositories and utilities safe in isolates/tests
  // that call them directly.
  if (!tz.timeZoneDatabase.isInitialized) {
    tzdata.initializeTimeZones();
  }
}

/// Returns whether [name] is an exact timezone name present in the bundled
/// IANA database. Whitespace and empty names are rejected instead of silently
/// falling back to UTC.
bool isValidIanaTimezone(String name) {
  if (name.isEmpty || name.trim() != name) return false;
  _ensureTimezoneDatabase();
  try {
    final location = tz.getLocation(name);
    return location.name == name;
  } catch (_) {
    return false;
  }
}

/// Alias used by callers that refer to IANA zones simply as timezones.
bool isValidTimezone(String name) => isValidIanaTimezone(name);

/// Validates a caller-supplied timezone and returns its exact value.
String validateIanaTimezone(String name) {
  if (!isValidIanaTimezone(name)) {
    throw const FormatException('시간대를 확인해 주세요.');
  }
  return name;
}

/// IANA 시간대를 해석한다. 잘못된 프로필 데이터에는 안전한 UTC 대체값을
/// 사용하며, 데이터베이스가 클라이언트에 전달하기 전에 값을 검증한다.
tz.Location plannerLocation(String name) {
  _ensureTimezoneDatabase();
  try {
    return tz.getLocation(name);
  } catch (_) {
    return tz.UTC;
  }
}

/// IANA 시간대에 입력한 벽시계 값을 UTC 시각으로 변환한다.
DateTime wallTimeToUtc(DateTime wall, String timezone) {
  final location = plannerLocation(timezone);
  // `timezone` resolves an autumn fold to the earlier (DST) offset.  Planner
  // wall times use the deterministic standard-time side instead.  Enumerate
  // nearby offsets and retain every exact round trip, choosing the latest UTC
  // instant for an ambiguous fold.  For a spring gap there is no exact round
  // trip; fall back to TZDateTime's documented forward resolution.
  final naive = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  );
  final naiveMillis = naive.millisecondsSinceEpoch;
  final offsets = <int>{};
  for (var hour = -48; hour <= 48; hour++) {
    offsets.add(
      location
          .lookupTimeZone(naiveMillis + hour * Duration.millisecondsPerHour)
          .timeZone
          .offset,
    );
  }
  final exact = <DateTime>[];
  for (final offset in offsets) {
    final candidate = DateTime.fromMicrosecondsSinceEpoch(
      naive.microsecondsSinceEpoch -
          offset * Duration.microsecondsPerMillisecond,
      isUtc: true,
    );
    final roundTrip = tz.TZDateTime.from(candidate, location);
    if (roundTrip.year == wall.year &&
        roundTrip.month == wall.month &&
        roundTrip.day == wall.day &&
        roundTrip.hour == wall.hour &&
        roundTrip.minute == wall.minute &&
        roundTrip.second == wall.second &&
        roundTrip.millisecond == wall.millisecond &&
        roundTrip.microsecond == wall.microsecond) {
      exact.add(candidate);
    }
  }
  if (exact.isNotEmpty) {
    exact.sort();
    return exact.last;
  }
  return tz.TZDateTime(
    location,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  ).toUtc();
}

/// 표시와 편집에 사용할 기기 독립적인 벽시계 값을 반환한다.
DateTime utcToWallTime(DateTime instant, String timezone) {
  final wall = utcToWallTimePrecise(instant, timezone);
  return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute);
}

/// Converts a UTC instant to a device-independent wall clock while preserving
/// seconds and microseconds. Range validation uses this variant so a request
/// at `00:00:00.001` cannot be rounded down to an apparently valid midnight.
DateTime utcToWallTimePrecise(DateTime instant, String timezone) {
  final wall = tz.TZDateTime.from(instant.toUtc(), plannerLocation(timezone));
  return DateTime(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  );
}

/// Tags a civil wall-clock tuple as UTC without changing any of its calendar
/// fields.  A plain `DateTime` constructed with the default constructor uses
/// the device timezone for arithmetic, which makes adding a day to a wall
/// value depend on where the app is running.  Recurrence arithmetic uses this
/// tuple representation exclusively; the value is never treated as an
/// instant until it is passed back to [wallTimeToUtc].
DateTime civilWallTime(DateTime value) => DateTime.utc(
  value.year,
  value.month,
  value.day,
  value.hour,
  value.minute,
  value.second,
  value.millisecond,
  value.microsecond,
);

/// Converts an instant to a UTC-tagged civil tuple for device-independent
/// wall-clock arithmetic.
DateTime utcToCivilWallTimePrecise(DateTime instant, String timezone) =>
    civilWallTime(utcToWallTimePrecise(instant, timezone));

/// Returns a UTC-tagged civil date.  The UTC tag is intentional: this value is
/// a date tuple, not midnight in the device timezone.
DateTime civilDateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

/// Adds whole civil days without consulting the host/device timezone.
DateTime civilDateAdd(DateTime date, int days) =>
    DateTime.utc(date.year, date.month, date.day + days);

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Calendar-date bounds in both the selected wall timezone and UTC.  Date
/// arithmetic intentionally uses calendar components (`DateTime(y,m,d+n)`)
/// instead of adding a fixed 24-hour duration, so local-midnight ranges stay
/// correct across DST transitions.
@immutable
class CalendarDateBounds {
  const CalendarDateBounds({
    required this.startDate,
    required this.endDate,
    required this.startUtc,
    required this.endUtc,
    required this.timezone,
  });

  final DateTime startDate;
  final DateTime endDate;
  final DateTime startUtc;
  final DateTime endUtc;
  final String timezone;

  EventRange toEventRange() =>
      EventRange(startUtc: startUtc, endUtc: endUtc, viewTimezone: timezone);
}

/// Returns one local calendar day as a UTC half-open range.
CalendarDateBounds calendarDayBounds(DateTime day, String timezone) {
  validateIanaTimezone(timezone);
  final startDate = dateOnly(day);
  final endDate = DateTime(startDate.year, startDate.month, startDate.day + 1);
  return CalendarDateBounds(
    startDate: startDate,
    endDate: endDate,
    startUtc: wallTimeToUtc(startDate, timezone),
    endUtc: wallTimeToUtc(endDate, timezone),
    timezone: timezone,
  );
}

/// Returns the visible Monday-start month grid.  A month grid is always at
/// least five weeks (35 dates) and expands to six weeks (42 dates) when the
/// month does not fit in five rows.
CalendarDateBounds calendarMonthBounds(int year, int month, String timezone) {
  validateIanaTimezone(timezone);
  final firstOfMonth = DateTime(year, month, 1);
  final gridStart = DateTime(
    firstOfMonth.year,
    firstOfMonth.month,
    firstOfMonth.day - (firstOfMonth.weekday - DateTime.monday),
  );
  final firstOfNextMonth = DateTime(year, month + 1, 1);
  final daysThroughMonth =
      DateTime.utc(
            firstOfNextMonth.year,
            firstOfNextMonth.month,
            firstOfNextMonth.day,
          )
          .difference(
            DateTime.utc(gridStart.year, gridStart.month, gridStart.day),
          )
          .inDays;
  final gridDays = daysThroughMonth <= 35 ? 35 : 42;
  final gridEnd = DateTime(
    gridStart.year,
    gridStart.month,
    gridStart.day + gridDays,
  );
  return CalendarDateBounds(
    startDate: gridStart,
    endDate: gridEnd,
    startUtc: wallTimeToUtc(gridStart, timezone),
    endUtc: wallTimeToUtc(gridEnd, timezone),
    timezone: timezone,
  );
}

/// The selected calendar month used by agenda mode. Agenda covers the civil
/// month itself; month-grid mode uses [calendarMonthBounds] and may include
/// leading/trailing dates from adjacent months.
CalendarDateBounds calendarAgendaBounds(int year, int month, String timezone) {
  validateIanaTimezone(timezone);
  final startDate = DateTime(year, month, 1);
  final endDate = DateTime(year, month + 1, 1);
  return CalendarDateBounds(
    startDate: startDate,
    endDate: endDate,
    startUtc: wallTimeToUtc(startDate, timezone),
    endUtc: wallTimeToUtc(endDate, timezone),
    timezone: timezone,
  );
}

/// Adds whole local calendar days without assuming every date is 24 hours.
DateTime calendarDateAdd(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// Returns the number of local calendar dates in the half-open range.  The
/// range is measured by date fields, not UTC duration, to make max-span checks
/// deterministic on 23/25-hour DST days.
int calendarDateSpan(DateTime startUtc, DateTime endUtc, String timezone) {
  validateIanaTimezone(timezone);
  final startDate = dateOnly(utcToWallTime(startUtc, timezone));
  final endDate = dateOnly(utcToWallTime(endUtc, timezone));
  return DateTime.utc(endDate.year, endDate.month, endDate.day)
      .difference(DateTime.utc(startDate.year, startDate.month, startDate.day))
      .inDays;
}

/// Applies the Feature 1 overlap policy to an event for a selected calendar
/// date.  Timed events use UTC instant overlap with the selected day's UTC
/// bounds; all-day events use stored date-only half-open boundaries.
bool eventOverlapsCalendarDate(
  PlannerEvent event,
  DateTime selectedDate,
  String viewTimezone,
) {
  final bounds = calendarDayBounds(selectedDate, viewTimezone);
  if (event.allDay) {
    final eventStart = dateOnly(
      event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
    );
    final eventEnd = dateOnly(
      event.allDayEndDate ?? utcToWallTime(event.endAt, event.timezone),
    );
    return !eventEnd.isBefore(eventStart) &&
        eventStart.isBefore(bounds.endDate) &&
        eventEnd.isAfter(bounds.startDate);
  }
  return event.startAt.toUtc().isBefore(bounds.endUtc) &&
      event.endAt.toUtc().isAfter(bounds.startUtc);
}

/// Applies the same overlap policy to an arbitrary bounded range.  All-day
/// rows are compared against the range's selected local date interval, while
/// timed rows remain UTC instant overlap.
bool eventOverlapsCalendarRange(PlannerEvent event, EventRange range) {
  validateIanaTimezone(range.viewTimezone);
  final startDate = dateOnly(utcToWallTime(range.startUtc, range.viewTimezone));
  final endDate = dateOnly(utcToWallTime(range.endUtc, range.viewTimezone));
  if (event.allDay) {
    final eventStart = dateOnly(
      event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
    );
    final eventEnd = dateOnly(
      event.allDayEndDate ?? utcToWallTime(event.endAt, event.timezone),
    );
    return eventStart.isBefore(endDate) && eventEnd.isAfter(startDate);
  }
  return event.startAt.toUtc().isBefore(range.endUtc) &&
      event.endAt.toUtc().isAfter(range.startUtc);
}
