import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String edgeFunction;
  late String functionConfig;
  late String accountMigration;

  setUpAll(() {
    edgeFunction = File(
      'supabase/functions/delete-account/index.ts',
    ).readAsStringSync();
    functionConfig = File('supabase/config.toml').readAsStringSync();
    accountMigration = File(
      'supabase/migrations/202608140003_account_deletion.sql',
    ).readAsStringSync();
  });

  test('Edge deletion verifies JWT and resolves current key-set secrets', () {
    expect(edgeFunction, contains('raw.trim().length === 0'));
    expect(edgeFunction, isNot(contains('raw.trim().isEmpty')));
    expect(edgeFunction, contains("defaultKey('SUPABASE_PUBLISHABLE_KEYS')"));
    expect(edgeFunction, contains("defaultKey('SUPABASE_SECRET_KEYS')"));
    expect(edgeFunction, contains('auth.getUser(token)'));
    expect(edgeFunction, contains('auth.admin.deleteUser'));
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
    expect(functionConfig, contains('[functions.delete-account]'));
    expect(functionConfig, contains('verify_jwt = false'));
  });

  test('Edge deletion handles Flutter web CORS preflight before auth', () {
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
      reason: 'every JSON response should carry the CORS headers',
    );
  });

  test(
    'account deletion migration documents the owned-data cascade policy',
    () {
      final sql = accountMigration.toLowerCase();
      expect(sql, contains('groups_owner_id_fkey'));
      expect(sql, contains('invite_codes_created_by_fkey'));
      expect(sql, contains('events_created_by_fkey'));
      expect(sql, contains('on delete cascade'));
      expect(sql, contains('감사 행은'));
    },
  );
}
