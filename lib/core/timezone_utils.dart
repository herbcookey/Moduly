import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_models.dart';

/// 미리보기 UI와 사용자가 그룹 시간대를 선택할 수 있기 전의 레거시 호출자가
/// 사용하는 기본값이다.
const defaultPlannerTimezone = 'Asia/Seoul';

void _ensureTimezoneDatabase() {
  // 일반적인 앱 실행에서는 `main.dart`가 데이터베이스를 초기화하지만, 이 지연
  // 가드를 유지하면 아이솔레이트나 테스트에서 저장소와 유틸리티를 직접 호출해도 안전하다.
  if (!tz.timeZoneDatabase.isInitialized) {
    tzdata.initializeTimeZones();
  }
}

/// [name]이 번들 IANA 데이터베이스에 정확히 존재하는 시간대 이름인지 반환한다.
/// 공백이나 빈 이름은 조용히 UTC로 대체하지 않고 거부한다.
bool isValidIanaTimezone(String name) {
  if (name.isEmpty || name.trim() != name) return false;
  // timezone 0.11의 번들 데이터베이스는 오프셋이 0인 위치를 `Etc/UTC`로 부르며
  // 기존 `UTC` 별칭을 더는 보장하지 않는다. 앱의 영구 저장/기본 전송 형식 계약은
  // `UTC`를 사용하므로 이 표준 별칭은 명시적으로 유지하되, 다른 모든 이름은
  // IANA 테이블을 기준으로 검증한다.
  if (name == 'UTC') return true;
  _ensureTimezoneDatabase();
  try {
    final location = tz.getLocation(name);
    return location.name == name;
  } catch (_) {
    return false;
  }
}

/// IANA 시간대를 단순히 시간대라고 부르는 호출자를 위한 별칭이다.
bool isValidTimezone(String name) => isValidIanaTimezone(name);

/// 호출자가 제공한 시간대를 검증하고 정확한 값을 반환한다.
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
  if (name == 'UTC') return tz.UTC;
  try {
    return tz.getLocation(name);
  } catch (_) {
    return tz.UTC;
  }
}

/// IANA 시간대에 입력한 벽시계 값을 UTC 시각으로 변환한다.
DateTime wallTimeToUtc(DateTime wall, String timezone) {
  final location = plannerLocation(timezone);
  // `timezone`은 가을철 중첩 시간을 더 이른 DST 오프셋으로 해석한다. Planner의 현지
  // 시각은 대신 결정론적인 표준시 쪽을 사용한다. 인접한 오프셋을 열거해 정확히
  // 왕복 변환되는 값을 모두 유지하고, 모호한 중첩 시간에서는 가장 늦은 UTC 시각을 고른다.
  // 봄철 공백은 정확한 왕복 변환이 없으므로 TZDateTime에 문서화된 순방향 해석을 따른다.
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
          .offset
          .inMilliseconds,
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

/// 초와 마이크로초를 보존하면서 UTC 시각을 기기 독립적인 현지 시각으로 변환한다.
/// 범위 검증은 이 형태를 사용하므로 `00:00:00.001` 요청이 겉보기에는 유효한 자정으로
/// 내림 처리될 수 없다.
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

/// 민간 현지 시각 튜플의 달력 필드를 바꾸지 않고 UTC 태그를 붙인다. 기본 생성자로
/// 만든 일반 `DateTime`은 기기 시간대를 기준으로 계산하므로, 현지 시각에 하루를
/// 더한 결과가 앱 실행 위치에 따라 달라진다. 반복 계산은 이 튜플 표현만 사용하며,
/// 값을 [wallTimeToUtc]에 다시 전달하기 전까지는 실제 시각으로 취급하지 않는다.
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

/// 기기 독립적인 현지 시각 계산을 위해 실제 시각을 UTC 태그가 붙은 민간력 튜플로
/// 변환한다.
DateTime utcToCivilWallTimePrecise(DateTime instant, String timezone) =>
    civilWallTime(utcToWallTimePrecise(instant, timezone));

/// UTC 태그가 붙은 민간력 날짜를 반환한다. UTC 태그는 의도적인 것으로, 이 값은
/// 기기 시간대의 자정이 아니라 날짜 튜플이다.
DateTime civilDateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

/// 호스트/기기 시간대를 참조하지 않고 민간력 날짜 단위로 더한다.
DateTime civilDateAdd(DateTime date, int days) =>
    DateTime.utc(date.year, date.month, date.day + days);

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 선택한 현지 시간대와 UTC 양쪽의 달력 날짜 경계다. 날짜 계산은 고정된 24시간을
/// 더하는 대신 의도적으로 달력 구성 요소(`DateTime(y,m,d+n)`)를 사용하므로 DST
/// 전환을 지나도 현지 자정 범위가 정확하다.
@immutable
class CalendarDateBounds {
  const CalendarDateBounds({
    required this.startDate,
    required this.endDate,
    required this.startUtc,
    required this.endUtc,
    required this.timezone,
  });

  /// 앱의 모든 달력 선택기가 공유하는 지원 날짜 범위다. PostgreSQL은 더 넓은
  /// 범위를 표현할 수 있지만 Flutter/웹 직렬화와 서버 범위 RPC가 동일한 유한
  /// 계약을 사용하도록 UI 및 컨트롤러 경계에서 이 범위로 제한한다.
  static final DateTime firstDate = DateTime(2000, 1, 1);
  static final DateTime lastDate = DateTime(2100, 12, 31);

  static bool contains(DateTime value) {
    final candidate = dateOnly(value);
    return !candidate.isBefore(firstDate) && !candidate.isAfter(lastDate);
  }

  static DateTime clamp(DateTime value) {
    final candidate = dateOnly(value);
    if (candidate.isBefore(firstDate)) return firstDate;
    if (candidate.isAfter(lastDate)) return lastDate;
    return candidate;
  }

  final DateTime startDate;
  final DateTime endDate;
  final DateTime startUtc;
  final DateTime endUtc;
  final String timezone;

  EventRange toEventRange() =>
      EventRange(startUtc: startUtc, endUtc: endUtc, viewTimezone: timezone);
}

/// 현지 달력 하루를 UTC 반개구간으로 반환한다.
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

/// 월요일부터 시작하는 표시 월 격자를 반환한다. 월 격자는 항상 최소 5주(35일)이며,
/// 해당 월이 5행에 들어가지 않으면 6주(42일)로 확장된다.
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

/// 일정 목록 모드에서 사용하는 선택된 달력 월이다. 일정 목록은 해당 민간력 월 자체를
/// 다루고, 월 격자 모드는 [calendarMonthBounds]를 사용해 인접한 월의 앞뒤 날짜를
/// 포함할 수 있다.
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

/// 모든 날짜가 24시간이라고 가정하지 않고 현지 달력 날짜 단위로 더한다.
DateTime calendarDateAdd(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// 반개구간에 포함된 현지 달력 날짜 수를 반환한다. 23시간 또는 25시간인 DST 날짜에도
/// 최대 범위 검사가 결정론적으로 동작하도록 UTC 기간이 아닌 날짜 필드로 범위를 잰다.
int calendarDateSpan(DateTime startUtc, DateTime endUtc, String timezone) {
  validateIanaTimezone(timezone);
  final startDate = dateOnly(utcToWallTime(startUtc, timezone));
  final endDate = dateOnly(utcToWallTime(endUtc, timezone));
  return DateTime.utc(endDate.year, endDate.month, endDate.day)
      .difference(DateTime.utc(startDate.year, startDate.month, startDate.day))
      .inDays;
}

/// 선택한 달력 날짜의 일정에 Feature 1 겹침 정책을 적용한다. 시간 지정 일정은 선택한
/// 날짜의 UTC 경계와 실제 UTC 시각의 겹침을 사용하고, 종일 일정은 저장된 날짜 전용
/// 반개구간 경계를 사용한다.
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

/// 임의의 제한된 범위에 같은 겹침 정책을 적용한다. 종일 행은 범위에서 선택한 현지
/// 날짜 구간과 비교하고, 시간 지정 행은 계속 실제 UTC 시각의 겹침을 사용한다.
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
