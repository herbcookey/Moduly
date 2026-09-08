// 이 테스트는 GoTrue의 내부 오류 알림 훅을 의도적으로 실행해 저장소가 공개 인증
// 스트림을 소유하고 정제하는지 확인한다. HTTP 클라이언트는 결정적인 공급자
// 실패를 강제로 만들 때만 사용하는 Supabase의 전이 의존성이다.
// ignore_for_file: invalid_use_of_internal_member, depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:moduly/repositories/auth_repository.dart';

class _ErrorHttpClient extends http.BaseClient {
  _ErrorHttpClient(this.message);

  final String message;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode(<String, String>{
      'message': message,
      'error_description': message,
      'error_code': message,
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      500,
      request: request,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

SupabaseClient _newRemoteClient() => SupabaseClient(
  'https://example.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
);

SupabaseClient _newErrorRemoteClient(String message) => SupabaseClient(
  'https://example.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
  httpClient: _ErrorHttpClient(message),
);

void main() {
  test('원격 인증 스트림이 공급자 오류를 정규화한다', () async {
    final client = _newRemoteClient();
    final auth = AuthRepository(client: client);
    addTearDown(() async {
      auth.dispose();
      await client.dispose();
    });

    final error = expectLater(
      auth.events,
      emitsError(
        isA<AuthException>().having(
          (value) => value.message,
          'message',
          authSessionErrorMessage,
        ),
      ),
    );
    client.auth.notifyException(
      const AuthException('internal provider secret account@example.com'),
    );
    await error;
  });

  test('원격 인증 스트림이 저장소 해제 후 대기한 오류를 무시한다', () async {
    final client = _newRemoteClient();
    final auth = AuthRepository(client: client);
    final errors = <Object>[];
    final subscription = auth.events.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) => errors.add(error),
    );

    auth.dispose();
    client.auth.notifyException(
      const AuthException('closed-controller secret account@example.com'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(errors, isEmpty);
    await subscription.cancel();
    await client.dispose();
  });

  test('원격 인증 정보 실패가 작업별 안전 문구를 사용한다', () async {
    const sentinel = 'provider-secret account=person@example.com status=500';
    final client = _newErrorRemoteClient(sentinel);
    final auth = AuthRepository(client: client);
    addTearDown(() async {
      auth.dispose();
      await client.dispose();
    });

    await expectLater(
      auth.signIn('person@example.com', 'password'),
      throwsA(
        isA<AuthException>().having(
          (value) => value.message,
          'message',
          authSignInErrorMessage,
        ),
      ),
    );
    await expectLater(
      auth.signUp('person@example.com', 'password', 'Person'),
      throwsA(
        isA<AuthException>().having(
          (value) => value.message,
          'message',
          authSignUpErrorMessage,
        ),
      ),
    );
    await expectLater(
      auth.resendSignupConfirmation('person@example.com'),
      throwsA(
        isA<AuthException>().having(
          (value) => value.message,
          'message',
          authResendSignupErrorMessage,
        ),
      ),
    );
    await expectLater(
      auth.updateRecoveredPassword('password'),
      throwsA(
        isA<AuthException>().having(
          (value) => value.message,
          'message',
          authRecoveredPasswordErrorMessage,
        ),
      ),
    );
  });
}
