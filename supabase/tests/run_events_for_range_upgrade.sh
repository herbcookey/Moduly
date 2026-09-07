#!/usr/bin/env bash

# Repeatable, credential-free upgrade evidence for the bounded calendar range
# migration.  It uses only a temporary local PostgreSQL cluster; no Docker,
# Supabase project, or remote database is contacted.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-range-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/socket"
port="${SPLANNER_TEST_PORT:-$((59000 + RANDOM % 500))}"

cleanup() {
  # Install the trap before initdb as well as before pg_ctl: a failed cluster
  # bootstrap must not leave a temporary directory behind.  Stop first when a
  # data directory exists, then remove only this script's dedicated mktemp
  # directory so PostgreSQL cannot race a disappearing socket/data path.
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

# Apply every migration before event_members in strict lexical order.  Seed
# legacy rows while event_members does not yet exist so its historical creator
# backfill (including inactive/deleted creators) is exercised on first install.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$event_members_migration" ]] && break
  printf 'applying %s\n' "$(basename "$migration")"
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

-- These rows predate event_members.  The deleted event deliberately has an
-- inactive creator: migration 30002 must preserve the historical assignment
-- and its event.created_at timestamp even though current RLS hides it.
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

printf 'applying %s\n' "$(basename "$event_members_migration")"
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
    raise exception 'historical creator backfill did not create both rows';
  end if;
  if (select created_at from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000fb01'::uuid
        and user_id = '00000000-0000-4000-8000-00000000f901'::uuid)
      <> v_expected_created_at then
    raise exception 'backfill did not preserve event.created_at';
  end if;
  if (select created_at from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000fb02'::uuid
        and user_id = '00000000-0000-4000-8000-00000000f903'::uuid)
      <> v_expected_created_at then
    raise exception 'inactive/deleted creator backfill timestamp changed';
  end if;
end;
$$;
SQL

printf 'applying %s\n' "$(basename "$range_migration")"
psql_test -f "$range_migration" >/dev/null

psql_test <<'SQL'
-- A live legacy event receives one assignment, and the new range RPC returns
-- the Feature 5 row shape to an active member without exposing the deleted
-- historical event.
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
    raise exception 'range RPC returned deleted or missing rows';
  end if;
  if not (v_payload->'events'->0 ? 'member_ids') then
    raise exception 'range RPC omitted member_ids';
  end if;
  if v_payload->>'has_more' <> 'false' or v_payload->>'next_cursor' is not null then
    raise exception 'single range page has an invalid envelope';
  end if;
end;
$$;
reset role;
SQL

# Reapplying the additive range migration is safe and preserves every row,
# timestamp, membership, and event version.  It also proves the migration's
# objects can be recreated without a second backfill or publication change.
printf 'reapplying %s\n' "$(basename "$range_migration")"
psql_test -f "$range_migration" >/dev/null
psql_test <<'SQL'
do $$
begin
  if (select count(*) from public.event_members) <> 2 then
    raise exception 'range migration reapply changed backfilled row count';
  end if;
  if (select version from public.events
      where id = '00000000-0000-4000-8000-00000000fb01'::uuid) <> 1 then
    raise exception 'range migration reapply changed event version';
  end if;
  if (select updated_at from public.events
      where id = '00000000-0000-4000-8000-00000000fb01'::uuid)
      <> '2026-01-06T00:00:00Z'::timestamptz then
    raise exception 'range migration reapply changed event timestamp';
  end if;
  if (select count(*) from public.event_members em
      where em.event_id = '00000000-0000-4000-8000-00000000fb01'::uuid
        and em.user_id = '00000000-0000-4000-8000-00000000f901'::uuid) <> 1 then
    raise exception 'range migration reapply duplicated creator assignment';
  end if;
end;
$$;
SQL

# The publication intentionally contains the parent events table only.  The
# child table is refetched after the parent realtime signal.
psql_test <<'SQL'
do $$
begin
  if exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'event_members'
  ) then
    raise exception 'event_members must not be added to supabase_realtime';
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
    raise exception 'events must remain the realtime invalidation signal';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ) then
    raise exception 'authenticated range RPC grant is missing';
  end if;
  if has_function_privilege(
    'anon',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ) then
    raise exception 'anon must not execute range RPC';
  end if;
end;
$$;
SQL

printf 'events_for_range upgrade/reapply/backfill checks passed\n'
