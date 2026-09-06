import 'package:timezone/timezone.dart' as tz;

/// IANA 시간대를 해석한다. 잘못된 프로필 데이터에는 안전한 UTC 대체값을
/// 사용하며, 데이터베이스가 클라이언트에 전달하기 전에 값을 검증한다.
tz.Location plannerLocation(String name) {
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
