import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/202608140004_function_acl_hardening.sql',
    );
    expect(file.existsSync(), isTrue, reason: 'ACL 강화 마이그레이션이 필요하다');
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('향후 함수의 기본 실행 권한이 비공개다', () {
    expect(
      migration,
      contains(
        'alter default privileges in schema public revoke execute on functions from public;',
      ),
    );
    expect(
      migration,
      contains(
        'alter default privileges in schema public revoke execute on functions from anon, authenticated;',
      ),
    );
  });

  test('API 역할이 트리거 전용 함수를 직접 호출할 수 없다', () {
    for (final functionName in <String>[
      'touch_updated_at',
      'enforce_version_increment',
      'enforce_initial_version',
      'enforce_group_integrity',
      'enforce_event_integrity',
      'enforce_invite_integrity',
      'enforce_membership_integrity',
      'write_audit_log',
      'handle_new_user',
      'handle_new_group',
    ]) {
      expect(
        migration,
        contains(
          'revoke execute on function public.$functionName() from public, anon, authenticated;',
        ),
        reason: '$functionName must remain trigger-only',
      );
    }
    expect(migration, contains("to_regprocedure('public.rls_auto_enable()')"));
    expect(
      migration,
      contains(
        "execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated'",
      ),
    );
  });

  test('RLS 도우미와 비즈니스 RPC가 인증 전용이다', () {
    final signatures = <String, bool>{
      'is_valid_timezone(text)': false,
      'is_group_owner(uuid)': false,
      'is_active_member(uuid)': false,
      'can_view_profile(uuid)': false,
      'create_group(text, text)': true,
      'create_invite_code(uuid, timestamptz, integer)': true,
      'join_group_with_invite(text)': true,
      'soft_delete_event_if_version(uuid, integer)': true,
      'archive_group_if_version(uuid, integer)': true,
      'revoke_invite_code(uuid, integer)': true,
      'set_member_active(uuid, uuid, boolean)': true,
    };

    for (final entry in signatures.entries) {
      final functionName = entry.key;
      expect(
        migration,
        contains(
          'revoke execute on function public.$functionName from public, anon, authenticated;',
        ),
        reason: '$functionName must not retain a stale role grant',
      );
      expect(
        migration,
        contains(
          'grant execute on function public.$functionName to authenticated;',
        ),
        reason: '$functionName must remain available to authenticated callers',
      );
    }
  });
}
