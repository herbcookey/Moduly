-- 인증된 초대 링크 미리 보기 및 수락 보강이다.
--
-- 이 마이그레이션은 기존 기능에 추가만 한다. 기존 invite_codes 행은 이전 48자
-- 16진수 코드를 포함한 SHA-256 다이제스트를 유지하며, 평문 Bearer 값은 기존
-- 데이터에 채우거나 새로 쓰지 않는다. 미리 보기는 의도적으로 인증된 작업으로
-- 두어 로그아웃 상태의 딥 링크가 그룹 메타데이터를 요청하기 전에 애플리케이션
-- 로그인 흐름을 거치게 한다.

begin;

-- 미리 보기 제한 원장은 의도적으로 가입 원장보다 작다. 토큰, 다이제스트, 그룹,
-- 결과 열은 없으며 요청자/타임스탬프만 요청 메타데이터로 보존한다. 복합 키를
-- 사용해 의도치 않은 연관 분석 수단이 될 수 있는 대체 식별자도 추가하지 않는다.
create table if not exists public.invite_preview_attempts (
  actor_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, attempted_at)
);

comment on table public.invite_preview_attempts is
  '비공개 미리 보기 속도 제한 원장이다. actor_id와 attempted_at만 저장하며 토큰이나 다이제스트는 보존하지 않는다.';
comment on column public.invite_preview_attempts.actor_id is
  '미리 보기 요청을 수행한 인증된 호출자다.';
comment on column public.invite_preview_attempts.attempted_at is
  '실제 미리 보기 시도의 벽시계 시각으로, 이동형 한 시간 제한에 사용한다.';

create index if not exists invite_preview_attempts_actor_time_idx
  on public.invite_preview_attempts (actor_id, attempted_at desc);
create index if not exists invite_preview_attempts_time_idx
  on public.invite_preview_attempts (attempted_at);

-- 이전 가입 원장에는 이동 창 검사용 요청자/시간 인덱스가 이미 있다. 범위가 제한된
-- 전체 오래된 행 정리가 모든 요청자의 이력을 스캔하지 않도록 타임스탬프 전용
-- 인덱스를 하나 더 둔다.
create index if not exists invite_join_attempts_time_idx
  on public.invite_join_attempts (attempted_at);

alter table public.invite_preview_attempts enable row level security;

-- 이후 마이그레이션이 실수로 테이블 권한을 복원해도 테이블을 비공개로 유지한다.
-- SECURITY DEFINER 미리 보기 RPC는 마이그레이션 역할이 소유하므로 원장을 계속
-- 관리할 수 있다.
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_policy p
    where p.polname = 'invite_preview_attempts_deny'
      and p.polrelid = 'public.invite_preview_attempts'::regclass
  ) then
    execute 'create policy invite_preview_attempts_deny on public.invite_preview_attempts for all to authenticated using (false) with check (false)';
  end if;
end;
$$;

revoke all on table public.invite_preview_attempts from public, anon, authenticated;

-- 서버에서도 lib/core/invite_code_utils.dart와 맞춘다. 구분자는 표시용일 뿐이다.
-- 짧은 코드는 사람이 읽는 문자 집합의 대문자로 정규화하고 이전 48자 16진수 값은
-- 소문자로 정규화한다. NULL은 입력이 비었거나 너무 길거나 잘못된 형식임을 뜻한다.
-- 호출자는 어느 검증 분기가 실패했는지 노출하지 않고 안전한 종료 결과 하나를 반환한다.
create or replace function public._canonicalize_invite_token(p_token text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_raw text;
  v_compact text;
  v_short_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
begin
  -- 정규화 전과 후에 모두 거부한다. 매우 큰 값이 들어왔을 때 공격자가 제어하는
  -- 접두사를 조용히 허용하는 일을 막는다.
  if p_token is null
     or pg_catalog.octet_length(p_token) > 256 then
    return null;
  end if;

  v_raw := pg_catalog.btrim(p_token);
  if pg_catalog.char_length(v_raw) = 0
     or pg_catalog.char_length(v_raw) > 256
     or pg_catalog.octet_length(v_raw) > 256 then
    return null;
  end if;

  v_compact := pg_catalog.regexp_replace(v_raw, '[[:space:]-]+', '', 'g');
  if pg_catalog.char_length(v_compact) = 0
     or pg_catalog.char_length(v_compact) > 256 then
    return null;
  end if;

  if v_compact ~ '^[0-9a-fA-F]{48}$' then
    return pg_catalog.lower(v_compact);
  end if;

  if pg_catalog.char_length(v_compact) = 12
     and pg_catalog.upper(v_compact) ~ ('^[' || v_short_alphabet || ']{12}$') then
    return pg_catalog.upper(v_compact);
  end if;

  return null;
end;
$$;

comment on function public._canonicalize_invite_token(text) is
  '서버 측 비공개 초대 정규화 함수다. 형식이 잘못되었거나 너무 긴 입력에는 NULL을 반환한다.';

-- 미리 보기는 최소 확인 필드만 노출한다. anon 실행 권한이 없고 토큰/해시를
-- 기록하지 않는다. 운영 중이 아닌 모든 상태는 그룹 없음 응답을 똑같이 사용하므로
-- 호출자가 숨겨진 그룹의 존재 여부를 탐색할 수 없다.
create or replace function public.preview_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_token text;
  v_token_hash text;
  v_attempt_count integer;
  v_invite_group_id uuid;
  v_group_name text;
  v_group_description text;
  v_group_timezone text;
  v_expires_at timestamptz;
  v_revoked_at timestamptz;
  v_uses_count integer;
  v_max_uses integer;
  v_already_member boolean;
  v_invalid_token_sentinel constant text := 'invalid-invite-token-sentinel';
begin
  if v_user_id is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using
      errcode = '28000',
      message = 'authentication is required';
  end if;

  -- 개수를 세기 전에 이 요청자의 이동 창을 직렬화하고 정리한다. 이미 한도에
  -- 도달한 요청은 행을 더 삽입하지 않으므로 반복해서 차단된 탐색이 자체 잠금
  -- 시간을 늘릴 수 없다.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  delete from public.invite_preview_attempts
  where actor_id = v_user_id
    and attempted_at <= pg_catalog.now() - interval '1 hour';

  -- 범위를 제한한 기회적 정리는 비활성 요청자의 행이 끝없이 늘어나는 것을 막는다.
  -- SKIP LOCKED는 동시 미리 보기 호출자의 동작을 결정적으로 만들고 각 호출을 작은
  -- ctid 묶음으로 제한한다.
  with stale as (
    select p.ctid
    from public.invite_preview_attempts p
    where p.attempted_at <= pg_catalog.now() - interval '1 hour'
    order by p.attempted_at, p.ctid
    for update skip locked
    limit 100
  )
  delete from public.invite_preview_attempts p
  using stale
  where p.ctid = stale.ctid;

  select count(*)::integer
    into v_attempt_count
  from public.invite_preview_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

  if v_attempt_count >= 60 then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'rate_limited'
    );
  end if;

  insert into public.invite_preview_attempts (actor_id, attempted_at)
  values (v_user_id, pg_catalog.clock_timestamp());

  v_token := public._canonicalize_invite_token(p_token);
  v_token_hash := encode(
    extensions.digest(
      pg_catalog.convert_to(coalesce(v_token, v_invalid_token_sentinel), 'utf8'),
      'sha256'
    ),
    'hex'
  );

  -- 위의 고정 표식은 잘못된 입력의 범위를 제한하고 공격자가 만든 임의 문자열을
  -- 보존하거나 다이제스트로 만들지 못하게 한다. 잘못된 값은 실제 초대 다이제스트와
  -- 일치할 수 없으므로 그룹을 조회하기 전에 동일한 종료 결과를 반환한다.
  if v_token is null then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  select i.group_id, g.name, g.description, g.timezone, i.expires_at,
         i.revoked_at, i.uses_count, i.max_uses,
         exists (
           select 1
           from public.memberships m
           where m.group_id = g.id
             and m.user_id = v_user_id
             and m.is_active
             and m.removed_at is null
         )
    into v_invite_group_id, v_group_name, v_group_description,
         v_group_timezone, v_expires_at, v_revoked_at, v_uses_count,
         v_max_uses, v_already_member
  from public.invite_codes i
  join public.groups g on g.id = i.group_id
  where i.token_hash = v_token_hash
    and g.deleted_at is null
  limit 1;

  if not found then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  -- 이미 활성 멤버인 호출자는 이전에 유효했던 토큰이 만료되거나 취소되거나
  -- max_uses에 도달한 뒤에도 안전하게 재시도할 수 있다. 멤버십 여부는 정확한
  -- 토큰/그룹 일치 뒤에만 노출하며 외부 사용자는 계속 아래와 같은 그룹 없음
  -- 종료 응답을 받는다.
  if not v_already_member
     and (
       v_revoked_at is not null
       or v_expires_at <= pg_catalog.now()
       or v_uses_count >= v_max_uses
     ) then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'valid', true,
    'group_id', v_invite_group_id,
    'group_name', v_group_name,
    'group_description', v_group_description,
    'group_timezone', v_group_timezone,
    'expires_at', v_expires_at,
    'already_member', v_already_member
  );
end;
$$;

-- 기존 PostgREST 시그니처나 행 형태를 바꾸지 않고 수락을 교체한다. 해시 전에
-- 정규화하고 너무 긴 입력은 조용히 자르지 않고 거부한다. 따라서 이전 48자
-- 다이제스트 행은 계속 유효하며 새로 발급한 12자 코드는 클라이언트와 같은
-- 구분자/대소문자 변형을 허용한다.
create or replace function public.join_group_with_invite(p_token text)
returns table (
  group_id uuid,
  membership_id uuid,
  joined boolean,
  reason text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_token text;
  v_token_hash text;
  v_attempt_id bigint;
  v_attempt_count integer;
  v_invite_id uuid;
  v_invite_group_id uuid;
  v_expires_at timestamptz;
  v_max_uses integer;
  v_uses_count integer;
  v_revoked_at timestamptz;
  v_group public.groups;
  v_group_owner uuid;
  v_membership_id uuid;
  v_membership_active boolean;
  v_invalid_token_sentinel constant text := 'invalid-invite-token-sentinel';
begin
  if v_user_id is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- 요청자 잠금은 정리, 개수 계산 및 실제 시도 원장 행을 모두 포함한다. 차단된
  -- 요청은 행을 삽입하지 않고 반환하여 공격자가 이동 창을 무한히 늘리지 못하게 한다.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  delete from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at <= pg_catalog.now() - interval '1 hour';

  select count(*)::integer
    into v_attempt_count
  from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

  -- 각 호출의 전체 정리 작업 범위를 제한한다. SKIP LOCKED를 사용하면 서로 다른
  -- 요청자의 호출자가 잠금 순환을 만들지 않고 오래된 행을 정리할 수 있다.
  with stale as (
    select a.ctid
    from public.invite_join_attempts a
    where a.attempted_at <= pg_catalog.now() - interval '1 hour'
    order by a.attempted_at, a.ctid
    for update skip locked
    limit 100
  )
  delete from public.invite_join_attempts a
  using stale
  where a.ctid = stale.ctid;

  if v_attempt_count >= 20 then
    return query select null::uuid, null::uuid, false, 'rate_limited'::text;
    return;
  end if;

  v_token := public._canonicalize_invite_token(p_token);
  v_token_hash := encode(
    extensions.digest(
      pg_catalog.convert_to(coalesce(v_token, v_invalid_token_sentinel), 'utf8'),
      'sha256'
    ),
    'hex'
  );

  -- 잘못된 입력을 포함한 모든 실제 시도에 다이제스트를 저장한다. Bearer 값 자체를
  -- 보존하지 않으면서 기존 비공개 원장 계약을 유지한다.
  insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
  values (v_user_id, v_token_hash, false, 'invalid_or_expired')
  returning id into v_attempt_id;

  if v_token is null then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  -- 그룹 잠금 대상을 정하기 위해서만 잠금 없이 상위 ID를 읽는다. 초대와 멤버십을
  -- 쓰기 전에 잠긴 그룹을 다시 확인한다.
  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.token_hash = v_token_hash;
  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  -- 그룹 우선 잠금 순서는 생성/취소/보관/이전과 공유하며 수명 주기 쓰기가 초대
  -- 사용 횟수 소비와 경합하는 것을 막는다.
  select i.id, i.group_id, i.expires_at, i.max_uses, i.uses_count, i.revoked_at
    into v_invite_id, v_invite_group_id, v_expires_at, v_max_uses, v_uses_count, v_revoked_at
  from public.invite_codes i
  where i.token_hash = v_token_hash
  for update;

  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_invite_group_id <> v_group.id then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_group.deleted_at is not null then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  v_group_owner := v_group.owner_id;
  select m.user_id, m.is_active
    into v_membership_id, v_membership_active
  from public.memberships m
  where m.group_id = v_invite_group_id
    and m.user_id = v_user_id
  for update;

  -- 활성 멤버는 토큰 수명 주기가 종료 상태에 도달한 뒤에도 안전하게 재시도할 수
  -- 있다. 위의 정확한 토큰/그룹 일치 및 운영 그룹 검사는 이 분기가 외부 사용자에게
  -- 멤버십을 노출하지 못하게 한다.
  if found and v_membership_active then
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if v_revoked_at is not null then
    update public.invite_join_attempts
      set reason = 'revoked'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_expires_at <= pg_catalog.now() then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_uses_count >= v_max_uses then
    update public.invite_join_attempts
      set reason = 'max_uses'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_group.deleted_at is not null then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  if v_group_owner = v_user_id then
    insert into public.memberships (group_id, user_id, role, is_active, removed_at)
    values (v_invite_group_id, v_user_id, 'owner', true, null)
    on conflict (group_id, user_id) do update
      set role = 'owner', is_active = true, removed_at = null,
          updated_at = pg_catalog.now()
    returning user_id into v_membership_id;
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if found then
    update public.memberships as m
      set role = 'member', is_active = true, removed_at = null,
          joined_at = pg_catalog.now()
      where m.group_id = v_invite_group_id
        and m.user_id = v_user_id
      returning m.user_id into v_membership_id;
  else
    insert into public.memberships (group_id, user_id, role, is_active, invited_by)
    values (v_invite_group_id, v_user_id, 'member', true, v_group_owner)
    returning user_id into v_membership_id;
  end if;

  update public.invite_codes
    set uses_count = uses_count + 1,
        version = version + 1
  where id = v_invite_id;
  update public.invite_join_attempts
    set succeeded = true, reason = 'joined'
    where id = v_attempt_id;

  return query select v_invite_group_id, v_membership_id, true, 'joined'::text;
end;
$$;

-- 과거 작성자가 아닌 현재 활성 그룹 소유자가 취소한다. 같은 낙관적 버전 및 일반
-- 충돌 응답을 유지하면서 소유권 이전 의미를 올바르게 보존한다.
create or replace function public.revoke_invite_code(
  p_invite_id uuid,
  p_expected_version integer
)
returns table (
  invite_id uuid,
  group_id uuid,
  expires_at timestamptz,
  max_uses integer,
  uses_count integer,
  revoked_at timestamptz,
  version integer,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_actor_row auth.users;
  v_invite_group_id uuid;
  v_group public.groups;
  v_invite public.invite_codes;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- 계정 삭제는 연쇄 그룹 행보다 auth.users를 먼저 잠근다. 호환되는 키 공유 잠금을
  -- 먼저 얻어 동시 취소가 삭제와 순서가 교차하는 교착 상태를 만들지 않고 요청자
  -- 행에서 기다리게 한다.
  select u.*
    into v_actor_row
  from auth.users u
  where u.id = v_user_id
  for key share;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.id = p_invite_id;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  select i.*
    into v_invite
  from public.invite_codes i
  where i.id = p_invite_id
  for update;
  if not found
     or v_invite.group_id <> v_group.id
     or p_expected_version is null
     or v_invite.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  -- 취소는 종료 상태다. 현재 종료 버전으로 재시도하면 일반 충돌이며 버전을 올리거나
  -- 감사 행을 또 출력해서는 안 된다.
  if v_invite.revoked_at is not null then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  update public.invite_codes i
  set revoked_at = pg_catalog.now(),
      version = i.version + 1
  where i.id = p_invite_id
    and i.version = p_expected_version
  returning i.* into v_invite;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  return query
  select v_invite.id, v_invite.group_id, v_invite.expires_at,
         v_invite.max_uses, v_invite.uses_count, v_invite.revoked_at,
         v_invite.version, v_invite.created_at, v_invite.updated_at;
end;
$$;

-- PostgreSQL은 새 함수에 기본적으로 PUBLIC EXECUTE 권한을 준다. 도우미는 비공개로
-- 유지하고 미리 보기는 인증된 호출자에게만 노출하며, 업그레이드된 배포에서는
-- 변경되지 않은 기존 초대 RPC ACL을 명시적으로 재설정한다.
revoke execute on function public._canonicalize_invite_token(text)
  from public, anon, authenticated;
revoke execute on function public.preview_invite(text)
  from public, anon, authenticated;
grant execute on function public.preview_invite(text) to authenticated;

revoke execute on function public.create_invite_code(uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.create_invite_code(uuid, timestamptz, integer)
  to authenticated;
revoke execute on function public.join_group_with_invite(text)
  from public, anon, authenticated;
grant execute on function public.join_group_with_invite(text) to authenticated;
revoke execute on function public.revoke_invite_code(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.revoke_invite_code(uuid, integer) to authenticated;

-- 소유자 승인 RPC만 초대를 변경할 수 있는 경로다. 신규 및 업그레이드된 DB 모두에서
-- 기존 202608110002 열 권한을 제거해야 한다.
revoke update on table public.invite_codes from public, anon, authenticated;
revoke update (expires_at, max_uses, revoked_at, version)
  on public.invite_codes from public, anon, authenticated;

commit;
