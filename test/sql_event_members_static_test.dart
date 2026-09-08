import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 일정 참여자 마이그레이션의 계약 수준 검사다. 함께 제공되는 pgTAP 픽스처와
/// 로컬 업그레이드 스크립트는 데이터베이스를 검사하며, 이 검사는 CI에 Supabase
/// 인스턴스가 없어도 마이그레이션을 검토할 수 있게 한다.
void main() {
  late String migration;
  late String upgrade;
  late String fixture;

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907130002_event_members.sql',
    );
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: 'event_members 마이그레이션이 있어야 한다',
    );
    migration = migrationFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    final upgradeFile = File('supabase/tests/run_group_management_upgrade.sh');
    expect(upgradeFile.existsSync(), isTrue, reason: '로컬 업그레이드 증거가 있어야 한다');
    upgrade = upgradeFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    final fixtureFile = File('supabase/tests/event_members.sql');
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'event_members pgTAP 픽스처가 있어야 한다',
    );
    fixture = fixtureFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('테이블, 키, 타임스탬프, 마이그레이션 채우기가 추가형이다', () {
    expect(
      migration,
      contains('create table if not exists public.event_members'),
    );
    expect(
      migration,
      contains(
        'event_id uuid not null references public.events(id) on delete cascade',
      ),
    );
    expect(
      migration,
      contains(
        'user_id uuid not null references auth.users(id) on delete cascade',
      ),
    );
    expect(
      migration,
      contains('created_at timestamptz not null default pg_catalog.now()'),
    );
    expect(migration, contains('primary key (event_id, user_id)'));
    expect(
      migration,
      contains(
        'create index if not exists event_members_user_event_idx on public.event_members (user_id, event_id)',
      ),
    );
    expect(
      migration,
      contains(
        'insert into public.event_members (event_id, user_id, created_at) select e.id, e.created_by, e.created_at from public.events e where not exists ( select 1 from public.event_members existing where existing.event_id = e.id and existing.user_id = e.created_by )',
      ),
    );
    expect(migration, contains('무결성/전환 트리거를 추가하기 전에 기존 데이터를 채운다'));
    expect(migration, contains('설치 완료 표식'));
    expect(migration, contains('pg_catalog.pg_trigger'));
    expect(migration, contains('v_feature_installed'));
    expect(migration, contains('if not v_feature_installed then'));
    expect(
      migration,
      contains('pg_catalog.pg_get_triggerdef(trigger_row.oid)'),
    );
    expect(upgrade, contains('20260907130002_event_members.sql'));
    expect(upgrade, contains('재적용 중'));
    expect(upgrade, contains('작성자 비활성화 뒤'));
    expect(upgrade, contains('작성자 정리/재적용 표식 회귀 검사를 통과'));
  });

  test('RLS와 ACL이 안전한 읽기만 허용하고 하위 쓰기를 거부한다', () {
    expect(
      migration,
      contains('alter table public.event_members enable row level security'),
    );
    expect(
      migration,
      contains(
        'create policy event_members_select on public.event_members for select to authenticated using',
      ),
    );
    expect(
      migration,
      contains(
        'create policy event_members_write_deny on public.event_members for all to authenticated using (false) with check (false)',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on table public.event_members from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains('grant select on table public.event_members to authenticated'),
    );
    expect(migration, contains('e.deleted_at is null'));
    expect(migration, contains('g.deleted_at is null'));
    expect(migration, contains('public.is_active_member(e.group_id)'));
    expect(migration, contains('target.is_active'));
    expect(migration, contains('target.removed_at is null'));
    expect(migration, isNot(contains('event_members for select to public')));
    expect(
      migration,
      isNot(contains('grant insert on table public.event_members')),
    );
    expect(
      migration,
      isNot(contains('grant update on table public.event_members')),
    );
    expect(
      migration,
      isNot(contains('grant delete on table public.event_members')),
    );
  });

  test('하위 테이블은 게시하지 않고 부모 일정이 Realtime 신호가 된다', () {
    expect(migration, contains('하위 테이블은 의도적으로 supabase_realtime에 추가하지 않는다'));
    expect(
      migration,
      isNot(
        contains(
          'alter publication supabase_realtime add table public.event_members',
        ),
      ),
    );
    expect(upgrade, contains('pg_catalog.pg_publication_tables'));
    expect(upgrade, contains('event_members'));
  });

  test('트리거 전용 함수가 강화되고 전환 버전 증가가 개인정보에 안전하다', () {
    for (final functionName in <String>[
      'bump_events_from_event_members_insert()',
      'bump_events_from_event_members_delete()',
      'enforce_event_member_integrity()',
      'seed_event_creator_member()',
    ]) {
      expect(
        migration,
        contains(
          'create or replace function public.$functionName returns trigger language plpgsql security definer set search_path = \'\'',
        ),
      );
      expect(
        migration,
        contains(
          'revoke execute on function public.$functionName from public, anon, authenticated',
        ),
      );
    }
    expect(migration, contains('referencing new table as new_rows'));
    expect(migration, contains('referencing old table as old_rows'));
    expect(migration, contains('order by g.id, e.id'));
    expect(migration, contains('for update of g'));
    expect(migration, contains('version = e.version + 1'));
    expect(migration, contains('updated_at'));
    expect(migration, contains('moduly.event_members_mutation_context'));
    expect(
      migration,
      contains(
        "pg_catalog.current_setting('moduly.event_members_mutation_context', true)",
      ),
    );
    expect(
      migration,
      contains(
        "pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true)",
      ),
    );
    expect(
      migration,
      contains(
        'create trigger events_seed_creator_member after insert on public.events',
      ),
    );
    expect(
      migration,
      contains(
        'insert into public.event_members (event_id, user_id, created_at)',
      ),
    );
    expect(migration, contains('if p_member_ids is null then'));
    final triggerText = migration.substring(
      0,
      migration.indexOf(
        'create or replace function public.create_event_with_members',
      ),
    );
    expect(triggerText, isNot(contains('member_ids')));
    expect(triggerText, isNot(contains('user_id::text')));
  });

  test('픽스처가 기존 트리거, 명시적 빈/사용자 지정 목록, 실패를 입증한다', () {
    for (final marker in <String>[
      '레거시 직접 insert는 이벤트의 초기 버전을 1로 유지한다',
      '레거시 직접 insert는 중복 없이 생성자 할당 하나를 만든다',
      '명시적인 빈 배열로 생성하면 참여자가 남지 않는다',
      '사용자 지정 목록 생성은 요청에 따라 생성자를 제외한다',
      'rls는 외부 사용자의 직접 이벤트 insert를 거부한다',
      '기존 이벤트 검사는 잘못된 직접 insert를 거부한다',
      '권한 없는 직접 insert는 참여자 행을 남기지 않는다',
      '잘못된 직접 insert는 참여자 행을 남기지 않는다',
      'authenticated 역할은 레거시 이벤트 초기화 트리거 함수를 직접 호출할 수 없다',
      '비활성화해도 소프트 삭제된 할당 행은 보존된다',
      '비활성화해도 소프트 삭제된 이벤트 버전은 변경되지 않는다',
      'leave_group은 소프트 삭제된 할당 이력을 보존한다',
      'leave_group은 보관된 그룹의 할당 이력을 그대로 보존한다',
    ]) {
      expect(fixture, contains(marker), reason: '픽스처가 $marker 항목을 검증해야 한다');
    }
  });

  test('RPC 시그니처와 정규 반환 형태가 안정적이다', () {
    expect(
      migration,
      contains(
        'create or replace function public.create_event_with_members( p_group_id uuid, p_title text, p_description text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text, p_is_all_day boolean, p_all_day_start date, p_all_day_end date, p_color_value bigint, p_member_ids uuid[] )',
      ),
    );
    expect(
      migration,
      contains(
        'create or replace function public.update_event_with_members_if_version( p_event_id uuid, p_expected_version integer, p_title text, p_description text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text, p_is_all_day boolean, p_all_day_start date, p_all_day_end date, p_color_value bigint, p_member_ids uuid[] )',
      ),
    );
    expect(
      migration,
      contains(
        'create or replace function public.replace_event_members_if_version( p_event_id uuid, p_expected_version integer, p_member_ids uuid[] )',
      ),
    );
    for (final functionName in <String>[
      'create_event_with_members',
      'update_event_with_members_if_version',
      'replace_event_members_if_version',
    ]) {
      final start = migration.indexOf(
        'create or replace function public.$functionName',
      );
      expect(start, greaterThanOrEqualTo(0), reason: functionName);
      final end = migration.indexOf(r'$$;', start);
      expect(end, greaterThan(start), reason: functionName);
      final body = migration.substring(start, end);
      expect(body, contains('returns table'));
      expect(body, contains('member_ids uuid[]'));
      expect(body, contains('security definer'));
      expect(body, contains('set search_path = \'\''));
      expect(body, contains('select auth.uid()'));
      expect(body, contains("coalesce(p_member_ids, '{}'::uuid[])"));
      expect(body, contains('select distinct supplied.user_id'));
      expect(
        body,
        contains('array_agg(supplied.user_id order by supplied.user_id)'),
      );
      expect(body, contains('for update'));
      expect(body, contains('active members'));
    }
    expect(
      migration,
      contains(
        'v_event.created_by <> v_actor_id and v_group.owner_id <> v_actor_id',
      ),
    );
    expect(migration, contains('p_expected_version'));
    expect(migration, contains('on conflict (event_id, user_id) do nothing'));
    expect(migration, contains('member_ids cannot contain null'));
    expect(migration, contains('명시적인 빈 배열은 실제 빈 할당'));
    for (final signature in <String>[
      'public.create_event_with_members',
      'public.update_event_with_members_if_version',
      'public.replace_event_members_if_version',
    ]) {
      expect(
        migration,
        contains('revoke execute on function $signature('),
        reason: '$signature should be revoked before the authenticated grant',
      );
      expect(
        migration,
        contains('grant execute on function $signature('),
        reason: '$signature should be callable by authenticated only',
      );
    }
  });

  test('멤버십 수명 주기가 할당을 정리하지만 복원하지 않는다', () {
    expect(
      migration,
      contains(
        'create or replace function public.leave_group(p_group_id uuid)',
      ),
    );
    expect(
      migration,
      contains('create or replace function public.set_member_active('),
    );
    expect(migration, contains('if not p_is_active then'));
    expect(migration, contains('delete from public.event_members em'));
    expect(migration, contains('select distinct event_id from removed'));
    expect(migration, contains('재활성화해도 제거된'));
    expect(migration, contains('removed_at = coalesce'));
    expect(migration, contains('e.deleted_at is null'));
    expect(migration, contains('g.deleted_at is null'));

    final leaveStart = migration.indexOf(
      'create or replace function public.leave_group(p_group_id uuid)',
    );
    final activeStart = migration.indexOf(
      'create or replace function public.set_member_active(',
    );
    final lifecycleEnd = migration.indexOf(
      '-- 직접 하위 쓰기를 계속 허용하지 않으며',
      activeStart,
    );
    expect(leaveStart, greaterThanOrEqualTo(0));
    expect(activeStart, greaterThan(leaveStart));
    expect(lifecycleEnd, greaterThan(activeStart));
    final leaveBody = migration.substring(leaveStart, activeStart);
    final activeBody = migration.substring(activeStart, lifecycleEnd);
    for (final body in <String>[leaveBody, activeBody]) {
      expect(body, contains('delete from public.event_members em'));
      expect(body, contains('and e.deleted_at is null'));
      expect(
        body,
        contains('where g.id = e.group_id and g.deleted_at is null'),
      );
    }
  });

  test('업그레이드 증거가 데이터 채우기, 연쇄 처리, 권한, 경합, 원자성을 다룬다', () {
    for (final marker in <String>[
      '데이터 채우기',
      'created_at',
      'primary key',
      '외래 키',
      'rls',
      'publication',
      '계정',
      '연쇄',
      'event_members',
      'replace_event_members_if_version',
      'stale',
      'lock timeout',
      'version',
      '원자적',
      '종료 비활성화 보존 검사를 통과',
      '종료 탈퇴/보관 보존 검사를 통과',
      '종료 비활성화 뒤 %s 재적용 중',
    ]) {
      expect(
        upgrade,
        contains(marker),
        reason: '업그레이드 스크립트가 $marker 항목을 검증해야 한다',
      );
    }
  });
}
