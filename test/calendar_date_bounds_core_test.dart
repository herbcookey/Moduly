import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/timezone_utils.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

class _NoAuth extends AuthRepository {
  _NoAuth() : super();

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();

  @override
  PlannerUser? get currentUser => null;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

void main() {
  test('공통 날짜 범위가 양 끝을 포함하고 시간 성분 없이 값을 제한한다', () {
    expect(CalendarDateBounds.firstDate, DateTime(2000, 1, 1));
    expect(CalendarDateBounds.lastDate, DateTime(2100, 12, 31));
    expect(CalendarDateBounds.contains(DateTime(2000, 1, 1, 23, 59)), isTrue);
    expect(CalendarDateBounds.contains(DateTime(2100, 12, 31, 23, 59)), isTrue);
    expect(CalendarDateBounds.contains(DateTime(1999, 12, 31)), isFalse);
    expect(CalendarDateBounds.contains(DateTime(2101, 1, 1)), isFalse);
    expect(
      CalendarDateBounds.clamp(DateTime(2050, 6, 7, 12, 34)),
      DateTime(2050, 6, 7),
    );
    expect(
      CalendarDateBounds.clamp(DateTime(1999, 12, 31)),
      CalendarDateBounds.firstDate,
    );
    expect(
      CalendarDateBounds.clamp(DateTime(2101, 1, 1)),
      CalendarDateBounds.lastDate,
    );
  });

  test('플래너 컨트롤러의 직접 할당과 이동도 공통 범위를 벗어나지 않는다', () {
    final auth = _NoAuth();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });

    controller.selectedDay = DateTime(1990, 4, 5, 10);
    expect(controller.selectedDay, CalendarDateBounds.firstDate);

    controller.setSelectedDay(DateTime(2200, 4, 5, 10));
    expect(controller.selectedDay, CalendarDateBounds.lastDate);

    controller.moveSelectedDay(1);
    expect(controller.selectedDay, CalendarDateBounds.lastDate);
    controller.selectedDay = CalendarDateBounds.firstDate;
    controller.moveSelectedDay(-1);
    expect(controller.selectedDay, CalendarDateBounds.firstDate);
  });
}
