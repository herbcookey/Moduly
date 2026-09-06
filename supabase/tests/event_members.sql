-- pgTAP fixture for event participant assignments.
--
-- It runs as the real authenticated role for reads/RPC calls.  Setup-only
-- writes use the session owner and are kept inside one transaction so this
-- file is safe to run repeatedly against a disposable local database.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table event_members_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  outsider_id uuid not null,
  second_owner_id uuid not null,
  inactive_id uuid not null,
  deleting_id uuid not null,
  group_id uuid,
  second_group_id uuid,
  archive_group_id uuid,
  cascade_group_id uuid,
  event_id uuid,
  default_event_id uuid,
  empty_event_id uuid,
  custom_event_id uuid,
  legacy_event_id uuid,
  soft_deleted_event_id uuid,
  deactivation_event_id uuid,
  archive_event_id uuid,
  account_event_id uuid,
  leave_event_id uuid
) on commit drop;
grant all on event_members_fixture to authenticated;

insert into event_members_fixture (
  owner_id, member_id, outsider_id, second_owner_id, inactive_id, deleting_id
) values (
  '00000000-0000-4000-8000-000000009101',
  '00000000-0000-4000-8000-000000009102',
  '00000000-0000-4000-8000-000000009103',
  '00000000-0000-4000-8000-000000009104',
  '00000000-0000-4000-8000-000000009105',
  '00000000-0000-4000-8000-000000009106'
);

reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    (select owner_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Event owner"}'::jsonb
  ),
  (
    (select member_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-member@example.test', '',
    now(), now(), now(), '{"display_name":"Event member"}'::jsonb
  ),
  (
    (select outsider_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-outsider@example.test', '',
    now(), now(), now(), '{"display_name":"Event outsider"}'::jsonb
  ),
  (
    (select second_owner_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-second-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Second owner"}'::jsonb
  ),
  (
    (select inactive_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Inactive target"}'::jsonb
  ),
  (
    (select deleting_id from event_members_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'event-delete-target@example.test', '',
    now(), now(), now(), '{"display_name":"Delete target"}'::jsonb
  )
on conflict (id) do nothing;

-- The owner creates the live fixture group and the second owner creates an
-- unrelated group used for cross-group target and hard-cascade assertions.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from event_members_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
update event_members_fixture f
set group_id = created.id
from public.create_group('Event participants', 'UTC', 'Participant fixture') as created;
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select second_owner_id::text from event_members_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select second_owner_id::text from event_members_fixture),
  true
);
set local role authenticated;
update event_members_fixture f
set second_group_id = created.id
from public.create_group('Other participants', 'UTC', '') as created;
reset role;

-- Membership rows are setup data.  The inactive row deliberately remains in
-- history but cannot ever be selected as an event target.
insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values
  (
    (select group_id from event_members_fixture),
    (select member_id from event_members_fixture),
    'member', true, now(), null
  ),
  (
    (select group_id from event_members_fixture),
    (select inactive_id from event_members_fixture),
    'member', false, now(), now()
  ),
  (
    (select group_id from event_members_fixture),
    (select deleting_id from event_members_fixture),
    'member', true, now(), null
  );

-- The event creator is an ordinary member.  This makes the group-owner versus
-- creator distinction explicit for both participant replacement and body edit.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from event_members_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
set local role authenticated;
update event_members_fixture f
set event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Assigned event', 'Initial description',
  '2026-02-01T00:00:00Z', '2026-02-01T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[
    (select owner_id from event_members_fixture),
    (select member_id from event_members_fixture),
    (select deleting_id from event_members_fixture),
    (select member_id from event_members_fixture)
  ]::uuid[]
) as created;
reset role;

select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
reset role;

-- A legacy/Data API INSERT remains supported for active creators. The new
-- AFTER INSERT trigger seeds exactly one creator row, keeps version at one,
-- and does not emit a second parent update. This path is intentionally tested
-- separately from the participant-aware RPCs below.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
insert into public.events (
  group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value
) values (
  (select group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  'Legacy direct event', '', '2026-02-01T02:00:00Z', '2026-02-01T03:00:00Z',
  'UTC', false, null, null, 1, 305419896
);
update event_members_fixture f
set legacy_event_id = created.id
from public.events created
where created.group_id = f.group_id
  and created.title = 'Legacy direct event';
select is(
  (select e.version from public.events e
   where e.id = (select legacy_event_id from event_members_fixture)),
  1,
  'legacy direct INSERT keeps the initial event version at one'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select legacy_event_id from event_members_fixture)),
  1,
  'legacy direct INSERT seeds one creator assignment without duplicates'
);
reset role;

-- RLS rejects an outsider direct event INSERT before the seed trigger can run.
-- A malformed active-creator INSERT fails the existing event checks; neither
-- failure may leave a child row behind.
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from event_members_fixture),
  true
);
set local role authenticated;
select throws_ok(
  format(
    'insert into public.events (group_id, created_by, title, description, starts_at, ends_at, timezone, is_all_day, version, color_value) values (%L::uuid, %L::uuid, ''Unauthorized direct event'', '''', %L::timestamptz, %L::timestamptz, ''UTC'', false, 1, 305419896)',
    (select group_id from event_members_fixture),
    (select owner_id from event_members_fixture),
    '2026-02-01T04:00:00Z', '2026-02-01T05:00:00Z'
  ),
  '42501',
  null,
  'RLS rejects an outsider direct event INSERT'
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id in (select e.id from public.events e where e.title = 'Unauthorized direct event')),
  0,
  'unauthorized direct INSERT leaves no participant row'
);

select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
set local role authenticated;
select throws_ok(
  format(
    'insert into public.events (group_id, created_by, title, description, starts_at, ends_at, timezone, is_all_day, version, color_value) values (%L::uuid, %L::uuid, ''Malformed direct event'', '''', %L::timestamptz, %L::timestamptz, ''UTC'', false, 1, 305419896)',
    (select group_id from event_members_fixture),
    (select member_id from event_members_fixture),
    '2026-02-01T06:00:00Z', '2026-02-01T06:00:00Z'
  ),
  '23514',
  null,
  'existing event checks reject malformed direct INSERT'
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id in (select e.id from public.events e where e.title = 'Malformed direct event')),
  0,
  'malformed direct INSERT leaves no participant row'
);

select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);

-- Basic catalog, key, index, RLS, ACL and publication assertions.
select ok(
  exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.event_members'::regclass
      and relrowsecurity
  ),
  'event_members has RLS enabled'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.event_members'::regclass and contype = 'p'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%(event_id, user_id)%'
  ),
  'event_members has the composite primary key'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.event_members'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.events'::regclass
      and c.confdeltype = 'c'
  ),
  'event_id cascades when an event is hard deleted'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.event_members'::regclass
      and c.contype = 'f'
      and c.confrelid = 'auth.users'::regclass
      and c.confdeltype = 'c'
  ),
  'user_id cascades when an account is deleted'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_index i on i.indexrelid = c.oid
    where c.oid = 'public.event_members_user_event_idx'::regclass
      and i.indrelid = 'public.event_members'::regclass
      and i.indisvalid
  ),
  'user-leading event_members index exists'
);
select ok(
  has_table_privilege('authenticated', 'public.event_members', 'select')
    and not has_table_privilege('authenticated', 'public.event_members', 'insert')
    and not has_table_privilege('authenticated', 'public.event_members', 'update')
    and not has_table_privilege('authenticated', 'public.event_members', 'delete'),
  'authenticated has SELECT but no direct child writes'
);
select ok(
  not has_table_privilege('anon', 'public.event_members', 'select')
    and not has_table_privilege('anon', 'public.event_members', 'insert'),
  'anon has no event_members table privileges'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.replace_event_members_if_version(uuid, integer, uuid[])',
    'execute'
  )
    and not has_function_privilege(
      'anon',
      'public.replace_event_members_if_version(uuid, integer, uuid[])',
      'execute'
    ),
  'participant replacement RPC is authenticated-only'
);
select ok(
  not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'event_members'
  ),
  'event_members is not added to supabase_realtime'
);

set local role authenticated;

select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  3,
  'active group owner sees current participant assignments'
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  3,
  'active ordinary member sees assignments in the shared group'
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from event_members_fixture),
  true
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  0,
  'outsider cannot see assignments from another group'
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);

-- The create RPC dedupes deterministically and returns creator/member IDs in
-- canonical order. NULL input defaults to the creator; an explicit empty
-- array is a real empty assignment set.
select is(
  (select cardinality(created.member_ids)
   from public.create_event_with_members(
     (select group_id from event_members_fixture),
     'Creator default', '',
     '2026-02-02T00:00:00Z', '2026-02-02T01:00:00Z',
     'UTC', false, null, null, 305419896, null
   ) as created),
  1,
  'create with NULL member_ids defaults to the creator'
);
update event_members_fixture f
set empty_event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Explicit empty assignment', '',
  '2026-02-02T02:00:00Z', '2026-02-02T03:00:00Z',
  'UTC', false, null, null, 305419896, '{}'::uuid[]
) as created;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select empty_event_id from event_members_fixture)),
  0,
  'create with an explicit empty array leaves no participants'
);
select is(
  (select e.version from public.events e
   where e.id = (select empty_event_id from event_members_fixture)),
  1,
  'explicit-empty create starts at version one'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select empty_event_id from event_members_fixture)),
  0,
  'explicit-empty create has no trigger-seeded creator row'
);
update event_members_fixture f
set default_event_id = created.id
from public.events created
where created.group_id = f.group_id
  and created.title = 'Creator default';

select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 1, array[%L::uuid]::uuid[])',
    (select default_event_id from event_members_fixture),
    (select member_id from event_members_fixture)
  ),
  '42501',
  'only the event creator or group owner can replace members',
  'ordinary member cannot replace another member-owned event'
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
select is(
  (select member_ids[1] from public.create_event_with_members(
     (select group_id from event_members_fixture),
     'Creator default two', '',
     '2026-02-03T00:00:00Z', '2026-02-03T01:00:00Z',
     'UTC', false, null, null, 305419896,
     array[(select member_id from event_members_fixture),
           (select member_id from event_members_fixture)]::uuid[]
  ) as created),
  (select member_id from event_members_fixture),
  'create dedupes duplicate UUIDs'
);
update event_members_fixture f
set custom_event_id = created.id
from public.events created
where created.group_id = f.group_id
  and created.title = 'Creator default two';
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select custom_event_id from event_members_fixture)),
  1,
  'create custom list excludes the creator when requested'
);
select ok(
  not exists (
    select 1 from public.event_members
    where event_id = (select custom_event_id from event_members_fixture)
      and user_id = (select owner_id from event_members_fixture)
  ),
  'create custom list does not re-add a trigger-seeded creator'
);

-- Owner replacement is allowed for a member-created event, leaves the body
-- untouched, bumps exactly once, and accepts an empty list.
select is(
  (select replaced.version
   from public.replace_event_members_if_version(
     (select event_id from event_members_fixture),
     1,
     array[
       (select owner_id from event_members_fixture),
       (select owner_id from event_members_fixture)
     ]::uuid[]
   ) as replaced),
  2,
  'group owner can replace a creator-owned participant list once'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  1,
  'owner replacement dedupes to one row'
);
select is(
  (select e.description from public.events e
   where e.id = (select event_id from event_members_fixture)),
  'Initial description',
  'participant replacement leaves event body unchanged'
);
select is(
  (select replaced.version
   from public.replace_event_members_if_version(
     (select event_id from event_members_fixture), 2, '{}'::uuid[]
   ) as replaced),
  3,
  'empty replacement clears all participants and bumps once'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  0,
  'empty replacement is allowed'
);

-- Reassign the event to active users for lifecycle and authorization checks.
select public.replace_event_members_if_version(
  (select event_id from event_members_fixture), 3,
  array[
    (select owner_id from event_members_fixture),
    (select member_id from event_members_fixture),
    (select deleting_id from event_members_fixture)
  ]::uuid[]
);
select is(
  (select e.version from public.events e
   where e.id = (select event_id from event_members_fixture)),
  4,
  'reassignment increments from the expected version'
);

-- Invalid target, cross-group target, duplicate membership, stale version and
-- outsider authorization all fail without a partial child replacement.
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[%L::uuid]::uuid[])',
    (select event_id from event_members_fixture),
    (select inactive_id from event_members_fixture)
  ),
  '42501',
  'all event members must be active members of the group',
  'inactive target is rejected'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  3,
  'failed inactive replacement is atomic'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[%L::uuid]::uuid[])',
    (select event_id from event_members_fixture),
    (select second_owner_id from event_members_fixture)
  ),
  '42501',
  'all event members must be active members of the group',
  'cross-group target is rejected'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[null]::uuid[])',
    (select event_id from event_members_fixture)
  ),
  '22023',
  'member_ids cannot contain null',
  'NULL participant IDs are rejected'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 3, ''{}''::uuid[])',
    (select event_id from event_members_fixture)
  ),
  '40001',
  'event was changed, deleted, or is unavailable',
  'stale participant replacement is rejected'
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from event_members_fixture),
  true
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, ''{}''::uuid[])',
    (select event_id from event_members_fixture)
  ),
  '42501',
  'only the event creator or group owner can replace members',
  'outsider cannot replace participants'
);

-- Body updates remain creator-only.  A group owner can replace the list but
-- cannot update title/body through the combined creator RPC.
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
select throws_ok(
  format(
    'select public.update_event_with_members_if_version(%L::uuid, 4, %L, %L, %L::timestamptz, %L::timestamptz, %L, false, null, null, 305419896, ''{}''::uuid[])',
    (select event_id from event_members_fixture), 'Owner body denied', '',
    '2026-02-01T00:00:00Z', '2026-02-01T01:00:00Z', 'UTC'
  ),
  '40001',
  'event was changed, deleted, or is not yours',
  'group owner cannot edit a non-owned event body'
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
select is(
  (select updated.version
   from public.update_event_with_members_if_version(
     (select event_id from event_members_fixture), 4,
     'Creator body', 'Updated description',
     '2026-02-01T00:00:00Z', '2026-02-01T01:00:00Z',
     'UTC', false, null, null, 305419897,
     array[(select member_id from event_members_fixture)]::uuid[]
   ) as updated),
  5,
  'creator can atomically update body and participant list'
);

-- Membership deactivation prunes each assignment and bumps each affected
-- event once.  Reactivation does not restore the removed row.
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
select public.set_member_active(
  (select group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  false
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)
     and user_id = (select member_id from event_members_fixture)),
  0,
  'deactivation prunes current event assignment'
);
select is(
  (select e.version from public.events e
   where e.id = (select event_id from event_members_fixture)),
  6,
  'deactivation bumps parent event exactly once'
);
select public.set_member_active(
  (select group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  true
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)
     and user_id = (select member_id from event_members_fixture)),
  0,
  'reactivation does not restore a pruned assignment'
);

-- Direct child writes are denied even to an authenticated caller, while
-- trigger functions and helper internals remain non-executable.
select throws_ok(
  format(
    'insert into public.event_members(event_id, user_id) values (%L::uuid, %L::uuid)',
    (select event_id from event_members_fixture),
    (select owner_id from event_members_fixture)
  ),
  '42501',
  null,
  'authenticated cannot insert event_members directly'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.enforce_event_member_integrity()',
    'execute'
  ),
  'authenticated cannot call trigger-only integrity function'
);
select throws_ok(
  'select public.seed_event_creator_member()',
  '42501',
  null,
  'authenticated cannot call the legacy event seed trigger function directly'
);

-- Soft-deleted/archived events retain rows but RLS hides them.  A hard event
-- delete cascades rows and a hard group delete cascades its event children.
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
update event_members_fixture f
set soft_deleted_event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Soft deleted event', '',
  '2026-02-04T00:00:00Z', '2026-02-04T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from event_members_fixture)]::uuid[]
) as created;
select public.soft_delete_event_if_version(
  (select soft_deleted_event_id from event_members_fixture), 1
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  'soft deletion retains assignment rows'
);
set local role authenticated;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  0,
  'soft-deleted assignment is hidden to the authenticated reader'
);

-- Deactivation prunes a live assignment exactly once but leaves the already
-- soft-deleted history row and version untouched.  Reactivation does not
-- restore either assignment.
update event_members_fixture f
set deactivation_event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Deactivation retention event', '',
  '2026-02-04T02:00:00Z', '2026-02-04T03:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from event_members_fixture)]::uuid[]
) as created;
select public.set_member_active(
  (select group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  false
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select deactivation_event_id from event_members_fixture)),
  0,
  'deactivation prunes the live assignment exactly once'
);
select is(
  (select e.version from public.events e
   where e.id = (select deactivation_event_id from event_members_fixture)),
  2,
  'deactivation bumps the live event once'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  'deactivation retains the soft-deleted assignment row'
);
select is(
  (select e.version from public.events e
   where e.id = (select soft_deleted_event_id from event_members_fixture)),
  2,
  'deactivation leaves the soft-deleted event version unchanged'
);
set local role authenticated;
select public.set_member_active(
  (select group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  true
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select deactivation_event_id from event_members_fixture)),
  0,
  'reactivation does not restore the deactivation-pruned assignment'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  'reactivation preserves the soft-deleted historical assignment'
);
set local role authenticated;

update event_members_fixture f
set archive_group_id = created.id
from public.create_group('Archived participants', 'UTC', '') as created;
reset role;
insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values (
  (select archive_group_id from event_members_fixture),
  (select member_id from event_members_fixture),
  'member', true, now(), null
);
set local role authenticated;
update event_members_fixture f
set archive_event_id = created.id
from public.create_event_with_members(
  (select archive_group_id from event_members_fixture),
  'Archived event', '',
  '2026-02-05T00:00:00Z', '2026-02-05T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from event_members_fixture)]::uuid[]
) as created;
select public.archive_group_if_version(
  (select archive_group_id from event_members_fixture), 1
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select archive_event_id from event_members_fixture)),
  1,
  'archiving a group retains assignment rows'
);
set local role authenticated;

select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  0,
  'RLS hides assignments for soft-deleted events'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select archive_event_id from event_members_fixture)),
  0,
  'RLS hides assignments in archived groups'
);

reset role;
select ok(
  (select count(*) from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)) = 1
    and (select count(*) from public.event_members
         where event_id = (select archive_event_id from event_members_fixture)) = 1,
  'setup owner can verify retained terminal rows'
);
delete from public.events
where id = (select default_event_id from event_members_fixture);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select default_event_id from event_members_fixture)),
  0,
  'hard event delete cascades event_members'
);

-- Account deletion of a non-creator target cascades its assignment and bumps
-- the surviving parent exactly once; the event creator remains intact.
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from event_members_fixture),
  true
);
set local role authenticated;
update event_members_fixture f
set account_event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Account cascade event', '',
  '2026-02-06T00:00:00Z', '2026-02-06T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select deleting_id from event_members_fixture)]::uuid[]
) as created;
reset role;
select is(
  (select e.version from public.events e
   where e.id = (select account_event_id from event_members_fixture)),
  1,
  'create starts account-cascade event at version one'
);
delete from auth.users
where id = (select deleting_id from event_members_fixture);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select account_event_id from event_members_fixture)),
  0,
  'account delete cascades participant assignment'
);
select is(
  (select e.version from public.events e
   where e.id = (select account_event_id from event_members_fixture)),
  2,
  'account cascade bumps surviving event exactly once'
);

-- Leave follows the same current-assignment rule as owner deactivation, but is
-- self-only and only ordinary members may invoke it.
set local role authenticated;
update event_members_fixture f
set leave_event_id = created.id
from public.create_event_with_members(
  (select group_id from event_members_fixture),
  'Leave cleanup event', '',
  '2026-02-06T02:00:00Z', '2026-02-06T03:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from event_members_fixture)]::uuid[]
) as created;
select public.leave_group((select group_id from event_members_fixture));
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select leave_event_id from event_members_fixture)),
  0,
  'leave_group prunes the leaving member assignment'
);
select is(
  (select e.version from public.events e
   where e.id = (select leave_event_id from event_members_fixture)),
  2,
  'leave_group bumps the parent event exactly once'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  'leave_group retains soft-deleted assignment history'
);
select is(
  (select e.version from public.events e
   where e.id = (select soft_deleted_event_id from event_members_fixture)),
  2,
  'leave_group leaves the soft-deleted event version unchanged'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select archive_event_id from event_members_fixture)),
  1,
  'leave_group leaves archived-group assignment history intact'
);

-- Hard-deleting an unrelated group cascades its owner membership, event and
-- event_members rows.  This is setup-only and does not represent API delete.
insert into public.groups (
  id, owner_id, name, description, timezone, version
) values (
  '00000000-0000-4000-8000-000000009201',
  (select second_owner_id from event_members_fixture),
  'Cascade participants', '', 'UTC', 1
)
;
update event_members_fixture
set cascade_group_id = '00000000-0000-4000-8000-000000009201';
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, version, color_value
) values (
  '00000000-0000-4000-8000-000000009202',
  (select cascade_group_id from event_members_fixture),
  (select second_owner_id from event_members_fixture),
  'Cascade event', '', '2026-02-07T00:00:00Z', '2026-02-07T01:00:00Z',
  'UTC', false, 1, 305419896
)
;
delete from public.groups
where id = (select cascade_group_id from event_members_fixture);
select is(
  (select count(*)::integer from public.event_members
   where event_id = '00000000-0000-4000-8000-000000009202'::uuid),
  0,
  'hard group delete cascades event_members'
);

-- Audit rows record no participant UUIDs/names.  Existing event audit entries
-- may contain only the event id and version metadata.
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'events'
      and a.metadata::text like '%' || (select deleting_id::text from event_members_fixture) || '%'
  ),
  'event participant changes do not put member UUIDs in audit metadata'
);

select * from finish();
rollback;
