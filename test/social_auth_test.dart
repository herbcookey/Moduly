import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/state/app_state.dart';

class _SocialAuth extends AuthRepository {
  _SocialAuth({this.error}) : super();

  final Object? error;
  final StreamController<AuthRepositoryEvent> _changes =
      StreamController<AuthRepositoryEvent>.broadcast();
  Completer<void>? gate;
  int calls = 0;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _changes.stream;

  void emit(AuthRepositoryEvent event) => _changes.add(event);

  @override
  Future<bool> signInWithOAuth(
    SocialAuthProvider provider, {
    String? redirectTo,
  }) async {
    calls++;
    final waitFor = gate;
    if (waitFor != null) await waitFor.future;
    final failure = error;
    if (failure != null) throw failure;
    return true;
  }

  @override
  void dispose() {
    unawaited(_changes.close());
    super.dispose();
  }
}

void main() {
  test('demo auth never fabricates a social login success', () async {
    final auth = AuthRepository();
    addTearDown(auth.dispose);

    await expectLater(
      auth.signInWithOAuth(SocialAuthProvider.google),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          socialAuthDemoMessage,
        ),
      ),
    );
  });

  test('controller rejects concurrent social login launches', () async {
    final auth = _SocialAuth()..gate = Completer<void>();
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    final first = controller.signInWithOAuth(SocialAuthProvider.google);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isSocialAuthInFlight, isTrue);
    await expectLater(
      controller.signInWithOAuth(SocialAuthProvider.apple),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          socialAuthBusyMessage,
        ),
      ),
    );
    expect(auth.calls, 1);

    auth.gate!.complete();
    await first;
    expect(controller.isSocialAuthInFlight, isTrue);
    auth.emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isSocialAuthInFlight, isFalse);
    expect(controller.user, isNull);
  });

  test('controller surfaces a safe provider-disabled message', () async {
    final auth = _SocialAuth(
      error: const AuthException('Unsupported provider: kakao'),
    );
    final controller = PlannerController(
      auth: auth,
      repository: LocalScheduleRepository(),
    );
    addTearDown(() {
      controller.dispose();
      auth.dispose();
    });
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      controller.signInWithOAuth(SocialAuthProvider.kakao),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          socialAuthProviderDisabledMessage,
        ),
      ),
    );
    expect(controller.errorMessage, socialAuthProviderDisabledMessage);
  });

  test(
    'controller maps provider errors even when adapter throws a plain error',
    () async {
      final auth = _SocialAuth(error: StateError('provider not enabled'));
      final controller = PlannerController(
        auth: auth,
        repository: LocalScheduleRepository(),
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
      });
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        controller.signInWithOAuth(SocialAuthProvider.kakao),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            socialAuthProviderDisabledMessage,
          ),
        ),
      );
    },
  );

  testWidgets('demo social button explains that remote auth is required', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Apple ID로 계속하기'), findsOneWidget);
    expect(find.text('Kakao로 계속하기'), findsOneWidget);

    await tester.tap(find.text('Google로 계속하기'));
    await tester.pumpAndSettle();

    expect(find.text(socialAuthDemoMessage), findsOneWidget);
  });
}
