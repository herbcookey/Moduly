import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;
  late String edgeFunction;
  late String preflightValidator;
  late String upgradeScript;
  late String realtimeMigration;
  late String schemaMigration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/20260907130001_group_management.sql',
    );
    expect(file.existsSync(), isTrue, reason: '단조 증가 그룹 관리 마이그레이션이 필요하다');
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    edgeFunction = File(
      'supabase/functions/delete-account/index.ts',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    preflightValidator = File(
      'supabase/functions/delete-account/preflight_validator.mjs',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    upgradeScript = File(
      'supabase/tests/run_group_management_upgrade.sh',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    realtimeMigration = File(
      'supabase/migrations/202608110002_rls_rpc.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    schemaMigration = File(
      'supabase/migrations/202608110001_schema.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  });

  test('갱신 RPC가 소유자 전용 잠금식 낙관적 갱신이다', () {
    expect(
      migration,
      contains(
        'create or replace function public.update_group_if_version( p_group_id uuid, p_expected_version integer, p_name text, p_description text, p_timezone text )',
      ),
    );
    expect(migration, contains('returns public.groups'));
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = \'\''));
    expect(migration, contains('v_user_id uuid := auth.uid()'));
    expect(migration, contains('pg_catalog.btrim(coalesce(p_name, \'\'))'));
    expect(migration, contains('char_length(v_name) not between 1 and 160'));
    expect(migration, contains('char_length(v_description) > 10000'));
    expect(migration, contains('pg_catalog.pg_timezone_names'));
    expect(
      migration,
      contains('from public.groups g where g.id = p_group_id for update'),
    );
    expect(
      migration,
      contains(
        'g.deleted_at is null and g.version = p_expected_version returning g.* into v_group',
      ),
    );
    expect(migration, contains("errcode = '40001'"));
    expect(migration, contains('version = g.version + 1'));
  });

  test('탈퇴 RPC가 본인 전용이며 멤버십 기록을 보존한다', () {
    expect(
      migration,
      contains(
        'create or replace function public.leave_group(p_group_id uuid)',
      ),
    );
    expect(migration, contains('returns void'));
    expect(migration, contains('only an active ordinary member can leave'));
    expect(migration, contains('for update'));
    expect(migration, contains('m.user_id = v_user_id'));
    expect(migration, contains('set is_active = false'));
    expect(migration, contains('removed_at = coalesce(m.removed_at'));
    expect(migration, contains("v_membership.role <> 'member'"));
  });

  test('이전이 검증된 트랜잭션 표식과 최종 불변 조건을 사용한다', () {
    expect(
      migration,
      contains(
        'create or replace function public.transfer_group_ownership( p_group_id uuid, p_new_owner_id uuid, p_expected_version integer )',
      ),
    );
    expect(
      migration,
      contains('pg_catalog.set_config(\'moduly.transfer_marker\''),
    );
    expect(
      migration,
      contains("current_setting('moduly.transfer_marker', true)"),
    );
    expect(migration, contains("'group_id'"));
    expect(migration, contains("'old_owner_id'"));
    expect(migration, contains("'new_owner_id'"));
    expect(
      migration,
      contains(
        'select g.* into v_group from public.groups g where g.id = p_group_id for update',
      ),
    );
    expect(
      migration,
      contains(
        'from public.memberships m where m.group_id = p_group_id and m.user_id = v_user_id for update',
      ),
    );
    expect(migration, contains("set role = 'member'"));
    expect(migration, contains("set role = 'owner'"));
    expect(migration, contains('owner_id = p_new_owner_id'));
    expect(migration, contains('v_active_owner_count <> 1'));
    expect(
      migration,
      contains(
        'create unique index if not exists memberships_one_active_owner_idx',
      ),
    );
    expect(migration, contains("where role = 'owner' and is_active"));
    expect(
      migration,
      contains(
        'revoke update (name, description, timezone, version) on public.groups from public, anon, authenticated',
      ),
    );
    expect(migration, contains('if tg_op = \'delete\' then return old;'));
  });

  test('기존 소유자 행과 같은 이름의 인덱스를 안전하게 복구하거나 거부한다', () {
    expect(migration, contains('pg_catalog.pg_index'));
    expect(migration, contains('pg_catalog.pg_get_expr'));
    expect(migration, contains('pg_catalog.pg_get_indexdef'));
    expect(migration, contains('v_expected_index_def'));
    expect(
      migration,
      contains(
        'memberships_one_active_owner_idx exists but is not the expected',
      ),
    );
    expect(migration, contains('deterministic backfill'));
    expect(migration, contains('m.user_id <> v_owner_id'));
    expect(migration, contains("set role = 'member'"));
    expect(migration, contains("insert into public.memberships"));
    expect(migration, contains('ambiguous active owner membership'));
    expect(
      migration,
      contains(
        'create unique index if not exists memberships_one_active_owner_idx',
      ),
    );
  });

  test('이전 표식과 멤버십 삭제 경로가 안전하게 실패한다', () {
    expect(
      migration,
      contains(
        "v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb",
      ),
    );
    expect(
      migration,
      contains("v_marker ->> 'old_owner_id' = v_owner_id::text"),
    );
    expect(migration, contains("if tg_op = 'delete' then return old;"));
    expect(
      migration,
      contains('before insert or update or delete on public.memberships'),
    );
  });

  test('그룹 범위 변경 RPC가 오래됨 검사/쓰기 전에 그룹을 잠근다', () {
    final functionNames = <String>[
      'create_invite_code',
      'join_group_with_invite',
      'soft_delete_event_if_version',
      'revoke_invite_code',
      'set_member_active',
    ];
    for (final functionName in functionNames) {
      final start = migration.indexOf(
        'create or replace function public.$functionName',
      );
      expect(start, greaterThanOrEqualTo(0), reason: functionName);
      final bodyStart = migration.indexOf(r'as $$', start);
      final bodyEnd = migration.indexOf(r'$$;', bodyStart);
      expect(bodyStart, greaterThanOrEqualTo(start), reason: functionName);
      expect(bodyEnd, greaterThan(bodyStart), reason: functionName);
      final body = migration.substring(bodyStart, bodyEnd);
      final groupLock = body.indexOf('for update');
      expect(groupLock, greaterThanOrEqualTo(0), reason: functionName);
      expect(
        body,
        isNot(contains('for share')),
        reason: '$functionName must not use a stale shared group lock',
      );
      expect(
        body.indexOf('from public.groups g where g.id ='),
        greaterThanOrEqualTo(0),
        reason: '$functionName must lock its parent group',
      );
      for (final write in <String>[
        'update public.invite_codes',
        'insert into public.invite_codes',
        'update public.memberships',
        'insert into public.memberships',
        'update public.events',
      ]) {
        final writeIndex = body.indexOf(write);
        if (writeIndex >= 0) {
          expect(
            groupLock,
            lessThan(writeIndex),
            reason: '$functionName writes $write before locking its group',
          );
        }
      }
      final lifecycleCheck = body.indexOf('v_group.deleted_at is not null');
      expect(
        lifecycleCheck,
        greaterThan(groupLock),
        reason: '$functionName checks lifecycle after the group lock',
      );
    }
  });

  test('직접 일정 쓰기가 종료형 그룹 전환과 직렬화된다', () {
    final eventGuard = migration.indexOf(
      'create or replace function public.enforce_event_integrity()',
    );
    expect(eventGuard, greaterThanOrEqualTo(0));
    final bodyStart = migration.indexOf(r'as $$', eventGuard);
    final bodyEnd = migration.indexOf(r'$$;', bodyStart);
    expect(bodyEnd, greaterThan(bodyStart));
    final declaration = migration.substring(eventGuard, bodyStart);
    final body = migration.substring(bodyStart, bodyEnd);
    expect(declaration, contains('security definer'));
    expect(
      body,
      contains('from public.groups g where g.id = new.group_id for update'),
    );
    expect(body, contains('v_group.deleted_at is not null'));
    expect(body, contains("errcode = '40001'"));
    expect(
      schemaMigration,
      contains(
        'create trigger events_integrity before insert or update on public.events',
      ),
    );
    expect(
      schemaMigration,
      isNot(contains('create trigger events_integrity before delete')),
    );
  });

  test('pgTAP 픽스처가 실제 인증된 소유자/멤버/외부인 흐름을 실행한다', () {
    final fixture = File(
      'supabase/tests/group_management.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    expect(fixture, contains('create extension if not exists pgtap'));
    expect(fixture, contains('set local role authenticated'));
    expect(fixture, contains("'role', 'authenticated'"));
    for (final id in <String>['owner_id', 'member_id', 'outsider_id']) {
      expect(fixture, contains("'sub', (select $id::text"));
    }
    expect(fixture, contains('has_column_privilege'));
    expect(fixture, contains('acl은 groups 직접 update를 거부한다'));
    expect(fixture, contains('acl은 멤버십 역할 직접 update를 거부한다'));
    expect(
      fixture,
      contains('authenticated 호출자는 멤버십 상태를 직접 업데이트할 수 없으며 관리 작업은 rpc로만 가능하다'),
    );
    expect(fixture, contains('잘못된 이전 표식은 거부된다'));
    expect(fixture, contains('사전 점검의 그룹 수가 정확하다'));
    expect(fixture, contains('사전 점검의 이벤트 연쇄 삭제 수가 정확하다'));
    expect(fixture, contains('사전 점검의 초대 연쇄 삭제 수가 정확하다'));
    expect(fixture, contains('사전 점검의 멤버십 연쇄 삭제 수가 정확하다'));
    expect(fixture, contains('사전 점검 요약은 사용자 uuid나 개인 식별 정보를 노출하지 않는다'));
    expect(fixture, contains('초대자를 삭제하면 남은 그룹의 invited_by가 null이 된다'));
    expect(fixture, contains('다른 소유자를 삭제하면 해당 그룹과 멤버십이 연쇄 삭제된다'));
    expect(fixture, contains('소유자는 오래된 버전으로 소유권을 이전할 수 없다'));
    expect(fixture, contains('소유자는 오래된 버전으로 그룹을 보관 처리할 수 없다'));
    expect(fixture, contains('활성 구성원은 오래된 버전으로 그룹을 업데이트할 수 없다'));
    expect(fixture, contains('활성 구성원은 오래된 버전으로 소유권을 이전할 수 없다'));
    expect(fixture, contains('활성 구성원은 오래된 버전으로 그룹을 보관 처리할 수 없다'));
    expect(fixture, contains('외부 사용자는 오래된 버전으로 그룹을 업데이트할 수 없다'));
    expect(fixture, contains('외부 사용자는 오래된 버전으로 소유권을 이전할 수 없다'));
    expect(fixture, contains('외부 사용자는 오래된 버전으로 그룹을 보관 처리할 수 없다'));
    expect(fixture, contains("'40001'"));
  });

  test('API ACL과 감사 페이로드가 최소 상태를 유지한다', () {
    expect(
      migration,
      contains(
        'revoke update on table public.groups from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'revoke update on table public.memberships from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'revoke update (group_id, user_id, role, joined_at, removed_at, invited_by, created_at, updated_at, is_active) on public.memberships from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      isNot(
        contains('grant update (is_active, removed_at) on public.memberships'),
      ),
    );
    expect(migration, contains('v_entity_id := null'));
    expect(
      migration,
      contains("where entity_type = 'memberships' and entity_id is not null"),
    );
    expect(migration, contains("jsonb_build_object('version', v_version)"));
    expect(
      migration,
      contains("alter publication supabase_realtime add table public.groups"),
    );
    expect(migration, contains("tablename = 'groups'"));
    expect(
      migration,
      contains(
        "alter publication supabase_realtime add table public.memberships",
      ),
    );
    expect(migration, contains("tablename = 'memberships'"));
    expect(realtimeMigration, contains("tablename = 'events'"));
    expect(
      realtimeMigration,
      contains(
        "execute 'alter publication supabase_realtime add table public.events'",
      ),
    );
    expect(migration, isNot(contains('create schema realtime')));
  });

  test('보관은 종료 상태이며 사전 검사는 인증 전용 JSON이다', () {
    expect(
      migration,
      contains(
        'create or replace function public.archive_group_if_version( p_group_id uuid, p_expected_version integer )',
      ),
    );
    expect(migration, contains('set deleted_at = pg_catalog.now()'));
    expect(migration, contains('old'));
    expect(migration, contains('하위 행은 그대로 두고'));
    expect(
      migration,
      contains(
        'create or replace function public.account_deletion_preflight()',
      ),
    );
    expect(migration, contains('returns jsonb'));
    expect(migration, contains("'owned_groups'"));
    expect(migration, contains("'active_owned_groups'"));
    expect(migration, contains("'archived_owned_groups'"));
    expect(migration, contains("'member_count'"));
    expect(migration, contains("'events', v_events"));
    expect(migration, contains("'invites', v_invites"));
    expect(migration, contains("'memberships', v_memberships"));
    expect(
      migration,
      contains(
        'revoke execute on function public.account_deletion_preflight() from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.account_deletion_preflight() to authenticated',
      ),
    );
  });

  test('계정 삭제가 관리자 삭제 전에 호출자 요약을 가져온다', () {
    final preflight = edgeFunction.indexOf(
      "authclient.rpc( 'account_deletion_preflight', )",
    );
    final adminDelete = edgeFunction.indexOf('auth.admin.deleteuser');
    expect(preflight, greaterThanOrEqualTo(0));
    expect(adminDelete, greaterThan(preflight));
    expect(edgeFunction, contains('preflight_failed'));
    expect(edgeFunction, contains('isvaliddeletionsummary(summary)'));
    expect(edgeFunction, contains("from './preflight_validator.mjs'"));
    expect(edgeFunction, contains('json({ deleted: true, summary })'));
    expect(edgeFunction, contains("catch (_) {"));
    expect(edgeFunction, contains("json({ error: 'internal_error' }, 500)"));
    expect(edgeFunction, isNot(contains('console.log')));
    expect(edgeFunction, isNot(contains('console.error')));
  });

  test('Edge 사전 검사기가 클라이언트의 안전 실패 계약을 따른다', () {
    expect(preflightValidator, contains('isvaliddeletionsummary'));
    expect(preflightValidator, contains('owned_groups'));
    expect(preflightValidator, contains('active_owned_groups'));
    expect(preflightValidator, contains('archived_owned_groups'));
    expect(preflightValidator, contains('isrequirednonnegativeinteger'));
    expect(preflightValidator, contains('member_count'));
    expect(preflightValidator, contains('membership_count'));
    expect(preflightValidator, contains('new set(owned.map'));
    expect(preflightValidator, contains('canonicalgroup'));
    expect(preflightValidator, contains('ownedcanonical.get(group.id)'));
    expect(preflightValidator, contains('activeids.size + archivedids.size'));
    expect(preflightValidator, contains("status === 'active'"));
    expect(preflightValidator, contains('date.parse'));
    expect(preflightValidator, isNot(contains('console.log')));
    expect(preflightValidator, isNot(contains('console.error')));
  });

  test('업그레이드 증거가 마이그레이션 1..10을 적용하고 보존을 검증한다', () {
    expect(upgradeScript, contains('initdb'));
    expect(upgradeScript, contains('마이그레이션 1..9 적용'));
    expect(upgradeScript, contains('20260907130001_group_management.sql'));
    expect(upgradeScript, contains('재적용 중'));
    expect(upgradeScript, contains('기존 그룹 필드를 보존하지 않았습니다'));
    expect(upgradeScript, contains('기존 멤버십 필드를 보존하지 않았습니다'));
    expect(upgradeScript, contains('기존 초대 필드를 보존하지 않았습니다'));
    expect(upgradeScript, contains('기존 일정 필드를 보존하지 않았습니다'));
    expect(upgradeScript, contains('기존 감사 필드를 보존하지 않았습니다'));
    expect(
      upgradeScript,
      contains('groups.owner_id 소유자 멤버십을 기존 데이터에 채우지 않았습니다'),
    );
    expect(upgradeScript, contains('활성 소유자 고유 부분 인덱스가 없습니다'));
    expect(upgradeScript, contains('lock_timeout'));
    expect(upgradeScript, contains('두 세션 이전/보관 그룹 잠금 경합 검사를 통과'));
    expect(upgradeScript, contains('error: +40001'));
    expect(upgradeScript, contains('repeatable read'));
    expect(upgradeScript, contains('일정 경합'));
    expect(upgradeScript, contains('보관 뒤 일정 하위 행이 변경되었습니다'));
    expect(upgradeScript, contains('멤버십/보관 rpc 전용 경합 검사를 통과'));
    expect(upgradeScript, contains('보관 뒤 멤버십 행이 변경되었습니다'));
    expect(upgradeScript, contains('보관 뒤 직접 멤버십 update가 예기치 않게 성공했습니다'));
    expect(upgradeScript, isNot(contains('supabase_url')));
    expect(upgradeScript, isNot(contains('service_role')));
  });
}
