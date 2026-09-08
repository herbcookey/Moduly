#!/usr/bin/env bash

# 인증된 초대 링크 마이그레이션을 자격 증명 없이 반복 검증한다. 임시 로컬
# PostgreSQL 클러스터만 사용하며 Docker, Supabase 프로젝트 또는 원격
# 데이터베이스에는 접속하지 않는다.

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

# 기존 기능에 추가하는 새 마이그레이션 전에 전체 이력을 적용한다. 명시적인 중지
# 지점을 사전순으로 확인하므로 이후 마이그레이션을 실수로 업그레이드 전 픽스처의
# 일부로 취급할 수 없다.
invite_migration="$repo_dir/supabase/migrations/20260907130004_invite_links.sql"
[[ -f "$invite_migration" ]]
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$invite_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

# 새 마이그레이션 전에 대표적인 이전 행을 시드한다. 아래 초대 평문은 픽스처
# 상수일 뿐이며 invite_codes에는 다이제스트가 들어간다.
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

printf '%s 적용 중\n' "$(basename "$invite_migration")"
psql_test -f "$invite_migration" >/dev/null
printf '%s 재적용 중\n' "$(basename "$invite_migration")"
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
    raise exception '재적용 시 이전 초대 필드를 보존하지 않았습니다';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class
    where oid = 'public.invite_preview_attempts'::regclass
      and relrowsecurity
  ) then
    raise exception '미리 보기 시도 원장 RLS가 없습니다';
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
    raise exception '범위 제한 오래된 행 정리용 타임스탬프 인덱스가 없습니다';
  end if;
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'invite_codes'
      and column_name in ('token', 'plaintext_token')
  ) then
    raise exception '평문 초대 열이 추가되었습니다';
  end if;
  if has_table_privilege('authenticated', 'public.invite_codes', 'update')
     or has_column_privilege('authenticated', 'public.invite_codes', 'revoked_at', 'update') then
    raise exception '직접 초대 UPDATE 권한이 남아 있습니다';
  end if;
  if has_table_privilege('authenticated', 'public.invite_preview_attempts', 'select')
     or has_table_privilege('authenticated', 'public.invite_preview_attempts', 'insert') then
    raise exception '미리 보기 시도 원장이 직접 노출되어 있습니다';
  end if;
  if has_function_privilege('anon', 'public.preview_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.preview_invite(text)', 'execute') then
    raise exception '미리 보기 RPC ACL이 올바르지 않습니다';
  end if;
  if has_function_privilege('anon', 'public.join_group_with_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.join_group_with_invite(text)', 'execute') then
    raise exception '가입 RPC ACL이 올바르지 않습니다';
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
    raise exception '미리 보기 페이로드가 정제 또는 정규화되지 않았습니다';
  end if;
  if (select uses_count from public.invite_codes
      where id = '00000000-0000-4000-8000-00000000b522') <> 0 then
    raise exception '미리 보기가 사용 횟수를 소비했습니다';
  end if;
end;
$$;

select 'invite-links 업그레이드/재적용 검사를 통과했습니다' as result;
SQL

# 계정 삭제는 소유 그룹으로 연쇄 작업하기 전에 auth.users 행 잠금을 얻는다. 소유자
# 취소 RPC가 시작되는 동안 해당 행을 잠시 유지한다. FOR KEY SHARE 우선 순서는
# 기다린 뒤 40P01 교착 상태 없이 완료되어야 한다. 차단 PID는 이 스크립트가 소유하며
# 항상 종료를 기다린다.
printf '인증 사용자/취소 잠금 순서 경합 실행 중\n'
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
    printf '인증 사용자/취소 잠금 순서 경합에서 교착 상태가 발생했습니다\n' >&2
  else
    printf '인증 사용자/취소 잠금 순서 경합에 실패했습니다\n' >&2
  fi
  exit "$race_status"
fi
if printf '%s' "$race_output" | grep -q '40P01'; then
  printf '%s\n' "$race_output" >&2
  printf '인증 사용자/취소 잠금 순서 경합이 40P01을 반환했습니다\n' >&2
  exit 1
fi
printf '인증 사용자/취소 잠금 순서 경합을 통과했습니다\n'

# 로컬 PostgreSQL 설치에 확장이 포함되어 있으면 실제 역할 pgTAP 픽스처를 실행한다.
# 표준 Supabase 스택에는 포함된다. Homebrew 기본 서버에는 pgTAP이 없는 경우가 많으므로
# 위의 스키마/ACL/재적용 검증은 그대로 실행할 수 있게 하고 아래 검증 호환 스텁으로
# 픽스처를 실행한다.
if [[ "$(psql_test -Atqc "select 1 from pg_catalog.pg_available_extensions where name = 'pgtap'")" == "1" ]]; then
  printf '%s 실행 중\n' invite_links.sql
  psql_test -f "$repo_dir/supabase/tests/invite_links.sql" >/dev/null
  printf 'invite-links pgTAP 픽스처를 통과했습니다\n'
else
  # 기본 PostgreSQL 설치에서도 픽스처를 실행할 수 있게 한다. 이 작은 검증 호환
  # 스텁은 같은 역할과 JWT 클레임으로 SQL을 실행한다. 검증 실패 시 보안 검사를
  # 조용히 건너뛰지 않고 예외를 발생시켜 psql을 중단한다. Supabase CI는 위의 실제
  # pgTAP 확장 분기를 사용한다.
  printf 'pgTAP 확장을 사용할 수 없어 invite_links.sql에 검증 스텁을 사용합니다\n'
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

create function public.is(p_actual anyelement, p_expected anyelement, p_description text)
returns text
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'pgTAP is 실패: % (실제 값 %, 기댓값 %)', p_description, p_actual, p_expected;
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

grant execute on function public.no_plan() to public;
grant execute on function public.ok(boolean, text) to public;
grant execute on function public.is(anyelement, anyelement, text) to public;
grant execute on function public.throws_ok(text, text, text, text) to public;
SQL
  sed '/^[[:space:]]*create extension if not exists pgtap;[[:space:]]*$/d' \
    "$repo_dir/supabase/tests/invite_links.sql" | psql_test >/dev/null
  printf 'invite-links 검증 스텁 픽스처를 통과했습니다\n'
fi
