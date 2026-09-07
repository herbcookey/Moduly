#!/usr/bin/env bash

# Repeatable, credential-free upgrade evidence for the authenticated invite
# links migration.  It uses only a temporary local PostgreSQL cluster; no
# Docker, Supabase project, or remote database is contacted.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-invite-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/socket"
port="${SPLANNER_TEST_PORT:-$((58000 + RANDOM % 500))}"

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
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );
$$;
SQL

# Apply the complete history before the new additive migration.  The explicit
# stop point is checked lexically, so a future migration cannot accidentally be
# treated as part of the pre-upgrade fixture.
invite_migration="$repo_dir/supabase/migrations/20260907130004_invite_links.sql"
[[ -f "$invite_migration" ]]
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$invite_migration" ]] && break
  printf 'applying %s\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

# Seed representative legacy rows before the new migration.  The invite
# plaintexts below are fixture constants only; invite_codes receives digests.
psql_test <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    '00000000-0000-4000-8000-00000000b501',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'upgrade-invite-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Upgrade invite owner"}'::jsonb
  ),
  (
    '00000000-0000-4000-8000-00000000b502',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'upgrade-invite-member@example.test', '',
    now(), now(), now(), '{"display_name":"Upgrade invite member"}'::jsonb
  );

insert into public.groups (
  id, owner_id, name, description, timezone, version,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b511',
  '00000000-0000-4000-8000-00000000b501',
  'Invite upgrade group', 'Preserve this group', 'UTC', 4,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b511',
  '00000000-0000-4000-8000-00000000b502',
  'member', true, '2026-01-03T00:00:00Z', null,
  '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z'
);

insert into public.invite_codes (
  id, group_id, created_by, token_hash, expires_at, max_uses,
  uses_count, version, created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000b521',
  '00000000-0000-4000-8000-00000000b511',
  '00000000-0000-4000-8000-00000000b501',
  encode(extensions.digest(convert_to('fedcba9876543210fedcba9876543210fedcba9876543210', 'utf8'), 'sha256'), 'hex'),
  '2026-01-10T00:00:00Z', 3, 1, 2,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
), (
  '00000000-0000-4000-8000-00000000b522',
  '00000000-0000-4000-8000-00000000b511',
  '00000000-0000-4000-8000-00000000b501',
  encode(extensions.digest(convert_to('3456ABCDEFGH', 'utf8'), 'sha256'), 'hex'),
  '2099-01-10T00:00:00Z', 2, 0, 1,
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);
SQL

printf 'applying %s\n' "$(basename "$invite_migration")"
psql_test -f "$invite_migration" >/dev/null
printf 'reapplying %s\n' "$(basename "$invite_migration")"
psql_test -f "$invite_migration" >/dev/null

psql_test <<'SQL'
do $$
declare
  v_invite public.invite_codes;
  v_payload jsonb;
begin
  select * into v_invite
  from public.invite_codes
  where id = '00000000-0000-4000-8000-00000000b521';
  if not found
     or v_invite.token_hash <> encode(extensions.digest(convert_to('fedcba9876543210fedcba9876543210fedcba9876543210', 'utf8'), 'sha256'), 'hex')
     or v_invite.max_uses <> 3
     or v_invite.uses_count <> 1
     or v_invite.version <> 2
     or v_invite.created_at <> '2026-01-01T00:00:00Z'::timestamptz
     or v_invite.updated_at <> '2026-01-02T00:00:00Z'::timestamptz then
    raise exception 'legacy invite fields were not preserved on reapply';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class
    where oid = 'public.invite_preview_attempts'::regclass
      and relrowsecurity
  ) then
    raise exception 'preview-attempt ledger RLS is missing';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_class
    where oid = 'public.invite_preview_attempts_time_idx'::regclass
  ) or not exists (
    select 1
    from pg_catalog.pg_class
    where oid = 'public.invite_join_attempts_time_idx'::regclass
  ) then
    raise exception 'timestamp indexes for bounded stale cleanup are missing';
  end if;
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'invite_codes'
      and column_name in ('token', 'plaintext_token')
  ) then
    raise exception 'plaintext invite column was introduced';
  end if;
  if has_table_privilege('authenticated', 'public.invite_codes', 'update')
     or has_column_privilege('authenticated', 'public.invite_codes', 'revoked_at', 'update') then
    raise exception 'direct invite UPDATE privilege remains';
  end if;
  if has_table_privilege('authenticated', 'public.invite_preview_attempts', 'select')
     or has_table_privilege('authenticated', 'public.invite_preview_attempts', 'insert') then
    raise exception 'preview-attempt ledger is directly exposed';
  end if;
  if has_function_privilege('anon', 'public.preview_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.preview_invite(text)', 'execute') then
    raise exception 'preview RPC ACL is incorrect';
  end if;
  if has_function_privilege('anon', 'public.join_group_with_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.join_group_with_invite(text)', 'execute') then
    raise exception 'join RPC ACL is incorrect';
  end if;

  set local request.jwt.claim.sub = '00000000-0000-4000-8000-00000000b502';
  set local request.jwt.claim.role = 'authenticated';
  execute 'set local role authenticated';
  v_payload := public.preview_invite('3456-abcd-efgh');
  if v_payload ->> 'valid' <> 'true'
     or v_payload ->> 'group_id' <> '00000000-0000-4000-8000-00000000b511'
     or v_payload ->> 'group_name' <> 'Invite upgrade group'
     or v_payload ->> 'group_description' <> 'Preserve this group'
     or v_payload ->> 'already_member' <> 'true'
     or v_payload ? 'token'
     or v_payload ? 'token_hash' then
    raise exception 'preview payload is not sanitized or canonicalized';
  end if;
  if (select uses_count from public.invite_codes
      where id = '00000000-0000-4000-8000-00000000b522') <> 0 then
    raise exception 'preview consumed a use';
  end if;
end;
$$;

select 'invite-links upgrade/reapply checks passed' as result;
SQL

# Account deletion takes an auth.users row lock before cascading into owned
# groups.  Hold that row briefly while the owner revoke RPC starts; its
# FOR-KEY-SHARE-first order must wait and then complete without a 40P01
# deadlock.  The blocker PID is owned by this script and is always waited on.
printf 'running auth-user/revoke lock-order race\n'
(
  psql_test <<'SQL'
begin;
select id
from auth.users
where id = '00000000-0000-4000-8000-00000000b501'
for update;
select pg_catalog.pg_sleep(1);
commit;
SQL
) &
blocker_pid=$!
sleep 0.1
set +e
race_output=$(
  psql_test 2>&1 <<'SQL'
set request.jwt.claim.sub = '00000000-0000-4000-8000-00000000b501';
set request.jwt.claim.role = 'authenticated';
set role authenticated;
select public.revoke_invite_code(
  '00000000-0000-4000-8000-00000000b522'::uuid,
  1
);
reset role;
SQL
)
race_status=$?
set -e
wait "$blocker_pid"
if (( race_status != 0 )); then
  printf '%s\n' "$race_output"
  if printf '%s' "$race_output" | grep -q '40P01'; then
    printf 'auth-user/revoke lock-order race deadlocked\n' >&2
  else
    printf 'auth-user/revoke lock-order race failed\n' >&2
  fi
  exit "$race_status"
fi
if printf '%s' "$race_output" | grep -q '40P01'; then
  printf '%s\n' "$race_output" >&2
  printf 'auth-user/revoke lock-order race returned 40P01\n' >&2
  exit 1
fi
printf 'auth-user/revoke lock-order race passed\n'

# Run the real-role pgTAP fixture when the local PostgreSQL installation ships
# the extension (the standard Supabase stack does).  Homebrew's bare server
# often omits pgTAP, so the schema/ACL/reapply evidence above remains runnable
# there and the fixture is executed through assertion-compatible stubs below.
if [[ "$(psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'")" == "1" ]]; then
  printf 'running %s\n' invite_links.sql
  psql_test -f "$repo_dir/supabase/tests/invite_links.sql" >/dev/null
  printf 'invite-links pgTAP fixture passed\n'
else
  # Keep the fixture executable on a bare PostgreSQL installation as well.
  # These tiny assertion-compatible stubs run the SQL under the same roles and
  # JWT claims; a failed assertion raises and aborts psql rather than silently
  # skipping the security checks.  Supabase CI uses the real pgTAP extension
  # branch above.
  printf 'pgTAP extension unavailable; using assertion stubs for invite_links.sql\n'
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

create function public.is(p_actual anyelement, p_expected anyelement, p_description text)
returns text
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'pgTAP is failed: % (actual %, expected %)', p_description, p_actual, p_expected;
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

grant execute on function public.no_plan() to public;
grant execute on function public.ok(boolean, text) to public;
grant execute on function public.is(anyelement, anyelement, text) to public;
grant execute on function public.throws_ok(text, text, text, text) to public;
SQL
  sed '/^[[:space:]]*create extension if not exists pgtap;[[:space:]]*$/d' \
    "$repo_dir/supabase/tests/invite_links.sql" | psql_test >/dev/null
  printf 'invite-links assertion-stub fixture passed\n'
fi
