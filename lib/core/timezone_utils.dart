import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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
  return tz.TZDateTime(
    location,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
  ).toUtc();
}

/// 표시와 편집에 사용할 기기 독립적인 벽시계 값을 반환한다.
DateTime utcToWallTime(DateTime instant, String timezone) {
  final wall = tz.TZDateTime.from(instant.toUtc(), plannerLocation(timezone));
  return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute);
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
