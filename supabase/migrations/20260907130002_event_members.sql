-- 일정 참여자 할당이다. 이 마이그레이션은 기존 기능에 추가만 하며 기존
-- events.member/creator 계약을 유지하면서 할당을 보호하고 조회하고 원자적으로
-- 교체할 수 있는 일반 관계로 만든다.

begin;

create table if not exists public.event_members (
  event_id uuid not null
    references public.events(id) on delete cascade,
  user_id uuid not null
    references auth.users(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (event_id, user_id)
);

comment on table public.event_members is
  '현재 참여자 할당이다. 보관/소프트 삭제된 일정의 행은 연쇄 작업/이력을 위해 남을 수 있지만 RLS가 숨긴다.';
comment on column public.event_members.created_at is
  '할당 생성 시각이다. 작성자 기존 데이터 채우기에는 일정 생성 시각을 사용한다.';

-- 목록 조회를 위해 기본 키는 일정을 선두에 둔다. 두 번째 인덱스는 계정 삭제,
-- 사용자 범위 정리 및 정책 조인이 전체 하위 테이블을 스캔하지 않게 한다.
create index if not exists event_members_user_event_idx
  on public.event_members (user_id, event_id);

-- 무결성/전환 트리거를 추가하기 전에 기존 데이터를 채운다. 그룹/일정이 종료
-- 상태이거나 작성자가 현재 비활성이어도 과거 일정은 의도적으로 포함한다. RLS가
-- 해당 행을 숨기고 이후 비활성화가 현재 할당을 정리한다. 일반적인 마이그레이션
-- 재적용에서 수명 주기 정리가 의도적으로 제거한 작성자 할당을 복원해서는 안 된다.
-- 따라서 트리거를 삭제/재생성하기 전에 설치 완료 표식을 확인해 기존 데이터
-- 채우기를 보호한다. 표식은 조작 가능한 행/데이터 조건자가 아니라 이 기능의 기존
-- events AFTER INSERT 트리거와 하위 테이블 객체다. 최초 실행이나 복구 가능한 부분
-- 설치(해당 트리거 없는 테이블)에서는 과거 데이터 채우기를 계속 수행한다.
do $$
declare
  v_feature_installed boolean;
begin
  select exists (
    select 1
    from pg_catalog.pg_class events_table
    join pg_catalog.pg_namespace events_schema
      on events_schema.oid = events_table.relnamespace
    join pg_catalog.pg_trigger trigger_row
      on trigger_row.tgrelid = events_table.oid
    join pg_catalog.pg_proc trigger_proc
      on trigger_proc.oid = trigger_row.tgfoid
    join pg_catalog.pg_namespace proc_schema
      on proc_schema.oid = trigger_proc.pronamespace
    where events_schema.nspname = 'public'
      and events_table.relname = 'events'
      and trigger_row.tgname = 'events_seed_creator_member'
      and not trigger_row.tgisinternal
      and proc_schema.nspname = 'public'
      and trigger_proc.proname = 'seed_event_creator_member'
      and trigger_proc.pronargs = 0
      and trigger_proc.prorettype = 'pg_catalog.trigger'::regtype
      and pg_catalog.pg_get_triggerdef(trigger_row.oid) ilike '%after insert%'
      and exists (
        select 1
        from pg_catalog.pg_class members_table
        join pg_catalog.pg_namespace members_schema
          on members_schema.oid = members_table.relnamespace
        where members_schema.nspname = 'public'
          and members_table.relname = 'event_members'
          and members_table.relkind = 'r'
      )
  ) into v_feature_installed;

  if not v_feature_installed then
    insert into public.event_members (event_id, user_id, created_at)
    select e.id, e.created_by, e.created_at
    from public.events e
    where not exists (
      select 1
      from public.event_members existing
      where existing.event_id = e.id
        and existing.user_id = e.created_by
    );
  end if;
end;
$$;

alter table public.event_members enable row level security;

drop policy if exists event_members_select on public.event_members;
drop policy if exists event_members_write_deny on public.event_members;

create policy event_members_select
on public.event_members
for select to authenticated
using (
  (select auth.uid()) is not null
  and exists (
    select 1
    from public.events e
    join public.groups g on g.id = e.group_id
    where e.id = event_members.event_id
      and e.deleted_at is null
      and g.deleted_at is null
      and public.is_active_member(e.group_id)
      and exists (
        select 1
        from public.memberships target
        where target.group_id = e.group_id
          and target.user_id = event_members.user_id
          and target.is_active
          and target.removed_at is null
      )
  )
);

-- RLS는 심층 방어 역할을 한다. 아래 ACL도 클라이언트가 직접 하위 INSERT/UPDATE/
-- DELETE 문으로 교체 RPC를 우회하지 못하게 한다.
create policy event_members_write_deny
on public.event_members
for all to authenticated
using (false)
with check (false);

revoke all on table public.event_members from public, anon, authenticated;
grant select on table public.event_members to authenticated;

-- 하위 테이블은 의도적으로 supabase_realtime에 추가하지 않는다. Realtime DELETE
-- 페이로드 권한 검사로는 삭제된 행에 대한 접근을 확인할 수 없어 하위 publication이
-- 일정/사용자 UUID를 노출할 수 있다. 대신 하위 전환 트리거가 이미 게시되었고 RLS
-- 정책이 설정된 상위 일정 행의 버전을 올린다.

-- 트리거 전용 도우미다. INSERT 전환 행은 RPC, 설정 또는 인증 사용자 연쇄 작업에서
-- 올 수 있다. 내부 변경자는 하위 행을 바꾸는 동안 트랜잭션 로컬 표시를 설정하고
-- 이후 명시적으로 events 버전을 한 번 올린다.
create or replace function public.bump_events_from_event_members_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('moduly.event_members_mutation_context', true) = 'internal' then
    return null;
  end if;

  -- 영향을 받는 모든 상위 그룹을 결정적인 순서로 먼저 잠근다. 모든 그룹 범위
  -- RPC와 순서를 맞추고 일정->그룹 교착 상태를 피한다.
  perform 1
  from public.groups g
  join public.events e on e.group_id = g.id
  join (
    select distinct event_id
    from new_rows
  ) changed on changed.event_id = e.id
  where g.deleted_at is null
    and e.deleted_at is null
  order by g.id, e.id
  for update of g;

  update public.events e
  set version = e.version + 1
  where e.id in (select distinct event_id from new_rows)
    and e.deleted_at is null
    and exists (
      select 1
      from public.groups g
      where g.id = e.group_id
        and g.deleted_at is null
    );
  return null;
end;
$$;

create or replace function public.bump_events_from_event_members_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('moduly.event_members_mutation_context', true) = 'internal' then
    return null;
  end if;

  perform 1
  from public.groups g
  join public.events e on e.group_id = g.id
  join (
    select distinct event_id
    from old_rows
  ) changed on changed.event_id = e.id
  where g.deleted_at is null
    and e.deleted_at is null
  order by g.id, e.id
  for update of g;

  update public.events e
  set version = e.version + 1
  where e.id in (select distinct event_id from old_rows)
    and e.deleted_at is null
    and exists (
      select 1
      from public.groups g
      where g.id = e.group_id
        and g.deleted_at is null
    );
  return null;
end;
$$;

-- 할당 쓰기는 RPC 전용이지만, 이 트리거는 권한 있는 설정 경로도 교차 그룹/비활성
-- 행으로부터 보호한다. 과거 데이터 채우기 뒤에 설치하여 이전의 비활성 작성자 행을
-- 계속 보존한다.
create or replace function public.enforce_event_member_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_group public.groups;
  v_membership public.memberships;
begin
  if tg_op = 'UPDATE'
     and (new.event_id <> old.event_id or new.user_id <> old.user_id) then
    raise exception using
      errcode = '22023',
      message = 'event member identity is immutable';
  end if;

  select e.*
    into v_event
  from public.events e
  where e.id = new.event_id;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or unavailable';
  end if;

  -- 멤버십 상태를 확인하기 전에 항상 상위 그룹을 잠근다.
  select g.*
    into v_group
  from public.groups g
  where g.id = v_event.group_id
  for update;
  if not found or v_group.deleted_at is not null or v_event.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'event group was archived or is unavailable';
  end if;

  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = v_event.group_id
    and m.user_id = new.user_id
  for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using
      errcode = '42501',
      message = 'event members must be active members of the event group';
  end if;
  return new;
end;
$$;

drop trigger if exists event_members_integrity on public.event_members;
create trigger event_members_integrity
before insert or update on public.event_members
for each row execute function public.enforce_event_member_integrity();

drop trigger if exists event_members_bump_after_insert on public.event_members;
create trigger event_members_bump_after_insert
after insert on public.event_members
referencing new table as new_rows
for each statement execute function public.bump_events_from_event_members_insert();

drop trigger if exists event_members_bump_after_delete on public.event_members;
create trigger event_members_bump_after_delete
after delete on public.event_members
referencing old table as old_rows
for each statement execute function public.bump_events_from_event_members_delete();

-- 이전/Data API 일정 INSERT에도 작성자 할당이 필요하다. 트리거는 기존 일정 무결성/
-- 감사 트리거 뒤에 실행되며 참여자를 인식하는 RPC와 같은 트랜잭션 로컬 표시를
-- 사용한다. 직접 삽입은 일정의 초기 버전을 바꾸지 않고 행 하나를 채우며,
-- create_event_with_members는 일정 INSERT 전에 표시를 설정하고 의도적인 빈 목록을
-- 포함한 호출자의 정규 목록을 명시적으로 쓴다.
create or replace function public.seed_event_creator_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('moduly.event_members_mutation_context', true) = 'internal' then
    return new;
  end if;

  perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
  insert into public.event_members (event_id, user_id, created_at)
  values (new.id, new.created_by, new.created_at)
  on conflict (event_id, user_id) do nothing;
  perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
  return new;
end;
$$;

drop trigger if exists events_seed_creator_member on public.events;
create trigger events_seed_creator_member
after insert on public.events
for each row execute function public.seed_event_creator_member();

-- 모든 참여자 인식 일정 RPC가 공유하는 응답 계약이다. events 행과 같은 형태에
-- 클라이언트용으로 정규화해 정렬한 UUID 배열을 추가한다.

create or replace function public.create_event_with_members(
  p_group_id uuid,
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_is_all_day boolean,
  p_all_day_start date,
  p_all_day_end date,
  p_color_value bigint,
  p_member_ids uuid[]
)
returns table (
  id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_group public.groups;
  v_actor_membership public.memberships;
  v_event public.events;
  v_target_ids uuid[];
  v_input_ids uuid[] := coalesce(p_member_ids, '{}'::uuid[]);
  v_valid_count integer;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if exists (
    select 1 from unnest(v_input_ids) as supplied(user_id)
    where supplied.user_id is null
  ) then
    raise exception using errcode = '22023', message = 'member_ids cannot contain null';
  end if;

  -- 그룹 우선 잠금 순서는 일정 쓰기와 멤버십 수명 주기 RPC가 공유한다. 작성자는
  -- 운영 중인 그룹의 활성 멤버여야 한다.
  select g.* into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'group was archived or is unavailable';
  end if;

  select m.* into v_actor_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_actor_id
  for update;
  if not found or not v_actor_membership.is_active or v_actor_membership.removed_at is not null then
    raise exception using errcode = '42501', message = 'only an active group member can create events';
  end if;

  -- NULL 목록은 기본적으로 작성자를 사용한다. 명시적인 빈 배열은 실제 빈 할당
  -- 집합이며 교체/갱신 RPC도 목록을 비우기 위해 이를 허용한다.
  if p_member_ids is null then
    v_target_ids := array[v_actor_id]::uuid[];
  else
    select coalesce(array_agg(supplied.user_id order by supplied.user_id), '{}'::uuid[])
      into v_target_ids
    from (
      select distinct supplied.user_id
      from unnest(v_input_ids) as supplied(user_id)
    ) supplied;
  end if;

  perform 1
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = any(v_target_ids)
  order by m.user_id
  for update;

  select count(*)::integer into v_valid_count
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = any(v_target_ids)
    and m.is_active
    and m.removed_at is null;
  if v_valid_count <> coalesce(array_length(v_target_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must be active members of the group';
  end if;

  -- 이 결합 RPC가 호출자가 제공한 정확한 목록을 쓰는 동안 이전 INSERT 트리거를
  -- 억제한다. 표시는 트랜잭션 로컬이며 일정 또는 하위 삽입이 실패하면 롤백이 지운다.
  perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
  insert into public.events (
    group_id, created_by, title, description, starts_at, ends_at, timezone,
    is_all_day, all_day_start, all_day_end, color_value, version
  ) values (
    p_group_id, v_actor_id, p_title, coalesce(p_description, ''), p_starts_at,
    p_ends_at, coalesce(p_timezone, 'UTC'), coalesce(p_is_all_day, false),
    p_all_day_start, p_all_day_end, coalesce(p_color_value, 4282874742), 1
  ) returning * into v_event;

  -- 하위 트리거는 검증을 위해 계속 활성 상태지만, 이 내부 표시가 생성 시 일정
  -- 초기 버전을 1로 유지한다. 일정 INSERT 자체가 Realtime 신호이며 응답에는
  -- 정규 멤버 목록을 담는다.
  insert into public.event_members (event_id, user_id)
  select v_event.id, supplied.user_id
  from unnest(v_target_ids) as supplied(user_id)
  on conflict (event_id, user_id) do nothing;
  perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);

  return query
  select e.id, e.group_id, e.created_by, e.title, e.description,
         e.starts_at, e.ends_at, e.timezone, e.is_all_day,
         e.all_day_start, e.all_day_end, e.version, e.deleted_at,
         e.created_at, e.updated_at, e.color_value,
         coalesce(
           (select array_agg(em.user_id order by em.user_id)
            from public.event_members em
            where em.event_id = e.id),
           '{}'::uuid[]
         )
  from public.events e
  where e.id = v_event.id;
end;
$$;

create or replace function public.update_event_with_members_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_is_all_day boolean,
  p_all_day_start date,
  p_all_day_end date,
  p_color_value bigint,
  p_member_ids uuid[]
)
returns table (
  id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_group_id uuid;
  v_group public.groups;
  v_event public.events;
  v_actor_membership public.memberships;
  v_target_ids uuid[];
  v_input_ids uuid[] := coalesce(p_member_ids, '{}'::uuid[]);
  v_existing_ids uuid[];
  v_valid_count integer;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if exists (
    select 1 from unnest(v_input_ids) as supplied(user_id)
    where supplied.user_id is null
  ) then
    raise exception using errcode = '22023', message = 'member_ids cannot contain null';
  end if;

  select e.group_id into v_group_id
  from public.events e
  where e.id = p_event_id;
  if v_group_id is null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;

  select g.* into v_group
  from public.groups g
  where g.id = v_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;

  -- 상위 그룹 다음에 일정을 잠근다. 본문 편집은 계속 작성자 전용이다.
  select e.* into v_event
  from public.events e
  where e.id = p_event_id
  for update;
  if not found
     or v_event.deleted_at is not null
     or v_event.created_by <> v_actor_id
     or p_expected_version is null
     or v_event.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours';
  end if;

  select m.* into v_actor_membership
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = v_actor_id
  for update;
  if not found or not v_actor_membership.is_active or v_actor_membership.removed_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours';
  end if;

  select coalesce(array_agg(supplied.user_id order by supplied.user_id), '{}'::uuid[])
    into v_target_ids
  from (
    select distinct supplied.user_id
    from unnest(v_input_ids) as supplied(user_id)
  ) supplied;

  perform 1
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = any(v_target_ids)
  order by m.user_id
  for update;
  select count(*)::integer into v_valid_count
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = any(v_target_ids)
    and m.is_active
    and m.removed_at is null;
  if v_valid_count <> coalesce(array_length(v_target_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must be active members of the group';
  end if;

  -- 일정 잠금 아래에서 현재 목록을 캡처하여 검증 실패나 오래된 일정 버전이
  -- 목록을 부분적으로 교체하지 못하게 한다.
  perform 1
  from public.event_members em
  where em.event_id = p_event_id
  order by em.user_id
  for update;
  select coalesce(array_agg(em.user_id order by em.user_id), '{}'::uuid[])
    into v_existing_ids
  from public.event_members em
  where em.event_id = p_event_id;

  -- 본문 갱신이 이 결합 저장의 논리적 버전 전환 한 번이다. 하위 전환 트리거는
  -- 다음 내부 DML에 대해서만 억제하며 활성 대상 무결성은 계속 강제한다.
  update public.events e
  set title = p_title,
      description = coalesce(p_description, ''),
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      timezone = coalesce(p_timezone, 'UTC'),
      is_all_day = coalesce(p_is_all_day, false),
      all_day_start = p_all_day_start,
      all_day_end = p_all_day_end,
      color_value = coalesce(p_color_value, 4282874742),
      version = e.version + 1
  where e.id = p_event_id
    and e.created_by = v_actor_id
    and e.deleted_at is null
    and e.version = p_expected_version
  returning e.* into v_event;
  if not found then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours';
  end if;

  if v_existing_ids is distinct from v_target_ids then
    perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
    delete from public.event_members em
    where em.event_id = p_event_id
      and not (em.user_id = any(v_target_ids));
    insert into public.event_members (event_id, user_id)
    select p_event_id, supplied.user_id
    from unnest(v_target_ids) as supplied(user_id)
    on conflict (event_id, user_id) do nothing;
    perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
  end if;

  return query
  select e.id, e.group_id, e.created_by, e.title, e.description,
         e.starts_at, e.ends_at, e.timezone, e.is_all_day,
         e.all_day_start, e.all_day_end, e.version, e.deleted_at,
         e.created_at, e.updated_at, e.color_value,
         coalesce(
           (select array_agg(em.user_id order by em.user_id)
            from public.event_members em
            where em.event_id = e.id),
           '{}'::uuid[]
         )
  from public.events e
  where e.id = v_event.id;
end;
$$;

create or replace function public.replace_event_members_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_member_ids uuid[]
)
returns table (
  id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_group_id uuid;
  v_group public.groups;
  v_event public.events;
  v_actor_membership public.memberships;
  v_target_ids uuid[];
  v_existing_ids uuid[];
  v_input_ids uuid[] := coalesce(p_member_ids, '{}'::uuid[]);
  v_valid_count integer;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if exists (
    select 1 from unnest(v_input_ids) as supplied(user_id)
    where supplied.user_id is null
  ) then
    raise exception using errcode = '22023', message = 'member_ids cannot contain null';
  end if;

  select e.group_id into v_group_id
  from public.events e
  where e.id = p_event_id;
  if v_group_id is null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;

  select g.* into v_group
  from public.groups g
  where g.id = v_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;

  select e.* into v_event
  from public.events e
  where e.id = p_event_id
  for update;
  if not found
     or v_event.deleted_at is not null
     or p_expected_version is null
     or v_event.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;

  -- 참여자 목록 권한은 의도적으로 일정 본문 권한보다 넓다. 작성자 또는 현재 그룹
  -- 소유자가 사용할 수 있다. 둘 다 운영 중인 활성 멤버십이 필요하며,
  -- groups.owner_id는 불변 소유자 행이 뒷받침한다.
  if v_event.created_by <> v_actor_id and v_group.owner_id <> v_actor_id then
    raise exception using errcode = '42501', message = 'only the event creator or group owner can replace members';
  end if;
  select m.* into v_actor_membership
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = v_actor_id
  for update;
  if not found or not v_actor_membership.is_active or v_actor_membership.removed_at is not null then
    raise exception using errcode = '42501', message = 'only an active group member can replace event members';
  end if;

  select coalesce(array_agg(supplied.user_id order by supplied.user_id), '{}'::uuid[])
    into v_target_ids
  from (
    select distinct supplied.user_id
    from unnest(v_input_ids) as supplied(user_id)
  ) supplied;

  perform 1
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = any(v_target_ids)
  order by m.user_id
  for update;
  select count(*)::integer into v_valid_count
  from public.memberships m
  where m.group_id = v_group_id
    and m.user_id = any(v_target_ids)
    and m.is_active
    and m.removed_at is null;
  if v_valid_count <> coalesce(array_length(v_target_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must be active members of the group';
  end if;

  perform 1
  from public.event_members em
  where em.event_id = p_event_id
  order by em.user_id
  for update;
  select coalesce(array_agg(em.user_id order by em.user_id), '{}'::uuid[])
    into v_existing_ids
  from public.event_members em
  where em.event_id = p_event_id;

  if v_existing_ids is distinct from v_target_ids then
    perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
    delete from public.event_members em
    where em.event_id = p_event_id
      and not (em.user_id = any(v_target_ids));
    insert into public.event_members (event_id, user_id)
    select p_event_id, supplied.user_id
    from unnest(v_target_ids) as supplied(user_id)
    on conflict (event_id, user_id) do nothing;
    perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);

    -- 목록만 교체하는 작업도 일정 변경이다. 위에서 하위 트리거를 억제했으므로
    -- 여기서 정확히 한 번 버전/갱신 전환을 수행한다.
    update public.events e
    set version = e.version + 1
    where e.id = p_event_id
      and e.deleted_at is null
      and e.version = p_expected_version
    returning e.* into v_event;
    if not found then
      raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable';
    end if;
  end if;

  return query
  select e.id, e.group_id, e.created_by, e.title, e.description,
         e.starts_at, e.ends_at, e.timezone, e.is_all_day,
         e.all_day_start, e.all_day_end, e.version, e.deleted_at,
         e.created_at, e.updated_at, e.color_value,
         coalesce(
           (select array_agg(em.user_id order by em.user_id)
            from public.event_members em
            where em.event_id = e.id),
           '{}'::uuid[]
         )
  from public.events e
  where e.id = v_event.id;
end;
$$;

-- 일반 멤버십이 비활성화되거나 탈퇴하면 현재 할당을 정리한다. 두 함수 모두 이미
-- 그룹을 먼저 잠근다. CTE가 영향을 받은 각 일정을 정확히 한 번 갱신하는 동안
-- 트랜잭션 로컬 표시가 하위 전환에 따른 버전 증가를 억제한다. 재활성화해도 제거된
-- 할당은 복원하지 않는다.
create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.* into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '42501', message = 'only an active ordinary member can leave this group';
  end if;

  select m.* into v_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_user_id
  for update;
  if not found or not v_membership.is_active or v_membership.role <> 'member' then
    raise exception using errcode = '42501', message = 'only an active ordinary member can leave this group';
  end if;

  update public.memberships m
  set is_active = false,
      removed_at = coalesce(m.removed_at, pg_catalog.now())
  where m.group_id = p_group_id
    and m.user_id = v_user_id
    and m.role = 'member'
    and m.is_active
    and exists (
      select 1 from public.groups g
      where g.id = m.group_id and g.deleted_at is null
    );
  if not found then
    raise exception using errcode = '40001', message = 'membership was changed or the group is unavailable';
  end if;

  perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
  with removed as (
    delete from public.event_members em
    using public.events e
    where em.event_id = e.id
      and e.group_id = p_group_id
      and e.deleted_at is null
      and em.user_id = v_user_id
      and exists (
        select 1 from public.groups g
        where g.id = e.group_id and g.deleted_at is null
      )
    returning em.event_id
  )
  update public.events e
  set version = e.version + 1
  from (select distinct event_id from removed) changed
  where e.id = changed.event_id
    and e.deleted_at is null
    and exists (
      select 1 from public.groups g
      where g.id = e.group_id and g.deleted_at is null
    );
  perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
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
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.* into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found
     or v_group.owner_id <> v_actor_id
     or v_group.deleted_at is not null
     or p_user_id = v_actor_id then
    raise exception using errcode = '42501', message = 'only the owner can change another member';
  end if;

  select m.* into v_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = p_user_id
  for update;
  if not found or v_membership.role <> 'member' then
    raise exception using errcode = '22023', message = 'member does not exist';
  end if;

  update public.memberships m
  set is_active = p_is_active,
      removed_at = case when p_is_active then null else coalesce(m.removed_at, pg_catalog.now()) end
  where m.group_id = p_group_id
    and m.user_id = p_user_id
    and m.role = 'member'
  returning m.* into v_membership;
  if not found then
    raise exception using errcode = '22023', message = 'member does not exist';
  end if;

  if not p_is_active then
    perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
    with removed as (
      delete from public.event_members em
      using public.events e
      where em.event_id = e.id
        and e.group_id = p_group_id
        and e.deleted_at is null
        and em.user_id = p_user_id
        and exists (
          select 1 from public.groups g
          where g.id = e.group_id and g.deleted_at is null
        )
      returning em.event_id
    )
    update public.events e
    set version = e.version + 1
    from (select distinct event_id from removed) changed
    where e.id = changed.event_id
      and e.deleted_at is null
      and exists (
        select 1 from public.groups g
        where g.id = e.group_id and g.deleted_at is null
      );
    perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
  end if;
  return v_membership;
end;
$$;

-- 직접 하위 쓰기를 계속 허용하지 않으며 모든 새 SECURITY DEFINER는 인증된
-- 클라이언트만 호출할 수 있게 한다. 트리거 전용 함수는 PostgreSQL 트리거 조회를
-- 위해 public에 있어도 계속 직접 호출할 수 없다.
revoke execute on function public.bump_events_from_event_members_insert()
  from public, anon, authenticated;
revoke execute on function public.bump_events_from_event_members_delete()
  from public, anon, authenticated;
revoke execute on function public.enforce_event_member_integrity()
  from public, anon, authenticated;
revoke execute on function public.seed_event_creator_member()
  from public, anon, authenticated;

revoke execute on function public.create_event_with_members(
  uuid, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[]
) from public, anon, authenticated;
grant execute on function public.create_event_with_members(
  uuid, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[]
) to authenticated;

revoke execute on function public.update_event_with_members_if_version(
  uuid, integer, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[]
) from public, anon, authenticated;
grant execute on function public.update_event_with_members_if_version(
  uuid, integer, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[]
) to authenticated;

revoke execute on function public.replace_event_members_if_version(uuid, integer, uuid[])
  from public, anon, authenticated;
grant execute on function public.replace_event_members_if_version(uuid, integer, uuid[])
  to authenticated;

revoke execute on function public.leave_group(uuid)
  from public, anon, authenticated;
grant execute on function public.leave_group(uuid) to authenticated;

revoke execute on function public.set_member_active(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.set_member_active(uuid, uuid, boolean)
  to authenticated;

commit;
