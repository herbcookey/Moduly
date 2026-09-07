#!/usr/bin/env bash

# Fresh/upgrade/reapply evidence for Feature 2.  This runner uses a dedicated
# temporary PostgreSQL cluster and never contacts a Supabase project.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-recurrence-upgrade.XXXXXX")
data_dir="$work_dir/data"
# Keep the Unix socket directory short enough for macOS' 103-byte limit; the
# mktemp prefix already contains the descriptive runner name.
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

# Install the pre-recurrence schema first and create a legacy single event.
# This proves the additive migration does not synthesize a rule for singles.
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$recurrence_migration" ]] && break
  printf 'applying %s\n' "$(basename "$migration")"
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

printf 'applying %s\n' "$(basename "$recurrence_migration")"
psql_test -f "$recurrence_migration" >/dev/null
printf 'reapplying %s\n' "$(basename "$recurrence_migration")"
psql_test -f "$recurrence_migration" >/dev/null

psql_test <<'SQL'
do $$
begin
  if (select count(*) from public.event_recurrence_rules
      where event_id = '00000000-0000-4000-8000-00000000e203'::uuid) <> 0 then
    raise exception 'legacy single unexpectedly received a recurrence rule';
  end if;
  if (select title from public.events
      where id = '00000000-0000-4000-8000-00000000e203'::uuid) <> 'Legacy single' then
    raise exception 'legacy event was changed during recurrence migration';
  end if;
  if (select description from public.groups
      where id = '00000000-0000-4000-8000-00000000e202'::uuid) <> 'keep me' then
    raise exception 'legacy group was changed during recurrence migration';
  end if;
end;
$$;
SQL

# Exercise the same auth.users lock order with real concurrent sessions.  The
# first session keeps a recurring create transaction open; account deletion
# must wait (and then succeed), never deadlock or observe a partial event.  A
# second held all-scope replacement repeats the check for participant writes.
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
  printf 'account deletion unexpectedly bypassed create auth.users lock\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf 'account deletion probe failed without a lock wait\n' >&2
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
  printf 'account deletion unexpectedly bypassed all-scope auth.users lock\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf 'account deletion all-scope probe failed without a lock wait\n' >&2
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
  printf 'recurring member lock marker was not produced\n' >&2
  kill "$lock_members_pid" 2>/dev/null || true
  wait "$lock_members_pid" 2>/dev/null || true
  exit 1
fi
sleep 0.25
lock_delete_probe="$work_dir/lock-delete-members.log"
if psql_test -Atqc "set statement_timeout = '800ms'; delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid" >"$lock_delete_probe" 2>&1; then
  cat "$lock_members_log" >&2
  printf 'account deletion unexpectedly bypassed recurring member auth.users lock\n' >&2
  exit 1
fi
if ! grep -Eq 'statement timeout|57014' "$lock_delete_probe"; then
  cat "$lock_delete_probe" >&2
  printf 'account deletion recurring-member probe failed without a lock wait\n' >&2
  exit 1
fi
wait "$lock_members_pid"

psql_test -Atqc "delete from auth.users where id = '00000000-0000-4000-8000-00000000e205'::uuid"

# Verify the security boundary from catalog state (not merely from a failed
# query): both additive child tables have RLS, no direct authenticated grants,
# only the named RPCs are executable, and no child table is published.
psql_test <<'SQL'
do $$
begin
  if not (select relrowsecurity from pg_catalog.pg_class c
          join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relname = 'event_recurrence_rules')
     or not (select relrowsecurity from pg_catalog.pg_class c
             join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = 'event_occurrence_overrides') then
    raise exception 'recurrence child RLS is not enabled';
  end if;
  if has_table_privilege('authenticated', 'public.event_recurrence_rules', 'select')
     or has_table_privilege('authenticated', 'public.event_occurrence_overrides', 'select') then
    raise exception 'authenticated role has a direct recurrence child grant';
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
    raise exception 'recurrence function ACL contract failed';
  end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role')
     and has_function_privilege('service_role',
       'public.replace_event_members_if_version(uuid,integer,uuid[])', 'execute') then
    raise exception 'compatibility wrapper is executable by service_role';
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
    raise exception 'a recurrence definer function has no fixed search_path';
  end if;
  if exists (select 1 from pg_catalog.pg_publication_tables
             where schemaname = 'public'
               and tablename in ('event_recurrence_rules', 'event_occurrence_overrides')) then
    raise exception 'recurrence children must not be in realtime publication';
  end if;
end;
$$;
SQL

if psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'" | grep -q '^1$'; then
  printf 'running recurrence pgTAP fixture\n'
  psql_test -f "$repo_dir/supabase/tests/recurrence.sql" >/dev/null
else
  printf 'pgtap is unavailable; running assertion fallback\n'
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
    raise exception 'interval zero unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null frequency', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 5::bigint, null, null::text, 1, '{}'::smallint[],
      'never', null, null, null
    );
    raise exception 'NULL frequency unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null end', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 6::bigint, null, 'daily', 1, '{}'::smallint[], null::text,
      null, null, null
    );
    raise exception 'NULL recurrence end unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'duplicate weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 9::bigint, null, 'weekly', 1, array[1,1]::smallint[],
      'never', null, null, null
    );
    raise exception 'duplicate weekdays unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'out of range weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 10::bigint, null, 'weekly', 1, array[0]::smallint[],
      'never', null, null, null
    );
    raise exception 'out of range weekdays unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null element weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 11::bigint, null, 'weekly', 1,
      array[1::smallint,NULL::smallint], 'never', null, null, null
    );
    raise exception 'NULL weekday element unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'invalid interval thousand', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 6::bigint, null, 'daily', 1000, '{}'::smallint[],
      'never', null, null, null
    );
    raise exception 'interval 1000 unexpectedly succeeded';
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
    raise exception 'member list without creator unexpectedly succeeded';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'unsorted weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 8::bigint, null, 'weekly', 1, array[3,1]::smallint[],
      'never', null, null, null
    );
    raise exception 'unsorted weekdays unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.create_recurring_event_with_members(
      (select group_id from recurrence_fallback), 'null weekdays', '',
      '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 9::bigint, null, 'daily', 1, null::smallint[],
      'never', null, null, null
    );
    raise exception 'null weekdays unexpectedly succeeded';
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
    raise exception 'fallback root rule assertion failed';
  end if;
  v_payload := public.events_for_range_v2(
    v_group, '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
  );
  if jsonb_array_length(v_payload->'events') <> 30 then
    raise exception 'fallback bounded expansion assertion failed';
  end if;
  if (select occurrence_key from public.event_occurrence_by_key(v_event, 'o00000000000000000002'))
      <> 'o00000000000000000002' then
    raise exception 'fallback stable key assertion failed';
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
    raise exception 'this-scope changed receipt/version failed';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_event, 2, 'o00000000000000000001', 'this', 'Fallback exception', 'changed',
    '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false, null, null,
    9::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null
  );
  if (v_receipt->>'changed')::boolean is not false
     or (v_receipt->>'series_version')::integer <> 2
     or (v_receipt->>'occurrence_version')::integer <> 1 then
    raise exception 'this-scope idempotent replay changed the parent';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_event, 2, 'o00000000000000000000', 'this'
  );
  if (v_receipt->>'changed')::boolean is not true
     or (v_receipt->>'series_version')::integer <> 3 then
    raise exception 'this-scope cancellation receipt/version failed';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_event, 3, 'o00000000000000000000', 'this'
  );
  if (v_receipt->>'changed')::boolean is not false
     or (v_receipt->>'series_version')::integer <> 3 then
    raise exception 'idempotent cancellation changed the parent';
  end if;
  if exists (select 1 from public.event_occurrence_by_key(v_event, 'o00000000000000000000')) then
    raise exception 'cancelled occurrence still resolves in point RPC';
  end if;
end;
$$;
reset role;
-- Iterate every page of three never-ending daily series.  The guard makes an
-- accidental unbounded cursor loop a deterministic failure instead of a hung
-- CI job.
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
    if v_pages > 10 then raise exception 'keyset pagination exceeded bounded page guard'; end if;
    for v_item in select value from jsonb_array_elements(v_payload->'events') loop
      v_key := (v_item->>'event_id') || ':' || (v_item->>'occurrence_key');
      if v_key = any(v_seen) then raise exception 'duplicate occurrence in keyset pages'; end if;
      v_seen := array_append(v_seen, v_key);
      v_total := v_total + 1;
    end loop;
    if coalesce((v_payload->>'has_more')::boolean, false) is false then exit; end if;
    v_cursor := v_payload->>'next_cursor';
    if v_cursor is null or v_cursor = '' then raise exception 'has_more page has no cursor'; end if;
  end loop;
  if v_total <> 1097 then raise exception 'expected 1097 bounded occurrences with no gaps, got %', v_total; end if;
end;
$$;
reset role;

-- All-scope participant replacement is atomic with the body/rule save and
-- emits one parent version transition; this also resets prior exceptions.
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
    raise exception 'all-scope participant replacement did not bump once';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event, 'o00000000000000000000');
  if v_point.member_ids <> array['00000000-0000-4000-8000-00000000e201'::uuid,
                                  '00000000-0000-4000-8000-00000000e204'::uuid]
     or v_point.occurrence_version <> 0 then
    raise exception 'all-scope participant replacement did not reset exceptions';
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
    raise exception 'all-scope participant replay was not a no-op';
  end if;
end;
$$;
reset role;

-- Recurring participant-only replacement has a receipt-bearing RPC.  A group
-- owner may update a member-created series, but the creator can never be
-- omitted; canonical input is sorted/deduped and identical input is a no-op.
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
    raise exception 'member RPC series was not created';
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
    raise exception 'creator-excluded recurring member replacement unexpectedly succeeded';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before
     or (select count(*) from public.event_members where event_id = v_event) <> v_members_before then
    raise exception 'creator-excluded recurring replacement partially changed data';
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
    raise exception 'recurring member replacement receipt/canonical key failed';
  end if;
  v_receipt := public.replace_recurring_event_members_if_version(
    v_event, v_before + 1, 'o00000000000000000001',
    array['00000000-0000-4000-8000-00000000e204'::uuid,
          '00000000-0000-4000-8000-00000000e201'::uuid]);
  if v_receipt->>'changed' is distinct from 'false'
     or (v_receipt->>'series_version')::integer <> v_before + 1
     or v_receipt->>'occurrence_key' <> 'o00000000000000000001' then
    raise exception 'identical recurring member replacement was not a no-op';
  end if;
  begin
    perform public.replace_recurring_event_members_if_version(
      v_event, v_before, 'single',
      array['00000000-0000-4000-8000-00000000e201'::uuid,
            '00000000-0000-4000-8000-00000000e204'::uuid]);
    raise exception 'stale recurring member replacement unexpectedly succeeded';
  exception when sqlstate '40001' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before + 1 then
    raise exception 'stale recurring member replacement changed version';
  end if;
  begin
    perform public.replace_event_members_if_version(
      v_event, v_before + 1,
      array['00000000-0000-4000-8000-00000000e201'::uuid]);
    raise exception 'legacy recurring replacement removed creator unexpectedly';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before + 1 then
    raise exception 'legacy recurring replacement changed version on creator rejection';
  end if;
  if (select replaced.version
      from public.replace_event_members_if_version(
        v_event, v_before + 1,
        array['00000000-0000-4000-8000-00000000e204'::uuid,
              '00000000-0000-4000-8000-00000000e201'::uuid]) replaced)
      <> v_before + 1 then
    raise exception 'legacy recurring replacement compatibility row failed';
  end if;
end;
$$;
reset role;

-- The compatibility wrapper still delegates singleton events to the original
-- table-returning implementation (including its historical empty-list rule).
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
    raise exception 'singleton compatibility empty replacement did not bump once';
  end if;
  if (select replaced.version from public.replace_event_members_if_version(
      v_event, 2,
      array['00000000-0000-4000-8000-00000000e201'::uuid]) replaced) <> 3 then
    raise exception 'singleton compatibility creator replacement failed';
  end if;
end;
$$;
reset role;

-- A removed event creator cannot use the recurring member RPC.  Membership
-- lifecycle pruning is isolated to this dedicated group and reactivation does
-- not silently restore the child assignment.
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
    raise exception 'removed creator recurring replacement unexpectedly succeeded';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before then
    raise exception 'removed creator replacement changed version';
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

-- Sequential future splits inherit a count after subtracting consumed
-- ordinals; an explicit count replaces (rather than subtracts) the prior one.
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
    raise exception 'inherited future count did not subtract the consumed ordinal';
  end if;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 2, 'o00000000000000000002', 'future', null, null, null, null, null,
    null, null, null, null, null, null, null, null, null, null, null, null);
  if v_receipt->>'changed' is distinct from 'true'
      or (select occurrence_count from public.event_recurrence_rules
          where event_id = v_id and start_occurrence_index = 2) <> 3 then
    raise exception 'sequential inherited future count is not the remaining count';
  end if;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_id, 3, 'o00000000000000000002', 'future', null, null, null, null, null,
      null, null, null, null, null, 'daily', 1, null::smallint[], null::text,
      null, null, null);
    raise exception 'explicit frequency with NULL weekdays unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_id, 3, 'o00000000000000000002', 'future', null, null, null, null, null,
      null, null, null, null, null, null, null, null, null, null, null, 4::smallint);
    raise exception 'inherited non-monthly rule accepted monthly_day unexpectedly';
  exception when sqlstate '22023' then null;
  end;
  select event_id into v_id from recurrence_future_count where event_id in (
    select id from public.events where title = 'Explicit count') limit 1;
  v_receipt := public.update_event_occurrence_scope_if_version(
    v_id, 1, 'o00000000000000000001', 'future', null, null, null, null, null,
    null, null, null, null, null, null, null, null, 'count', 2, null, null);
  if (select occurrence_count from public.event_recurrence_rules
      where event_id = v_id and start_occurrence_index = 1) <> 2 then
    raise exception 'explicit future count did not replace the inherited count';
  end if;
end;
$$;
reset role;

-- Create, future, and all-scope saves all derive a civil wall duration across
-- DST transitions (stored duration remains 24h; UTC projection varies).
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
    raise exception 'future DST save did not preserve civil 24-hour duration';
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
    raise exception 'all-scope DST save did not preserve civil 24-hour duration';
  end if;
end;
$$;

-- A this-scope move beyond the 366-day scheduled look-behind is discovered
-- through effective override indexes, while the original scheduled slot is
-- suppressed and cancellation removes the moved-in row.
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
    raise exception 'moved override update did not commit';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2027-06-01T00:00:00Z',
    '2027-06-30T00:00:00Z', 'UTC', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text
                   and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception 'moved-in override was not discovered outside scheduled look-behind';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2026-01-01T00:00:00Z',
    '2026-01-02T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text) then
    raise exception 'moved-out scheduled slot was not suppressed';
  end if;
  v_receipt := public.delete_event_occurrence_scope_if_version(
    v_id, 2, 'o00000000000000000000', 'this');
  if v_receipt->>'changed' is distinct from 'true' then
    raise exception 'moved override cancellation did not commit';
  end if;
  v_payload := public.events_for_range_v2(
    (select group_id from recurrence_fallback), '2027-06-01T00:00:00Z',
    '2027-06-30T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text
               and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception 'cancelled moved override was reintroduced';
  end if;
end;
$$;
reset role;

-- Matrix rows exercise all three frequencies, interval/weekdays, all end
-- modes, month-end clamping, DST gap/fold behavior, participant inheritance,
-- and all-day local half-open dates.  They are created after the 1000+ row
-- pagination check so that its expected cardinality stays deterministic.
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
  if v_count <> 6 then raise exception 'weekly interval/weekdays expansion count=%', v_count; end if;
  if (select starts_at::date from public.event_occurrence_by_key(v_id, 'o00000000000000000000')) <> '2026-01-07'::date
     or (select starts_at::date from public.event_occurrence_by_key(v_id, 'o00000000000000000002')) <> '2026-01-19'::date then
    raise exception 'weekly interval did not anchor and skip an intervening week';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix until';
  select count(*) into v_count from public._event_occurrences_for_range(v_id, '2026-01-01', '2026-01-05', 'UTC');
  if v_count <> 3 then raise exception 'inclusive until expansion count=%', v_count; end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix participant';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if v_row.member_ids <> array['00000000-0000-4000-8000-00000000e201'::uuid,
                                '00000000-0000-4000-8000-00000000e204'::uuid] then
    raise exception 'participant inheritance was not series-wide';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix gap';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (v_row.starts_at at time zone 'America/New_York')::time <> '03:30:00'::time then
    raise exception 'DST gap was not resolved forward';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix fold';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if v_row.starts_at <> '2026-11-01T06:30:00Z'::timestamptz then
    raise exception 'DST fold did not choose standard time';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix spring duration';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception 'spring anchor did not preserve a 24-hour civil duration';
  end if;
  if extract(epoch from v_row.ends_at - v_row.starts_at) <> 23 * 3600 then
    raise exception 'spring transition did not produce a 23-hour UTC elapsed projection';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix fall duration';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000000');
  if (select duration_seconds from public.event_recurrence_rules where event_id = v_id) <> 86400 then
    raise exception 'fall anchor did not preserve a 24-hour civil duration';
  end if;
  if extract(epoch from v_row.ends_at - v_row.starts_at) <> 25 * 3600 then
    raise exception 'fall transition did not produce a 25-hour UTC elapsed projection';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix all day';
  select * into v_row from public.event_occurrence_by_key(v_id, 'o00000000000000000001');
  if v_row.all_day_start <> '2026-01-03'::date or v_row.all_day_end <> '2026-01-05'::date then
    raise exception 'all-day half-open dates are wrong';
  end if;
  v_payload := public.events_for_range_v2(v_group, '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z', 'UTC', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text and e->>'occurrence_key' = 'o00000000000000000001') then
    raise exception 'all-day half-open overlap omitted boundary occurrence';
  end if;
  v_payload := public.events_for_range_v2(v_group, '2026-01-05T00:00:00Z', '2026-01-06T00:00:00Z', 'UTC', 200, null, null);
  if exists (select 1 from jsonb_array_elements(v_payload->'events') e
             where e->>'event_id' = v_id::text) then
    raise exception 'all-day half-open end boundary was included';
  end if;
  select id into v_id from public.events where group_id = v_group and title = 'Matrix all day offset';
  v_payload := public.events_for_range_v2(
    v_group, '2026-01-01T00:00:00-10:00', '2026-01-02T00:00:00-10:00',
    'Pacific/Honolulu', 200, null, null);
  if not exists (select 1 from jsonb_array_elements(v_payload->'events') e
                 where e->>'event_id' = v_id::text
                   and e->>'occurrence_key' = 'o00000000000000000000') then
    raise exception 'all-day overlap did not use civil effective dates';
  end if;
  for v_id in select id from public.events where group_id = v_group and title like 'Matrix clamp %' loop
    select count(*) into v_count from public._event_occurrences_for_range(v_id, '2024-01-01', '2024-06-01', 'UTC');
    if v_count <> 3 then raise exception 'clamp series % has % rows', v_id, v_count; end if;
    if (select count(distinct starts_at::date) from public._event_occurrences_for_range(v_id, '2024-01-01', '2024-06-01', 'UTC')) <> 3 then
      raise exception 'clamp series % duplicated an occurrence date', v_id;
    end if;
  end loop;
end;
$$;

-- Explicit group deletion must cascade the anchor and both additive child
-- tables (account deletion below exercises the same path through auth.users).
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
    raise exception 'group deletion did not cascade recurrence children';
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
    raise exception 'NULL update scope unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', null::text);
    raise exception 'NULL delete scope unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'all',
      'bad end', '', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false,
      null, null, 1::bigint,
      array['00000000-0000-4000-8000-00000000e201'::uuid],
      'daily', 1, '{}'::smallint[], null::text, null, null, null);
    raise exception 'NULL all-scope recurrence end unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
end;
$$;
reset role;

-- Extreme 20-digit ordinals are rejected before materialization or mutation;
-- neither update nor delete may bump the parent version.
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
    raise exception 'overflow point lookup unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      v_event, v_before, 'o00000000002147483648', 'this', 'overflow', '',
      '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
      null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
    raise exception 'overflow update unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      v_event, v_before, 'o00000000002147483648', 'this');
    raise exception 'overflow delete unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before then
    raise exception 'overflow mutation changed parent version';
  end if;
end;
$$;
reset role;

-- A canonical maximum supported ordinal is still a valid key.  Date/month/
-- timestamp arithmetic at that ordinal must be treated as an absent row for
-- every frequency, including anchors near both practical date boundaries.
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
      raise exception '% extreme point unexpectedly materialized', v_row.kind;
    end if;
    select version into v_before from public.events where id = v_row.event_id;
    begin
      perform public.update_event_occurrence_scope_if_version(
        v_row.event_id, v_before, 'o00000000002147483647', 'this', 'overflow', '',
        '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
        null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
      raise exception '% extreme update unexpectedly succeeded', v_row.kind;
    exception when sqlstate '22023' then
      null;
    end;
    if (select version from public.events where id = v_row.event_id) <> v_before then
      raise exception '% extreme update changed parent version', v_row.kind;
    end if;
    begin
      perform public.delete_event_occurrence_scope_if_version(
        v_row.event_id, v_before, 'o00000000002147483647', 'this');
      raise exception '% extreme delete unexpectedly succeeded', v_row.kind;
    exception when sqlstate '22023' then
      null;
    end;
    if (select version from public.events where id = v_row.event_id) <> v_before then
      raise exception '% extreme delete changed parent version', v_row.kind;
    end if;
  end loop;
end;
$$;
reset role;

-- Missing target accounts are rejected while still before group/event/child
-- locks, so an all-scope replacement cannot partially alter members/version.
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
    raise exception 'missing account all-scope update unexpectedly succeeded';
  exception when sqlstate '42501' then null;
  end;
  if (select version from public.events where id = v_event) <> v_before
     or (select count(*) from public.event_members where event_id = v_event) <> v_members_before then
    raise exception 'missing account rejection partially changed the event';
  end if;
end;
$$;
reset role;

-- Anonymous and deactivated actors must not use the authenticated range RPC.
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
    raise exception 'anonymous create call unexpectedly succeeded';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.update_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'this',
      'anonymous update', '', '2026-01-01T12:00:00Z', '2026-01-01T13:00:00Z', 'UTC', false,
      null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null);
    raise exception 'anonymous update call unexpectedly succeeded';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.delete_event_occurrence_scope_if_version(
      (select event_id from recurrence_fallback), 4, 'o00000000000000000000', 'this');
    raise exception 'anonymous delete call unexpectedly succeeded';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.event_occurrence_by_key(
      (select event_id from recurrence_fallback), 'o00000000000000000000');
    raise exception 'anonymous point call unexpectedly succeeded';
  exception when sqlstate '28000' then null;
  end;
  begin
    perform public.events_for_range_v2(
      (select group_id from recurrence_fallback),
      '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null
    );
    raise exception 'anonymous range call unexpectedly succeeded';
  exception when sqlstate '28000' then
    null;
  end;
  begin
    perform public.replace_recurring_event_members_if_version(
      (select event_id from recurrence_member_rpc_event), 2, 'single',
      array['00000000-0000-4000-8000-00000000e201'::uuid,
            '00000000-0000-4000-8000-00000000e204'::uuid]);
    raise exception 'anonymous recurring member replacement unexpectedly succeeded';
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
    raise exception 'deactivated range call unexpectedly succeeded';
  exception when sqlstate '42501' then
    null;
  end;
end;
$$;
reset role;

-- A legacy singleton can become a recurrence and later return to a singleton
-- without replacing its logical anchor row or participant assignments.
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
    raise exception 'singleton-to-recurrence conversion receipt/version failed';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'o00000000000000000000');
  if v_point.event_id is distinct from v_event_id
     or v_point.occurrence_key <> 'o00000000000000000000'
     or v_point.version <> 2 then
    raise exception 'singleton-to-recurrence conversion did not retain anchor';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'single');
  if v_point.event_id is distinct from v_event_id
     or v_point.occurrence_key <> 'o00000000000000000000'
     or v_point.occurrence_index <> 0 then
    raise exception 'recurring legacy single key did not normalize to ordinal zero';
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
    raise exception 'recurrence-to-singleton conversion receipt/version failed';
  end if;
  select * into v_point from public.event_occurrence_by_key(v_event_id, 'single');
  if v_point.event_id is distinct from v_event_id or v_point.version <> 3 then
    raise exception 'recurrence-to-singleton conversion did not clear children';
  end if;
  if v_point.occurrence_key <> 'single' then
    raise exception 'converted singleton point key failed';
  end if;
end;
$$;
reset role;

-- Account deletion cascades groups/events and both recurrence child tables.
delete from auth.users where id = '00000000-0000-4000-8000-00000000e201'::uuid;
do $$
begin
  if exists (select 1 from public.event_recurrence_rules
             where event_id in (select event_id from recurrence_fallback)) then
    raise exception 'account deletion left recurrence rules';
  end if;
  if exists (select 1 from public.event_occurrence_overrides
             where event_id in (select event_id from recurrence_fallback)) then
    raise exception 'account deletion left occurrence overrides';
  end if;
end;
$$;
commit;
SQL
fi

# Explain the two child indexes so CI logs retain evidence that event-scoped
# expansion and cascade lookups have usable plans.
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

printf 'recurrence fresh/upgrade/reapply checks passed\n'
