#!/usr/bin/env bash

# 범위 제한 캘린더 마이그레이션을 자격 증명 없이 반복 검증한다. 임시 로컬
# PostgreSQL 클러스터만 사용하며 Docker, Supabase 프로젝트 또는 원격
# 데이터베이스에는 접속하지 않는다.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-range-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/socket"
port="${SPLANNER_TEST_PORT:-$((59000 + RANDOM % 500))}"

cleanup() {
  # initdb와 pg_ctl보다 먼저 트랩을 설치한다. 클러스터 부트스트랩이 실패해도 임시
  # 디렉터리를 남겨서는 안 된다. 데이터 디렉터리가 있으면 먼저 중지한 다음 이
  # 스크립트 전용 mktemp 디렉터리만 제거하여 PostgreSQL이 사라지는 소켓/데이터
  # 경로와 경합하지 않게 한다.
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
SQL

event_members_migration="$repo_dir/supabase/migrations/20260907130002_event_members.sql"
range_migration="$repo_dir/supabase/migrations/20260907130003_calendar_range.sql"
finite_migration_candidates=(
  "$repo_dir"/supabase/migrations/*_reject_non_finite_event_timestamps.sql
)
if [[ ${#finite_migration_candidates[@]} -ne 1 || ! -f "${finite_migration_candidates[0]}" ]]; then
  printf '비유한 일정 타임스탬프 마이그레이션을 정확히 하나 찾을 수 없습니다\n' >&2
  exit 1
fi
finite_migration="${finite_migration_candidates[0]}"
validate_migration_candidates=(
  "$repo_dir"/supabase/migrations/*_validate_event_timestamps.sql
)
if [[ ${#validate_migration_candidates[@]} -ne 1 || ! -f "${validate_migration_candidates[0]}" ]]; then
  printf '일정 타임스탬프 검증 마이그레이션을 정확히 하나 찾을 수 없습니다\n' >&2
  exit 1
fi
validate_migration="${validate_migration_candidates[0]}"

# event_members 이전의 모든 마이그레이션을 엄격한 사전순으로 적용한다.
# event_members가 아직 없을 때 이전 행을 시드하여 최초 설치 시 비활성/삭제 작성자를
# 포함한 과거 작성자 데이터 채우기를 검사한다.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$event_members_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    '00000000-0000-4000-8000-00000000f901',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-upgrade-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Range upgrade owner"}'::jsonb
  ),
  (
    '00000000-0000-4000-8000-00000000f902',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-upgrade-member@example.test', '',
    now(), now(), now(), '{"display_name":"Range upgrade member"}'::jsonb
  ),
  (
    '00000000-0000-4000-8000-00000000f903',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-upgrade-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Range upgrade inactive"}'::jsonb
  );

insert into public.groups (
  id, owner_id, name, description, timezone, version, deleted_at,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Range upgrade group', 'Preserve this description', 'UTC', 3, null,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at,
  created_at, updated_at
) values
  (
    '00000000-0000-4000-8000-00000000fa01',
    '00000000-0000-4000-8000-00000000f902',
    'member', true, '2026-01-03T00:00:00Z', null,
    '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z'
  ),
  (
    '00000000-0000-4000-8000-00000000fa01',
    '00000000-0000-4000-8000-00000000f903',
    'member', false, '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z',
    '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z'
  );

-- 이 행은 event_members보다 먼저 존재한다. 삭제된 일정에는 의도적으로 비활성
-- 작성자가 있다. 현재 RLS가 숨기더라도 마이그레이션 30002는 과거 할당과
-- event.created_at 타임스탬프를 보존해야 한다.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  deleted_at, created_at, updated_at
) values
  (
    '00000000-0000-4000-8000-00000000fb01',
    '00000000-0000-4000-8000-00000000fa01',
    '00000000-0000-4000-8000-00000000f901',
    'Legacy range event', 'Preserve this event',
    '2026-01-05T00:00:00Z', '2026-01-05T01:00:00Z',
    'UTC', false, null, null, 1, 305419896, null,
    '2026-01-05T00:00:00Z', '2026-01-06T00:00:00Z'
  ),
  (
    '00000000-0000-4000-8000-00000000fb02',
    '00000000-0000-4000-8000-00000000fa01',
    '00000000-0000-4000-8000-00000000f903',
    'Deleted inactive legacy range event', 'Keep historical creator',
    '2026-01-05T02:00:00Z', '2026-01-05T03:00:00Z',
    'UTC', false, null, null, 1, 305419897,
    '2026-01-06T00:00:00Z',
    '2026-01-05T00:00:00Z', '2026-01-06T00:00:00Z'
  );
SQL

printf '%s 적용 중\n' "$(basename "$event_members_migration")"
psql_test -f "$event_members_migration" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_expected_created_at timestamptz := '2026-01-05T00:00:00Z';
begin
  if (select count(*) from public.event_members
      where event_id in (
        '00000000-0000-4000-8000-00000000fb01'::uuid,
        '00000000-0000-4000-8000-00000000fb02'::uuid
      )) <> 2 then
    raise exception '과거 작성자 데이터 채우기가 두 행을 모두 만들지 않았습니다';
  end if;
  if (select created_at from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000fb01'::uuid
        and user_id = '00000000-0000-4000-8000-00000000f901'::uuid)
      <> v_expected_created_at then
    raise exception '데이터 채우기가 event.created_at을 보존하지 않았습니다';
  end if;
  if (select created_at from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000fb02'::uuid
        and user_id = '00000000-0000-4000-8000-00000000f903'::uuid)
      <> v_expected_created_at then
    raise exception '비활성/삭제 작성자 데이터 채우기의 타임스탬프가 변경되었습니다';
  end if;
end;
$$;
SQL

printf '%s 적용 중\n' "$(basename "$range_migration")"
psql_test -f "$range_migration" >/dev/null

psql_test <<'SQL'
-- 운영 중인 이전 일정은 할당 하나를 받고 새 범위 RPC는 삭제된 과거 일정을 노출하지
-- 않으면서 활성 멤버에게 기능 5의 행 형태를 반환한다.
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000f902';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
do $$
declare
  v_payload jsonb;
begin
  v_payload := public.events_for_range(
    '00000000-0000-4000-8000-00000000fa01'::uuid,
    '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z',
    'UTC', 100, null, null
  );
  if jsonb_array_length(v_payload->'events') <> 1 then
    raise exception '범위 RPC가 삭제된 행을 반환했거나 필요한 행을 누락했습니다';
  end if;
  if not (v_payload->'events'->0 ? 'member_ids') then
    raise exception '범위 RPC가 member_ids를 누락했습니다';
  end if;
  if v_payload->>'has_more' <> 'false' or v_payload->>'next_cursor' is not null then
    raise exception '단일 범위 페이지의 봉투가 올바르지 않습니다';
  end if;
end;
$$;
reset role;
SQL

# 기존 기능에 추가만 하는 범위 마이그레이션은 재적용해도 안전하며 모든 행,
# 타임스탬프, 멤버십 및 일정 버전을 보존한다. 두 번째 데이터 채우기나 publication
# 변경 없이 마이그레이션 객체를 다시 만들 수 있는지도 확인한다.
printf '%s 재적용 중\n' "$(basename "$range_migration")"
psql_test -f "$range_migration" >/dev/null
psql_test <<'SQL'
do $$
begin
  if (select count(*) from public.event_members) <> 2 then
    raise exception '범위 마이그레이션 재적용으로 채운 행 개수가 변경되었습니다';
  end if;
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000fb01'::uuid) <> 1 then
    raise exception '범위 마이그레이션 재적용으로 일정 버전이 변경되었습니다';
  end if;
  if (select updated_at from public.events
      where id = '00000000-0000-4000-8000-00000000fb01'::uuid)
      <> '2026-01-06T00:00:00Z'::timestamptz then
    raise exception '범위 마이그레이션 재적용으로 일정 타임스탬프가 변경되었습니다';
  end if;
  if (select count(*) from public.event_members em
      where em.event_id = '00000000-0000-4000-8000-00000000fb01'::uuid
        and em.user_id = '00000000-0000-4000-8000-00000000f901'::uuid) <> 1 then
    raise exception '범위 마이그레이션 재적용으로 작성자 할당이 중복되었습니다';
  end if;
end;
$$;
SQL

# 이미 배포된 스키마는 PostgreSQL이 허용한 비유한 경계와 수명 주기 시각을 포함할
# 수 있다. 각 열의 과거 행과 이후 갱신 검사를 구분할 수 있도록 고정 행을 만든다.
psql_test <<'SQL'
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version, color_value,
  deleted_at, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000fb03',
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Legacy non-finite range event', 'Must require explicit deployer action',
  '-infinity', 'infinity', 'UTC', false, null, null, 1, 305419898,
  null, '2026-01-05T00:00:00Z', '2026-01-06T00:00:00Z'
) , (
  '00000000-0000-4000-8000-00000000fb04',
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Legacy non-finite created event', 'Must preserve created_at',
  '2026-01-08T00:00:00Z', '2026-01-08T01:00:00Z',
  'UTC', false, null, null, 1, 305419899,
  null, '-infinity', '2026-01-08T02:00:00Z'
) , (
  '00000000-0000-4000-8000-00000000fb05',
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Legacy non-finite updated event', 'Must preserve updated_at',
  '2026-01-09T00:00:00Z', '2026-01-09T01:00:00Z',
  'UTC', false, null, null, 1, 305419900,
  null, '2026-01-09T02:00:00Z', 'infinity'
) , (
  '00000000-0000-4000-8000-00000000fb06',
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Legacy non-finite deleted event', 'Must preserve deleted_at',
  '2026-01-10T00:00:00Z', '2026-01-10T01:00:00Z',
  'UTC', false, null, null, 1, 305419901,
  null, '2026-01-10T02:00:00Z', '2026-01-10T03:00:00Z'
) , (
  '00000000-0000-4000-8000-00000000fb07',
  '00000000-0000-4000-8000-00000000fa01',
  '00000000-0000-4000-8000-00000000f901',
  'Finite update target', 'Must remain finite after rejected updates',
  '2026-01-11T00:00:00Z', '2026-01-11T01:00:00Z',
  'UTC', false, null, null, 1, 305419902,
  null, '2026-01-11T02:00:00Z', '2026-01-11T03:00:00Z'
);
update public.events
set deleted_at = 'infinity', version = 2
where id = '00000000-0000-4000-8000-00000000fb06'::uuid;
SQL

# 첫 단계는 테이블을 스캔하지 않는 NOT VALID 보호막만 커밋한다. 과거 비유한 행이
# 남아 있어도 성공해야 하며 이후 INSERT/UPDATE부터 즉시 차단해야 한다.
printf '%s NOT VALID 유한성 보호막 적용 중\n' "$(basename "$finite_migration")"
psql_test -f "$finite_migration" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_constraint_name text;
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.events'::pg_catalog.regclass
      and c.conname = 'events_finite_time_bounds'
      and c.contype = 'c'
      and not c.convalidated
  ) then
    raise exception 'NOT VALID 유한성 보호막이 커밋되지 않았습니다';
  end if;
  if not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb03'::uuid
      and e.starts_at = '-infinity'::timestamptz
      and e.ends_at = 'infinity'::timestamptz
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb04'::uuid
      and e.created_at = '-infinity'::timestamptz
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb05'::uuid
      and e.updated_at = 'infinity'::timestamptz
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb06'::uuid
      and e.deleted_at = 'infinity'::timestamptz
  ) then
    raise exception 'NOT VALID 보호막이 기존 비유한 일정 행을 변경했습니다';
  end if;

  begin
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value,
      created_at, updated_at
    ) values (
      '00000000-0000-4000-8000-00000000fa01',
      '00000000-0000-4000-8000-00000000f901',
      'Rejected created_at upgrade event', '',
      '2026-01-12T00:00:00Z', '2026-01-12T01:00:00Z',
      'UTC', false, null, null, 1, 305419903,
      '-infinity', '2026-01-12T02:00:00Z'
    );
    raise exception 'created_at 비유한 신규 일정이 허용되었습니다';
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'events_finite_time_bounds' then raise; end if;
  end;

  begin
    update public.events
    set created_at = '-infinity', version = version + 1
    where id = '00000000-0000-4000-8000-00000000fb07'::uuid;
    raise exception 'created_at 비유한 갱신이 허용되었습니다';
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'events_finite_time_bounds' then raise; end if;
  end;

  begin
    update public.events
    set deleted_at = 'infinity', version = version + 1
    where id = '00000000-0000-4000-8000-00000000fb07'::uuid;
    raise exception 'deleted_at 비유한 갱신이 허용되었습니다';
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'events_finite_time_bounds' then raise; end if;
  end;
end;
$$;

set session_replication_role = replica;
do $$
declare
  v_constraint_name text;
begin
  begin
    update public.events
    set updated_at = 'infinity'
    where id = '00000000-0000-4000-8000-00000000fb07'::uuid;
    raise exception 'updated_at 비유한 갱신이 허용되었습니다';
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'events_finite_time_bounds' then raise; end if;
  end;
end;
$$;
reset session_replication_role;

do $$
begin
  if not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb07'::uuid
      and e.created_at = '2026-01-11T02:00:00Z'::timestamptz
      and e.updated_at = '2026-01-11T03:00:00Z'::timestamptz
      and e.deleted_at is null
      and e.version = 1
  ) then
    raise exception '거부된 비유한 갱신이 유한한 대상 행을 변경했습니다';
  end if;
end;
$$;
SQL

# 두 번째 단계가 과거 비유한 행을 명시적으로 탐지한다. 실패해도 앞 단계의 보호막은
# 이미 커밋되었으므로 신규 bad write 차단이 유지되고 모든 과거 행은 그대로여야 한다.
finite_failure_log="$work_dir/non-finite-validation.log"
if psql_test -f "$validate_migration" >"$finite_failure_log" 2>&1; then
  printf '기존 비유한 일정 행을 탐지하지 못했습니다\n' >&2
  exit 1
fi
if ! grep -Fq 'events contain non-finite timestamps; validation made no data changes' "$finite_failure_log"; then
  printf '비유한 일정 탐지 오류가 배포자 조치를 안내하지 않았습니다\n' >&2
  sed -n '1,160p' "$finite_failure_log" >&2
  exit 1
fi
if ! grep -Fq 'invalid event count: 4; sample event ids: 00000000-0000-4000-8000-00000000fb03, 00000000-0000-4000-8000-00000000fb04, 00000000-0000-4000-8000-00000000fb05, 00000000-0000-4000-8000-00000000fb06' "$finite_failure_log"; then
  printf '비유한 일정 탐지 오류에 개수와 표본 ID가 없습니다\n' >&2
  sed -n '1,160p' "$finite_failure_log" >&2
  exit 1
fi
if ! grep -Fq 'Inspect with SELECT id, starts_at, ends_at, created_at, updated_at, deleted_at FROM public.events' "$finite_failure_log"; then
  printf '비유한 일정 탐지 오류에 점검 쿼리가 없습니다\n' >&2
  sed -n '1,160p' "$finite_failure_log" >&2
  exit 1
fi

psql_test <<'SQL'
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.events'::pg_catalog.regclass
      and c.conname = 'events_finite_time_bounds'
      and not c.convalidated
  ) then
    raise exception '실패한 검증 뒤 NOT VALID 보호막이 유지되지 않았습니다';
  end if;
  if not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb03'::uuid
      and e.starts_at = '-infinity'::timestamptz
      and e.ends_at = 'infinity'::timestamptz
      and e.version = 1
      and e.updated_at = '2026-01-06T00:00:00Z'::timestamptz
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb04'::uuid
      and e.created_at = '-infinity'::timestamptz
      and e.version = 1
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb05'::uuid
      and e.updated_at = 'infinity'::timestamptz
      and e.version = 1
  ) or not exists (
    select 1 from public.events e
    where e.id = '00000000-0000-4000-8000-00000000fb06'::uuid
      and e.deleted_at = 'infinity'::timestamptz
      and e.version = 2
  ) then
    raise exception '비유한 일정 행은 실패한 마이그레이션에서 변경되면 안 됩니다';
  end if;
end;
$$;

-- 실제 운영에서는 위 오류가 알려 준 ID를 검토한 뒤 배포자가 데이터 의미에 맞는
-- 시각을 정한다. 이 일회용 픽스처에서는 그 명시 조치만 모사한다.
update public.events
set starts_at = '2026-01-07T00:00:00Z',
    ends_at = '2026-01-07T01:00:00Z',
    version = 2
where id = '00000000-0000-4000-8000-00000000fb03'::uuid;
update public.events
set created_at = '2026-01-08T02:00:00Z', version = 2
where id = '00000000-0000-4000-8000-00000000fb04'::uuid;
update public.events
set title = title, version = 2
where id = '00000000-0000-4000-8000-00000000fb05'::uuid;
update public.events
set deleted_at = '2026-01-10T04:00:00Z', version = 3
where id = '00000000-0000-4000-8000-00000000fb06'::uuid;
SQL

printf '%s 배포자 명시 조치 후 유한성 검증 마이그레이션을 적용 중\n' "$(basename "$validate_migration")"
psql_test -f "$validate_migration" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_constraint_name text;
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.events'::pg_catalog.regclass
      and c.conname = 'events_finite_time_bounds'
      and c.contype = 'c'
      and c.convalidated
  ) then
    raise exception '일정 유한성 검사가 검증된 상태가 아닙니다';
  end if;

  begin
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value
    ) values (
      '00000000-0000-4000-8000-00000000fa01',
      '00000000-0000-4000-8000-00000000f901',
      'Rejected non-finite upgrade event', '', '-infinity', 'infinity',
      'UTC', false, null, null, 1, 305419899
    );
    raise exception '신규 비유한 일정 경계가 허용되었습니다';
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
      if v_constraint_name <> 'events_finite_time_bounds' then
        raise;
      end if;
  end;

  if exists (
    select 1 from public.events where title = 'Rejected non-finite upgrade event'
  ) then
    raise exception '거부된 비유한 일정 행이 남았습니다';
  end if;
end;
$$;
SQL

# publication에는 의도적으로 상위 events 테이블만 포함한다. 상위 Realtime 신호 뒤에
# 하위 테이블을 다시 가져온다.
psql_test <<'SQL'
do $$
begin
  if exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'event_members'
  ) then
    raise exception 'event_members를 supabase_realtime에 추가해서는 안 됩니다';
  end if;
  if exists (
    select 1 from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'events'
  ) then
    raise exception 'events가 Realtime 무효화 신호로 유지되어야 합니다';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ) then
    raise exception 'authenticated 범위 RPC 권한이 없습니다';
  end if;
  if has_function_privilege(
    'anon',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ) then
    raise exception 'anon은 범위 RPC를 실행할 수 없어야 합니다';
  end if;
end;
$$;
SQL

printf 'events_for_range 업그레이드/재적용/데이터 채우기 검사를 통과했습니다\n'
