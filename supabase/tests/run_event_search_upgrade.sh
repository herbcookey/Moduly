#!/usr/bin/env bash

# Fresh/upgrade/reapply evidence for Feature G.  This runner uses only a
# temporary local PostgreSQL cluster and never contacts a Supabase project.

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
# Keep a UTF-8 database so the fixture exercises Korean, emoji, and NFC/NFD
# codepoints instead of silently reducing the local cluster to SQL_ASCII.
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

# Applying every migration before G is the fresh-schema path.  Legacy rows are
# then inserted before G, which proves the upgrade path does not rewrite them.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$g_migration" ]] && break
  printf 'applying %s\n' "$(basename "$migration")"
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

printf 'applying %s (upgrade path)\n' "$(basename "$g_migration")"
psql_test -f "$g_migration" >/dev/null
legacy_updated_before=$(psql_test -Atqc "select updated_at::text from public.events where id = '00000000-0000-4000-8000-00000000e931'::uuid")
printf 'reapplying %s\n' "$(basename "$g_migration")"
psql_test -f "$g_migration" >/dev/null
legacy_updated_after=$(psql_test -Atqc "select updated_at::text from public.events where id = '00000000-0000-4000-8000-00000000e931'::uuid")
if [[ "$legacy_updated_before" != "$legacy_updated_after" ]]; then
  printf 'upgrade/reapply changed legacy event timestamp (%s -> %s)\n' \
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
    raise exception 'creator partial index missing after upgrade/reapply';
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
    raise exception 'upgrade search result/envelope is invalid';
  end if;
end;
$$;
SQL

# The pgTAP extension is optional in local bare PostgreSQL.  Run the complete
# fixture where available.  On a bare install, define strict assertion-
# compatible stubs and feed the exact same complete fixture through psql; any
# failed assertion or SQL error must still abort this runner.
if psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'" | grep -q '^1$'; then
  printf 'running event_search.sql (pgTAP)\n'
  psql_test -f "$repo_dir/supabase/tests/event_search.sql" >/dev/null
else
  printf 'pgTAP unavailable; using strict assertion stubs for event_search.sql\n'
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
    raise exception 'pgTAP ok failed: %', p_description;
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
    raise exception 'pgTAP is failed: % (actual %, expected %)',
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
      raise exception 'pgTAP throws_ok failed: % (state %, message %)',
        p_description, v_state, v_message;
    end if;
    return 'ok';
  end;
  raise exception 'pgTAP throws_ok expected an error: %', p_description;
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
  printf 'event_search assertion-stub fixture passed\n'
fi

printf 'event_search fresh/upgrade/reapply checks passed\n'
