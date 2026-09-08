import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String edgeFunction;
  late String preflightValidator;
  late String functionConfig;
  late String accountMigration;

  setUpAll(() {
    edgeFunction = File(
      'supabase/functions/delete-account/index.ts',
    ).readAsStringSync();
    preflightValidator = File(
      'supabase/functions/delete-account/preflight_validator.mjs',
    ).readAsStringSync();
    functionConfig = File('supabase/config.toml').readAsStringSync();
    accountMigration = File(
      'supabase/migrations/202608140003_account_deletion.sql',
    ).readAsStringSync();
  });

  test('Edge 삭제가 JWT를 검증하고 현재 키 집합 비밀 값을 확인한다', () {
    expect(edgeFunction, contains('raw.trim().length === 0'));
    expect(edgeFunction, isNot(contains('raw.trim().isEmpty')));
    expect(edgeFunction, contains("defaultKey('SUPABASE_PUBLISHABLE_KEYS')"));
    expect(edgeFunction, contains("defaultKey('SUPABASE_SECRET_KEYS')"));
    expect(edgeFunction, contains('auth.getUser(token)'));
    expect(edgeFunction, contains('auth.admin.deleteUser'));
    expect(edgeFunction, contains('isValidDeletionSummary(summary)'));
    expect(
      edgeFunction.indexOf("defaultKey('SUPABASE_PUBLISHABLE_KEYS')"),
      lessThan(
        edgeFunction.indexOf("Deno.env.get('SUPABASE_PUBLISHABLE_KEY')"),
      ),
    );
    expect(
      edgeFunction.indexOf("defaultKey('SUPABASE_SECRET_KEYS')"),
      lessThan(edgeFunction.indexOf("Deno.env.get('SUPABASE_SECRET_KEY')")),
    );
    expect(
      edgeFunction.indexOf('isValidDeletionSummary(summary)'),
      lessThan(edgeFunction.indexOf('auth.admin.deleteUser')),
    );
    expect(functionConfig, contains('[functions.delete-account]'));
    expect(functionConfig, contains('verify_jwt = false'));
  });

  test('Edge 삭제가 인증 전에 Flutter 웹 CORS 사전 요청을 처리한다', () {
    expect(edgeFunction, contains("'Access-Control-Allow-Origin': '*'"));
    expect(
      edgeFunction,
      contains(
        "'Access-Control-Allow-Headers':\n    'authorization, x-client-info, apikey, content-type'",
      ),
    );
    expect(
      edgeFunction,
      contains("'Access-Control-Allow-Methods': 'POST, OPTIONS'"),
    );
    expect(edgeFunction, contains("request.method === 'OPTIONS'"));
    expect(edgeFunction, contains('new Response(null, { status: 204'));
    expect(edgeFunction, isNot(contains('Access-Control-Allow-Credentials')));

    final preflight = edgeFunction.indexOf("request.method === 'OPTIONS'");
    final bearerValidation = edgeFunction.indexOf('bearerToken(request)');
    expect(preflight, greaterThanOrEqualTo(0));
    expect(bearerValidation, greaterThan(preflight));
    expect(
      edgeFunction,
      contains("headers: jsonHeaders"),
      reason: '모든 JSON 응답에 CORS 헤더가 있어야 한다',
    );
  });

  test('사전 검사기가 순수하며 로깅이나 공급자 의존성이 없다', () {
    expect(
      preflightValidator,
      contains('export function isValidDeletionSummary'),
    );
    expect(preflightValidator, contains('return false'));
    expect(preflightValidator, contains('return true'));
    expect(preflightValidator, isNot(contains('Deno.')));
    expect(preflightValidator, isNot(contains('supabase')));
    expect(preflightValidator, isNot(contains('console.')));
  });

  test('계정 삭제 마이그레이션이 소유 데이터 연쇄 삭제 정책을 설명한다', () {
    final sql = accountMigration.toLowerCase();
    expect(sql, contains('groups_owner_id_fkey'));
    expect(sql, contains('invite_codes_created_by_fkey'));
    expect(sql, contains('events_created_by_fkey'));
    expect(sql, contains('on delete cascade'));
    expect(sql, contains('감사 행은'));
  });
}
