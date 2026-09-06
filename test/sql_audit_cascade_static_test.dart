import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/20260907130000_skip_orphan_membership_audit.sql',
    );
    expect(
      file.existsSync(),
      isTrue,
      reason: 'The account-deletion audit cascade migration is required',
    );
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('skips only audit rows whose group was already deleted', () {
    final guard = migration.indexOf('if v_group_id is not null');
    final auditInsert = migration.indexOf('insert into public.audit_logs');
    expect(guard, greaterThanOrEqualTo(0));
    expect(auditInsert, greaterThan(guard));
    expect(
      migration,
      contains(
        'and not exists ( select 1 from public.groups g where g.id = v_group_id ) then return null;',
      ),
    );
    expect(migration, isNot(contains('pg_trigger_depth')));
  });

  test('retains trigger security and the minimal audit payload', () {
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = public, auth, extensions'));
    expect(migration, contains('jsonb_build_object(\'version\', v_version)'));
    expect(
      migration,
      contains(
        'revoke execute on function public.write_audit_log() from public, anon, authenticated;',
      ),
    );
  });
}
