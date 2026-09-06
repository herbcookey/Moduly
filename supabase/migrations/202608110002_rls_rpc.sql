-- 권한 부여, 행 수준 보안 및 서버 측 작업이다.

begin;

create or replace function public.is_group_owner(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1
       from public.groups g
       where g.id = p_group_id
         and g.owner_id = auth.uid()
         and g.deleted_at is null
     );
$$;

create or replace function public.is_active_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1
       from public.memberships m
       join public.groups g on g.id = m.group_id
       where m.group_id = p_group_id
         and m.user_id = auth.uid()
         and m.is_active
         and m.removed_at is null
         and g.deleted_at is null
     );
$$;

create or replace function public.can_view_profile(
  p_target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (
       p_target_user_id = auth.uid()
       or exists (
         select 1
         from public.memberships mine
         join public.memberships theirs on theirs.group_id = mine.group_id
         join public.groups g on g.id = mine.group_id
         where mine.user_id = auth.uid()
           and theirs.user_id = p_target_user_id
           and mine.is_active
           and mine.removed_at is null
           and theirs.is_active
           and theirs.removed_at is null
           and g.deleted_at is null
       )
     );
$$;

create or replace function public.create_group(
  p_name text,
  p_timezone text default 'UTC'
)
returns public.groups
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'group name must be 1-160 characters';
  end if;
  if not public.is_valid_timezone(coalesce(p_timezone, 'UTC')) then
    raise exception using errcode = '22023', message = 'timezone must be an IANA timezone name';
  end if;

  insert into public.groups (owner_id, name, timezone)
  values (v_user_id, btrim(p_name), coalesce(p_timezone, 'UTC'))
  returning * into v_group;
  return v_group;
end;
$$;

create or replace function public.create_invite_code(
  p_group_id uuid,
  p_expires_at timestamptz,
  p_max_uses integer default 1
)
returns table (
  invite_id uuid,
  token text,
  expires_at timestamptz,
  max_uses integer
)
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text;
  v_token_hash text;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if not public.is_group_owner(p_group_id) then
    raise exception using errcode = '42501', message = 'only the group owner can create invites';
  end if;
  if p_expires_at is null or p_expires_at <= now() then
    raise exception using errcode = '22023', message = 'invite expiration must be in the future';
  end if;
  if p_max_uses is null or p_max_uses not between 1 and 100000 then
    raise exception using errcode = '22023', message = 'max_uses must be between 1 and 100000';
  end if;

  -- 무작위 24바이트(16진수 48자)는 정확히 한 번 반환한다. invite_codes에는
  -- 그 값의 SHA-256 다이제스트만 삽입한다.
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  v_token_hash := encode(extensions.digest(convert_to(v_token, 'utf8'), 'sha256'), 'hex');

  insert into public.invite_codes (group_id, created_by, token_hash, expires_at, max_uses)
  values (p_group_id, v_user_id, v_token_hash, p_expires_at, p_max_uses);
  select i.id, i.expires_at, i.max_uses
    into invite_id, expires_at, max_uses
  from public.invite_codes i
  where i.token_hash = v_token_hash;
  token := v_token;
  return next;
end;
$$;

create or replace function public.join_group_with_invite(p_token text)
returns table (
  group_id uuid,
  membership_id uuid,
  joined boolean,
  reason text
)
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := btrim(coalesce(p_token, ''));
  v_token_hash text;
  v_attempt_id bigint;
  v_attempt_count integer;
  v_invite_id uuid;
  v_invite_group_id uuid;
  v_expires_at timestamptz;
  v_max_uses integer;
  v_uses_count integer;
  v_revoked_at timestamptz;
  v_group_owner uuid;
  v_membership_id uuid;
  v_membership_active boolean;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if char_length(v_token) > 256 then
    v_token := left(v_token, 256);
  end if;
  v_token_hash := encode(extensions.digest(convert_to(v_token, 'utf8'), 'sha256'), 'hex');

  -- 인증된 사용자별 시도를 직렬화한다. 클라이언트가 여러 요청을 동시에
  -- 보내도 이동 창 검사가 유효하게 유지된다.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));
  select count(*)::integer into v_attempt_count
  from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at > now() - interval '1 hour';

  if v_attempt_count >= 20 then
    insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
    values (v_user_id, v_token_hash, false, 'rate_limited')
    returning id into v_attempt_id;
    return query select null::uuid, null::uuid, false, 'rate_limited'::text;
    return;
  end if;

  insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
  values (v_user_id, v_token_hash, false, 'invalid_or_expired')
  returning id into v_attempt_id;

  -- 초대 행 잠금으로 uses_count/max_uses 갱신과 멤버십 upsert를 원자적으로
  -- 처리한다. 어떤 호출자도 마지막 사용 횟수를 두고 경쟁할 수 없다.
  select i.id, i.group_id, i.expires_at, i.max_uses, i.uses_count, i.revoked_at
    into v_invite_id, v_invite_group_id, v_expires_at, v_max_uses, v_uses_count, v_revoked_at
  from public.invite_codes i
  where i.token_hash = v_token_hash
  for update;

  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_revoked_at is not null then
    update public.invite_join_attempts
      set reason = 'revoked'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_expires_at <= now() then
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

  select g.owner_id into v_group_owner
  from public.groups g
  where g.id = v_invite_group_id
    and g.deleted_at is null
  for share;
  if not found then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  select m.user_id, m.is_active
    into v_membership_id, v_membership_active
  from public.memberships m
  where m.group_id = v_invite_group_id
    and m.user_id = v_user_id
  for update;

  if found and v_membership_active then
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  -- 일정방 트리거로 소유자는 이미 멤버다. 오래된 데이터베이스가 일관되지
  -- 않을 때 초대를 소모하지 않고 누락된 소유자 행을 복구한다.
  if v_group_owner = v_user_id then
    insert into public.memberships (group_id, user_id, role, is_active, removed_at)
    values (v_invite_group_id, v_user_id, 'owner', true, null)
    on conflict (group_id, user_id) do update
      set role = 'owner', is_active = true, removed_at = null, updated_at = now()
    returning user_id into v_membership_id;
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if found then
    update public.memberships
      set role = 'member', is_active = true, removed_at = null, joined_at = now()
      where group_id = v_invite_group_id and user_id = v_user_id
      returning user_id into v_membership_id;
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

create or replace function public.soft_delete_event_if_version(
  p_event_id uuid,
  p_expected_version integer
)
returns public.events
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_event public.events;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  update public.events
  set deleted_at = now(), version = version + 1
  where id = p_event_id
    and created_by = v_user_id
    and deleted_at is null
    and public.is_active_member(group_id)
    and version = p_expected_version
  returning * into v_event;
  if not found then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours';
  end if;
  return v_event;
end;
$$;

create or replace function public.archive_group_if_version(
  p_group_id uuid,
  p_expected_version integer
)
returns public.groups
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  update public.groups
  set deleted_at = now(), version = version + 1
  where id = p_group_id
    and owner_id = v_user_id
    and deleted_at is null
    and version = p_expected_version
  returning * into v_group;
  if not found then
    raise exception using errcode = '40001', message = 'group was changed, archived, or is not yours';
  end if;
  return v_group;
end;
$$;

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
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_invite public.invite_codes;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  update public.invite_codes i
  set revoked_at = coalesce(i.revoked_at, now()), version = i.version + 1
  where i.id = p_invite_id
    and i.created_by = v_user_id
    and public.is_group_owner(i.group_id)
    and i.version = p_expected_version
  returning i.* into v_invite;
  if not found then
    raise exception using errcode = '40001', message = 'invite was changed, revoked, or is not yours';
  end if;
  return query
  select v_invite.id, v_invite.group_id, v_invite.expires_at,
         v_invite.max_uses, v_invite.uses_count, v_invite.revoked_at,
         v_invite.version, v_invite.created_at, v_invite.updated_at;
end;
$$;

create or replace function public.set_member_active(
  p_group_id uuid,
  p_user_id uuid,
  p_is_active boolean
)
returns public.memberships
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor_id uuid := auth.uid();
  v_membership public.memberships;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_user_id = v_actor_id or not public.is_group_owner(p_group_id) then
    raise exception using errcode = '42501', message = 'only the owner can change another member';
  end if;

  update public.memberships
  set is_active = p_is_active,
      removed_at = case when p_is_active then null else coalesce(removed_at, now()) end
  where group_id = p_group_id
    and user_id = p_user_id
    and role = 'member'
  returning * into v_membership;
  if not found then
    raise exception using errcode = '22023', message = 'member does not exist';
  end if;
  return v_membership;
end;
$$;

-- 외부에 노출된 모든 테이블에 RLS를 적용한다. invite_join_attempts에는
-- 인증 정책이 없으므로 정의자 RPC만 쓰고 읽을 수 있다.
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.memberships enable row level security;
alter table public.invite_codes enable row level security;
alter table public.events enable row level security;
alter table public.audit_logs enable row level security;
alter table public.invite_join_attempts enable row level security;

create policy profiles_select on public.profiles
for select to authenticated
using (id = auth.uid() or public.can_view_profile(id));
create policy profiles_insert on public.profiles
for insert to authenticated
with check (id = auth.uid());
create policy profiles_update on public.profiles
for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy groups_select on public.groups
for select to authenticated
using (
  deleted_at is null
  and (owner_id = auth.uid() or public.is_active_member(id))
);
create policy groups_insert on public.groups
for insert to authenticated
with check (owner_id = auth.uid() and deleted_at is null);
create policy groups_update on public.groups
for update to authenticated
using (owner_id = auth.uid() and deleted_at is null)
with check (owner_id = auth.uid() and deleted_at is null);

create policy memberships_select on public.memberships
for select to authenticated
using (
  public.is_group_owner(group_id)
  or (is_active and public.is_active_member(group_id))
);
create policy memberships_update on public.memberships
for update to authenticated
using (public.is_group_owner(group_id) and role = 'member')
with check (public.is_group_owner(group_id) and role = 'member');

create policy invite_codes_select on public.invite_codes
for select to authenticated
using (public.is_group_owner(group_id));
create policy invite_codes_update on public.invite_codes
for update to authenticated
using (public.is_group_owner(group_id))
with check (public.is_group_owner(group_id));

create policy events_select on public.events
for select to authenticated
using (deleted_at is null and public.is_active_member(group_id));
create policy events_insert on public.events
for insert to authenticated
with check (
  created_by = auth.uid()
  and deleted_at is null
  and public.is_active_member(group_id)
);
create policy events_update on public.events
for update to authenticated
using (
  created_by = auth.uid()
  and deleted_at is null
  and public.is_active_member(group_id)
)
with check (
  created_by = auth.uid()
  and deleted_at is null
  and public.is_active_member(group_id)
);

create policy audit_logs_select on public.audit_logs
for select to authenticated
using (
  public.is_group_owner(group_id)
  or (
    actor_id = auth.uid()
    and (group_id is null or public.is_active_member(group_id))
  )
);

-- 이후 마이그레이션에서 실수로 테이블 권한을 추가해도 속도 제한 원장은
-- 비공개로 유지한다. SECURITY DEFINER join RPC만 기록할 수 있다.
create policy invite_join_attempts_deny on public.invite_join_attempts
for all to authenticated
using (false)
with check (false);

-- 테이블 권한을 처음에는 부여하지 않고 Flutter 앱에 필요한 열만 허용한다.
-- PostgreSQL 열 권한으로 클라이언트가 소유권, 토큰 해시, 사용 횟수 또는
-- 감사 기록을 변경하지 못하게 한다.
revoke all on table public.profiles, public.groups, public.memberships,
  public.invite_codes, public.events, public.audit_logs,
  public.invite_join_attempts from anon, authenticated;

grant select on public.profiles to authenticated;
grant insert (id, display_name, avatar_url, timezone) on public.profiles to authenticated;
grant update (display_name, avatar_url, timezone) on public.profiles to authenticated;

grant select on public.groups to authenticated;
grant insert (owner_id, name, timezone) on public.groups to authenticated;
grant update (name, timezone, version) on public.groups to authenticated;

grant select on public.memberships to authenticated;
grant update (is_active, removed_at) on public.memberships to authenticated;

grant select (
  id, group_id, created_by, expires_at, max_uses, uses_count,
  revoked_at, version, created_at, updated_at
) on public.invite_codes to authenticated;
grant update (expires_at, max_uses, revoked_at, version) on public.invite_codes to authenticated;

grant select on public.events to authenticated;
grant insert (group_id, created_by, title, description, starts_at, ends_at, timezone,
              is_all_day, all_day_start, all_day_end, version) on public.events to authenticated;
grant update (title, description, starts_at, ends_at, timezone, is_all_day,
              all_day_start, all_day_end, version) on public.events to authenticated;

grant select on public.audit_logs to authenticated;

-- RLS 정책은 호출자 권한으로 이 도우미를 평가하므로 authenticated에
-- 실행 권한이 필요하다. 익명 호출자에게는 도우미나 RPC 실행 권한을 주지 않는다.
revoke execute on function public.is_valid_timezone(text) from public;
grant execute on function public.is_valid_timezone(text) to authenticated;
revoke execute on function public.is_group_owner(uuid) from public;
grant execute on function public.is_group_owner(uuid) to authenticated;
revoke execute on function public.is_active_member(uuid) from public;
grant execute on function public.is_active_member(uuid) to authenticated;
revoke execute on function public.can_view_profile(uuid) from public;
grant execute on function public.can_view_profile(uuid) to authenticated;

revoke execute on function public.create_group(text, text) from public;
grant execute on function public.create_group(text, text) to authenticated;
revoke execute on function public.create_invite_code(uuid, timestamptz, integer) from public;
grant execute on function public.create_invite_code(uuid, timestamptz, integer) to authenticated;
revoke execute on function public.join_group_with_invite(text) from public;
grant execute on function public.join_group_with_invite(text) to authenticated;
revoke execute on function public.soft_delete_event_if_version(uuid, integer) from public;
grant execute on function public.soft_delete_event_if_version(uuid, integer) to authenticated;
revoke execute on function public.archive_group_if_version(uuid, integer) from public;
grant execute on function public.archive_group_if_version(uuid, integer) to authenticated;
revoke execute on function public.revoke_invite_code(uuid, integer) from public;
grant execute on function public.revoke_invite_code(uuid, integer) to authenticated;
revoke execute on function public.set_member_active(uuid, uuid, boolean) from public;
grant execute on function public.set_member_active(uuid, uuid, boolean) to authenticated;

-- Supabase Realtime 서비스가 `.stream()` 클라이언트를 위해 이 publication을
-- 사용한다. 가드를 두어 일반 PostgreSQL 테스트 데이터베이스에서도
-- 마이그레이션이 동작하게 하며, 표준 자가 호스팅 Supabase 스택은 이미 이를 만든다.
do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'events'
     ) then
    execute 'alter publication supabase_realtime add table public.events';
  end if;
end;
$$;

commit;
