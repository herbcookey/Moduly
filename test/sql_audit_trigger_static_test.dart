import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/202608140005_write_audit_log_field_safe.sql',
    );
    expect(
      file.existsSync(),
      isTrue,
      reason: 'The field-safe audit trigger migration is required',
    );
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('audit trigger branches before reading table-specific fields', () {
    expect(
      migration,
      contains('create or replace function public.write_audit_log()'),
    );
    for (final table in <String>[
      'groups',
      'memberships',
      'invite_codes',
      'events',
    ]) {
      expect(
        migration,
        contains("if tg_table_name = '$table' then"),
        reason: 'write_audit_log must isolate $table record fields',
      );
    }

    // 운영 장애를 일으킨 형태다. PL/pgSQL이 두 CASE 분기를 현재 테이블
    // 레코드에 대해 해석할 수 있다.
    expect(
      migration,
      isNot(
        contains("case when tg_table_name = 'memberships' then new.user_id"),
      ),
    );
    expect(
      migration,
      isNot(contains("case when tg_table_name = 'groups' then old.id")),
    );
    expect(
      migration,
      isNot(
        contains(
          "case when tg_table_name in ('groups', 'events', 'invite_codes') then new.version",
        ),
      ),
    );
  });

  test('audit rows keep the existing privacy and lifecycle contract', () {
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = public, auth, extensions'));
    expect(migration, contains('jsonb_build_object(\'version\', v_version)'));
    expect(migration, contains('insert into public.audit_logs'));
    expect(migration, contains("then 'join'"));
    expect(migration, contains("v_action := 'revoke'"));
    expect(migration, contains("v_action := 'soft_delete'"));
  });
}
