#!/usr/bin/env bash

# 기능 G의 신규 설치/업그레이드/재적용 검증이다. 이 실행기는 임시 로컬
# PostgreSQL 클러스터만 사용하며 Supabase 프로젝트에 접속하지 않는다.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-event-search-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/s"
port="${SPLANNER_TEST_PORT:-$((59600 + RANDOM % 150))}"
g_migration="$repo_dir/supabase/migrations/20260907171029_event_search.sql"

cleanup() {
  if [[ -d "$data_dir" ]]; then
    pg_ctl -D "$data_dir" -m fast -w stop >/dev/null 2>&1 || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$socket_dir"
# 로컬 클러스터가 조용히 SQL_ASCII로 축소되지 않고 픽스처에서 한국어, 이모지 및
# NFC/NFD 코드 포인트를 검사하도록 UTF-8 데이터베이스를 유지한다.
initdb -D "$data_dir" -A trust --locale=en_US.UTF-8 >/dev/null
pg_ctl -D "$data_dir" -o "-p $port -k $socket_dir" -w start >/dev/null

psql_test() {
  psql -X -v ON_ERROR_STOP=1 -h "$socket_dir" -p "$port" postgres "$@"
}

psql_test <<'SQL'
create schema auth;
create role anon;
create role authenticated;
create role service_role;
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

# G 이전의 모든 마이그레이션을 적용하는 것이 신규 스키마 경로다. 그 뒤 G 전에
# 이전 행을 삽입하여 업그레이드 경로가 해당 행을 다시 쓰지 않는지 확인한다.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$g_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  ('00000000-0000-4000-8000-00000000e901',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-upgrade-owner@example.test', '', now(), now(), now(),
   '{"display_name":"Search upgrade owner"}'::jsonb),
  ('00000000-0000-4000-8000-00000000e902',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-upgrade-member@example.test', '', now(), now(), now(),
   '{"display_name":"Search upgrade member"}'::jsonb),
  ('00000000-0000-4000-8000-00000000e903',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-upgrade-inactive@example.test', '', now(), now(), now(),
   '{"display_name":"Search upgrade inactive"}'::jsonb),
  ('00000000-0000-4000-8000-00000000e904',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-upgrade-outsider@example.test', '', now(), now(), now(),
   '{"display_name":"Search upgrade outsider"}'::jsonb);
insert into public.groups (
  id, owner_id, name, description, timezone, version, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000e921',
  '00000000-0000-4000-8000-00000000e901',
  'Search upgrade group', 'legacy group payload', 'UTC', 1,
  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
);
insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values
  ('00000000-0000-4000-8000-00000000e921',
   '00000000-0000-4000-8000-00000000e902', 'member', true,
   '2026-01-01T00:00:00Z', null),
  ('00000000-0000-4000-8000-00000000e921',
   '00000000-0000-4000-8000-00000000e903', 'member', false,
   '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000e931',
  '00000000-0000-4000-8000-00000000e921',
  '00000000-0000-4000-8000-00000000e901',
  'Legacy search event', 'legacy search description',
  '2026-02-01T09:00:00Z', '2026-02-01T10:00:00Z', 'UTC', false,
  null, null, 1, 305419896,
  '2026-01-02T00:00:00Z', '2026-01-03T00:00:00Z'
);
insert into public.event_members (event_id, user_id)
values ('00000000-0000-4000-8000-00000000e931',
        '00000000-0000-4000-8000-00000000e902');
SQL

printf '%s 적용 중(업그레이드 경로)\n' "$(basename "$g_migration")"
psql_test -f "$g_migration" >/dev/null
legacy_updated_before=$(psql_test -Atqc "select updated_at::text from public.events where id = '00000000-0000-4000-8000-00000000e931'::uuid")
printf '%s 재적용 중\n' "$(basename "$g_migration")"
psql_test -f "$g_migration" >/dev/null
legacy_updated_after=$(psql_test -Atqc "select updated_at::text from public.events where id = '00000000-0000-4000-8000-00000000e931'::uuid")
if [[ "$legacy_updated_before" != "$legacy_updated_after" ]]; then
  printf '업그레이드/재적용으로 이전 일정 타임스탬프가 변경되었습니다(%s -> %s)\n' \
    "$legacy_updated_before" "$legacy_updated_after" >&2
  exit 1
fi

psql_test <<'SQL'
do $$
declare
  v_payload jsonb;
begin
  if not exists (
    select 1 from pg_catalog.pg_class
     where oid = 'public.events_group_creator_start_id_live_idx'::regclass
       and relkind = 'i'
  ) then
    raise exception '업그레이드/재적용 뒤 작성자 부분 인덱스가 없습니다';
  end if;
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000e901', true);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000e901","role":"authenticated"}', true);
  v_payload := public.search_events_v1(
    '00000000-0000-4000-8000-00000000e921'::uuid,
    '2026-02-01T00:00:00Z', '2026-02-02T00:00:00Z', 'UTC', 'legacy',
    null, null, 50, null
  );
  if jsonb_array_length(v_payload->'events') <> 1
     or v_payload->'events'->0->>'title' <> 'Legacy search event'
     or v_payload ? 'count' then
    raise exception '업그레이드 검색 결과/봉투가 올바르지 않습니다';
  end if;
end;
$$;
SQL

# 로컬 기본 PostgreSQL에서 pgTAP 확장은 선택 사항이다. 사용할 수 있으면 전체
# 픽스처를 실행한다. 기본 설치에서는 엄격한 검증 호환 스텁을 정의하고 정확히 같은
# 전체 픽스처를 psql에 전달한다. 검증 실패나 SQL 오류가 있으면 실행기를 중단해야 한다.
if psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'" | grep -q '^1$'; then
  printf 'event_search.sql 실행 중(pgTAP)\n'
  psql_test -f "$repo_dir/supabase/tests/event_search.sql" >/dev/null
else
  printf 'pgTAP을 사용할 수 없어 event_search.sql에 엄격한 검증 스텁을 사용합니다\n'
  psql_test <<'SQL'
create function public.no_plan()
returns text
language sql
as $$ select '1..0'; $$;

create function public.ok(p_condition boolean, p_description text)
returns text
language plpgsql
as $$
begin
  if p_condition is distinct from true then
    raise exception 'pgTAP ok 실패: %', p_description;
  end if;
  return 'ok';
end;
$$;

create function public.is(
  p_actual anyelement,
  p_expected anyelement,
  p_description text
)
returns text
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'pgTAP is 실패: % (실제 값 %, 기댓값 %)',
      p_description, p_actual, p_expected;
  end if;
  return 'ok';
end;
$$;

create function public.throws_ok(
  p_sql text,
  p_sqlstate text,
  p_message text,
  p_description text
)
returns text
language plpgsql
as $$
declare
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_message = message_text;
    if v_state <> p_sqlstate
       or (p_message is not null and v_message <> p_message) then
      raise exception 'pgTAP throws_ok 실패: % (상태 %, 메시지 %)',
        p_description, v_state, v_message;
    end if;
    return 'ok';
  end;
  raise exception 'pgTAP throws_ok에서 오류를 기대했습니다: %', p_description;
end;
$$;

create function public.finish()
returns table(result text)
language sql
as $$ select 'finish'; $$;

grant execute on function public.no_plan() to public;
grant execute on function public.ok(boolean, text) to public;
grant execute on function public.is(anyelement, anyelement, text) to public;
grant execute on function public.throws_ok(text, text, text, text) to public;
grant execute on function public.finish() to public;
SQL
  sed '/^[[:space:]]*create extension if not exists pgtap;[[:space:]]*$/d' \
    "$repo_dir/supabase/tests/event_search.sql" | psql_test >/dev/null
  printf 'event_search 검증 스텁 픽스처를 통과했습니다\n'
fi

printf 'event_search 신규 설치/업그레이드/재적용 검사를 통과했습니다\n'
