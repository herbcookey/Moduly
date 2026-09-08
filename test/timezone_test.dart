import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:moduly/core/timezone_utils.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('Asia/Seoul 종일 자정 경계가 같은 날짜로 유지된다', () {
    final start = wallTimeToUtc(DateTime(2026, 1, 1), 'Asia/Seoul');
    final end = wallTimeToUtc(DateTime(2026, 1, 3), 'Asia/Seoul');
    expect(start, DateTime.utc(2025, 12, 31, 15));
    expect(end, DateTime.utc(2026, 1, 2, 15));
    expect(utcToWallTime(start, 'Asia/Seoul'), DateTime(2026, 1, 1));
    expect(utcToWallTime(end, 'Asia/Seoul'), DateTime(2026, 1, 3));
  });

  test('America/Los_Angeles DST 전환이 현지 날짜 경계를 유지한다', () {
    final start = wallTimeToUtc(DateTime(2026, 3, 8), 'America/Los_Angeles');
    final end = wallTimeToUtc(DateTime(2026, 3, 9), 'America/Los_Angeles');
    expect(start, DateTime.utc(2026, 3, 8, 8));
    expect(end, DateTime.utc(2026, 3, 9, 7));
    expect(utcToWallTime(start, 'America/Los_Angeles'), DateTime(2026, 3, 8));
    expect(utcToWallTime(end, 'America/Los_Angeles'), DateTime(2026, 3, 9));
  });

  test('고정 및 정규 UTC 별칭이 전체 IANA 데이터에서도 유효하다', () {
    expect(isValidIanaTimezone('EST'), isTrue);
    expect(
      wallTimeToUtc(DateTime(2026, 1, 1, 9), 'EST'),
      DateTime.utc(2026, 1, 1, 14),
    );
    expect(isValidIanaTimezone('UTC'), isTrue);
    expect(isValidIanaTimezone('Etc/UTC'), isTrue);
    expect(
      wallTimeToUtc(DateTime(2026, 1, 1, 9), 'UTC'),
      DateTime.utc(2026, 1, 1, 9),
    );
    expect(
      wallTimeToUtc(DateTime(2026, 1, 1, 9), 'Etc/UTC'),
      DateTime.utc(2026, 1, 1, 9),
    );
  });
}
