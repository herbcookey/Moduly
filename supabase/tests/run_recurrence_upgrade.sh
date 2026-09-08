#!/usr/bin/env bash

# 기능 2의 신규 설치/업그레이드/재적용 검증이다. 이 실행기는 전용 임시 PostgreSQL
# 클러스터를 사용하며 Supabase 프로젝트에 접속하지 않는다.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-recurrence-upgrade.XXXXXX")
data_dir="$work_dir/data"
# macOS의 103바이트 제한에 맞도록 Unix 소켓 디렉터리를 짧게 유지한다. mktemp
# 접두사에 이미 실행기를 설명하는 이름이 들어 있다.
socket_dir="$work_dir/s"
port="${SPLANNER_TEST_PORT:-$((59000 + RANDOM % 500))}"

cleanup() {
  if [[ -d "$data_dir" ]]; then
    pg_ctl -D "$data_dir" -m fast -w stop >/dev/null 2>&1 || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$socket_dir"
initdb -D "$data_dir" -A trust --no-locale >/dev/null
pg_ctl -D "$data_dir" -o "-p $port -k $socket_dir" -w start >/dev/null

psql_test() {
  psql -X -v ON_ERROR_STOP=1 -h "$socket_dir" -p "$port" postgres "$@"
}

psql_test <<'SQL'
create schema auth;
create role anon;
create role authenticated;
create table auth.users (
  id uuid primary key,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);
create function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
SQL

recurrence_migration="$repo_dir/supabase/migrations/20260907130005_recurrence.sql"
monthly_contract_migration="$repo_dir/supabase/migrations/20260908001038_fix_monthly_occurrence_zero.sql"
until_contract_migration="$repo_dir/supabase/migrations/20260908003015_reject_recurrence_ending_before_first_occurrence.sql"

# 반복 일정 이전 스키마를 먼저 설치하고 이전 단일 일정을 만든다. 기존 기능에
# 추가하는 마이그레이션이 단일 일정용 규칙을 만들어 내지 않는지 확인한다.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$recurrence_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values (
  '00000000-0000-4000-8000-00000000e201',
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  'upgrade-owner@example.test', '', now(), now(), now(), '{}'::jsonb
);
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values (
  '00000000-0000-4000-8000-00000000e204',
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  'upgrade-inactive@example.test', '', now(), now(), now(), '{}'::jsonb
);
insert into public.groups (
  id, owner_id, name, description, timezone, version, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000e202',
  '00000000-0000-4000-8000-00000000e201', 'Upgrade group', 'keep me', 'UTC', 1,
  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
);
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, version, color_value, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000e203',
  '00000000-0000-4000-8000-00000000e202',
  '00000000-0000-4000-8000-00000000e201', 'Legacy single', 'keep event',
  '2026-01-02T09:00:00Z', '2026-01-02T10:00:00Z', 'UTC', false, 1,
  305419896, '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z'
);
insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
values ('00000000-0000-4000-8000-00000000e202', '00000000-0000-4000-8000-00000000e201', 'owner', true, now(), null)
on conflict (group_id, user_id) do nothing;
SQL

printf '%s 적용 중\n' "$(basename "$recurrence_migration")"
psql_test -f "$recurrence_migration" >/dev/null
printf '%s 재적용 중\n' "$(basename "$recurrence_migration")"
psql_test -f "$recurrence_migration" >/dev/null
printf '%s 적용 중\n' "$(basename "$monthly_contract_migration")"
psql_test -f "$monthly_contract_migration" >/dev/null
printf '%s 재적용 중\n' "$(basename "$monthly_contract_migration")"
psql_test -f "$monthly_contract_migration" >/dev/null
printf '%s 적용 중\n' "$(basename "$until_contract_migration")"
psql_test -f "$until_contract_migration" >/dev/null
printf '%s 재적용 중\n' "$(basename "$until_contract_migration")"
psql_test -f "$until_contract_migration" >/dev/null

# 기준 달의 monthly_day가 이미 지나간 규칙은 다음 달의 첫 유효한 날짜를
# 순번 0으로 삼는다. until_date가 그 날짜보다 이르면 생성 RPC가 기준
# 일정/규칙을 쓴 뒤 0행을 반환하지 말고 어떤 DML 전에 명확히 거부해야 한다.
psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_returned_rows bigint;
  v_rejected boolean := false;
  v_message text;
begin
  begin
    select pg_catalog.count(*) into v_returned_rows
    from public.create_recurring_event_with_members(
      '00000000-0000-4000-8000-00000000e202',
      'Until before normalized occurrence zero', '',
      '2030-01-20T09:00:00Z', '2030-01-20T10:00:00Z', 'UTC', false,
      null, null, 904::bigint, null, 'monthly', 2, '{}'::smallint[],
      'until', null, '2030-01-20', 15::smallint
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_message = message_text;
      if v_message <> 'until_date precedes the first occurrence' then
        raise;
      end if;
      v_rejected := true;
  end;

  if not v_rejected then
    if v_returned_rows = 0 and exists (
      select 1
      from public.events e
      where e.group_id = '00000000-0000-4000-8000-00000000e202'::uuid
        and e.title = 'Until before normalized occurrence zero'
    ) then
      raise exception 'create RPC committed a monthly series but returned zero rows when until_date preceded occurrence zero';
    end if;
    raise exception 'create RPC did not reject until_date before monthly occurrence zero; returned rows: %',
      v_returned_rows;
  end if;

  if exists (
    select 1
    from public.events e
    where e.group_id = '00000000-0000-4000-8000-00000000e202'::uuid
      and e.title = 'Until before normalized occurrence zero'
  ) then
    raise exception 'rejected monthly series left partial event data';
  end if;
end;
$$;
reset role;
SQL

psql_test <<'SQL'
do $$
begin
  if (select count(*) from public.event_recurrence_rules
      where event_id = '00000000-0000-4000-8000-00000000e203'::uuid) <> 0 then
    raise exception '이전 단일 일정에 예기치 않게 반복 규칙이 생겼습니다';
  end if;
  if (select title from public.events
      where id = '00000000-0000-4000-8000-00000000e203'::uuid) <> 'Legacy single' then
    raise exception '반복 마이그레이션 중 이전 일정이 변경되었습니다';
  end if;
  if (select description from public.groups
      where id = '00000000-0000-4000-8000-00000000e202'::uuid) <> 'keep me' then
    raise exception '반복 마이그레이션 중 이전 그룹이 변경되었습니다';
  end if;
end;
$$;
SQL

# 실제 동시 세션으로 같은 auth.users 잠금 순서를 검사한다. 첫 세션은 반복 일정 생성
# 트랜잭션을 열린 채로 유지한다. 계정 삭제는 기다린 뒤 성공해야 하며 교착 상태가
# 되거나 부분 일정이 보여서는 안 된다. 두 번째 전체 범위 교체 잠금으로 참여자
# 쓰기에 대해 같은 검사를 반복한다.
psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values (
  '00000000-0000-4000-8000-00000000e205',
  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  'lock-target@example.test', '', now(), now(), now(), '{}'::jsonb
);
insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
values ('00000000-0000-4000-8000-00000000e202',
        '00000000-0000-4000-8000-00000000e205', 'member', true, now(), null)
on conflict (group_id, user_id) do update
set is_active = true, removed_at = null;
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select id from public.create_recurring_event_with_members(
  '00000000-0000-4000-8000-00000000e202', 'Lock dedicated members', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 903::bigint,
  array['00000000-0000-4000-8000-00000000e201'::uuid,
        '00000000-0000-4000-8000-00000000e205'::uuid],
  'daily', 1, '{}'::smallint[], 'count', 2, null, null);
reset role;
SQL

lock_create_log="$work_dir/lock-create.log"
psql_test >"$lock_create_log" 2>&1 <<'SQL' &
begin;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select id from public.create_recurring_event_with_members(
  '00000000-0000-4000-8000-00000000e202', 'Lock create', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 901::bigint,
  array['00000000-0000-4000-8000-00000000e201'::uuid,
        '00000000-0000-4000-8000-00000000e205'::uuid],
  'daily', 1, '{}'::smallint[], 'count', 2, null, null);
select pg_sleep(2);
commit;
SQL
lock_create_pid=$!
sleep 0.25
lock_delete_probe="$work_dir/lock-delete-create.log"
if psql_test -Atqc "set statement_timeout = '800ms'; delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid" >"$lock_delete_probe" 2>&1; then
  printf '계정 삭제가 예기치 않게 생성 auth.users 잠금을 우회했습니다\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf '계정 삭제 탐색이 잠금을 기다리지 않고 실패했습니다\n' >&2
  exit 1
fi
wait "$lock_create_pid"

lock_all_log="$work_dir/lock-all.log"
psql_test >"$lock_all_log" 2>&1 <<'SQL' &
begin;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_id uuid;
begin
  select id into v_id from public.events
   where group_id = '00000000-0000-4000-8000-00000000e202'::uuid
     and title = 'Lock create';
  perform public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000000', 'all', 'Lock all changed', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    902::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid,
          '00000000-0000-4000-8000-00000000e205'::uuid],
    'daily', 1, '{}'::smallint[], 'count', 2, null, null);
end;
$$;
select pg_sleep(2);
commit;
SQL
lock_all_pid=$!
sleep 0.25
lock_delete_probe="$work_dir/lock-delete-all.log"
if psql_test -Atqc "set statement_timeout = '800ms'; delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid" >"$lock_delete_probe" 2>&1; then
  printf '계정 삭제가 예기치 않게 전체 범위 auth.users 잠금을 우회했습니다\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf '계정 삭제 전체 범위 탐색이 잠금을 기다리지 않고 실패했습니다\n' >&2
  exit 1
fi
wait "$lock_all_pid"

lock_members_log="$work_dir/lock-members.log"
lock_members_marker="$work_dir/lock-members-started"
psql_test >"$lock_members_log" 2>&1 <<SQL &
begin;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
\! touch "$lock_members_marker"
select public.replace_recurring_event_members_if_version(
  (select id from public.events
   where group_id = '00000000-0000-4000-8000-00000000e202'::uuid
     and title = 'Lock dedicated members'),
  1, 'single',
  array['00000000-0000-4000-8000-00000000e201'::uuid,
        '00000000-0000-4000-8000-00000000e205'::uuid]);
select pg_sleep(2);
commit;
SQL
lock_members_pid=$!
for _ in {1..100}; do
  [[ -f "$lock_members_marker" ]] && break
  sleep 0.05
done
if [[ ! -f "$lock_members_marker" ]]; then
  printf '반복 일정 멤버 잠금 표시가 생성되지 않았습니다\n' >&2
  kill "$lock_members_pid" 2>/dev/null || true
  wait "$lock_members_pid" 2>/dev/null || true
  exit 1
fi
sleep 0.25
lock_delete_probe="$work_dir/lock-delete-members.log"
if psql_test -Atqc "set statement_timeout = '800ms'; delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid" >"$lock_delete_probe" 2>&1; then
  cat "$lock_members_log" >&2
  printf '계정 삭제가 예기치 않게 반복 일정 멤버 auth.users 잠금을 우회했습니다\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf '계정 삭제 반복 일정 멤버 탐색이 잠금을 기다리지 않고 실패했습니다\n' >&2
  exit 1
fi
wait "$lock_members_pid"

psql_test -Atqc "delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid"

# 실패한 쿼리만 보지 않고 카탈로그 상태에서 보안 경계를 확인한다. 기존 기능에 추가한
# 두 하위 테이블에는 RLS가 있고 authenticated 직접 권한은 없으며, 이름을 지정한
# RPC만 실행할 수 있고 하위 테이블은 게시되지 않는다.
psql_test <<'SQL'
do $$
begin
  if not (select relrowsecurity from pg_catalog.pg_class c
          join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relname = 'event_recurrence_rules')
     or not (select relrowsecurity from pg_catalog.pg_class c
             join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = 'event_occurrence_overrides') then
    raise exception '반복 일정 하위 RLS가 활성화되지 않았습니다';
  end if;
  if has_table_privilege('authenticated', 'public.event_recurrence_rules', 'select')
     or has_table_privilege('authenticated', 'public.event_occurrence_overrides', 'select') then
    raise exception 'authenticated 역할에 반복 일정 하위 직접 권한이 있습니다';
  end if;
  if not has_function_privilege('authenticated',
      'public.events_for_range_v2(uuid,timestamptz,timestamptz,text,integer,text,uuid)', 'execute')
     or not has_function_privilege('authenticated',
      'public.create_recurring_event_with_members(uuid,text,text,timestamptz,timestamptz,text,boolean,date,date,bigint,uuid[],text,integer,smallint[],text,integer,date,smallint)', 'execute')
     or not has_function_privilege('authenticated',
      'public.update_event_occurrence_scope_if_version(uuid,integer,text,text,text,text,timestamptz,timestamptz,text,boolean,date,date,bigint,uuid[],text,integer,smallint[],text,integer,date,smallint)', 'execute')
     or not has_function_privilege('authenticated',
      'public.replace_event_members_if_version(uuid,integer,uuid[])', 'execute')
     or has_function_privilege('anon',
      'public.replace_event_members_if_version(uuid,integer,uuid[])', 'execute')
     or exists (
       select 1
       from pg_catalog.pg_proc p
       cross join lateral pg_catalog.aclexplode(
         coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) acl
       where p.oid = 'public.replace_event_members_if_version(uuid,integer,uuid[])'::regprocedure
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     )
     or has_function_privilege('authenticated',
      'public._event_occurrence_at_index(uuid,bigint)', 'execute') then
    raise exception '반복 일정 함수 ACL 계약에 실패했습니다';
  end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role')
     and has_function_privilege('service_role',
       'public.replace_event_members_if_version(uuid,integer,uuid[])', 'execute') then
    raise exception 'service_role이 호환성 래퍼를 실행할 수 있습니다';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p
             join pg_catalog.pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname in ('_event_occurrence_at_index', '_event_occurrences_for_range',
                                 'events_for_range_v2', 'event_occurrence_by_key',
                                 'create_recurring_event_with_members',
                                 'update_event_occurrence_scope_if_version',
                                 'delete_event_occurrence_scope_if_version')
               and coalesce(pg_catalog.array_to_string(p.proconfig, ','), '') not like '%search_path=%') then
    raise exception '반복 일정 정의자 함수에 고정 search_path가 없습니다';
  end if;
  if exists (select 1 from pg_catalog.pg_publication_tables
             where schemaname = 'public'
               and tablename in ('event_recurrence_rules', 'event_occurrence_overrides')) then
    raise exception '반복 일정 하위 테이블이 Realtime publication에 있어서는 안 됩니다';
  end if;
end;
$$;
SQL

if psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'" | grep -q '^1$'; then
  printf '반복 일정 pgTAP 픽스처 실행 중\n'
  psql_test -f "$repo_dir/supabase/tests/recurrence.sql" >/dev/null
else
  printf 'pgTAP을 사용할 수 없어 대체 검증을 실행합니다\n'
  psql_test <<'SQL'
begin;
create temporary table recurrence_fallback (
  group_id uuid not null,
  event_id uuid not null
) on commit drop;
grant all on recurrence_fallback to authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000e201', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
with created_group as (
  select id from public.create_group('Fallback recurrence', 'UTC', '')
), created_event as (
  select id from public.create_recurring_event_with_members(
    (select id from created_group), 'Fallback daily', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
    null, null, 1::bigint, null, 'daily', 1, '{}'::smallint[],
    'count', 3, null, null
  )
)
insert into recurrence_fallback(group_id, event_id)
select (select id from created_group), (select id from created_event);
do $$
declare
  v_created record;
  v_next record;
  v_range_indexes bigint[];
begin
  select * into strict v_created
  from public.create_recurring_event_with_members(
    (select group_id from recurrence_fallback), 'Monthly after anchor', '',
    '2030-01-20T09:00:00Z', '2030-01-20T10:00:00Z', 'UTC', false,
    null, null, 101::bigint, null, 'monthly', 2, '{}'::smallint[],
    'count', 3, null, 15::smallint
  );
  if v_created.occurrence_index <> 0
     or v_created.starts_at <> '2030-02-15T09:00:00Z'::timestamptz then
    raise exception '월간 순번 0이 기준 시각 이후의 첫 유효한 날짜가 아닙니다';
  end if;
  select * into strict v_next
  from public.event_occurrence_by_key(
    v_created.event_id,
    'o00000000000000000001'
  );
  if v_next.starts_at <> '2030-04-15T09:00:00Z'::timestamptz then
    raise exception '월간 간격이 정규화된 순번 0에서부터 계산되지 않았습니다';
  end if;
  select pg_catalog.array_agg(
    (item->>'occurrence_index')::bigint
    order by (item->>'occurrence_index')::bigint
  ) into v_range_indexes
  from pg_catalog.jsonb_array_elements(
    public.events_for_range_v2(
      (select group_id from recurrence_fallback),
      '2030-02-01T00:00:00Z', '2030-07-01T00:00:00Z', 'UTC', 200, null, null
    )->'events'
  ) item
  where item->>'event_id' = v_created.event_id::text;
  if v_range_indexes is distinct from array[0, 1, 2]::bigint[] then
    raise exception '월간 범위 확장이 정규화된 순번과 횟수를 유지하지 않았습니다: %',
      v_range_indexes;
  end if;
end;
$$;
with fallback_group as (
  select group_id from recurrence_fallback
), extra_events as (
  select id from public.create_recurring_event_with_members(
    (select group_id from fallback_group), 'Fallback daily two', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
    null, null, 2::bigint, null, 'daily', 1, '{}'::smallint[],
    'never', null, null, null
  )
  union all
  select id from public.create_recurring_event_with_members(
    (select group_id from fallback_group), 'Fallback daily three', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
    null, null, 3::bigint, null, 'daily', 1, '{}'::smallint[],
    'never', null, null, null
  )
  union all
  select id from public.create_recurring_event_with_members(
    (select group_id from fallback_group), 'Fallback daily four', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
    null, null, 4::bigint, null, 'daily', 1, '{}'::smallint[],
    'never', null, null, null
  )
)
select count(*) from extra_events;
reset role;
insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
values ((select group_id from recurrence_fallback),
        '00000000-0000-4000-8000-00000000e204'::uuid,
        'member', true, now(), null)
on conflict (group_id, user_id) do update
set is_active = true, removed_at = null;
set role authenticated;
do $$
begin
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'invalid interval zero', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 5::bigint, null, 'daily', 0, '{}'::smallint[],
      'never', null, null, null
    );
    raise exception '간격 0이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null frequency', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 5::bigint, null, null::text, 1, '{}'::smallint[],
      'never', null, null, null
    );
    raise exception 'NULL 빈도가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null end', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 6::bigint, null, 'daily', 1, '{}'::smallint[], null::text,
      null, null, null
    );
    raise exception 'NULL 반복 종료가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'duplicate weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 9::bigint, null, 'weekly', 1, array[1,1]::smallint[],
      'never', null, null, null
    );
    raise exception '중복 요일이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'out of range weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 10::bigint, null, 'weekly', 1, array[0]::smallint[],
      'never', null, null, null
    );
    raise exception '범위를 벗어난 요일이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null element weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 11::bigint, null, 'weekly', 1,
      array[1::smallint,NULL::smallint], 'never', null, null, null
    );
    raise exception 'NULL 요일 요소가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'invalid interval thousand', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 6::bigint, null, 'daily', 1000, '{}'::smallint[],
      'never', null, null, null
    );
    raise exception '간격 1000이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'missing creator', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 7::bigint,
      array['00000000-0000-4000-8000-00000000e204'::uuid],
      'daily', 1, '{}'::smallint[], 'never', null, null, null
    );
    raise exception '작성자 없는 멤버 목록이 예기치 않게 성공했습니다';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'unsorted weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 8::bigint, null, 'weekly', 1, array[3,1]::smallint[],
      'never', null, null, null
    );
    raise exception '정렬되지 않은 요일이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 9::bigint, null, 'daily', 1, null::smallint[],
      'never', null, null, null
    );
    raise exception 'null 요일이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
end;
$$;
reset role;
do $$
declare
  v_group uuid := (select group_id from recurrence_fallback);
  v_event uuid := (select event_id from recurrence_fallback);
  v_payload jsonb;
begin
  if (select count(*) from public.event_recurrence_rules where event_id = v_event) <> 1 then
    raise exception '대체 루트 규칙 검증에 실패했습니다';
  end if;
  v_payload := public.events_for_range_v2(
    v_group, '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
  );
  if jsonb_array_length(v_payload->'events') <> 30 then
    raise exception '대체 범위 제한 확장 검증에 실패했습니다';
  end if;
  if (select occurrence_key from public.event_occurrence_by_key(v_event, 'o00000000000000000002'))
      <> 'o00000000000000000002' then
    raise exception '대체 안정 키 검증에 실패했습니다';
  end if;
end;
$$;
set role authenticated;
do $$
declare
  v_receipt jsonb;
  v_event uuid := (select event_id from recurrence_fallback);
begin
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event, 1, 'o00000000000000000001', 'this', 'Fallback exception', 'changed',
    '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false, null, null,
    9::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null
  );
  if (v_receipt->>'changed')::boolean is not true
     or (v_receipt->>'series_version')::integer <> 2
     or (v_receipt->>'occurrence_version')::integer <> 1 then
    raise exception '현재 범위 변경 응답/버전 검증에 실패했습니다';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event, 2, 'o00000000000000000001', 'this', 'Fallback exception', 'changed',
    '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false, null, null,
    9::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null
  );
  if (v_receipt->>'changed')::boolean is not false
     or (v_receipt->>'series_version')::integer <> 2
     or (v_receipt->>'occurrence_version')::integer <> 1 then
    raise exception '현재 범위 멱등 재실행이 상위 행을 변경했습니다';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_event, 2, 'o00000000000000000000', 'this'
  );
  if (v_receipt->>'changed')::boolean is not true
     or (v_receipt->>'series_version')::integer <> 3 then
    raise exception '현재 범위 취소 응답/버전 검증에 실패했습니다';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_event, 3, 'o00000000000000000000', 'this'
  );
  if (v_receipt->>'changed')::boolean is not false
     or (v_receipt->>'series_version')::integer <> 3 then
    raise exception '멱등 취소가 상위 행을 변경했습니다';
  end if;
  if exists (select 1 from public.event_occurrence_by_key(v_event, 'o00000000000000000000')) then
    raise exception '취소된 발생이 지점 RPC에서 계속 조회됩니다';
  end if;
end;
$$;
reset role;
-- 끝이 없는 일간 묶음 세 개의 모든 페이지를 순회한다. 보호 조건은 실수로 생긴
-- 제한 없는 커서 반복을 CI 작업 중단 대신 결정적인 실패로 만든다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_payload jsonb;
  v_cursor text;
  v_total integer := 0;
  v_pages integer := 0;
  v_seen text[] := '{}';
  v_item jsonb;
  v_key text;
begin
  loop
    v_payload := public.events_for_range_v2(
      (select group_id from recurrence_fallback),
      '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z', 'UTC', 200, v_cursor, null
    );
    v_pages := v_pages + 1;
    if v_pages > 10 then raise exception '키셋 페이지네이션이 제한된 페이지 보호를 초과했습니다'; end if;
    for v_item in select value from jsonb_array_elements(v_payload->'events') loop
      v_key := (v_item->>'event_id') || ':' || (v_item->>'occurrence_key');
      if v_key = any(v_seen) then raise exception '키셋 페이지에 중복 발생이 있습니다'; end if;
      v_seen := array_append(v_seen, v_key);
      v_total := v_total + 1;
    end loop;
    if coalesce((v_payload->>'has_more')::boolean, false) is false then exit; end if;
    v_cursor := v_payload->>'next_cursor';
    if v_cursor is null or v_cursor = '' then raise exception 'has_more 페이지에 커서가 없습니다'; end if;
  end loop;
  if v_total <> 1097 then raise exception '누락 없는 제한 발생 1097개를 기대했지만 %개입니다', v_total; end if;
end;
$$;
reset role;

-- 전체 범위 참여자 교체는 본문/규칙 저장과 원자적이며 상위 버전 전환을 한 번
-- 출력한다. 이전 예외도 함께 재설정한다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_receipt jsonb;
  v_event uuid := (select event_id from recurrence_fallback);
  v_point record;
begin
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event, 3, 'o00000000000000000001', 'all', 'Fallback daily', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid,
          '00000000-0000-4000-8000-00000000e204'::uuid],
    'daily', 1, '{}'::smallint[], 'count', 3, null, null
  );
  if v_receipt->>'changed' is distinct from 'true'
     or (v_receipt->>'series_version')::integer <> 4 then
    raise exception '전체 범위 참여자 교체가 버전을 한 번 올리지 않았습니다';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event, 'o00000000000000000000');
  if v_point.member_ids <> array['00000000-0000-4000-8000-00000000e201'::uuid,
                                  '00000000-0000-4000-8000-00000000e204'::uuid]
     or v_point.occurrence_version <> 0 then
    raise exception '전체 범위 참여자 교체가 예외를 재설정하지 않았습니다';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event, 4, 'o00000000000000000001', 'all', 'Fallback daily', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid,
          '00000000-0000-4000-8000-00000000e204'::uuid],
    'daily', 1, '{}'::smallint[], 'count', 3, null, null
  );
  if v_receipt->>'changed' is distinct from 'false'
     or (v_receipt->>'series_version')::integer <> 4 then
    raise exception '전체 범위 참여자 재실행이 무동작이 아니었습니다';
  end if;
end;
$$;
reset role;

-- 반복 일정에서 참여자만 교체할 때는 응답 반환 RPC를 사용한다. 그룹 소유자는
-- 멤버가 만든 묶음을 갱신할 수 있지만 작성자를 절대 빼면 안 된다. 정규 입력은
-- 정렬하고 중복을 제거하며 동일한 입력은 무동작이다.
create temporary table recurrence_member_rpc_event (
  group_id uuid not null,
  event_id uuid,
  series_version integer
) on commit drop;
grant all on recurrence_member_rpc_event to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into recurrence_member_rpc_event(group_id)
select id from public.create_group('Member RPC group', 'UTC', '');
reset role;
insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
select group_id, '00000000-0000-4000-8000-00000000e204'::uuid,
  'member', true, now(), null from recurrence_member_rpc_event;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e204';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e204","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_member_rpc_event), 'Member RPC series', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
  25::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null);
reset role;
update recurrence_member_rpc_event f set event_id = e.id, series_version = e.version
from public.events e
where e.group_id = (select group_id from recurrence_member_rpc_event)
  and e.title = 'Member RPC series';
do $$
begin
  if not exists (select 1 from recurrence_member_rpc_event where event_id is not null) then
    raise exception '멤버 RPC 묶음이 생성되지 않았습니다';
  end if;
end;
$$;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_event uuid := (select event_id from recurrence_member_rpc_event);
  v_before integer := (select version from public.events where id = v_event);
  v_members_before integer := (select count(*) from public.event_members where event_id = v_event);
  v_receipt jsonb;
begin
  begin
    perform public.replace_recurring_event_members_if_version(
      v_event, v_before, 'single',
      array['00000000-0000-4000-8000-00000000e201'::uuid]);
    raise exception '작성자를 제외한 반복 멤버 교체가 예기치 않게 성공했습니다';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before
     or (select count(*) from public.event_members where event_id = v_event) <> v_members_before then
    raise exception '작성자를 제외한 반복 교체가 데이터를 부분적으로 변경했습니다';
  end if;
  v_receipt := public.replace_recurring_event_members_if_version(
    v_event, v_before, 'single',
    array['00000000-0000-4000-8000-00000000e204'::uuid,
          '00000000-0000-4000-8000-00000000e201'::uuid]);
  if v_receipt->>'changed' is distinct from 'true'
     or (v_receipt->>'series_version')::integer <> v_before + 1
     or v_receipt->>'occurrence_key' <> 'o00000000000000000000'
     or v_receipt->>'scope' <> 'all'
     or (v_receipt->>'occurrence_version')::integer <> 0
     or v_receipt->>'committed' is distinct from 'true' then
    raise exception '반복 멤버 교체 응답/정규 키 검증에 실패했습니다';
  end if;
  v_receipt := public.replace_recurring_event_members_if_version(
    v_event, v_before + 1, 'o00000000000000000001',
    array['00000000-0000-4000-8000-00000000e204'::uuid,
          '00000000-0000-4000-8000-00000000e201'::uuid]);
  if v_receipt->>'changed' is distinct from 'false'
     or (v_receipt->>'series_version')::integer <> v_before + 1
     or v_receipt->>'occurrence_key' <> 'o00000000000000000001' then
    raise exception '동일한 반복 멤버 교체가 무동작이 아니었습니다';
  end if;
  begin
    perform public.replace_recurring_event_members_if_version(
      v_event, v_before, 'single',
      array['00000000-0000-4000-8000-00000000e201'::uuid,
            '00000000-0000-4000-8000-00000000e204'::uuid]);
    raise exception '오래된 반복 멤버 교체가 예기치 않게 성공했습니다';
  exception when sqlstate '40001' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before + 1 then
    raise exception '오래된 반복 멤버 교체가 버전을 변경했습니다';
  end if;
  begin
    perform public.replace_event_members_if_version(
      v_event, v_before + 1,
      array['00000000-0000-4000-8000-00000000e201'::uuid]);
    raise exception '이전 반복 교체가 예기치 않게 작성자를 제거했습니다';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before + 1 then
    raise exception '이전 반복 교체가 작성자 거부 시 버전을 변경했습니다';
  end if;
  if (select replaced.version
      from public.replace_event_members_if_version(
        v_event, v_before + 1,
        array['00000000-0000-4000-8000-00000000e204'::uuid,
              '00000000-0000-4000-8000-00000000e201'::uuid]) replaced)
      <> v_before + 1 then
    raise exception '이전 반복 교체 호환성 행 검증에 실패했습니다';
  end if;
end;
$$;
reset role;

-- 호환성 래퍼는 이전 빈 목록 규칙을 포함해 단일 일정을 계속 원래의 테이블 반환
-- 구현에 위임한다.
create temporary table recurrence_single_rpc_event (event_id uuid not null) on commit drop;
grant all on recurrence_single_rpc_event to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into recurrence_single_rpc_event(event_id)
select id from public.create_event_with_members(
  (select group_id from recurrence_member_rpc_event), 'Member RPC singleton', '',
  '2026-01-05T09:00:00Z', '2026-01-05T10:00:00Z', 'UTC', false, null, null,
  26::bigint, null);
reset role;
set role authenticated;
do $$
declare
  v_event uuid := (select event_id from recurrence_single_rpc_event);
begin
  if (select replaced.version from public.replace_event_members_if_version(
      v_event, 1, '{}'::uuid[]) replaced) <> 2 then
    raise exception '단일 일정 호환성 빈 교체가 버전을 한 번 올리지 않았습니다';
  end if;
  if (select replaced.version from public.replace_event_members_if_version(
      v_event, 2,
      array['00000000-0000-4000-8000-00000000e201'::uuid]) replaced) <> 3 then
    raise exception '단일 일정 호환성 작성자 교체에 실패했습니다';
  end if;
end;
$$;
reset role;

-- 제거된 일정 작성자는 반복 멤버 RPC를 사용할 수 없다. 멤버십 수명 주기 정리는
-- 이 전용 그룹으로 격리되며 재활성화가 하위 할당을 조용히 복원하지 않는다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  (select group_id from recurrence_member_rpc_event),
  '00000000-0000-4000-8000-00000000e204'::uuid, false);
reset role;
update recurrence_member_rpc_event f
set series_version = e.version
from public.events e
where e.id = f.event_id;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e204';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e204","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_event uuid := (select event_id from recurrence_member_rpc_event);
  v_before integer := (select series_version from recurrence_member_rpc_event);
begin
  begin
    perform public.replace_recurring_event_members_if_version(
      v_event, v_before, 'single',
      array['00000000-0000-4000-8000-00000000e204'::uuid]);
    raise exception '제거된 작성자의 반복 교체가 예기치 않게 성공했습니다';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before then
    raise exception '제거된 작성자 교체가 버전을 변경했습니다';
  end if;
end;
$$;
reset role;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  (select group_id from recurrence_member_rpc_event),
  '00000000-0000-4000-8000-00000000e204'::uuid, true);
reset role;

-- 연속된 향후 분할은 소비한 순번을 뺀 횟수를 상속한다. 명시적인 횟수는 이전
-- 횟수에서 빼지 않고 교체한다.
create temporary table recurrence_future_count (event_id uuid not null) on commit drop;
grant all on recurrence_future_count to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
reset role;
insert into recurrence_future_count(event_id)
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Inherited count', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 18::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 5, null, null
);
insert into recurrence_future_count(event_id)
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Explicit count', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 19::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 5, null, null
);
reset role;
do $$
declare
  v_id uuid;
  v_receipt jsonb;
begin
  select event_id into v_id from recurrence_future_count where event_id in (
    select id from public.events where title = 'Inherited count') limit 1;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000001', 'future', null, null, null, null, null,
    null, null, null, null, null, null, null, null, null, null, null, null);
  if v_receipt->>'changed' is distinct from 'true' or (v_receipt->>'series_version')::integer <> 2
      or (select occurrence_count from public.event_recurrence_rules
          where event_id = v_id and start_occurrence_index = 1) <> 4 then
    raise exception '상속된 향후 횟수에서 소비한 순번을 빼지 않았습니다';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 2, 'o00000000000000000002', 'future', null, null, null, null, null,
    null, null, null, null, null, null, null, null, null, null, null, null);
  if v_receipt->>'changed' is distinct from 'true'
      or (select occurrence_count from public.event_recurrence_rules
          where event_id = v_id and start_occurrence_index = 2) <> 3 then
    raise exception '연속해서 상속된 향후 횟수가 남은 횟수와 다릅니다';
  end if;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_id, 3, 'o00000000000000000002', 'future', null, null, null, null, null,
      null, null, null, null, null, 'daily', 1, null::smallint[], null::text,
      null, null, null);
    raise exception 'NULL 요일을 사용한 명시적 빈도가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_id, 3, 'o00000000000000000002', 'future', null, null, null, null, null,
      null, null, null, null, null, null, null, null, null, null, null, 4::smallint);
    raise exception '상속된 비월간 규칙이 예기치 않게 monthly_day를 허용했습니다';
  exception when sqlstate '22023' then null;
  end;
  select event_id into v_id from recurrence_future_count where event_id in (
    select id from public.events where title = 'Explicit count') limit 1;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000001', 'future', null, null, null, null, null,
    null, null, null, null, null, null, null, null, 'count', 2, null, null);
  if (select occurrence_count from public.event_recurrence_rules
      where event_id = v_id and start_occurrence_index = 1) <> 2 then
    raise exception '명시적 향후 횟수가 상속된 횟수를 교체하지 않았습니다';
  end if;
end;
$$;
reset role;

-- 생성, 향후 및 전체 범위 저장은 모두 DST 전환을 지나는 현지 벽시계 기간을 구한다.
-- 저장된 기간은 24시간으로 유지되고 UTC 투영은 달라진다.
create temporary table recurrence_duration_event (kind text not null, event_id uuid not null) on commit drop;
grant all on recurrence_duration_event to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into recurrence_duration_event(kind, event_id)
select 'future', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Future DST duration', '',
  '2026-03-07T09:00:00-05:00', '2026-03-07T10:00:00-05:00', 'America/New_York', false,
  null, null, 23::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 2, null, null
);
insert into recurrence_duration_event(kind, event_id)
select 'all', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'All DST duration', '',
  '2026-03-07T09:00:00-05:00', '2026-03-07T10:00:00-05:00', 'America/New_York', false,
  null, null, 24::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 2, null, null
);
reset role;
do $$
declare
  v_id uuid;
  v_receipt jsonb;
begin
  select event_id into v_id from recurrence_duration_event where kind = 'future';
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000000', 'future', null, null,
    '2026-03-07T09:00:00-05:00', '2026-03-08T09:00:00-04:00', 'America/New_York', false,
    null, null, null, null, null, null, null, null, null, null, null);
  if v_receipt->>'changed' is distinct from 'true'
     or (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception '향후 DST 저장이 현지 24시간 기간을 보존하지 않았습니다';
  end if;
  select event_id into v_id from recurrence_duration_event where kind = 'all';
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000000', 'all', 'All DST duration', '',
    '2026-03-07T09:00:00-05:00', '2026-03-08T09:00:00-04:00', 'America/New_York', false,
    null, null, 24::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid],
    'daily', 1, '{}'::smallint[], 'count', 2, null, null);
  if v_receipt->>'changed' is distinct from 'true'
     or (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception '전체 범위 DST 저장이 현지 24시간 기간을 보존하지 않았습니다';
  end if;
end;
$$;

-- 366일 예정 시각 이전 조회 범위를 넘는 현재 범위 이동은 유효 재정의 인덱스를 통해
-- 찾는다. 원래 예정 슬롯은 억제하고 취소 시 범위 안으로 이동한 행을 제거한다.
create temporary table recurrence_moved_event (event_id uuid not null) on commit drop;
grant all on recurrence_moved_event to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into recurrence_moved_event(event_id)
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Moved override', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 21::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null
);
do $$
declare
  v_id uuid := (select event_id from recurrence_moved_event);
  v_payload jsonb;
  v_receipt jsonb;
begin
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000000', 'this', 'Moved override', '',
    '2027-06-10T09:00:00Z', '2027-06-10T10:00:00Z', 'UTC', false,
    null, null, 21::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
  if v_receipt->>'changed' is distinct from 'true' then
    raise exception '이동한 재정의 갱신이 커밋되지 않았습니다';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2027-06-01T00:00:00Z',
    '2027-06-30T00:00:00Z', 'UTC', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text
                   and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception '예정 이전 조회 범위 밖에서 범위 안으로 이동한 재정의를 찾지 못했습니다';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2026-01-01T00:00:00Z',
    '2026-01-02T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text) then
    raise exception '범위 밖으로 이동한 예정 슬롯을 억제하지 않았습니다';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_id, 2, 'o00000000000000000000', 'this');
  if v_receipt->>'changed' is distinct from 'true' then
    raise exception '이동한 재정의 취소가 커밋되지 않았습니다';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2027-06-01T00:00:00Z',
    '2027-06-30T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text
               and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception '취소된 이동 재정의가 다시 나타났습니다';
  end if;
end;
$$;
reset role;

-- 행렬 행은 세 가지 빈도, 간격/요일, 모든 종료 모드, 월말 제한, DST 누락/중복 동작,
-- 참여자 상속 및 종일 현지 반열린 날짜를 검사한다. 1,000개 초과 행 페이지네이션
-- 검사 뒤에 만들어 예상 카디널리티를 결정적으로 유지한다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix weekly', '',
  '2026-01-07T09:00:00Z', '2026-01-07T10:00:00Z', 'UTC', false,
  null, null, 10::bigint, null, 'weekly', 2, array[1,3,5]::smallint[],
  'count', 6, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix until', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 11::bigint, null, 'daily', 1, '{}'::smallint[],
  'until', null, '2026-01-03', null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix participant', '',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
  null, null, 12::bigint,
  array['00000000-0000-4000-8000-00000000e201'::uuid,
        '00000000-0000-4000-8000-00000000e204'::uuid],
  'daily', 1, '{}'::smallint[], 'count', 1, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix gap', '',
  '2026-03-08T02:30:00-05:00', '2026-03-08T04:30:00-04:00',
  'America/New_York', false, null, null, 13::bigint, null,
  'daily', 2, '{}'::smallint[], 'count', 2, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix fold', '',
  '2026-11-01T01:30:00-04:00', '2026-11-01T02:30:00-05:00',
  'America/New_York', false, null, null, 14::bigint, null,
  'daily', 2, '{}'::smallint[], 'count', 2, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix spring duration', '',
  '2026-03-07T09:00:00-05:00', '2026-03-08T09:00:00-04:00',
  'America/New_York', false, null, null, 16::bigint, null,
  'daily', 1, '{}'::smallint[], 'count', 1, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix fall duration', '',
  '2026-10-31T09:00:00-04:00', '2026-11-01T09:00:00-05:00',
  'America/New_York', false, null, null, 17::bigint, null,
  'daily', 1, '{}'::smallint[], 'count', 1, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix all day', '',
  '2026-01-01T00:00:00Z', '2026-01-03T00:00:00Z', 'UTC', true,
  '2026-01-01', '2026-01-03', 15::bigint, null,
  'daily', 2, '{}'::smallint[], 'count', 2, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix all day offset', '',
  '2026-01-01T00:00:00-05:00', '2026-01-02T00:00:00-05:00', 'America/New_York', true,
  '2026-01-01', '2026-01-02', 22::bigint, null,
  'daily', 1, '{}'::smallint[], 'count', 1, null, null
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix clamp 28', '',
  '2024-01-28T09:00:00Z', '2024-01-28T10:00:00Z', 'UTC', false,
  null, null, 28::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 28::smallint
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix clamp 29', '',
  '2024-01-29T09:00:00Z', '2024-01-29T10:00:00Z', 'UTC', false,
  null, null, 29::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 29::smallint
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix clamp 30', '',
  '2024-01-30T09:00:00Z', '2024-01-30T10:00:00Z', 'UTC', false,
  null, null, 30::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 30::smallint
);
select id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'Matrix clamp 31', '',
  '2024-01-31T09:00:00Z', '2024-01-31T10:00:00Z', 'UTC', false,
  null, null, 31::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 31::smallint
);
reset role;
do $$
declare
  v_group uuid := (select group_id from recurrence_fallback);
  v_id uuid;
  v_row record;
  v_payload jsonb;
  v_count integer;
begin
  select id into v_id from public.events where group_id = v_group and title = 'Matrix weekly';
  select count(*) into v_count from public._event_occurrences_for_range(v_id, '2026-01-01', '2026-03-01', 'UTC');
  if v_count <> 6 then raise exception '주간 간격/요일 확장 개수=%', v_count; end if;
  if (select starts_at::date from public.event_occurrence_by_key(v_id, 'o00000000000000000000')) <> '2026-01-07'::date
     or (select starts_at::date from public.event_occurrence_by_key(v_id, 'o00000000000000000002')) <> '2026-01-19'::date then
    raise exception '주간 간격이 기준점을 잡고 사이의 한 주를 건너뛰지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix until';
  select count(*) into v_count from public._event_occurrences_for_range(v_id, '2026-01-01', '2026-01-05', 'UTC');
  if v_count <> 3 then raise exception '포함형 종료일까지의 확장 개수=%', v_count; end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix participant';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if v_row.member_ids <> array['00000000-0000-4000-8000-00000000e201'::uuid,
                                '00000000-0000-4000-8000-00000000e204'::uuid] then
    raise exception '참여자 상속이 묶음 전체에 적용되지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix gap';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (v_row.starts_at at time zone 'America/New_York')::time <> '03:30:00'::time then
    raise exception 'DST 누락 시각을 앞으로 해석하지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix fold';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if v_row.starts_at <> '2026-11-01T06:30:00Z'::timestamptz then
    raise exception 'DST 중복 시각에서 표준시를 선택하지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix spring duration';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception '봄 기준점이 현지 24시간 기간을 보존하지 않았습니다';
  end if;
  if extract(epoch from v_row.ends_at - v_row.starts_at) <> 23 * 3600 then
    raise exception '봄 전환이 23시간 UTC 경과 투영을 만들지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix fall duration';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception '가을 기준점이 현지 24시간 기간을 보존하지 않았습니다';
  end if;
  if extract(epoch from v_row.ends_at - v_row.starts_at) <> 25 * 3600 then
    raise exception '가을 전환이 25시간 UTC 경과 투영을 만들지 않았습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix all day';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000001');
  if v_row.all_day_start <> '2026-01-03'::date or v_row.all_day_end <> '2026-01-05'::date then
    raise exception '종일 일정 반열린 날짜가 올바르지 않습니다';
  end if;
  v_payload := public.events_for_range_v2(v_group, '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z', 'UTC', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text and e->>'occurrence_key' = 'o00000000000000000001') then
    raise exception '종일 일정 반열린 겹침이 경계 발생을 누락했습니다';
  end if;
  v_payload := public.events_for_range_v2(v_group, '2026-01-05T00:00:00Z', '2026-01-06T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text) then
    raise exception '종일 일정 반열린 끝 경계를 포함했습니다';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix all day offset';
  v_payload := public.events_for_range_v2(
    v_group, '2026-01-01T00:00:00-10:00', '2026-01-02T00:00:00-10:00',
    'Pacific/Honolulu', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text
                   and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception '종일 일정 겹침이 유효 현지 날짜를 사용하지 않았습니다';
  end if;
  for v_id in select id from public.events where group_id = v_group and title like 'Matrix clamp %' loop
    select count(*) into v_count from public._event_occurrences_for_range(v_id, '2024-01-01', '2024-06-01', 'UTC');
    if v_count <> 3 then raise exception '범위 제한 묶음 %의 행 개수가 %개입니다', v_id, v_count; end if;
    if (select count(distinct starts_at::date) from public._event_occurrences_for_range(v_id, '2024-01-01', '2024-06-01', 'UTC')) <> 3 then
      raise exception '범위 제한 묶음 %에서 발생 날짜가 중복되었습니다', v_id;
    end if;
  end loop;
end;
$$;

-- 명시적 그룹 삭제는 기준점과 기존 기능에 추가한 두 하위 테이블을 연쇄 삭제해야
-- 한다. 아래 계정 삭제는 auth.users를 통해 같은 경로를 검사한다.
create temporary table recurrence_cascade (group_id uuid not null, event_id uuid not null) on commit drop;
grant all on recurrence_cascade to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
with created_group as (
  select id from public.create_group('Cascade group', 'UTC', '')
), created_event as (
  select id from public.create_recurring_event_with_members(
    (select id from created_group), 'Cascade recurrence', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
    null, null, 20::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 2, null, null
  )
)
insert into recurrence_cascade(group_id, event_id)
select (select id from created_group), (select id from created_event);
reset role;
delete from public.groups where id = (select group_id from recurrence_cascade);
do $$
begin
  if exists (select 1 from public.events where id = (select event_id from recurrence_cascade))
     or exists (select 1 from public.event_recurrence_rules where event_id = (select event_id from recurrence_cascade))
     or exists (select 1 from public.event_occurrence_overrides where event_id = (select event_id from recurrence_cascade)) then
    raise exception '그룹 삭제가 반복 일정 하위 행을 연쇄 삭제하지 않았습니다';
  end if;
end;
$$;

set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
begin
  begin
    perform public.update_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', null::text,
      'bad scope', '', '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
      null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
    raise exception 'NULL 갱신 범위가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', null::text);
    raise exception 'NULL 삭제 범위가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'all',
      'bad end', '', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 1::bigint,
      array['00000000-0000-4000-8000-00000000e201'::uuid],
      'daily', 1, '{}'::smallint[], null::text, null, null, null);
    raise exception 'NULL 전체 범위 반복 종료가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
end;
$$;
reset role;

-- 극단적인 20자리 순번은 구체화나 변경 전에 거부한다. 갱신과 삭제 어느 쪽도 상위
-- 버전을 올려서는 안 된다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_event uuid := (select event_id from recurrence_fallback);
  v_before integer := (select version from public.events where id = v_event);
begin
  begin
    perform public.event_occurrence_by_key(v_event, 'o00000000002147483648');
    raise exception '오버플로 지점 조회가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_event, v_before, 'o00000000002147483648', 'this', 'overflow', '',
      '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
      null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
    raise exception '오버플로 갱신이 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      v_event, v_before, 'o00000000002147483648', 'this');
    raise exception '오버플로 삭제가 예기치 않게 성공했습니다';
  exception when sqlstate '22023' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before then
    raise exception '오버플로 변경이 상위 버전을 변경했습니다';
  end if;
end;
$$;
reset role;

-- 정규화된 최대 지원 순번도 유효한 키다. 실제 날짜 양쪽 경계에 가까운 기준점을
-- 포함해 모든 빈도에서 해당 순번의 날짜/월/타임스탬프 연산은 없는 행으로 취급해야 한다.
create temporary table recurrence_extreme (kind text not null, event_id uuid not null) on commit drop;
grant all on recurrence_extreme to authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into recurrence_extreme(kind, event_id)
select 'daily_max', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'daily max anchor', '',
  '9999-12-31T09:00:00Z', '9999-12-31T10:00:00Z', 'UTC', false, null, null,
  71::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null);
insert into recurrence_extreme(kind, event_id)
select 'daily_min', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'daily min anchor', '',
  '0001-01-01T09:00:00Z', '0001-01-01T10:00:00Z', 'UTC', false, null, null,
  72::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null);
insert into recurrence_extreme(kind, event_id)
select 'weekly_max', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'weekly max anchor', '',
  '9999-12-31T09:00:00Z', '9999-12-31T10:00:00Z', 'UTC', false, null, null,
  73::bigint, null, 'weekly', 1, array[1,2,3,4,5,6,7]::smallint[], 'never', null, null, null);
insert into recurrence_extreme(kind, event_id)
select 'weekly_min', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'weekly min anchor', '',
  '0001-01-01T09:00:00Z', '0001-01-01T10:00:00Z', 'UTC', false, null, null,
  74::bigint, null, 'weekly', 1, array[1,2,3,4,5,6,7]::smallint[], 'never', null, null, null);
insert into recurrence_extreme(kind, event_id)
select 'monthly_max', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'monthly max anchor', '',
  '9999-12-31T09:00:00Z', '9999-12-31T10:00:00Z', 'UTC', false, null, null,
  75::bigint, null, 'monthly', 1, '{}'::smallint[], 'never', null, null, 31::smallint);
insert into recurrence_extreme(kind, event_id)
select 'monthly_min', id from public.create_recurring_event_with_members(
  (select group_id from recurrence_fallback), 'monthly min anchor', '',
  '0001-01-01T09:00:00Z', '0001-01-01T10:00:00Z', 'UTC', false, null, null,
  76::bigint, null, 'monthly', 1, '{}'::smallint[], 'never', null, null, 1::smallint);
reset role;
do $$
declare
  v_row record;
  v_before integer;
  v_count integer;
begin
  for v_row in select kind, event_id from recurrence_extreme order by kind loop
    select count(*)::integer into v_count
      from public.event_occurrence_by_key(v_row.event_id, 'o00000000002147483647');
    if v_count <> 0 then
      raise exception '% 극단 지점이 예기치 않게 구체화되었습니다', v_row.kind;
    end if;
    select version into v_before from public.events where id = v_row.event_id;
    begin
      perform public.update_event_occurrence_scope_if_version(
        v_row.event_id, v_before, 'o00000000002147483647', 'this', 'overflow', '',
        '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
        null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
      raise exception '% 극단 갱신이 예기치 않게 성공했습니다', v_row.kind;
    exception when sqlstate '22023' then
      null;
    end;
    if (select version from public.events where id = v_row.event_id) <> v_before then
      raise exception '% 극단 갱신이 상위 버전을 변경했습니다', v_row.kind;
    end if;
    begin
      perform public.delete_event_occurrence_scope_if_version(
        v_row.event_id, v_before, 'o00000000002147483647', 'this');
      raise exception '% 극단 삭제가 예기치 않게 성공했습니다', v_row.kind;
    exception when sqlstate '22023' then
      null;
    end;
    if (select version from public.events where id = v_row.event_id) <> v_before then
      raise exception '% 극단 삭제가 상위 버전을 변경했습니다', v_row.kind;
    end if;
  end loop;
end;
$$;
reset role;

-- 없는 대상 계정은 그룹/일정/하위 잠금 전에 거부하므로 전체 범위 교체가 멤버/버전을
-- 부분적으로 바꿀 수 없다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
set request.jwt.claim.role = 'authenticated';
reset role;
do $$
declare
  v_event uuid := (select event_id from recurrence_fallback);
  v_before integer := (select version from public.events where id = v_event);
  v_members_before integer := (select count(*) from public.event_members where event_id = v_event);
begin
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_event, v_before, 'o00000000000000000000', 'all', 'should fail', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
      1::bigint,
      array['00000000-0000-4000-8000-00000000e201'::uuid,
            '00000000-0000-4000-8000-00000000e205'::uuid],
      'daily', 1, '{}'::smallint[], 'never', null, null, null);
    raise exception '없는 계정의 전체 범위 갱신이 예기치 않게 성공했습니다';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before
     or (select count(*) from public.event_members where event_id = v_event) <> v_members_before then
    raise exception '없는 계정 거부가 일정을 부분적으로 변경했습니다';
  end if;
end;
$$;
reset role;

-- 익명 및 비활성 요청자는 인증된 범위 RPC를 사용할 수 없다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated","is_anonymous":true}';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
begin
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'anonymous create', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
      99::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null);
    raise exception '익명 생성 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'this',
      'anonymous update', '', '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
      null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
    raise exception '익명 갱신 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'this');
    raise exception '익명 삭제 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.event_occurrence_by_key(
      (select event_id from recurrence_fallback), 'o00000000000000000000');
    raise exception '익명 지점 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.events_for_range_v2(
      (select group_id from recurrence_fallback),
      '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null
    );
    raise exception '익명 범위 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then
    null;
  end;
  begin
    perform public.replace_recurring_event_members_if_version(
      (select event_id from recurrence_member_rpc_event), 2, 'single',
      array['00000000-0000-4000-8000-00000000e201'::uuid,
            '00000000-0000-4000-8000-00000000e204'::uuid]);
    raise exception '익명 반복 멤버 교체가 예기치 않게 성공했습니다';
  exception when sqlstate '28000' then
    null;
  end;
end;
$$;
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000e201","role":"authenticated"}';
reset role;
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e204';
update public.memberships set is_active = false, removed_at = now()
where group_id = (select group_id from recurrence_fallback)
  and user_id = '00000000-0000-4000-8000-00000000e204'::uuid;
set role authenticated;
do $$
begin
  begin
    perform public.events_for_range_v2(
      (select group_id from recurrence_fallback),
      '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null
    );
    raise exception '비활성화된 범위 호출이 예기치 않게 성공했습니다';
  exception when sqlstate '42501' then
    null;
  end;
end;
$$;
reset role;

-- 이전 단일 일정은 논리 기준 행이나 참여자 할당을 교체하지 않고 반복 일정이 되었다가
-- 나중에 단일 일정으로 돌아갈 수 있다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000e201';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_receipt jsonb;
  v_event_id uuid := '00000000-0000-4000-8000-00000000e203'::uuid;
  v_point record;
begin
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event_id, 1, 'single', 'all', 'Legacy recurring', 'keep event',
    '2026-01-02T09:00:00Z', '2026-01-02T10:00:00Z', 'UTC', false, null, null,
    305419896::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid],
    'daily', 1, '{}'::smallint[], 'count', 2, null, null
  );
  if v_receipt->>'committed' is distinct from 'true'
     or v_receipt->>'changed' is distinct from 'true'
     or (v_receipt->>'series_version')::integer <> 2 then
    raise exception '단일 일정에서 반복 일정으로 변환한 응답/버전 검증에 실패했습니다';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'o00000000000000000000');
  if v_point.event_id is distinct from v_event_id
     or v_point.occurrence_key <> 'o00000000000000000000'
     or v_point.version <> 2 then
    raise exception '단일 일정에서 반복 일정으로 변환할 때 기준점을 유지하지 않았습니다';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'single');
  if v_point.event_id is distinct from v_event_id
     or v_point.occurrence_key <> 'o00000000000000000000'
     or v_point.occurrence_index <> 0 then
    raise exception '반복되는 이전 단일 일정 키가 순번 0으로 정규화되지 않았습니다';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event_id, 2, 'o00000000000000000001', 'all', 'Legacy single again', 'keep event',
    '2026-01-02T09:00:00Z', '2026-01-02T10:00:00Z', 'UTC', false, null, null,
    305419896::bigint,
    array['00000000-0000-4000-8000-00000000e201'::uuid],
    null, null, null, null, null, null, null
  );
  if v_receipt->>'committed' is distinct from 'true'
     or v_receipt->>'changed' is distinct from 'true'
     or (v_receipt->>'series_version')::integer <> 3 then
    raise exception '반복 일정에서 단일 일정으로 변환한 응답/버전 검증에 실패했습니다';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'single');
  if v_point.event_id is distinct from v_event_id or v_point.version <> 3 then
    raise exception '반복 일정에서 단일 일정으로 변환할 때 하위 행을 지우지 않았습니다';
  end if;
  if v_point.occurrence_key <> 'single' then
    raise exception '변환된 단일 일정 지점 키 검증에 실패했습니다';
  end if;
end;
$$;
reset role;

-- 계정 삭제는 그룹/일정 및 두 반복 일정 하위 테이블을 연쇄 삭제한다.
delete from auth.users where id = '00000000-0000-4000-8000-00000000e201'::uuid;
do $$
begin
  if exists (select 1 from public.event_recurrence_rules
             where event_id in (select event_id from recurrence_fallback)) then
    raise exception '계정 삭제 뒤 반복 규칙이 남았습니다';
  end if;
  if exists (select 1 from public.event_occurrence_overrides
             where event_id in (select event_id from recurrence_fallback)) then
    raise exception '계정 삭제 뒤 발생 재정의가 남았습니다';
  end if;
end;
$$;
commit;
SQL
fi

# 두 하위 인덱스를 EXPLAIN하여 일정 범위 확장과 연쇄 조회에 사용할 수 있는 실행
# 계획이 있음을 CI 로그에 증거로 남긴다.
psql_test <<'SQL'
explain (costs off)
select event_id, start_occurrence_index
from public.event_recurrence_rules
where event_id = '00000000-0000-4000-8000-00000000e203'::uuid
order by start_occurrence_index;
explain (costs off)
select event_id, occurrence_index
from public.event_occurrence_overrides
where event_id = '00000000-0000-4000-8000-00000000e203'::uuid
order by occurrence_index;
set enable_seqscan = off;
explain (costs off)
select event_id, occurrence_index
from public.event_occurrence_overrides
where event_id = '00000000-0000-4000-8000-00000000e203'::uuid
  and not is_cancelled and starts_at is not null and ends_at is not null
  and starts_at < '2027-01-01T00:00:00Z'::timestamptz
  and ends_at > '2026-01-01T00:00:00Z'::timestamptz;
explain (costs off)
select event_id, occurrence_index
from public.event_occurrence_overrides
where event_id = '00000000-0000-4000-8000-00000000e203'::uuid
  and not is_cancelled and is_all_day and all_day_start is not null and all_day_end is not null
  and all_day_start < '2027-01-01'::date and all_day_end > '2026-01-01'::date;
reset enable_seqscan;
SQL

printf '반복 일정 신규 설치/업그레이드/재적용 검사를 통과했습니다\n'
