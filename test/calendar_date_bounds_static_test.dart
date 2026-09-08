import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String normalized(String path) =>
      File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').trim();

  test('모든 날짜 선택기와 플래너 컨트롤러가 공통 달력 날짜 범위를 사용한다', () {
    final timezoneUtils = normalized('lib/core/timezone_utils.dart');
    final controller = normalized('lib/state/app_state.dart');
    final pickerSources = <String>[
      normalized('lib/screens/home_screen.dart'),
      normalized('lib/screens/event_search_screen.dart'),
      normalized('lib/screens/event_editor_screen.dart'),
      normalized('lib/screens/widgets/recurrence_controls.dart'),
    ];

    expect(
      timezoneUtils,
      contains('static final DateTime firstDate = DateTime(2000, 1, 1);'),
    );
    expect(
      timezoneUtils,
      contains('static final DateTime lastDate = DateTime(2100, 12, 31);'),
    );
    expect(controller, contains('CalendarDateBounds.clamp(day)'));

    for (final source in pickerSources) {
      expect(source, contains('CalendarDateBounds.firstDate'));
      expect(source, contains('CalendarDateBounds.lastDate'));
    }
  });
}
