import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/202608140005_write_audit_log_field_safe.sql',
    );
    expect(file.existsSync(), isTrue, reason: '필드에 안전한 감사 트리거 마이그레이션이 필요하다');
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('감사 트리거가 테이블별 필드를 읽기 전에 분기한다', () {
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
        reason: 'write_audit_log가 $table 레코드 필드를 격리해야 한다',
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

  test('감사 행이 기존 개인정보 보호 및 수명 주기 계약을 유지한다', () {
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = public, auth, extensions'));
    expect(migration, contains('jsonb_build_object(\'version\', v_version)'));
    expect(migration, contains('insert into public.audit_logs'));
    expect(migration, contains("then 'join'"));
    expect(migration, contains("v_action := 'revoke'"));
    expect(migration, contains("v_action := 'soft_delete'"));
  });
}
