import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/models/notification_models.dart';
import 'package:moduly/platform/notification_bindings.dart';
import 'package:moduly/platform/notification_local_scheduler.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/notification_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';
import 'package:moduly/state/notification_state.dart';

const _user = PlannerUser(id: 'deep-link-user', email: 'deep-link@example.com');
const _group = PlannerGroup(
  id: 'deep-link-group',
  name: 'Deep links',
  timezone: 'UTC',
  ownerId: 'deep-link-user',
);
const _eventA = '123e4567-e89b-12d3-a456-426614174000';
const _eventB = '123e4567-e89b-12d3-a456-426614174001';

class _Auth extends AuthRepository {
  _Auth() : super();

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

class _Schedule extends LocalScheduleRepository {
  Completer<PlannerEvent?>? deferred;
  PlannerEvent? response;
  int lookupCalls = 0;

  @override
  bool get useBoundedEventRangeReads => true;

  @override
  Future<PlannerEvent?> eventById({
    required String userId,
    required String groupId,
    required String eventId,
  }) async {
    lookupCalls += 1;
    final wait = deferred;
    if (wait != null) {
      deferred = null;
      return wait.future;
    }
    return response;
  }
}

PlannerEvent _event(String id) => PlannerEvent(
  id: id,
  groupId: _group.id,
  title: 'authoritative event',
  startAt: DateTime.utc(2026, 9, 10, 9),
  endAt: DateTime.utc(2026, 9, 10, 10),
  ownerId: _user.id,
  memberIds: const <String>['deep-link-user'],
  timezone: 'UTC',
);

PlannerController _planner(_Auth auth, _Schedule schedule) {
  final planner = PlannerController(auth: auth, repository: schedule);
  planner.user = _user;
  planner.groups = <PlannerGroup>[_group];
  planner.selectedGroup = _group;
  planner.members = <PlannerMember>[
    const PlannerMember(
      id: 'deep-link-user',
      name: 'Deep-link user',
      email: 'deep-link@example.com',
      isOwner: true,
      isActive: true,
    ),
  ];
  planner.events = const <PlannerEvent>[];
  planner.isLoading = false;
  planner.authFlowState = AuthFlowState.signedIn;
  return planner;
}

Widget _app(
  PlannerController planner,
  FlutterLocalNotificationScheduler scheduler,
) {
  final router = GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      GoRoute(
        path: '/home',
        builder: (context, state) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/event/:id',
        builder: (context, state) =>
            Scaffold(body: Text('opened ${state.pathParameters['id']}')),
      ),
    ],
  );
  final notificationController = NotificationController(
    repository: ConfigurationBlockedNotificationRepository('test'),
  );
  return ProviderScope(
    overrides: <Override>[
      plannerControllerProvider.overrideWith((ref) => planner),
      notificationControllerProvider.overrideWith(
        (ref) => notificationController,
      ),
      localNotificationSchedulerProvider.overrideWithValue(scheduler),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => NotificationLifecycleBinding(
        router: router,
        schedulerReady: Future<void>.value(),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

NotificationPayload _payload(String eventId) =>
    NotificationPayload(eventId: eventId, occurrenceKey: 'single');

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('distinct warm taps each open after authoritative validation', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule()..response = _event(_eventA);
    final planner = _planner(auth, schedule);
    final scheduler = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      initializeOverride: () async => true,
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, scheduler));
    await _settle(tester);
    scheduler.onPayload?.call(_payload(_eventA));
    await _settle(tester);
    expect(schedule.lookupCalls, 1);
    expect(find.text('opened $_eventA'), findsOneWidget);

    schedule.response = _event(_eventB);
    scheduler.onPayload?.call(_payload(_eventB));
    await _settle(tester);
    expect(find.text('opened $_eventB'), findsOneWidget);
    expect(schedule.lookupCalls, 2);
  });

  testWidgets('duplicate in-flight warm callbacks are coalesced', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule();
    final wait = Completer<PlannerEvent?>();
    schedule.deferred = wait;
    final planner = _planner(auth, schedule);
    final scheduler = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      initializeOverride: () async => true,
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, scheduler));
    await _settle(tester);
    final payload = _payload(_eventA);
    scheduler.onPayload?.call(payload);
    scheduler.onPayload?.call(payload);
    await tester.pump();
    expect(schedule.lookupCalls, 1);
    wait.complete(_event(_eventA));
    await _settle(tester);
    expect(find.text('opened $_eventA'), findsOneWidget);
  });

  testWidgets('a rejected tap does not block a later valid tap', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule();
    final planner = _planner(auth, schedule);
    final scheduler = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      initializeOverride: () async => true,
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, scheduler));
    await _settle(tester);
    scheduler.onPayload?.call(_payload(_eventA));
    await _settle(tester);
    expect(find.text('알림에서 요청한 일정을 열 수 없어요.'), findsOneWidget);

    schedule.response = _event(_eventB);
    scheduler.onPayload?.call(_payload(_eventB));
    await _settle(tester);
    expect(find.text('opened $_eventB'), findsOneWidget);
  });

  testWidgets('stale account state cannot route a deferred tap', (
    tester,
  ) async {
    final auth = _Auth();
    final schedule = _Schedule();
    final wait = Completer<PlannerEvent?>();
    schedule.deferred = wait;
    final planner = _planner(auth, schedule);
    final scheduler = FlutterLocalNotificationScheduler(
      supportedPlatformOverride: true,
      initializeOverride: () async => true,
    );
    addTearDown(auth.dispose);

    await tester.pumpWidget(_app(planner, scheduler));
    await _settle(tester);
    scheduler.onPayload?.call(_payload(_eventA));
    await tester.pump();
    planner.user = const PlannerUser(
      id: 'different-user',
      email: 'different@example.com',
    );
    planner.notifyListeners();
    wait.complete(_event(_eventA));
    await _settle(tester);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('opened $_eventA'), findsNothing);
  });
}
