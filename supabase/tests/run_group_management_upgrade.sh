#!/usr/bin/env bash

# event_members 마이그레이션을 자격 증명 없이 반복 검증한다.
#
# 이 스크립트는 격리된 로컬 PostgreSQL 클러스터를 만들고 이 마이그레이션에 필요한
# 최소 인증 표면만 초기화한다. 그룹 관리 이전의 모든 마이그레이션을 적용하고 대표
# 행을 시드한 뒤 event_members와 새 마이그레이션을 적용하고 재적용한다.
# 원래 업그레이드 검증과의 호환성을 위해 여전히 “마이그레이션 1..9 적용” 뒤에
# 마이그레이션 10(그룹 관리) 및 재적용이 이어지는 것으로 설명한다. event_members는
# 마이그레이션 11이며 역시 재실행하여 보호/인덱스/데이터 채우기 경로의 멱등성을
# 확인한다. Supabase나 원격 데이터베이스에는 절대 접속하지 않는다. 실패한 실행을
# 조사할 수 있도록 임시 클러스터 디렉터리를 출력하고 종료 시 서버를 중지한다.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-group-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/socket"
port="${SPLANNER_TEST_PORT:-$((55000 + RANDOM % 1000))}"

mkdir -p "$socket_dir"
initdb -D "$data_dir" -A trust --no-locale >/dev/null
pg_ctl -D "$data_dir" -o "-p $port -k $socket_dir" -w start >/dev/null

cleanup() {
  pg_ctl -D "$data_dir" -m fast -w stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
SQL

target_migration="$repo_dir/supabase/migrations/20260906154329_persist_group_description_event_color.sql"
group_migration="$repo_dir/supabase/migrations/20260907130001_group_management.sql"
event_members_migration="$repo_dir/supabase/migrations/20260907130002_event_members.sql"

for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$target_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

# 새 열 마이그레이션 전에 구형 스키마의 행을 시드한다. groups.description와
# events.color_value가 아직 없으므로, 마이그레이션은 두 행의 표시 값을 백필하면서
# 각 낙관적 잠금 버전을 정확히 한 단계 올려야 한다.
psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values (
  '00000000-0000-4000-8000-00000000aa11',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'persist-upgrade-owner@example.test', '',
  now(), now(), now(), '{}'::jsonb
);

insert into public.groups (
  id, owner_id, name, timezone, version, deleted_at, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000bb11',
  '00000000-0000-4000-8000-00000000aa11',
  'Persist upgrade group', 'UTC', 7, null,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, version, deleted_at, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000dd11',
  '00000000-0000-4000-8000-00000000bb11',
  '00000000-0000-4000-8000-00000000aa11',
  'Persist upgrade event', 'legacy event description',
  '2026-01-05T00:00:00Z', '2026-01-05T01:00:00Z',
  'UTC', false, 1, null,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);
SQL

printf '%s 적용 중\n' "$(basename "$target_migration")"
psql_test -f "$target_migration" >/dev/null
printf '%s 재적용 중\n' "$(basename "$target_migration")"
psql_test -f "$target_migration" >/dev/null

# 대상 마이그레이션 뒤의 이력은 그룹 관리 전에 계속 적용한다. 대상 파일은 위에서
# 두 번 실행했으므로 여기서는 중복하지 않는다.
target_applied=false
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  if [[ "$migration" == "$target_migration" ]]; then
    target_applied=true
    continue
  fi
  [[ "$migration" == "$group_migration" ]] && break
  if [[ "$target_applied" == true ]]; then
    printf '%s 적용 중\n' "$(basename "$migration")"
    psql_test -f "$migration" >/dev/null
  fi
done

# 마이그레이션 9 뒤 사용자 둘과 그룹 하나를 시드한다. 소유자 멤버십을 의도적으로
# 제거하여 마이그레이션 10이 groups.owner_id에서 다시 채우게 한다. 일반 멤버와
# 모든 하위 행은 변경 없이 남아야 한다.
psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    '00000000-0000-4000-8000-00000000a001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'upgrade-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Upgrade owner"}'::jsonb
  ),
  (
    '00000000-0000-4000-8000-00000000a002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'upgrade-member@example.test', '',
    now(), now(), now(), '{"display_name":"Upgrade member"}'::jsonb
  ),
  (
    '00000000-0000-4000-8000-00000000a003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'upgrade-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Upgrade inactive"}'::jsonb
  );

insert into public.groups (
  id, owner_id, name, description, timezone, version, deleted_at,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a001',
  'Upgrade group', 'Existing description', 'Asia/Seoul', 7, null,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at, invited_by,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a002',
  'member', true, '2026-01-03T00:00:00Z', null,
  '00000000-0000-4000-8000-00000000a001',
  '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z'
);

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at,
  invited_by, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a003',
  'member', false, '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z',
  '00000000-0000-4000-8000-00000000a001',
  '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z'
);

insert into public.invite_codes (
  id, group_id, created_by, token_hash, expires_at, max_uses,
  uses_count, version, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000c001',
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a001',
  repeat('b', 64), '2026-01-10T00:00:00Z', 3, 1, 2,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000d001',
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a002',
  'Existing event', 'Existing event description',
  '2026-01-05T00:00:00Z', '2026-01-05T01:00:00Z',
  'UTC', false, null, null, 1, 305419896,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

-- 비활성 사용자가 만든 삭제된 일정으로 작성자 데이터 채우기가 필터링된 현재
-- 멤버십 투영이 아니라 과거 데이터임을 확인한다.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  deleted_at, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000d002',
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a003',
  'Deleted legacy event', 'Preserve this row',
  '2026-01-05T02:00:00Z', '2026-01-05T03:00:00Z',
  'UTC', false, null, null, 1, 305419897,
  '2026-01-06T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.audit_logs (
  id, group_id, actor_id, action, entity_type, entity_id, metadata,
  created_at
) values (
  '00000000-0000-4000-8000-00000000e001',
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a001',
  'update', 'groups', '00000000-0000-4000-8000-00000000b001',
  '{"version":7}'::jsonb, '2026-01-06T00:00:00Z'
);

-- 의도적인 이전 데이터 불일치다. 마이그레이션이 owner_id에서 이 행을 복원해야 한다.
delete from public.memberships
where group_id = '00000000-0000-4000-8000-00000000b001'
  and user_id = '00000000-0000-4000-8000-00000000a001';

do $$
begin
  if exists (
    select 1 from public.memberships
    where group_id = '00000000-0000-4000-8000-00000000b001'
      and user_id = '00000000-0000-4000-8000-00000000a001'
  ) then
    raise exception '시드 소유자 멤버십이 제거되지 않았습니다';
  end if;
end;
$$;
SQL

printf '%s 적용 중\n' 20260907130001_group_management.sql
psql_test -f "$group_migration" >/dev/null
printf '%s 재적용 중\n' 20260907130001_group_management.sql
psql_test -f "$group_migration" >/dev/null

printf '%s 적용 중\n' 20260907130002_event_members.sql
psql_test -f "$event_members_migration" >/dev/null

# 활성 작성자의 이전/Data API 일정 INSERT는 새 AFTER INSERT 초기화 트리거가
# 완성해야 한다. 할당을 정확히 하나 만들고 일정은 초기 버전으로 남겨야 하며, 아래
# 마이그레이션 재적용에서 중복을 추가해서는 안 된다.
psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
insert into public.events (
  group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, version, color_value
) values (
  '00000000-0000-4000-8000-00000000b001',
  '00000000-0000-4000-8000-00000000a002',
  'Legacy direct event upgrade', '', '2026-01-05T04:00:00Z', '2026-01-05T05:00:00Z',
  'UTC', false, 1, 305419896
);
do $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
  from public.events
  where title = 'Legacy direct event upgrade'
    and group_id = '00000000-0000-4000-8000-00000000b001';
  if v_event_id is null then
    raise exception '이전 직접 일정 행이 삽입되지 않았습니다';
  end if;
  if (select version from public.events where id = v_event_id) <> 1 then
    raise exception '작성자 초기화 중 이전 직접 일정 버전이 변경되었습니다';
  end if;
  if (select count(*) from public.event_members
      where event_id = v_event_id
        and user_id = '00000000-0000-4000-8000-00000000a002') <> 1 then
    raise exception '이전 직접 일정 작성자 할당이 정확히 한 번 초기화되지 않았습니다';
  end if;
end;
$$;
reset role;
SQL

# 설정 역할을 통해 작성자가 아닌 할당 하나를 추가한다. 표시는 이 픽스처 전용 DML의
# 전환 버전 증가를 억제한다. 실제 할당과 마찬가지로 반복 마이그레이션/데이터
# 채우기에서도 타임스탬프가 유지되어야 한다.
psql_test <<'SQL'
begin;
select pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
insert into public.event_members (event_id, user_id, created_at)
values (
  '00000000-0000-4000-8000-00000000d001',
  '00000000-0000-4000-8000-00000000a001',
  '2026-01-07T00:00:00Z'
)
on conflict (event_id, user_id) do nothing;
select pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
commit;
SQL

printf '%s 재적용 중\n' 20260907130002_event_members.sql
psql_test -f "$event_members_migration" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_persist_group public.groups;
  v_persist_event public.events;
  v_group public.groups;
  v_member public.memberships;
  v_owner public.memberships;
  v_invite public.invite_codes;
  v_event public.events;
  v_audit public.audit_logs;
begin
  select * into v_persist_group
  from public.groups
  where id = '00000000-0000-4000-8000-00000000bb11';
  if not found
     or v_persist_group.description <> ''
     or v_persist_group.version <> 8 then
    raise exception '그룹 표시 열 백필이 기존 버전을 정확히 한 단계 올리지 않았습니다';
  end if;

  select * into v_persist_event
  from public.events
  where id = '00000000-0000-4000-8000-00000000dd11';
  if not found
     or v_persist_event.color_value <> 4282874742
     or v_persist_event.version <> 2 then
    raise exception '일정 색상 백필이 기존 버전을 정확히 한 단계 올리지 않았습니다';
  end if;

  select * into v_group
  from public.groups
  where id = '00000000-0000-4000-8000-00000000b001';
  if not found
     or v_group.owner_id <> '00000000-0000-4000-8000-00000000a001'
     or v_group.name <> 'Upgrade group'
     or v_group.description <> 'Existing description'
     or v_group.timezone <> 'Asia/Seoul'
     or v_group.version <> 7
     or v_group.deleted_at is not null then
    raise exception '기존 그룹 필드를 보존하지 않았습니다';
  end if;

  select * into v_member
  from public.memberships
  where group_id = '00000000-0000-4000-8000-00000000b001'
    and user_id = '00000000-0000-4000-8000-00000000a002';
  if not found
     or v_member.role <> 'member'
     or not v_member.is_active
     or v_member.joined_at <> '2026-01-03T00:00:00Z'
     or v_member.invited_by <> '00000000-0000-4000-8000-00000000a001' then
    raise exception '기존 멤버십 필드를 보존하지 않았습니다';
  end if;

  select * into v_owner
  from public.memberships
  where group_id = '00000000-0000-4000-8000-00000000b001'
    and user_id = '00000000-0000-4000-8000-00000000a001';
  if not found or v_owner.role <> 'owner' or not v_owner.is_active
     or v_owner.removed_at is not null then
    raise exception 'groups.owner_id 소유자 멤버십을 기존 데이터에 채우지 않았습니다';
  end if;
  if (select count(*) from public.memberships
      where group_id = '00000000-0000-4000-8000-00000000b001'
        and role = 'owner' and is_active and removed_at is null) <> 1 then
    raise exception '데이터 채우기 뒤 활성 소유자가 정확히 한 명이 아닙니다';
  end if;

  select * into v_invite from public.invite_codes
  where id = '00000000-0000-4000-8000-00000000c001';
  if not found or v_invite.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_invite.created_by <> '00000000-0000-4000-8000-00000000a001'
     or v_invite.token_hash <> repeat('b', 64)
     or v_invite.max_uses <> 3 or v_invite.uses_count <> 1
     or v_invite.version <> 2 then
    raise exception '기존 초대 필드를 보존하지 않았습니다';
  end if;

  select * into v_event from public.events
  where id = '00000000-0000-4000-8000-00000000d001';
  if not found or v_event.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_event.created_by <> '00000000-0000-4000-8000-00000000a002'
     or v_event.title <> 'Existing event'
     or v_event.description <> 'Existing event description'
     or v_event.version <> 1 or v_event.color_value <> 305419896 then
    raise exception '기존 일정 필드를 보존하지 않았습니다';
  end if;

  select * into v_audit from public.audit_logs
  where id = '00000000-0000-4000-8000-00000000e001';
  if not found or v_audit.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_audit.actor_id <> '00000000-0000-4000-8000-00000000a001'
     or v_audit.entity_id <> '00000000-0000-4000-8000-00000000b001'
     or v_audit.metadata <> '{"version":7}'::jsonb then
    raise exception '기존 감사 필드를 보존하지 않았습니다';
  end if;

  -- 카탈로그 검사는 하위 기본 키와 두 외래 키 연쇄 작업을 포함한다. 아래에서 행
  -- 수준 보안(RLS)과 authenticated ACL을 검사한다.
  if not exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_index i on i.indexrelid = c.oid
    where c.oid = 'public.memberships_one_active_owner_idx'::regclass
      and i.indrelid = 'public.memberships'::regclass
      and i.indisunique and i.indisvalid and i.indnkeyatts = 1
      and i.indnatts = 1
      and i.indkey[0] = (
        select a.attnum
        from pg_catalog.pg_attribute a
        where a.attrelid = 'public.memberships'::regclass
          and a.attname = 'group_id'
      )
      and i.indexprs is null
      and pg_catalog.pg_get_expr(i.indpred, i.indrelid)
          like '%role%owner%is_active%'
  ) then
    raise exception '활성 소유자 고유 부분 인덱스가 없습니다';
  end if;

  -- 계정 연쇄 작업과 하드 삭제 검사는 event_members 외래 키로 나타낸다. pgTAP
  -- 픽스처가 각 연쇄 경로 실행을 다룬다.
  if not exists (
    select 1
    from public.event_members em
    where em.event_id = '00000000-0000-4000-8000-00000000d001'
      and em.user_id = '00000000-0000-4000-8000-00000000a002'
      and em.created_at = '2026-01-01T00:00:00Z'
  ) then
    raise exception '일정 작성자 데이터 채우기/타임스탬프를 보존하지 않았습니다';
  end if;
  if not exists (
    select 1
    from public.event_members em
    where em.event_id = '00000000-0000-4000-8000-00000000d002'
      and em.user_id = '00000000-0000-4000-8000-00000000a003'
      and em.created_at = '2026-01-01T00:00:00Z'
  ) then
    raise exception '비활성/삭제 작성자 데이터 채우기가 필터링되었습니다';
  end if;
  if not exists (
    select 1
    from public.event_members em
    where em.event_id = '00000000-0000-4000-8000-00000000d001'
      and em.user_id = '00000000-0000-4000-8000-00000000a001'
      and em.created_at = '2026-01-07T00:00:00Z'
  ) then
    raise exception '재적용 시 기존 일정 멤버 타임스탬프를 보존하지 않았습니다';
  end if;
  if not exists (
    select 1
    from public.event_members em
    join public.events e on e.id = em.event_id
    where e.title = 'Legacy direct event upgrade'
      and e.group_id = '00000000-0000-4000-8000-00000000b001'
      and em.user_id = '00000000-0000-4000-8000-00000000a002'
  ) then
    raise exception '재적용 시 이전 직접 일정 작성자 할당을 잃었습니다';
  end if;
  if (select count(*) from public.event_members) <> 5 then
    raise exception '일정 멤버 데이터 채우기/재적용이 멱등적이지 않습니다';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.event_members'::regclass and relrowsecurity
  ) then
    raise exception 'event_members RLS가 활성화되지 않았습니다';
  end if;
  if not has_table_privilege('authenticated', 'public.event_members', 'select')
     or has_table_privilege('authenticated', 'public.event_members', 'insert')
     or has_table_privilege('authenticated', 'public.event_members', 'update')
     or has_table_privilege('authenticated', 'public.event_members', 'delete') then
    raise exception 'authenticated에 대한 event_members ACL이 읽기 전용이 아닙니다';
  end if;
  if exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'event_members'
  ) then
    raise exception 'event_members를 직접 게시해서는 안 됩니다';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.event_members'::regclass
      and c.contype = 'p'
  ) then
    raise exception 'event_members 기본 키가 없습니다';
  end if;
end;
$$;

select 'group-management/event_members 업그레이드 보존/재적용 검사를 통과했습니다' as result;
SQL

# 설치 표식 회귀 검사다. 수명 주기 정리가 작성자 할당을 제거한 뒤 일반 마이그레이션
# 재적용은 해당 행을 복원하거나 비활성 멤버 트리거를 실패시키지 말고 과거 데이터
# 채우기를 건너뛰어야 한다. 이후 재활성화도 의도적으로 검사한다. 현재 할당 의미는
# 정리된 참여자를 복원하지 않는다.
psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  '00000000-0000-4000-8000-00000000a002'::uuid,
  false
);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d001') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d001'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '작성자 비활성화가 d001을 정확히 한 번 정리하지 않았습니다';
  end if;
end;
$$;
SQL

printf '작성자 비활성화 뒤 %s 재적용 중\n' 20260907130002_event_members.sql
psql_test -f "$event_members_migration" >/dev/null

psql_test <<'SQL'
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d001') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d001'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception 'event_members 재적용이 정리된 작성자를 복원했거나 d001 버전을 변경했습니다';
  end if;
end;
$$;
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  '00000000-0000-4000-8000-00000000a002'::uuid,
  true
);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d001') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d001'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '재활성화가 예기치 않게 정리된 작성자 할당을 복원했습니다';
  end if;
end;
$$;
SQL

printf '작성자 정리/재적용 표식 회귀 검사를 통과했습니다\n'

# 종료 이력 수명 주기 회귀 검사다. 운영 일정과 소프트 삭제된 일정 모두 같은 일반
# 멤버 할당을 갖는다. 멤버십 비활성화/탈퇴는 운영 행만 정리하고 해당 일정 버전을
# 한 번 올린다. 종료 행은 그대로이며 버전도 안정적으로 유지한다. 마이그레이션을
# 재적용해도 의도적으로 정리한 운영 행을 복원하거나 남은 소프트 삭제 행에서
# 실패해서는 안 된다.
psql_test <<'SQL'
reset role;
insert into public.groups (
  id, owner_id, name, description, timezone, version,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b004',
  '00000000-0000-4000-8000-00000000a001',
  'Terminal history group', '', 'UTC', 1,
  '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
);
insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values
  (
    '00000000-0000-4000-8000-00000000b004',
    '00000000-0000-4000-8000-00000000a002',
    'member', true, '2026-01-09T00:00:00Z', null
  );
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values
  (
    '00000000-0000-4000-8000-00000000d004',
    '00000000-0000-4000-8000-00000000b004',
    '00000000-0000-4000-8000-00000000a002',
    'Terminal live event', '',
    '2026-01-09T01:00:00Z', '2026-01-09T02:00:00Z',
    'UTC', false, null, null, 1, 305419896,
    '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
  ),
  (
    '00000000-0000-4000-8000-00000000d005',
    '00000000-0000-4000-8000-00000000b004',
    '00000000-0000-4000-8000-00000000a002',
    'Terminal soft-deleted event', '',
    '2026-01-09T03:00:00Z', '2026-01-09T04:00:00Z',
    'UTC', false, null, null, 1, 305419896,
    '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
  );
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.soft_delete_event_if_version(
  '00000000-0000-4000-8000-00000000d005'::uuid, 1
);
reset role;
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  '00000000-0000-4000-8000-00000000b004'::uuid,
  '00000000-0000-4000-8000-00000000a002'::uuid,
  false
);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d004') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d004'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '비활성화가 종료 회귀 검사의 운영 행을 정확히 한 번 정리하지 않았습니다';
  end if;
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d005') <> 2
     or (select count(*) from public.event_members
         where event_id = '00000000-0000-4000-8000-00000000d005'
           and user_id = '00000000-0000-4000-8000-00000000a002') <> 1 then
    raise exception '비활성화가 소프트 삭제된 이력 행/버전을 변경했습니다';
  end if;
end;
$$;
SQL

printf '종료 비활성화 보존 검사를 통과했습니다\n'

printf '종료 비활성화 뒤 %s 재적용 중\n' 20260907130002_event_members.sql
psql_test -f "$event_members_migration" >/dev/null

psql_test <<'SQL'
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d004') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d004'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '종료 상태 재적용이 정리된 운영 할당/버전을 복원했습니다';
  end if;
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d005') <> 2
     or (select count(*) from public.event_members
         where event_id = '00000000-0000-4000-8000-00000000d005'
           and user_id = '00000000-0000-4000-8000-00000000a002') <> 1 then
    raise exception '종료 상태 재적용이 소프트 삭제된 이력 행/버전을 변경했습니다';
  end if;
end;
$$;
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.set_member_active(
  '00000000-0000-4000-8000-00000000b004'::uuid,
  '00000000-0000-4000-8000-00000000a002'::uuid,
  true
);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d004') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d004'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '비활성화 뒤 재활성화가 정리된 할당을 복원했습니다';
  end if;
end;
$$;
SQL

# 탈퇴 회귀 검사는 같은 그룹에서 두 번째 운영/소프트 삭제 쌍을 사용한다. 이후 그룹을
# 보관하고 탈퇴 정리와 보관 전환 뒤에도 종료 이력이 남는지 확인한다.
psql_test <<'SQL'
reset role;
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values
  (
    '00000000-0000-4000-8000-00000000d006',
    '00000000-0000-4000-8000-00000000b004',
    '00000000-0000-4000-8000-00000000a002',
    'Leave live event', '',
    '2026-01-09T05:00:00Z', '2026-01-09T06:00:00Z',
    'UTC', false, null, null, 1, 305419896,
    '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
  ),
  (
    '00000000-0000-4000-8000-00000000d007',
    '00000000-0000-4000-8000-00000000b004',
    '00000000-0000-4000-8000-00000000a002',
    'Leave soft-deleted event', '',
    '2026-01-09T07:00:00Z', '2026-01-09T08:00:00Z',
    'UTC', false, null, null, 1, 305419896,
    '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
  );
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.soft_delete_event_if_version(
  '00000000-0000-4000-8000-00000000d007'::uuid, 1
);
select public.leave_group('00000000-0000-4000-8000-00000000b004'::uuid);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d006') <> 2
     or exists (
       select 1 from public.event_members
       where event_id = '00000000-0000-4000-8000-00000000d006'
         and user_id = '00000000-0000-4000-8000-00000000a002'
     ) then
    raise exception '탈퇴가 종료 회귀 검사의 운영 행을 정확히 한 번 정리하지 않았습니다';
  end if;
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d007') <> 2
     or (select count(*) from public.event_members
         where event_id = '00000000-0000-4000-8000-00000000d007'
           and user_id = '00000000-0000-4000-8000-00000000a002') <> 1 then
    raise exception '탈퇴가 소프트 삭제된 이력 행/버전을 변경했습니다';
  end if;
end;
$$;
SQL

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.archive_group_if_version(
  '00000000-0000-4000-8000-00000000b004'::uuid, 1
);
reset role;
do $$
begin
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000d007') <> 2
     or (select count(*) from public.event_members
         where event_id = '00000000-0000-4000-8000-00000000d007'
           and user_id = '00000000-0000-4000-8000-00000000a002') <> 1 then
    raise exception '보관이 유지된 탈퇴 이력 행/버전을 변경했습니다';
  end if;
end;
$$;
SQL

printf '종료 탈퇴/보관 보존 검사를 통과했습니다\n'

# 두 세션 경합 검증이다. 세션 1은 소유권을 이전하면서 상위 그룹 행 잠금을 유지한다.
# 세션 2는 짧은 잠금 제한 시간으로 이전 소유자 자격에서 보관을 시도하여 그룹 잠금에
# 의해 차단되는지 확인한다. 세션 1이 커밋한 뒤 같은 오래된 호출자는 보관된/새 소유자
# 그룹을 쓰지 않고 일반 40001 충돌로 거부된다. 모든 작업은 이 임시 클러스터 안에
# 머물며 자격 증명이나 원격 Supabase 상태를 사용하지 않는다.
lock_marker="$work_dir/group-lock-held"
transfer_log="$work_dir/transfer-race.log"
archive_lock_log="$work_dir/archive-lock-timeout.log"
archive_stale_log="$work_dir/archive-stale-owner.log"

(
  psql_test -v VERBOSITY=verbose >"$transfer_log" 2>&1 <<SQL
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
begin;
-- 설정 역할이 잠금을 얻은 뒤 같은 트랜잭션에서 RPC를 authenticated로 실행한다.
-- 소유권이 원자적으로 바뀌는 동안 잠금을 유지한다.
select id from public.groups
where id = '00000000-0000-4000-8000-00000000b001'
for update;
\! touch "$lock_marker"
select pg_catalog.pg_sleep(2);
set local role authenticated;
select public.transfer_group_ownership(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  '00000000-0000-4000-8000-00000000a002'::uuid,
  7
);
commit;
SQL
) &
transfer_pid=$!

for _ in {1..100}; do
  [[ -f "$lock_marker" ]] && break
  sleep 0.05
done
if [[ ! -f "$lock_marker" ]]; then
  echo '이전 경합 잠금 표시가 생성되지 않았습니다' >&2
  kill "$transfer_pid" 2>/dev/null || true
  wait "$transfer_pid" 2>/dev/null || true
  exit 1
fi

if psql_test -v VERBOSITY=verbose >"$archive_lock_log" 2>&1 <<'SQL'; then
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
set lock_timeout = '100ms';
select public.archive_group_if_version(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  7
);
SQL
  echo '보관이 예기치 않게 유지 중인 그룹 잠금을 우회했습니다' >&2
  wait "$transfer_pid"
  exit 1
fi
grep -Eq 'SQL state: 55P03|lock timeout|canceling statement due to lock timeout' "$archive_lock_log"

wait "$transfer_pid"

if psql_test -v VERBOSITY=verbose >"$archive_stale_log" 2>&1 <<'SQL'; then
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.archive_group_if_version(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  7
);
SQL
  echo '이전 소유자가 소유권 이전 뒤 예기치 않게 보관했습니다' >&2
  exit 1
fi
grep -Eq 'SQL state: 40001|ERROR: +40001:' "$archive_stale_log"

psql_test <<'SQL'
do $$
declare
  v_group public.groups;
begin
  select * into v_group
  from public.groups
  where id = '00000000-0000-4000-8000-00000000b001';
  if not found
     or v_group.owner_id <> '00000000-0000-4000-8000-00000000a002'
     or v_group.version <> 8
     or v_group.deleted_at is not null then
    raise exception '이전 경합에서 새 소유자를 원자적으로 커밋하지 않았습니다';
  end if;
end;
$$;
SQL

# 두 번째 활성 그룹은 멤버십 경합을 아래 일정 경합과 분리한다. 아래 경합은 첫 픽스처
# 그룹을 보관한다. 소유자 트리거가 b002의 소유자 멤버십을 만들고 여기에서 일반 멤버
# 행을 시드한다.
psql_test <<'SQL'
insert into public.groups (
  id, owner_id, name, description, timezone, version
) values (
  '00000000-0000-4000-8000-00000000b002',
  '00000000-0000-4000-8000-00000000a002',
  'Membership race group', '', 'UTC', 1
);
insert into public.memberships (
  group_id, user_id, role, is_active, removed_at
) values (
  '00000000-0000-4000-8000-00000000b002',
  '00000000-0000-4000-8000-00000000a001',
  'member', true, null
);

-- 참여자 교체 경합을 위해 세 번째 운영 그룹/일정을 남겨 두어 기존 보관 경합에서
-- 사용하는 과거 일정이 버전 1을 유지하게 한다.
insert into public.groups (
  id, owner_id, name, description, timezone, version
) values (
  '00000000-0000-4000-8000-00000000b003',
  '00000000-0000-4000-8000-00000000a002',
  'Participant race group', '', 'UTC', 1
);
insert into public.memberships (
  group_id, user_id, role, is_active, removed_at
) values (
  '00000000-0000-4000-8000-00000000b003',
  '00000000-0000-4000-8000-00000000a001',
  'member', true, null
);
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value
) values (
  '00000000-0000-4000-8000-00000000d003',
  '00000000-0000-4000-8000-00000000b003',
  '00000000-0000-4000-8000-00000000a002',
  'Participant race event', '',
  '2026-01-08T00:00:00Z', '2026-01-08T01:00:00Z',
  'UTC', false, null, null, 1, 305419898
);
SQL

# 멤버십 경합 검증이다. API 역할에는 의도적으로 직접 상태 UPDATE를 거부하며 관리는
# RPC 전용이다. 오래된 REPEATABLE READ 세션이 멤버십 스냅샷을 얻는 동안 소유자가
# 상위 그룹을 보관한다. 직접 쓰기 시도는 권한 거부로 실패하고 과거 행은 바뀌지 않는다.
membership_marker="$work_dir/membership-snapshot-ready"
membership_update_log="$work_dir/membership-stale-update.log"

(
  psql_test -v VERBOSITY=verbose >"$membership_update_log" 2>&1 <<SQL
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
begin;
set transaction isolation level repeatable read;
select is_active from public.memberships
where group_id = '00000000-0000-4000-8000-00000000b002'
  and user_id = '00000000-0000-4000-8000-00000000a001';
\\! touch "$membership_marker"
select pg_catalog.pg_sleep(2);
update public.memberships
set is_active = false, removed_at = pg_catalog.now()
where group_id = '00000000-0000-4000-8000-00000000b002'
  and user_id = '00000000-0000-4000-8000-00000000a001';
commit;
SQL
) &
membership_pid=$!

for _ in {1..100}; do
  [[ -f "$membership_marker" ]] && break
  sleep 0.05
done
if [[ ! -f "$membership_marker" ]]; then
  echo '멤버십 경합 스냅샷 표시가 생성되지 않았습니다' >&2
  kill "$membership_pid" 2>/dev/null || true
  wait "$membership_pid" 2>/dev/null || true
  exit 1
fi

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.archive_group_if_version(
  '00000000-0000-4000-8000-00000000b002'::uuid,
  1
);
SQL

if wait "$membership_pid"; then
  echo '보관 뒤 직접 멤버십 UPDATE가 예기치 않게 성공했습니다' >&2
  exit 1
fi
grep -Eq 'SQL state: 42501|ERROR: +42501:|permission denied for table memberships' "$membership_update_log"

psql_test <<'SQL'
do $$
declare
  v_group public.groups;
  v_member public.memberships;
begin
  select * into v_group from public.groups
  where id = '00000000-0000-4000-8000-00000000b002';
  select * into v_member from public.memberships
  where group_id = '00000000-0000-4000-8000-00000000b002'
    and user_id = '00000000-0000-4000-8000-00000000a001';
  if not found
     or v_group.deleted_at is null
     or v_member.is_active is distinct from true
     or v_member.removed_at is not null then
    raise exception '보관 뒤 멤버십 행이 변경되었습니다';
  end if;
end;
$$;
SQL

printf '반복 가능 읽기 멤버십/보관 RPC 전용 경합 검사를 통과했습니다\n'

# 참여자 교체 경합이다. 목록 교체와 그룹 수명 주기는 모두 그룹 우선 잠금을 사용한다.
# 세션 1이 d003을 교체하면서 b003을 유지한다. 세션 2는 오래된 교체를 끼워 넣지 못하고
# 잠금 제한 시간을 받으며, 세션 1이 커밋한 뒤 같은 예상 버전은 거부된다.
participant_marker="$work_dir/participant-group-lock-held"
participant_replace_log="$work_dir/participant-replace-race.log"
participant_lock_log="$work_dir/participant-lock-timeout.log"
participant_stale_log="$work_dir/participant-stale-replace.log"

(
  psql_test -v VERBOSITY=verbose >"$participant_replace_log" 2>&1 <<SQL
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
begin;
select id from public.groups
where id = '00000000-0000-4000-8000-00000000b003'
for update;
\! touch "$participant_marker"
select pg_catalog.pg_sleep(2);
set local role authenticated;
select public.replace_event_members_if_version(
  '00000000-0000-4000-8000-00000000d003'::uuid,
  1,
  array['00000000-0000-4000-8000-00000000a001'::uuid]
);
commit;
SQL
) &
participant_pid=$!

for _ in {1..100}; do
  [[ -f "$participant_marker" ]] && break
  sleep 0.05
done
if [[ ! -f "$participant_marker" ]]; then
  echo '참여자 경합 잠금 표시가 생성되지 않았습니다' >&2
  kill "$participant_pid" 2>/dev/null || true
  wait "$participant_pid" 2>/dev/null || true
  exit 1
fi

if psql_test -v VERBOSITY=verbose >"$participant_lock_log" 2>&1 <<'SQL'; then
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
set lock_timeout = '100ms';
select public.replace_event_members_if_version(
  '00000000-0000-4000-8000-00000000d003'::uuid,
  1,
  '{}'::uuid[]
);
SQL
  echo '참여자 교체가 예기치 않게 유지 중인 그룹 잠금을 우회했습니다' >&2
  wait "$participant_pid"
  exit 1
fi
grep -Eq 'SQL state: 55P03|lock timeout|canceling statement due to lock timeout' "$participant_lock_log"
wait "$participant_pid"

if psql_test -v VERBOSITY=verbose >"$participant_stale_log" 2>&1 <<'SQL'; then
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.replace_event_members_if_version(
  '00000000-0000-4000-8000-00000000d003'::uuid,
  1,
  '{}'::uuid[]
);
SQL
  echo '오래된 참여자 교체가 예기치 않게 성공했습니다' >&2
  exit 1
fi
grep -Eq 'SQL state: 40001|ERROR: +40001:' "$participant_stale_log"

psql_test <<'SQL'
do $$
declare
  v_event public.events;
begin
  select * into v_event
  from public.events
  where id = '00000000-0000-4000-8000-00000000d003';
  if not found or v_event.version <> 2
     or (select count(*) from public.event_members
         where event_id = v_event.id
           and user_id = '00000000-0000-4000-8000-00000000a001') <> 1 then
    raise exception '참여자 교체 경합이 최종 버전 하나를 커밋하지 않았습니다';
  end if;
end;
$$;
SQL

printf '두 세션 참여자/그룹 잠금 경합 검사를 통과했습니다\n'

# 직접 일정 RLS 경합 검증이다. 세션 2가 그룹 활성 상태에서 REPEATABLE READ
# 스냅샷을 얻고 기다린다. 세션 1이 그룹을 보관한다. 세션 2가 마침내 일정을 갱신하면
# 트리거의 상위 그룹 FOR UPDATE가 종료 전환을 확인하거나 동등한 직렬화 충돌을
# 보고하며 오래된 하위 쓰기를 롤백한다.
event_marker="$work_dir/event-snapshot-ready"
event_update_log="$work_dir/event-stale-update.log"

(
  psql_test -v VERBOSITY=verbose >"$event_update_log" 2>&1 <<SQL
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
begin;
set transaction isolation level repeatable read;
select id from public.events
where id = '00000000-0000-4000-8000-00000000d001';
\\! touch "$event_marker"
select pg_catalog.pg_sleep(2);
update public.events
set title = 'stale event write', version = version + 1
where id = '00000000-0000-4000-8000-00000000d001';
commit;
SQL
) &
event_pid=$!

for _ in {1..100}; do
  [[ -f "$event_marker" ]] && break
  sleep 0.05
done
if [[ ! -f "$event_marker" ]]; then
  echo '일정 경합 스냅샷 표시가 생성되지 않았습니다' >&2
  kill "$event_pid" 2>/dev/null || true
  wait "$event_pid" 2>/dev/null || true
  exit 1
fi

psql_test <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a002';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.archive_group_if_version(
  '00000000-0000-4000-8000-00000000b001'::uuid,
  8
);
SQL

if wait "$event_pid"; then
  echo '보관 뒤 오래된 일정 갱신이 예기치 않게 성공했습니다' >&2
  exit 1
fi
grep -Eq 'SQL state: 40001|ERROR: +40001:|could not serialize access due to concurrent update' "$event_update_log"

psql_test <<'SQL'
do $$
declare
  v_group public.groups;
  v_event public.events;
begin
  select * into v_group from public.groups
  where id = '00000000-0000-4000-8000-00000000b001';
  select * into v_event from public.events
  where id = '00000000-0000-4000-8000-00000000d001';
  if not found
     or v_group.deleted_at is null
     or v_event.title <> 'Existing event'
     or v_event.version <> 2 then
    raise exception '보관 뒤 일정 하위 행이 변경되었습니다';
  end if;
end;
$$;
SQL

printf '반복 가능 읽기 직접 일정/보관 경합 검사를 통과했습니다\n'

printf '두 세션 이전/보관 그룹 잠금 경합 검사를 통과했습니다\n'

printf '임시 PostgreSQL 클러스터: %s\n' "$work_dir"
