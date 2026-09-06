-- Moduly 데이터베이스 스키마다.
--
-- 이 마이그레이션은 로컬 및 자가 호스팅 Supabase 스택을 포함한 Supabase
-- 프로젝트용이다. 데이터베이스 메타데이터만 바꾸며 개발자 PC의 Docker를
-- 설치, 시작 또는 설정하지 않는다.

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create type public.group_member_role as enum ('owner', 'member');

create or replace function public.is_valid_timezone(value text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select value is not null
     and exists (select 1 from pg_timezone_names where name = value);
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default ''
    check (char_length(display_name) <= 120),
  avatar_url text
    check (avatar_url is null or char_length(avatar_url) <= 2048),
  timezone text not null default 'UTC'
    check (public.is_valid_timezone(timezone)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'One profile per auth.users row. Profile reads are restricted to the user and active co-members.';
comment on column public.profiles.timezone is
  'IANA/Olson timezone name used for display and date-only event entry.';

create table public.groups (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  timezone text not null default 'UTC'
    check (public.is_valid_timezone(timezone)),
  version integer not null default 1 check (version > 0),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (deleted_at is null or deleted_at >= created_at)
);

comment on table public.groups is
  'Planner workspaces. A group owner is also represented by an owner membership row.';
comment on column public.groups.version is
  'Optimistic-lock value. Every update must send the previous value plus one.';
comment on column public.groups.deleted_at is
  'Soft-delete marker; groups are never hard-deleted through the authenticated API.';

create table public.memberships (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.group_member_role not null default 'member',
  is_active boolean not null default true,
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, user_id),
  check ((is_active and removed_at is null) or (not is_active and removed_at is not null))
);

comment on table public.memberships is
  'Current and historical group membership. Only active rows are visible to ordinary members.';

create table public.invite_codes (
  id uuid primary key default extensions.gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict,
  -- 엔트로피가 높은 일회성 토큰의 SHA-256 16진수 다이제스트다. 평문은 저장하지 않는다.
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  max_uses integer not null default 1 check (max_uses between 1 and 100000),
  uses_count integer not null default 0 check (uses_count between 0 and max_uses),
  revoked_at timestamptz,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (token_hash),
  check (expires_at > created_at)
);

comment on table public.invite_codes is
  'Bearer invite metadata. Only the hash is persisted; create_invite_code returns plaintext once.';
comment on column public.invite_codes.uses_count is
  'Incremented while holding the invite row lock in join_group_with_invite.';

create table public.events (
  id uuid primary key default extensions.gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  title text not null check (char_length(btrim(title)) between 1 and 240),
  description text not null default '' check (char_length(description) <= 10000),
  -- 모든 시각은 timestamptz이므로 PostgreSQL이 UTC로 저장한다.
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  -- 이 일정을 표시하거나 편집할 때 사용하는 IANA/Olson 이름이다.
  timezone text not null default 'UTC'
    check (public.is_valid_timezone(timezone)),
  is_all_day boolean not null default false,
  -- 종일 일정에서는 반열린 로컬 날짜 범위 [start, end)다.
  all_day_start date,
  all_day_end date,
  version integer not null default 1 check (version > 0),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (
    (is_all_day and all_day_start is not null and all_day_end is not null and all_day_end > all_day_start)
    or
    (not is_all_day and all_day_start is null and all_day_end is null)
  ),
  check (deleted_at is null or deleted_at >= created_at)
);

comment on table public.events is
  'Planner events. Timed boundaries are UTC instants; all-day events additionally carry an IANA timezone and local date range.';
comment on column public.events.all_day_end is
  'Exclusive end date for an all-day event, so [all_day_start, all_day_end) is unambiguous.';
comment on column public.events.version is
  'Optimistic-lock value. Every update must send the previous value plus one.';
comment on column public.events.deleted_at is
  'Soft-delete marker. Authenticated clients use soft_delete_event_if_version.';

create table public.audit_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  group_id uuid references public.groups(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('insert', 'update', 'soft_delete', 'revoke', 'join')),
  entity_type text not null check (entity_type in ('groups', 'memberships', 'invite_codes', 'events')),
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  'Append-only security/audit trail. Direct writes are denied; table triggers write minimal metadata.';

create table public.invite_join_attempts (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id) on delete cascade,
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  attempted_at timestamptz not null default now(),
  succeeded boolean not null default false,
  reason text not null check (reason in ('joined', 'already_member', 'invalid_or_expired', 'revoked', 'max_uses', 'group_unavailable', 'rate_limited'))
);

comment on table public.invite_join_attempts is
  'Private rate-limit ledger. It stores only a token hash and is writable by the join RPC.';

create index memberships_user_active_idx
  on public.memberships (user_id, group_id)
  where is_active;
create index memberships_group_active_idx
  on public.memberships (group_id, user_id)
  where is_active;
create index events_group_start_idx
  on public.events (group_id, starts_at)
  where deleted_at is null;
create index invite_codes_group_idx
  on public.invite_codes (group_id, created_at desc);
create index invite_join_attempts_actor_time_idx
  on public.invite_join_attempts (actor_id, attempted_at desc);
create index audit_logs_group_time_idx
  on public.audit_logs (group_id, created_at desc);

create or replace function public.enforce_version_increment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.version <> old.version + 1 then
    raise exception using
      errcode = '40001',
      message = format('optimistic version conflict on %s: expected %s', tg_table_name, old.version + 1);
  end if;
  return new;
end;
$$;

create or replace function public.enforce_initial_version()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.version <> 1 then
    raise exception using
      errcode = '22023',
      message = format('%s must start at version 1', tg_table_name);
  end if;
  return new;
end;
$$;

create or replace function public.enforce_group_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if new.owner_id <> old.owner_id then
      raise exception 'group owner_id is immutable';
    end if;
    if old.deleted_at is not null and new.deleted_at is null then
      raise exception 'a deleted group cannot be restored';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_event_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if new.group_id <> old.group_id or new.created_by <> old.created_by then
      raise exception 'event group_id and created_by are immutable';
    end if;
    if old.deleted_at is not null and new.deleted_at is null then
      raise exception 'a deleted event cannot be restored';
    end if;
  end if;

  if new.is_all_day then
    -- UTC 시각을 일정의 IANA 시간대로 다시 변환한다. 두 경계는 로컬
    -- 자정이어야 하며 반열린 날짜 범위와 일치해야 한다.
    if (new.starts_at at time zone new.timezone) <> (new.all_day_start::timestamp)
       or (new.ends_at at time zone new.timezone) <> (new.all_day_end::timestamp) then
      raise exception 'all-day UTC boundaries must be local midnight for the supplied IANA date range';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_invite_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if new.group_id <> old.group_id
       or new.created_by <> old.created_by
       or new.token_hash <> old.token_hash then
      raise exception 'invite ownership and token_hash are immutable';
    end if;
    if new.uses_count < old.uses_count then
      raise exception 'invite uses_count cannot decrease';
    end if;
    if old.revoked_at is not null and new.revoked_at is null then
      raise exception 'a revoked invite cannot be restored';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_membership_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_owner_id uuid;
begin
  if tg_op = 'UPDATE' and (new.group_id <> old.group_id or new.user_id <> old.user_id) then
    raise exception 'membership group_id and user_id are immutable';
  end if;

  select owner_id into v_owner_id from public.groups where id = new.group_id;
  if v_owner_id is null then
    raise exception 'membership group does not exist';
  end if;

  if new.user_id = v_owner_id then
    if new.role <> 'owner' or not new.is_active or new.removed_at is not null then
      raise exception 'the group owner must retain an active owner membership';
    end if;
  elsif new.role = 'owner' then
    raise exception 'only groups.owner_id may have the owner role';
  end if;

  if (new.is_active and new.removed_at is not null)
     or (not new.is_active and new.removed_at is null) then
    raise exception 'is_active and removed_at must agree';
  end if;
  return new;
end;
$$;

create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_group_id uuid;
  v_entity_id uuid;
  v_action text;
  v_version integer;
begin
  if tg_op = 'DELETE' then
    v_entity_id := case when tg_table_name = 'memberships' then old.user_id else old.id end;
    v_group_id := case when tg_table_name = 'groups' then old.id else old.group_id end;
    v_action := 'soft_delete';
  else
    v_entity_id := case when tg_table_name = 'memberships' then new.user_id else new.id end;
    v_group_id := case when tg_table_name = 'groups' then new.id else new.group_id end;
    v_version := case when tg_table_name in ('groups', 'events', 'invite_codes') then new.version else null end;
    if tg_op = 'INSERT' then
      v_action := case when tg_table_name = 'memberships' then 'join' else 'insert' end;
    elsif tg_table_name = 'invite_codes' then
      if new.revoked_at is not null and old.revoked_at is null then
        v_action := 'revoke';
      else
        v_action := 'update';
      end if;
    elsif tg_table_name = 'events' then
      if old.deleted_at is null and new.deleted_at is not null then
        v_action := 'soft_delete';
      else
        v_action := 'update';
      end if;
    else
      v_action := 'update';
    end if;
  end if;

  -- token_hash, 일정 설명 또는 다른 전달자/PII 필드를 감사 행에 넣지
  -- 않는다. 버전과 수명 주기 작업만으로 충분하다.
  insert into public.audit_logs (group_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_group_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    jsonb_build_object('version', v_version)
  );
  return null;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.profiles (id, display_name, timezone)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    coalesce(nullif(new.raw_user_meta_data ->> 'timezone', ''), 'UTC')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.handle_new_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.memberships (group_id, user_id, role, is_active)
  values (new.id, new.owner_id, 'owner', true)
  on conflict (group_id, user_id) do update
    set role = 'owner', is_active = true, removed_at = null, updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.touch_updated_at();

create trigger groups_set_updated_at
before update on public.groups
for each row execute function public.touch_updated_at();
create trigger groups_integrity
before insert or update on public.groups
for each row execute function public.enforce_group_integrity();
create trigger groups_audit
after insert or update on public.groups
for each row execute function public.write_audit_log();
create trigger groups_create_owner_membership
after insert on public.groups
for each row execute function public.handle_new_group();

create trigger memberships_set_updated_at
before update on public.memberships
for each row execute function public.touch_updated_at();
create trigger memberships_integrity
before insert or update on public.memberships
for each row execute function public.enforce_membership_integrity();
create trigger memberships_audit
after insert or update on public.memberships
for each row execute function public.write_audit_log();

create trigger invite_codes_set_updated_at
before update on public.invite_codes
for each row execute function public.touch_updated_at();
create trigger invite_codes_version
before update on public.invite_codes
for each row execute function public.enforce_version_increment();
create trigger invite_codes_integrity
before insert or update on public.invite_codes
for each row execute function public.enforce_invite_integrity();
create trigger invite_codes_audit
after insert or update on public.invite_codes
for each row execute function public.write_audit_log();

create trigger events_set_updated_at
before update on public.events
for each row execute function public.touch_updated_at();
create trigger events_initial_version
before insert on public.events
for each row execute function public.enforce_initial_version();
create trigger events_version
before update on public.events
for each row execute function public.enforce_version_increment();
create trigger events_integrity
before insert or update on public.events
for each row execute function public.enforce_event_integrity();
create trigger events_audit
after insert or update on public.events
for each row execute function public.write_audit_log();

create trigger groups_version
before update on public.groups
for each row execute function public.enforce_version_increment();

create trigger auth_users_create_profile
after insert on auth.users
for each row execute function public.handle_new_user();

commit;
