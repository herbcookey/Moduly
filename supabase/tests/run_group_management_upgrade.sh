#!/usr/bin/env bash

# Repeatable, credential-free upgrade evidence for the tenth migration.
#
# This script creates an isolated local PostgreSQL cluster, bootstraps only the
# tiny auth surface required by these migrations, applies migrations 1..9,
# seeds representative rows, applies migration 10, and reapplies migration 10
# to prove its guarded/index/backfill path is idempotent.  It never connects to
# Supabase or any remote database.  The temporary cluster directory is printed
# so a failed run can be inspected; the server is stopped on exit.

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

for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == *20260907130001_group_management.sql ]] && break
  printf 'applying %s\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

# Seed two users and one group after migration 9. The owner membership is
# removed deliberately so migration 10 must backfill it from groups.owner_id;
# the ordinary member and every child row must survive unchanged.
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

-- Deliberate legacy drift: the migration must restore this row from owner_id.
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
    raise exception 'seed owner membership was not removed';
  end if;
end;
$$;
SQL

printf 'applying %s\n' 20260907130001_group_management.sql
psql_test -f "$repo_dir/supabase/migrations/20260907130001_group_management.sql" >/dev/null
printf 'reapplying %s\n' 20260907130001_group_management.sql
psql_test -f "$repo_dir/supabase/migrations/20260907130001_group_management.sql" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_group public.groups;
  v_member public.memberships;
  v_owner public.memberships;
  v_invite public.invite_codes;
  v_event public.events;
  v_audit public.audit_logs;
begin
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
    raise exception 'existing group fields were not preserved';
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
    raise exception 'existing membership fields were not preserved';
  end if;

  select * into v_owner
  from public.memberships
  where group_id = '00000000-0000-4000-8000-00000000b001'
    and user_id = '00000000-0000-4000-8000-00000000a001';
  if not found or v_owner.role <> 'owner' or not v_owner.is_active
     or v_owner.removed_at is not null then
    raise exception 'groups.owner_id owner membership was not backfilled';
  end if;
  if (select count(*) from public.memberships
      where group_id = '00000000-0000-4000-8000-00000000b001'
        and role = 'owner' and is_active and removed_at is null) <> 1 then
    raise exception 'backfill did not leave exactly one active owner';
  end if;

  select * into v_invite from public.invite_codes
  where id = '00000000-0000-4000-8000-00000000c001';
  if not found or v_invite.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_invite.created_by <> '00000000-0000-4000-8000-00000000a001'
     or v_invite.token_hash <> repeat('b', 64)
     or v_invite.max_uses <> 3 or v_invite.uses_count <> 1
     or v_invite.version <> 2 then
    raise exception 'existing invite fields were not preserved';
  end if;

  select * into v_event from public.events
  where id = '00000000-0000-4000-8000-00000000d001';
  if not found or v_event.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_event.created_by <> '00000000-0000-4000-8000-00000000a002'
     or v_event.title <> 'Existing event'
     or v_event.description <> 'Existing event description'
     or v_event.version <> 1 or v_event.color_value <> 305419896 then
    raise exception 'existing event fields were not preserved';
  end if;

  select * into v_audit from public.audit_logs
  where id = '00000000-0000-4000-8000-00000000e001';
  if not found or v_audit.group_id <> '00000000-0000-4000-8000-00000000b001'
     or v_audit.actor_id <> '00000000-0000-4000-8000-00000000a001'
     or v_audit.entity_id <> '00000000-0000-4000-8000-00000000b001'
     or v_audit.metadata <> '{"version":7}'::jsonb then
    raise exception 'existing audit fields were not preserved';
  end if;

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
    raise exception 'active-owner unique partial index is missing';
  end if;
end;
$$;

select 'group-management upgrade preservation/reapply checks passed' as result;
SQL

# Two-session race evidence: session 1 holds the parent group row lock while
# transferring ownership. Session 2 attempts to archive as the old owner with
# a short lock timeout, proving it blocks on the group lock. After session 1
# commits, the same stale caller is rejected with the normal 40001 conflict
# instead of writing an archived/new-owner group. Everything remains local to
# this temporary cluster and uses no credentials or remote Supabase state.
lock_marker="$work_dir/group-lock-held"
transfer_log="$work_dir/transfer-race.log"
archive_lock_log="$work_dir/archive-lock-timeout.log"
archive_stale_log="$work_dir/archive-stale-owner.log"

(
  psql_test -v VERBOSITY=verbose >"$transfer_log" 2>&1 <<SQL
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000a001';
set request.jwt.claim.role = 'authenticated';
begin;
-- Setup role acquires the lock; the RPC then runs under authenticated in the
-- same transaction, retaining the lock while ownership changes atomically.
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
  echo 'transfer race lock marker was not produced' >&2
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
  echo 'archive unexpectedly bypassed the held group lock' >&2
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
  echo 'old owner unexpectedly archived after transfer' >&2
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
    raise exception 'transfer race did not commit the new owner atomically';
  end if;
end;
$$;
SQL

# A second active group keeps the membership race independent from the event
# race below (which archives the first fixture group). The owner trigger
# creates b002's owner membership; the ordinary member row is seeded here.
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
SQL

# Membership race evidence: direct status UPDATE is deliberately denied for
# API roles (moderation is RPC-only). A stale REPEATABLE READ session takes a
# membership snapshot while the owner archives the parent group; the attempted
# direct write fails with privilege denial and the historical row is unchanged.
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
  echo 'membership race snapshot marker was not produced' >&2
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
  echo 'direct membership UPDATE unexpectedly succeeded after archive' >&2
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
    raise exception 'membership row was modified after archive';
  end if;
end;
$$;
SQL

printf 'repeatable-read membership/archive RPC-only race checks passed\n'

# Direct event RLS race evidence: session 2 takes a REPEATABLE READ snapshot
# while the group is active, then waits. Session 1 archives the group. When
# session 2 finally updates the event, the trigger's parent-group FOR UPDATE
# sees the terminal transition (or reports the equivalent serialization
# conflict) and the stale child write is rolled back.
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
  echo 'event race snapshot marker was not produced' >&2
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
  echo 'stale event update unexpectedly succeeded after archive' >&2
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
     or v_event.version <> 1 then
    raise exception 'event child was modified after archive';
  end if;
end;
$$;
SQL

printf 'repeatable-read direct event/archive race checks passed\n'

printf 'two-session transfer/archive group-lock race checks passed\n'

printf 'temporary PostgreSQL cluster: %s\n' "$work_dir"
