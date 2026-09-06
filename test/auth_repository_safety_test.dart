// This test intentionally drives GoTrue's internal error notification hook to
// verify that the repository owns and sanitizes the public auth stream.
// The HTTP client is a transitive Supabase dependency used only to force
// deterministic provider failures.
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
  test('remote auth stream normalizes provider errors', () async {
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

  test(
    'remote auth stream ignores errors queued after repository dispose',
    () async {
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
    },
  );

  test('remote credential failures use operation-specific safe copy', () async {
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
