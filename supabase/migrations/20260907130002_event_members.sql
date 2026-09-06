-- Event participant assignments.  This migration is additive and keeps the
-- existing events.member/creator contract while making assignments a normal
-- relation that can be secured, queried, and replaced atomically.

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
  'Current participant assignments.  Rows for archived/soft-deleted events may remain for cascade/history, but are hidden by RLS.';
comment on column public.event_members.created_at is
  'Assignment creation time; creator backfills use the event creation time.';

-- The primary key is event-leading for list reads.  This second index keeps
-- account deletion, user-scoped cleanup, and policy joins from scanning the
-- entire child table.
create index if not exists event_members_user_event_idx
  on public.event_members (user_id, event_id);

-- Backfill before adding integrity/transition triggers. Historical events are
-- intentionally included even when their group/event is terminal or the
-- creator is now inactive; RLS hides such rows and future deactivation prunes
-- current assignments. A normal migration reapply must not restore a creator
-- assignment that lifecycle cleanup deliberately removed, so the backfill is
-- guarded by an installation-complete sentinel checked before any trigger is
-- dropped/recreated. The sentinel is the feature's existing events AFTER
-- INSERT trigger plus the child table object—not a spoofable row/data
-- predicate. A first run or recoverable partial install (table without that
-- trigger) still performs the historical backfill.
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

-- RLS is defense in depth; ACLs below also ensure no client can bypass the
-- replacement RPC with direct child INSERT/UPDATE/DELETE statements.
create policy event_members_write_deny
on public.event_members
for all to authenticated
using (false)
with check (false);

revoke all on table public.event_members from public, anon, authenticated;
grant select on table public.event_members to authenticated;

-- The child table is deliberately not added to supabase_realtime.  Realtime
-- DELETE payload authorization cannot verify access to the deleted row, so a
-- child publication could disclose event/user UUIDs.  Child transition
-- triggers instead bump the parent event row, which is already published and
-- whose RLS policy is established.

-- Trigger-only helper: INSERT transition rows can come from the RPCs, setup,
-- or an auth-user cascade.  Internal mutators set the transaction-local marker
-- while changing children and explicitly bump events once afterward.
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

  -- Lock all affected parent groups first, in deterministic order.  This
  -- matches every group-scoped RPC and avoids event->group deadlocks.
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

-- Assignment writes are RPC-only, but this trigger also protects privileged
-- setup paths from cross-group/inactive rows.  It is installed after the
-- historical backfill so legacy inactive creator rows remain preserved.
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

  -- Parent group is always locked before checking membership state.
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

-- Legacy/Data API event INSERTs still need a creator assignment.  The trigger
-- runs after the existing event integrity/audit triggers and uses the same
-- transaction-local marker as the participant-aware RPCs: direct inserts seed
-- one row without changing the event's initial version, while create_event_
-- with_members sets the marker before its event INSERT and writes the caller's
-- canonical list explicitly (including an intentional empty list).
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

-- Shared response contract for all participant-aware event RPCs.  It mirrors
-- the events row and adds a canonical, sorted UUID array for the client.

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

  -- Group-first lock order is shared by event writes and membership lifecycle
  -- RPCs.  The creator must be an active member of a live group.
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

  -- A NULL list defaults to the creator.  An explicit empty array is a real
  -- empty assignment set; replacement/update RPCs also accept it to clear.
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

  -- Suppress the legacy INSERT trigger while this combined RPC writes its
  -- exact caller-supplied list.  The marker is transaction-local and rollback
  -- clears it if either the event or child insert fails.
  perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
  insert into public.events (
    group_id, created_by, title, description, starts_at, ends_at, timezone,
    is_all_day, all_day_start, all_day_end, color_value, version
  ) values (
    p_group_id, v_actor_id, p_title, coalesce(p_description, ''), p_starts_at,
    p_ends_at, coalesce(p_timezone, 'UTC'), coalesce(p_is_all_day, false),
    p_all_day_start, p_all_day_end, coalesce(p_color_value, 4282874742), 1
  ) returning * into v_event;

  -- Child triggers are still active for validation, but this internal marker
  -- keeps creation's initial event version at 1.  The event INSERT itself is
  -- the realtime signal; the response carries the canonical member list.
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

  -- Lock the event after its parent group; body edits remain creator-only.
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

  -- Capture the current list under the event lock so a failed validation or
  -- stale event version can never partially replace it.
  perform 1
  from public.event_members em
  where em.event_id = p_event_id
  order by em.user_id
  for update;
  select coalesce(array_agg(em.user_id order by em.user_id), '{}'::uuid[])
    into v_existing_ids
  from public.event_members em
  where em.event_id = p_event_id;

  -- The body update is the one logical version transition for this combined
  -- save.  Child transition triggers are suppressed only for the following
  -- internal DML and still enforce active-target integrity.
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

  -- Participant-list authority is intentionally broader than event-body
  -- authority: creator OR current group owner.  Both still need a live active
  -- membership; groups.owner_id is backed by an invariant owner row.
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

    -- List-only replacement is itself an event mutation.  The child triggers
    -- were suppressed above, so this is exactly one version/update transition.
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

-- Prune current assignments when an ordinary membership becomes inactive or
-- leaves.  Both functions already lock the group first; the transaction-local
-- marker suppresses child transition bumps while the CTE updates each affected
-- event exactly once.  Reactivation never restores removed assignments.
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

-- Keep direct child writes unavailable and make every new SECURITY DEFINER
-- callable only by authenticated clients.  Trigger-only functions stay
-- non-callable even though they live in public for PostgreSQL trigger lookup.
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
