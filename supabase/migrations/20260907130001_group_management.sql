-- Group management RPCs and invariants.
--
-- This migration deliberately keeps group ownership changes behind RPCs.  The
-- API roles retain no direct UPDATE privilege for ownership, role, or group
-- presentation columns.  SECURITY DEFINER functions use an empty search_path
-- and qualify every application object.

begin;

-- The index name is part of the schema contract.  A pre-existing object with
-- that name is accepted only when pg_catalog confirms the exact unique,
-- one-column, partial definition; a malformed same-name index aborts before
-- any data repair can occur.
do $$
declare
  v_index_oid oid;
  v_indrelid oid;
  v_indisunique boolean;
  v_indisvalid boolean;
  v_indnkeyatts integer;
  v_indnatts integer;
  v_index_key_attnum integer;
  v_group_attnum integer;
  v_index_has_expr boolean;
  v_predicate text;
  v_index_def text;
  v_expected_predicate text := '((role = ''owner''::public.group_member_role) AND is_active)';
  v_expected_index_def text := 'CREATE UNIQUE INDEX memberships_one_active_owner_idx ON public.memberships USING btree (group_id) WHERE ((role = ''owner''::public.group_member_role) AND is_active)';
begin
  perform pg_catalog.set_config('search_path', '', true);

  select c.oid,
         i.indrelid,
         i.indisunique,
         i.indisvalid,
         i.indnkeyatts,
         i.indnatts,
         i.indkey[0],
         i.indexprs is not null,
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         pg_catalog.pg_get_indexdef(c.oid)
    into v_index_oid,
         v_indrelid,
         v_indisunique,
         v_indisvalid,
         v_indnkeyatts,
         v_indnatts,
         v_index_key_attnum,
         v_index_has_expr,
         v_predicate,
         v_index_def
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  left join pg_catalog.pg_index i on i.indexrelid = c.oid
  where n.nspname = 'public'
    and c.relname = 'memberships_one_active_owner_idx';

  if found then
    select a.attnum
      into v_group_attnum
    from pg_catalog.pg_attribute a
    where a.attrelid = 'public.memberships'::regclass
      and a.attname = 'group_id';

    if v_index_oid is null
       or v_indrelid <> 'public.memberships'::regclass
       or v_indisunique is distinct from true
       or v_indisvalid is distinct from true
       or v_indnkeyatts <> 1
       or v_indnatts <> 1
       or v_index_key_attnum <> v_group_attnum
       or v_index_has_expr
       or v_index_def is null
       or pg_catalog.regexp_replace(
            pg_catalog.lower(coalesce(v_predicate, '')),
            '[[:space:]]+', '', 'g'
          ) <> pg_catalog.regexp_replace(
            pg_catalog.lower(v_expected_predicate),
            '[[:space:]]+', '', 'g'
          )
       or pg_catalog.regexp_replace(
            pg_catalog.lower(coalesce(v_index_def, '')),
            '[[:space:]]+', '', 'g'
          ) <> pg_catalog.regexp_replace(
            pg_catalog.lower(v_expected_index_def),
            '[[:space:]]+', '', 'g'
          ) then
      raise exception using
        errcode = '55000',
        message = 'memberships_one_active_owner_idx exists but is not the expected unique partial index on memberships(group_id)';
    end if;
  end if;
end;
$$;

-- Repair only deterministic owner-membership drift before creating the unique
-- index.  For each group, extra active owner rows are demoted first, then the
-- groups.owner_id row is inserted/reactivated/promoted.  This order is safe
-- with the existing membership trigger and also works when a valid index was
-- already present.  No arbitrary owner is selected; groups.owner_id is the
-- sole source of truth.
do $$
declare
  v_group_id uuid;
  v_owner_id uuid;
  v_owner_role public.group_member_role;
  v_owner_active boolean;
  v_owner_removed_at timestamptz;
begin
  perform pg_catalog.set_config('search_path', '', true);

  for v_group_id, v_owner_id in
    select g.id, g.owner_id
    from public.groups g
    order by g.id
  loop
    update public.memberships m
    set role = 'member',
        updated_at = pg_catalog.now()
    where m.group_id = v_group_id
      and m.user_id <> v_owner_id
      and m.role = 'owner'
      and m.is_active;

    select m.role, m.is_active, m.removed_at
      into v_owner_role, v_owner_active, v_owner_removed_at
    from public.memberships m
    where m.group_id = v_group_id
      and m.user_id = v_owner_id;

    if not found then
      insert into public.memberships (
        group_id, user_id, role, is_active, removed_at
      ) values (
        v_group_id, v_owner_id, 'owner', true, null
      );
    elsif v_owner_role is distinct from 'owner'::public.group_member_role
       or v_owner_active is distinct from true
       or v_owner_removed_at is not null then
      update public.memberships m
      set role = 'owner',
          is_active = true,
          removed_at = null,
          updated_at = pg_catalog.now()
      where m.group_id = v_group_id
        and m.user_id = v_owner_id;
    end if;
  end loop;
end;
$$;

-- Abort informatively if a malformed/ambiguous legacy row still remains.  A
-- group must have exactly one active owner row, and it must be groups.owner_id.
do $$
declare
  v_bad_group uuid;
begin
  select g.id
    into v_bad_group
  from public.groups g
  where not exists (
          select 1
          from public.memberships m
          where m.group_id = g.id
            and m.user_id = g.owner_id
            and m.role = 'owner'
            and m.is_active
            and m.removed_at is null
        )
     or 1 <> (
          select count(*)
          from public.memberships m
          where m.group_id = g.id
            and m.role = 'owner'
            and m.is_active
            and m.removed_at is null
        )
  order by g.id
  limit 1;
  if found then
    raise exception using
      errcode = '55000',
      message = pg_catalog.format('group %s has an ambiguous active owner membership after deterministic backfill', v_bad_group);
  end if;
end;
$$;

-- There must never be two active owners for a group.  The guarded CREATE is
-- followed by a pg_catalog definition check so IF NOT EXISTS cannot hide a
-- malformed object introduced by an older deployment.
create unique index if not exists memberships_one_active_owner_idx
  on public.memberships (group_id)
  where role = 'owner' and is_active;

do $$
declare
  v_index_oid oid;
  v_indrelid oid;
  v_indisunique boolean;
  v_indisvalid boolean;
  v_indnkeyatts integer;
  v_indnatts integer;
  v_index_key_attnum integer;
  v_group_attnum integer;
  v_index_has_expr boolean;
  v_predicate text;
  v_index_def text;
  v_expected_predicate text := '((role = ''owner''::public.group_member_role) AND is_active)';
  v_expected_index_def text := 'CREATE UNIQUE INDEX memberships_one_active_owner_idx ON public.memberships USING btree (group_id) WHERE ((role = ''owner''::public.group_member_role) AND is_active)';
begin
  perform pg_catalog.set_config('search_path', '', true);
  select c.oid,
         i.indrelid,
         i.indisunique,
         i.indisvalid,
         i.indnkeyatts,
         i.indnatts,
         i.indkey[0],
         i.indexprs is not null,
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         pg_catalog.pg_get_indexdef(c.oid)
    into v_index_oid,
         v_indrelid,
         v_indisunique,
         v_indisvalid,
         v_indnkeyatts,
         v_indnatts,
         v_index_key_attnum,
         v_index_has_expr,
         v_predicate,
         v_index_def
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_index i on i.indexrelid = c.oid
  where n.nspname = 'public'
    and c.relname = 'memberships_one_active_owner_idx';

  select a.attnum
    into v_group_attnum
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.memberships'::regclass
    and a.attname = 'group_id';

  if v_index_oid is null
     or v_indrelid <> 'public.memberships'::regclass
     or v_indisunique is distinct from true
     or v_indisvalid is distinct from true
     or v_indnkeyatts <> 1
     or v_indnatts <> 1
     or v_index_key_attnum <> v_group_attnum
     or v_index_has_expr
     or v_index_def is null
     or pg_catalog.regexp_replace(
          pg_catalog.lower(coalesce(v_predicate, '')),
          '[[:space:]]+', '', 'g'
        ) <> pg_catalog.regexp_replace(
          pg_catalog.lower(v_expected_predicate),
          '[[:space:]]+', '', 'g'
        )
     or pg_catalog.regexp_replace(
          pg_catalog.lower(coalesce(v_index_def, '')),
          '[[:space:]]+', '', 'g'
        ) <> pg_catalog.regexp_replace(
          pg_catalog.lower(v_expected_index_def),
          '[[:space:]]+', '', 'g'
        ) then
    raise exception using
      errcode = '55000',
      message = 'memberships_one_active_owner_idx is not the expected unique partial index on memberships(group_id)';
  end if;
end;
$$;

comment on index public.memberships_one_active_owner_idx is
  'At most one active owner membership may exist for each group.';

-- Realtime is optional in plain Postgres tests.  When the Supabase publication
-- exists, include groups and memberships idempotently for group lifecycle and
-- membership invalidation; the realtime schema itself is never modified.
do $$
begin
  if exists (
       select 1
       from pg_catalog.pg_publication
       where pubname = 'supabase_realtime'
     )
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'groups'
     ) then
    execute 'alter publication supabase_realtime add table public.groups';
  end if;
end;
$$;

do $$
begin
  if exists (
       select 1
       from pg_catalog.pg_publication
       where pubname = 'supabase_realtime'
     )
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'memberships'
     ) then
    execute 'alter publication supabase_realtime add table public.memberships';
  end if;
end;
$$;

-- Direct events INSERT/UPDATE statements are still part of the client write
-- contract, so their RLS membership check must be serialized with archive.
-- The existing events_integrity trigger is reused: it locks the parent group
-- first and rejects a terminal row before validating event fields.  DELETEs
-- (including auth/group cascades) do not fire this trigger and remain intact.
create or replace function public.enforce_event_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group public.groups;
begin
  select g.*
    into v_group
  from public.groups g
  where g.id = new.group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'group was archived or is unavailable';
  end if;

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

-- A transfer is the only operation that may change groups.owner_id or a
-- membership role.  The marker is transaction-local and is checked by both
-- immutable-table triggers.  It contains the exact group, old owner, and new
-- owner UUIDs; a malformed, stale, or partial marker is never accepted.
create or replace function public.enforce_group_integrity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_marker jsonb;
  v_marker_valid boolean := false;
begin
  if tg_op = 'UPDATE' then
    if new.owner_id <> old.owner_id then
      begin
        v_marker := nullif(pg_catalog.current_setting('moduly.transfer_marker', true), '')::jsonb;
      exception when others then
        v_marker := null;
      end;

      v_marker_valid := v_marker is not null
        and pg_catalog.jsonb_typeof(v_marker) = 'object'
        and v_marker ->> 'group_id' = old.id::text
        and v_marker ->> 'old_owner_id' = old.owner_id::text
        and v_marker ->> 'new_owner_id' = new.owner_id::text
        and v_marker ->> 'group_id' is not null
        and v_marker ->> 'old_owner_id' is not null
        and v_marker ->> 'new_owner_id' is not null
        and v_marker -> 'group_id' is not null
        and v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb;

      if not v_marker_valid then
        raise exception using
          errcode = '42501',
          message = 'group owner_id is immutable outside transfer_group_ownership';
      end if;
    end if;

    if old.deleted_at is not null and new.deleted_at is null then
      raise exception using
        errcode = '22023',
        message = 'a deleted group cannot be restored';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_membership_integrity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_owner_id uuid;
  v_marker jsonb;
  v_marker_valid boolean := false;
  v_transfer_role_change boolean := false;
begin
  -- Cascading account/group deletes must be allowed to remove memberships
  -- without consulting a parent row that may already be gone.  The row-level
  -- CHECK constraint still protects inserts/updates; DELETE has no invariant
  -- to enforce here.
  if tg_op = 'DELETE' then
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if new.group_id <> old.group_id or new.user_id <> old.user_id then
      raise exception using
        errcode = '42501',
        message = 'membership group_id and user_id are immutable';
    end if;
  end if;

  select g.owner_id
    into v_owner_id
  from public.groups g
  where g.id = new.group_id;
  if v_owner_id is null then
    raise exception using
      errcode = '23503',
      message = 'membership group does not exist';
  end if;

  begin
    v_marker := nullif(pg_catalog.current_setting('moduly.transfer_marker', true), '')::jsonb;
  exception when others then
    v_marker := null;
  end;
  v_marker_valid := v_marker is not null
    and pg_catalog.jsonb_typeof(v_marker) = 'object'
    and v_marker ->> 'group_id' = new.group_id::text
    and v_marker ->> 'old_owner_id' is not null
    and v_marker ->> 'new_owner_id' is not null
    and v_marker ->> 'old_owner_id' = v_owner_id::text
    and v_marker ->> 'new_owner_id' <> v_owner_id::text
    and v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb;

  -- During a valid transfer the old owner's row is demoted before the group
  -- owner_id changes, and the target is promoted while groups.owner_id still
  -- names the old owner.  These are the two and only two role transitions
  -- allowed by the transaction marker.
  if tg_op = 'UPDATE' then
    v_transfer_role_change := v_marker_valid and (
      (
        old.user_id::text = v_marker ->> 'old_owner_id'
        and old.role = 'owner'
        and new.user_id = old.user_id
        and new.role = 'member'
        and new.is_active
        and new.removed_at is null
      )
      or
      (
        old.user_id::text = v_marker ->> 'new_owner_id'
        and old.role = 'member'
        and new.user_id = old.user_id
        and new.role = 'owner'
        and new.is_active
        and new.removed_at is null
      )
    );
  end if;

  if new.user_id = v_owner_id then
    if (new.role <> 'owner' or not new.is_active or new.removed_at is not null)
       and not v_transfer_role_change then
      raise exception using
        errcode = '23514',
        message = 'the group owner must retain an active owner membership';
    end if;
  elsif new.role = 'owner' and not v_transfer_role_change then
    raise exception using
      errcode = '23514',
      message = 'only groups.owner_id may have the owner role';
  end if;

  if (new.is_active and new.removed_at is not null)
     or (not new.is_active and new.removed_at is null) then
    raise exception using
      errcode = '23514',
      message = 'is_active and removed_at must agree';
  end if;
  return new;
end;
$$;

-- Keep the DELETE path explicit as well as safe.  Cascading account/group
-- deletes may invoke the trigger after the parent row has disappeared; the
-- function's early return above intentionally makes that path a no-op.
drop trigger if exists memberships_integrity on public.memberships;
create trigger memberships_integrity
before insert or update or delete on public.memberships
for each row execute function public.enforce_membership_integrity();

-- Keep the field-safe/orphan-safe audit trigger while marking both event and
-- group NULL-to-non-NULL deleted_at transitions as soft_delete.  Archived
-- children remain stored, but their lifecycle is represented by this minimal
-- audit action rather than a generic update.
create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
  v_entity_id uuid;
  v_action text;
  v_version integer;
begin
  if tg_table_name = 'groups' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.id;
      v_version := new.version;
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif old.deleted_at is null and new.deleted_at is not null then
        v_action := 'soft_delete';
      else
        v_action := 'update';
      end if;
    end if;

  elsif tg_table_name = 'memberships' then
    if tg_op = 'DELETE' then
      -- Membership rows intentionally never identify a user in audit_logs.
      -- The group/action/timestamp remain useful without exposing a UUID.
      v_entity_id := null;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := null;
      v_group_id := new.group_id;
      v_action := case when tg_op = 'INSERT' then 'join' else 'update' end;
    end if;

  elsif tg_table_name = 'invite_codes' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.group_id;
      v_version := new.version;
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif new.revoked_at is not null and old.revoked_at is null then
        v_action := 'revoke';
      else
        v_action := 'update';
      end if;
    end if;

  elsif tg_table_name = 'events' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.group_id;
      v_version := new.version;
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif old.deleted_at is null and new.deleted_at is not null then
        v_action := 'soft_delete';
      else
        v_action := 'update';
      end if;
    end if;

  else
    raise exception using
      errcode = '22023',
      message = pg_catalog.format('unsupported audit trigger table: %s', tg_table_name);
  end if;

  -- Account-deletion cascades may SET NULL invited_by after the owning group
  -- row has already disappeared.  Skip only that orphaned internal update;
  -- normal writes for an existing group remain auditable.
  if v_group_id is not null
     and not exists (
       select 1
       from public.groups g
       where g.id = v_group_id
     ) then
    return null;
  end if;

  insert into public.audit_logs (
    group_id, actor_id, action, entity_type, entity_id, metadata
  ) values (
    v_group_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    pg_catalog.jsonb_build_object('version', v_version)
  );
  return null;
end;
$$;

-- Owner-only, optimistic-locking group details update.  The row lock is taken
-- before validation so a concurrent archive or transfer cannot produce a
-- non-deterministic result.  Input errors use 22023; stale, deleted, missing,
-- or unauthorized rows use the safe serialization/conflict code 40001.
create or replace function public.update_group_if_version(
  p_group_id uuid,
  p_expected_version integer,
  p_name text,
  p_description text,
  p_timezone text
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_name text := pg_catalog.btrim(coalesce(p_name, ''));
  v_description text := pg_catalog.btrim(coalesce(p_description, ''));
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if pg_catalog.char_length(v_name) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'group name must be 1-160 characters';
  end if;
  if pg_catalog.char_length(v_description) > 10000 then
    raise exception using errcode = '22023', message = 'group description must be at most 10000 characters';
  end if;
  if p_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names t
       where t.name = p_timezone
     ) then
    raise exception using errcode = '22023', message = 'timezone must be an exact IANA timezone name';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  update public.groups g
  set name = v_name,
      description = v_description,
      timezone = p_timezone,
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;
  return v_group;
end;
$$;

-- An active ordinary member can leave only their own membership.  The group
-- lock makes archive/leave races deterministic; owner and archived groups are
-- rejected before the membership row is changed.
create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '42501',
      message = 'only an active ordinary member can leave this group';
  end if;

  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_user_id
  for update;

  if not found
     or not v_membership.is_active
     or v_membership.role <> 'member' then
    raise exception using
      errcode = '42501',
      message = 'only an active ordinary member can leave this group';
  end if;

  update public.memberships m
  set is_active = false,
      removed_at = coalesce(m.removed_at, pg_catalog.now())
  where m.group_id = p_group_id
    and m.user_id = v_user_id
    and m.role = 'member'
    and m.is_active
    and exists (
      select 1
      from public.groups g
      where g.id = m.group_id
        and g.deleted_at is null
    );

  if not found then
    raise exception using
      errcode = '40001',
      message = 'membership was changed or the group is unavailable';
  end if;
  return;
end;
$$;

-- Transfer ownership atomically.  The group row is locked first, followed by
-- both membership rows.  The transaction-local marker is populated only after
-- all ownership and membership checks pass and is validated by the immutable
-- triggers on every affected row.
create or replace function public.transfer_group_ownership(
  p_group_id uuid,
  p_new_owner_id uuid,
  p_expected_version integer
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_old_membership public.memberships;
  v_new_membership public.memberships;
  v_active_owner_count integer;
  v_final_owner_id uuid;
  v_marker text;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_new_owner_id is null or p_new_owner_id = v_user_id then
    raise exception using errcode = '22023', message = 'new owner must be another user';
  end if;

  -- Lock the group before any membership row.  This lock order is shared by
  -- archive/update and prevents transfer deadlocks with terminal operations.
  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  -- The ordered query acquires both membership locks after the group lock.
  -- The result rows are copied below so each required role/state is checked.
  select m.*
    into v_old_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_user_id
  for update;
  if not found
     or v_old_membership.role <> 'owner'
     or not v_old_membership.is_active
     or v_old_membership.removed_at is not null then
    raise exception using
      errcode = '40001',
      message = 'current owner membership is unavailable';
  end if;

  select m.*
    into v_new_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = p_new_owner_id
  for update;
  if not found
     or v_new_membership.role <> 'member'
     or not v_new_membership.is_active
     or v_new_membership.removed_at is not null then
    raise exception using
      errcode = '42501',
      message = 'new owner must be an active member of this group';
  end if;

  v_marker := pg_catalog.json_build_object(
    'group_id', p_group_id::text,
    'old_owner_id', v_user_id::text,
    'new_owner_id', p_new_owner_id::text
  )::text;
  perform pg_catalog.set_config('moduly.transfer_marker', v_marker, true);

  -- Demote then promote before changing groups.owner_id.  The partial unique
  -- index therefore cannot observe two active owners, even within this write.
  update public.memberships m
  set role = 'member',
      updated_at = pg_catalog.now()
  where m.group_id = p_group_id
    and m.user_id = v_user_id
    and m.role = 'owner'
    and m.is_active;
  if not found then
    raise exception using errcode = '40001', message = 'current owner membership changed';
  end if;

  update public.memberships m
  set role = 'owner',
      updated_at = pg_catalog.now()
  where m.group_id = p_group_id
    and m.user_id = p_new_owner_id
    and m.role = 'member'
    and m.is_active
    and m.removed_at is null;
  if not found then
    raise exception using errcode = '40001', message = 'new owner membership changed';
  end if;

  update public.groups g
  set owner_id = p_new_owner_id,
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;
  if not found then
    raise exception using errcode = '40001', message = 'group was changed during ownership transfer';
  end if;

  -- Check the final invariant in the same transaction before returning.  The
  -- unique index catches duplicate owners; these checks also catch a missing
  -- owner row or a trigger/schema drift.
  select count(*)::integer
    into v_active_owner_count
  from public.memberships m
  where m.group_id = p_group_id
    and m.role = 'owner'
    and m.is_active
    and m.removed_at is null;
  select m.user_id
    into v_final_owner_id
  from public.memberships m
  where m.group_id = p_group_id
    and m.role = 'owner'
    and m.is_active
    and m.removed_at is null
  limit 1;
  if v_active_owner_count <> 1
     or v_final_owner_id <> p_new_owner_id
     or v_group.owner_id <> p_new_owner_id then
    raise exception using
      errcode = '40001',
      message = 'ownership transfer invariant failed';
  end if;

  perform pg_catalog.set_config('moduly.transfer_marker', '', true);
  return v_group;
end;
$$;

-- Preserve archive_group_if_version's public signature while taking a terminal
-- group lock.  The existing groups audit trigger records the transition from
-- deleted_at NULL to non-NULL as action soft_delete; child rows remain intact
-- and are hidden by the existing group/member/event RLS helpers.
create or replace function public.archive_group_if_version(
  p_group_id uuid,
  p_expected_version integer
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  update public.groups g
  set deleted_at = pg_catalog.now(),
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;
  return v_group;
end;
$$;

-- Existing group-scoped RPCs also take the group lock before checking
-- ownership/lifecycle state.  Transfer, archive, moderation, invite and event
-- writes therefore share one lock order (group first), so a concurrent
-- transfer/archive cannot pass a helper check and then write stale data.
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
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_token text;
  v_token_hash text;
  v_random bytea;
  v_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_index integer;
  v_attempt integer;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- Lock the target group before checking owner/deleted state.  All other
  -- group-scoped writes in this migration use the same group-first order.
  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null then
    raise exception using
      errcode = '42501',
      message = 'only the group owner can create invites';
  end if;

  if p_expires_at is null or p_expires_at <= pg_catalog.now() then
    raise exception using errcode = '22023', message = 'invite expiration must be in the future';
  end if;
  if p_max_uses is null or p_max_uses not between 1 and 100000 then
    raise exception using errcode = '22023', message = 'max_uses must be between 1 and 100000';
  end if;

  -- Preserve the human-friendly 12-character code and SHA-256 hash semantics
  -- introduced by 20260815055218_shorten_invite_codes.sql.
  for v_attempt in 1..5 loop
    v_random := extensions.gen_random_bytes(12);
    v_token := '';
    for v_index in 0..11 loop
      v_token := v_token || pg_catalog.substr(
        v_alphabet,
        (pg_catalog.get_byte(v_random, v_index) % 32) + 1,
        1
      );
    end loop;
    v_token_hash := encode(
      extensions.digest(pg_catalog.convert_to(v_token, 'utf8'), 'sha256'),
      'hex'
    );

    insert into public.invite_codes as issued (
      group_id, created_by, token_hash, expires_at, max_uses
    )
    values (p_group_id, v_user_id, v_token_hash, p_expires_at, p_max_uses)
    on conflict (token_hash) do nothing
    returning issued.id, issued.expires_at, issued.max_uses
      into invite_id, expires_at, max_uses;

    if invite_id is not null then
      token := v_token;
      return next;
      return;
    end if;
  end loop;

  raise exception using errcode = '55000', message = 'could not generate a unique invite code';
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
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := pg_catalog.btrim(coalesce(p_token, ''));
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
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if pg_catalog.char_length(v_token) > 256 then
    v_token := pg_catalog.left(v_token, 256);
  end if;
  v_token_hash := encode(
    extensions.digest(pg_catalog.convert_to(v_token, 'utf8'), 'sha256'),
    'hex'
  );

  -- Serialize a caller's attempts exactly as before. The group lock below is
  -- acquired before any group-owned membership/invite write.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  select count(*)::integer into v_attempt_count
  from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

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

  -- Read the group id without locking only to establish the lock target.  The
  -- locked group row is rechecked before the invite row and membership are
  -- changed, so a concurrent archive/transfer cannot leave stale writes.
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

  -- Lock the invite only after its parent group, matching revoke/create and
  -- every other group-scoped RPC's group-first lock order.
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
  v_group_owner := v_group.owner_id;

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

  -- The group lock remains held while repairing/rejoining membership and
  -- consuming the invite, so archive/transfer cannot interleave here.
  if v_group_owner = v_user_id then
    insert into public.memberships (group_id, user_id, role, is_active, removed_at)
    values (v_invite_group_id, v_user_id, 'owner', true, null)
    on conflict (group_id, user_id) do update
      set role = 'owner', is_active = true, removed_at = null, updated_at = pg_catalog.now()
    returning user_id into v_membership_id;
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if found then
    update public.memberships
      set role = 'member', is_active = true, removed_at = null, joined_at = pg_catalog.now()
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
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_event_group_id uuid;
  v_group public.groups;
  v_membership public.memberships;
  v_event public.events;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select e.group_id
    into v_event_group_id
  from public.events e
  where e.id = p_event_id;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_event_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  -- Group-first then membership lock matches moderation/join and prevents a
  -- deactivation from racing the active-member check below.
  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = v_event_group_id
    and m.user_id = v_user_id
  for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  select e.*
    into v_event
  from public.events e
  where e.id = p_event_id
  for update;
  if not found
     or v_event.group_id <> v_event_group_id
     or v_event.created_by <> v_user_id
     or v_event.deleted_at is not null
     or p_expected_version is null
     or v_event.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  update public.events e
  set deleted_at = pg_catalog.now(),
      version = e.version + 1
  where e.id = p_event_id
    and e.created_by = v_user_id
    and e.deleted_at is null
    and e.version = p_expected_version
  returning e.* into v_event;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;
  return v_event;
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
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invite_group_id uuid;
  v_group public.groups;
  v_invite public.invite_codes;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- Resolve the parent without a lock, then lock group first and re-read the
  -- invite under that lock. Invite ownership/group lifecycle cannot change
  -- between the check and write now.
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
     or v_invite.created_by <> v_user_id
     or p_expected_version is null
     or v_invite.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  update public.invite_codes i
  set revoked_at = coalesce(i.revoked_at, pg_catalog.now()),
      version = i.version + 1
  where i.id = p_invite_id
    and i.created_by = v_user_id
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
  v_actor_id uuid := auth.uid();
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found
     or v_group.owner_id <> v_actor_id
     or v_group.deleted_at is not null
     or p_user_id = v_actor_id then
    raise exception using
      errcode = '42501',
      message = 'only the owner can change another member';
  end if;

  select m.*
    into v_membership
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
  return v_membership;
end;
$$;

-- Return only current-user-owned group names/IDs/status and deletion counts.
-- This is a display preflight for account deletion, not an audit/logging API.
create or replace function public.account_deletion_preflight()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owned_groups jsonb;
  v_active_owned_groups jsonb;
  v_archived_owned_groups jsonb;
  v_events bigint;
  v_invites bigint;
  v_memberships bigint;
  v_groups bigint;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', case when g.deleted_at is null then 'active' else 'archived' end,
        'member_count', (
          select count(*)::integer
          from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer
          from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_owned_groups
  from public.groups g
  where g.owner_id = v_user_id;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', 'active',
        'member_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_active_owned_groups
  from public.groups g
  where g.owner_id = v_user_id and g.deleted_at is null;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', 'archived',
        'member_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_archived_owned_groups
  from public.groups g
  where g.owner_id = v_user_id and g.deleted_at is not null;

  -- Owned groups and authored rows both disappear on auth.users cascade.  Use
  -- OR predicates so each row is counted once even when both conditions hold.
  select count(*) into v_groups
  from public.groups g
  where g.owner_id = v_user_id;
  select count(*) into v_events
  from public.events e
  where e.created_by = v_user_id
     or exists (select 1 from public.groups g where g.id = e.group_id and g.owner_id = v_user_id);
  select count(*) into v_invites
  from public.invite_codes i
  where i.created_by = v_user_id
     or exists (select 1 from public.groups g where g.id = i.group_id and g.owner_id = v_user_id);
  select count(*) into v_memberships
  from public.memberships m
  where m.user_id = v_user_id
     or exists (select 1 from public.groups g where g.id = m.group_id and g.owner_id = v_user_id);

  return pg_catalog.jsonb_build_object(
    'owned_groups', v_owned_groups,
    'active_owned_groups', v_active_owned_groups,
    'archived_owned_groups', v_archived_owned_groups,
    'groups', v_groups,
    'events', v_events,
    'invites', v_invites,
    'memberships', v_memberships
  );
end;
$$;

-- Older deployments recorded membership.user_id in audit_logs.entity_id.
-- Remove only that identifiable field; group/action/version metadata is kept.
update public.audit_logs
set entity_id = null
where entity_type = 'memberships'
  and entity_id is not null;

-- Auth deletion fans out through both auth.users and groups.  Deferring the
-- audit FKs lets PostgreSQL apply the actor_id and group_id SET NULL actions
-- together after the cascaded parent deletes, avoiding a transient
-- cross-cascade violation while preserving the audit rows themselves.
alter table public.audit_logs
  alter constraint audit_logs_group_id_fkey deferrable initially deferred;
alter table public.audit_logs
  alter constraint audit_logs_actor_id_fkey deferrable initially deferred;

-- Keep direct detail updates RPC-only.  Revoke stale table-level and
-- column-level grants from every API role; SECURITY DEFINER RPCs retain the
-- owner-authorized write path.  Groups INSERT remains compatible with the
-- existing create_group trigger/RPC contract.
revoke update on table public.groups from public, anon, authenticated;
revoke update (owner_id, name, description, timezone, version, deleted_at,
               created_at, updated_at) on public.groups
  from public, anon, authenticated;
-- Keep the approved detail-column list explicit for upgraded ACL catalogs.
revoke update (name, description, timezone, version) on public.groups
  from public, anon, authenticated;

-- Membership status changes are exposed only through the owner moderation RPC.
-- Removing the remaining column grant closes the stale direct-UPDATE path:
-- set_member_active takes the parent group lock before its membership check,
-- while account/group cascades retain unrestricted owner-side execution.
revoke update on table public.memberships from public, anon, authenticated;
revoke update (group_id, user_id, role, joined_at, removed_at, invited_by,
               created_at, updated_at, is_active) on public.memberships
  from public, anon, authenticated;

-- New SECURITY DEFINER functions must not inherit PUBLIC's default EXECUTE.
revoke execute on function public.write_audit_log()
  from public, anon, authenticated;

revoke execute on function public.update_group_if_version(uuid, integer, text, text, text)
  from public, anon, authenticated;
grant execute on function public.update_group_if_version(uuid, integer, text, text, text)
  to authenticated;

revoke execute on function public.leave_group(uuid)
  from public, anon, authenticated;
grant execute on function public.leave_group(uuid) to authenticated;

revoke execute on function public.transfer_group_ownership(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.transfer_group_ownership(uuid, uuid, integer)
  to authenticated;

revoke execute on function public.archive_group_if_version(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.archive_group_if_version(uuid, integer)
  to authenticated;

revoke execute on function public.account_deletion_preflight()
  from public, anon, authenticated;
grant execute on function public.account_deletion_preflight() to authenticated;

commit;
