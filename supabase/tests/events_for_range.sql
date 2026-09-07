-- pgTAP fixture for bounded, keyset-paginated calendar reads.
--
-- The fixture intentionally calls the range RPC as the real authenticated
-- role.  Setup writes use the session owner and the complete test is rolled
-- back, so it is safe to run against a disposable local Supabase database.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table events_for_range_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  inactive_id uuid not null,
  outsider_id uuid not null,
  other_owner_id uuid not null,
  group_id uuid not null,
  archive_group_id uuid not null,
  other_group_id uuid not null,
  overlap_event_id uuid,
  end_boundary_event_id uuid,
  start_boundary_event_id uuid,
  all_day_event_id uuid,
  dst_all_day_event_id uuid,
  assigned_event_id uuid,
  unassigned_event_id uuid,
  deleted_event_id uuid,
  archived_event_id uuid,
  canonical_cursor text
) on commit drop;
grant all on events_for_range_fixture to authenticated;

insert into events_for_range_fixture (
  owner_id, member_id, inactive_id, outsider_id, other_owner_id,
  group_id, archive_group_id, other_group_id
) values (
  '00000000-0000-4000-8000-00000000f101',
  '00000000-0000-4000-8000-00000000f102',
  '00000000-0000-4000-8000-00000000f103',
  '00000000-0000-4000-8000-00000000f104',
  '00000000-0000-4000-8000-00000000f105',
  '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f202',
  '00000000-0000-4000-8000-00000000f203'
);

reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    (select owner_id from events_for_range_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Range owner"}'::jsonb
  ),
  (
    (select member_id from events_for_range_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-member@example.test', '',
    now(), now(), now(), '{"display_name":"Range member"}'::jsonb
  ),
  (
    (select inactive_id from events_for_range_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Range inactive"}'::jsonb
  ),
  (
    (select outsider_id from events_for_range_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-outsider@example.test', '',
    now(), now(), now(), '{"display_name":"Range outsider"}'::jsonb
  ),
  (
    (select other_owner_id from events_for_range_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'range-other-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Other owner"}'::jsonb
  )
on conflict (id) do nothing;

-- Fixed IDs make the privacy and cross-group checks deterministic.  Group
-- inserts create their owner membership through the existing trigger.
insert into public.groups (
  id, owner_id, name, description, timezone, version, deleted_at,
  created_at, updated_at
) values
  (
    (select group_id from events_for_range_fixture),
    (select owner_id from events_for_range_fixture),
    'Range fixture', 'Bounded range tests', 'UTC', 1, null,
    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
  ),
  (
    (select archive_group_id from events_for_range_fixture),
    (select owner_id from events_for_range_fixture),
    'Archived range fixture', '', 'UTC', 1, null,
    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
  ),
  (
    (select other_group_id from events_for_range_fixture),
    (select other_owner_id from events_for_range_fixture),
    'Other range fixture', '', 'UTC', 1, null,
    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
  );

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values
  (
    (select group_id from events_for_range_fixture),
    (select member_id from events_for_range_fixture),
    'member', true, '2026-01-01T00:00:00Z', null
  ),
  (
    (select group_id from events_for_range_fixture),
    (select inactive_id from events_for_range_fixture),
    'member', false, '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
  );
reset role;

-- Every event below is created through the participant-aware RPC so the
-- fixture also proves that this read contract consumes the Feature 5 row
-- shape.  Explicit member lists are sorted/deduped by that RPC.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from events_for_range_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from events_for_range_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

update events_for_range_fixture f
set overlap_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range overlap', '',
  '2026-02-28T23:00:00Z', '2026-03-01T02:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set end_boundary_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range end boundary', '',
  '2026-02-28T23:00:00Z', '2026-03-01T00:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select owner_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set start_boundary_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range start boundary', '',
  '2026-03-02T00:00:00Z', '2026-03-02T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select owner_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set all_day_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range all day', '',
  '2026-03-01T00:00:00Z', '2026-03-03T00:00:00Z',
  'UTC', true, '2026-03-01', '2026-03-03', 305419896,
  array[(select member_id from events_for_range_fixture)]::uuid[]
) as created;

-- The 2026 New York spring-forward day is a 23-hour UTC interval.  Its
-- local-midnight endpoints are still accepted when p_view_timezone is NY.
update events_for_range_fixture f
set dst_all_day_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range DST all day', '',
  '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z',
  'America/New_York', true, '2026-03-08', '2026-03-09', 305419896,
  array[(select member_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set assigned_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range assigned member', '',
  '2026-03-04T00:00:00Z', '2026-03-04T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set unassigned_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range owner only', '',
  '2026-03-04T02:00:00Z', '2026-03-04T03:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select owner_id from events_for_range_fixture)]::uuid[]
) as created;

update events_for_range_fixture f
set deleted_event_id = created.id
from public.create_event_with_members(
  (select group_id from events_for_range_fixture),
  'Range deleted', '',
  '2026-03-04T04:00:00Z', '2026-03-04T05:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select member_id from events_for_range_fixture)]::uuid[]
) as created;

select public.soft_delete_event_if_version(
  (select deleted_event_id from events_for_range_fixture), 1
);

-- The archived group's event is retained by the database but must be invisible
-- to this RPC after archive_group_if_version transitions the group terminal.
update events_for_range_fixture f
set archived_event_id = created.id
from public.create_event_with_members(
  (select archive_group_id from events_for_range_fixture),
  'Archived range event', '',
  '2026-03-01T00:00:00Z', '2026-03-01T01:00:00Z',
  'UTC', false, null, null, 305419896,
  array[(select owner_id from events_for_range_fixture)]::uuid[]
) as created;
select public.archive_group_if_version(
  (select archive_group_id from events_for_range_fixture), 1
);
reset role;

-- Catalog and permission assertions are run as the migration owner.
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
    where c.oid = 'public.events_group_start_id_live_idx'::regclass
      and c.relkind = 'i'
  ),
  'deterministic live-event keyset index exists'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
    where c.oid = 'public.events_group_allday_dates_live_idx'::regclass
      and c.relkind = 'i'
  ),
  'all-day date overlap index exists'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ),
  'authenticated can execute events_for_range'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'public',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ),
  'anon and PUBLIC cannot execute events_for_range'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_proc p
    where p.oid = 'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)'::regprocedure
      and p.prosecdef
      and p.proconfig @> array['search_path=""']::text[]
  ),
  'range function is SECURITY DEFINER with an empty search_path'
);
select ok(
  not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'event_members'
  ),
  'event_members remains out of the realtime publication'
);
select ok(
  not exists (
    select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime'
  )
  or exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'events'
  ),
  'when realtime is configured, the parent events table remains the invalidation signal'
);

-- Owner and active member see the same live-group rows, including every
-- Feature 5 event field and a canonical member_ids array.
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from events_for_range_fixture),
  true
);
set local role authenticated;
update events_for_range_fixture f
set canonical_cursor = public.events_for_range(
  (select group_id from events_for_range_fixture),
  '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
  'UTC', 1, null, null
)->>'next_cursor';
select ok(
  (select canonical_cursor from events_for_range_fixture) is not null
    and (select canonical_cursor from events_for_range_fixture) !~ '='
    and (select canonical_cursor from events_for_range_fixture) ~ '^[A-Za-z0-9_-]+$',
  'a valid canonical cursor is emitted as unpadded URL-safe base64'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 1, (select canonical_cursor from events_for_range_fixture), null
  )->'events')),
  1,
  'a canonical cursor emitted by the RPC is accepted for the next page'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  2,
  'owner sees the overlap and all-day rows in the exact half-open day'
);
select ok(
  not exists (
    select 1
    from jsonb_array_elements((public.events_for_range(
      (select group_id from events_for_range_fixture),
      '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
      'UTC', 100, null, null
    )->'events')) event_row
    where event_row ? 'deleted_at'
      and event_row->>'deleted_at' is not null
  ),
  'soft-deleted events are excluded from the live range'
);
select ok(
  exists (
    select 1
    from jsonb_array_elements((public.events_for_range(
      (select group_id from events_for_range_fixture),
      '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
      'UTC', 100, null, null
    )->'events')) event_row
    where event_row->>'id' = (select all_day_event_id::text from events_for_range_fixture)
      and event_row ? 'member_ids'
      and event_row ? 'color_value'
      and event_row ? 'version'
  ),
  'range rows include the complete event shape and member_ids'
);
select is(
  (select public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events'->0->>'title'),
  'Range overlap',
  'timed and all-day rows use deterministic starts_at,id ordering'
);

select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from events_for_range_fixture),
  true
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    null, 100, null, null
  )->'events')),
  2,
  'active ordinary members can read the live group with its locked timezone'
);

-- Exact half-open timed/date boundaries: an event ending at the start or
-- starting at the end is excluded, while the spanning row is retained.
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  2,
  'the range is half-open at both timed boundaries'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-03T00:00:00Z', '2026-03-04T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  0,
  'an all-day event ending at range_start is excluded'
);

-- Participant filtering is server-side and requires an active target in this
-- same group.  It never turns an inactive, outsider, or cross-group UUID into
-- a distinguishable list response.
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    'UTC', 100, null, (select member_id from events_for_range_fixture)
  )->'events')),
  1,
  'participant filter returns only rows assigned to the active target'
);
select is(
  (public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    'UTC', 100, null, (select member_id from events_for_range_fixture)
  )->'events'->0->>'id'),
  (select assigned_event_id::text from events_for_range_fixture),
  'participant filtering does not return an unassigned owner-only event'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, null, %L::uuid)',
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    (select inactive_id from events_for_range_fixture)
  ),
  '42501',
  'participant is not an active member of this group',
  'inactive participant targets are rejected without a list leak'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, null, %L::uuid)',
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    (select outsider_id from events_for_range_fixture)
  ),
  '42501',
  'participant is not an active member of this group',
  'outsider participant targets are rejected without a list leak'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, null, %L::uuid)',
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    (select other_owner_id from events_for_range_fixture)
  ),
  '42501',
  'participant is not an active member of this group',
  'cross-group participant targets are rejected without a status leak'
);

-- Outsiders, inactive members, missing groups, and archived groups all fail
-- closed with the same group-unavailable code/message.
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from events_for_range_fixture),
  true
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'an outsider cannot read group event ranges'
);
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from events_for_range_fixture),
  true
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'an inactive member cannot read group event ranges'
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from events_for_range_fixture),
  true
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select archive_group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'archived groups fail closed without returning historical rows'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz)',
    '00000000-0000-4000-8000-00000000ffff',
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'missing groups fail closed with the same authorization result'
);

-- Date/time validation is strict and fail-closed.  Local date ranges are
-- measured after timezone conversion, so a fall-back/short UTC interval is
-- still one valid calendar day.
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'')',
    (select group_id from events_for_range_fixture),
    '2026-03-01T01:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'range endpoints must be local midnight in the view timezone',
  'non-midnight UTC endpoints are rejected'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z',
    'America/New_York', 100, null, null
  )->'events')),
  1,
  'DST local-midnight validation accepts the 23-hour UTC day'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, null, null)',
    (select group_id from events_for_range_fixture),
    '2025-01-01T00:00:00Z', '2026-01-03T00:00:00Z'
  ),
  '22023', 'range must not exceed 366 calendar days',
  'ranges over 366 local calendar days are rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 0)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 200',
  'zero limit is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 201)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 200',
  'limit above the bounded maximum is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'not-a-cursor!'
  ),
  '22023', 'cursor must be an unpadded URL-safe base64 event cursor',
  'malformed cursors are rejected before querying rows'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    repeat('A', 4097)
  ),
  '22023', 'cursor must be an unpadded URL-safe base64 event cursor',
  'oversized cursors are rejected before base64 decoding'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to('[]', 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  'a non-object cursor payload is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 2,
        'starts_at', '2026-03-01T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor version is unsupported',
  'a cursor from another version is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', '1',
        'starts_at', '2026-03-01T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  'a string cursor version is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1.0::numeric,
        'starts_at', '2026-03-01T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  'a floating-point cursor version is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T00:00:00',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp must include an explicit timezone',
  'a timezone-less cursor timestamp is rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp is invalid',
  'cursor timestamps require seconds'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T00:00:00.1234567Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp is invalid',
  'cursor fractions longer than six digits are rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-02-29T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp is invalid',
  'impossible cursor calendar dates are rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T24:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp is invalid',
  'invalid cursor clock components are rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T00:00:00+24:00',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp is invalid',
  'invalid cursor offsets are rejected'
);
do $$
declare
  v_fraction text;
  v_payload jsonb;
begin
  foreach v_fraction in array array['.1', '.12', '.123', '.1234', '.12345', '.123456'] loop
    v_payload := public.events_for_range(
      (select group_id from events_for_range_fixture),
      '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
      'UTC', 100,
      rtrim(translate(replace(encode(convert_to(
        json_build_object(
          'v', 1,
          'starts_at', '2026-03-03T00:00:00' || v_fraction || 'Z',
          'event_id', (select overlap_event_id from events_for_range_fixture)
        )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '='),
      null
    );
    if jsonb_array_length(v_payload->'events') <> 0 then
      raise exception 'valid fraction cursor unexpectedly returned rows';
    end if;
  end loop;
end;
$$;
select ok(
  true,
  'valid cursor fractions from one through six digits are accepted'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 100,
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-03T00:00:00.123456+09:30',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '='),
    null
  )->'events')),
  0,
  'valid six-digit cursor fractions with an explicit offset are accepted'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-01T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture),
        'extra', 'not-allowed'
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  'unknown cursor keys are rejected'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', 'infinity',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor timestamp must include an explicit timezone',
  'non-finite cursor tuples are rejected before timestamp casting'
);

-- A cursor tuple after range_end is valid for the tuple-only contract: the
-- all-day row's stored starts_at is expressed in its own timezone.  It simply
-- yields an empty continuation page rather than leaking or failing.
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 100,
    rtrim(translate(replace(encode(convert_to(
      json_build_object(
        'v', 1,
        'starts_at', '2026-03-03T00:00:00Z',
        'event_id', (select overlap_event_id from events_for_range_fixture)
      )::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '='),
    null
  )->'events')),
  0,
  'a finite tuple after range_end is accepted as an empty continuation'
);

-- Keyset pagination over 1001 same-start events must have no duplicates or
-- omissions.  Direct setup INSERTs exercise the legacy event seed trigger;
-- each event remains at its initial version and gets exactly its creator.
reset role;
create temporary table range_bulk_events (
  event_id uuid primary key
) on commit drop;
grant all on range_bulk_events to authenticated;
insert into public.events (
  group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value
)
select
  (select group_id from events_for_range_fixture),
  (select owner_id from events_for_range_fixture),
  'Bulk range ' || n,
  '',
  '2026-05-01T00:00:00Z',
  '2026-05-01T00:01:00Z',
  'UTC', false, null, null, 1, 305419896
from generate_series(1, 1001) as numbers(n)
returning id;
insert into range_bulk_events(event_id)
select id from public.events
where group_id = (select group_id from events_for_range_fixture)
  and title like 'Bulk range %';
select is(
  (select count(*)::integer from range_bulk_events),
  1001,
  'the bulk pagination fixture contains 1001 events'
);
select ok(
  not exists (
    select 1 from public.events e
    where e.id in (select event_id from range_bulk_events)
      and e.version <> 1
  ),
  'legacy event seed does not bump the initial bulk event versions'
);
select ok(
  not exists (
    select 1
    from public.event_members em
    where em.event_id in (select event_id from range_bulk_events)
    group by em.event_id
    having count(*) <> 1
  ),
  'legacy bulk inserts seed exactly one creator participant each'
);

set local role authenticated;
create temporary table range_seen (
  event_id uuid primary key,
  first_page integer not null
) on commit drop;
grant all on range_seen to authenticated;
do $$
declare
  v_payload jsonb;
  v_cursor text;
  v_group_id uuid;
  v_page integer := 0;
  v_inserted integer;
begin
  select group_id into v_group_id from events_for_range_fixture;
  loop
    v_payload := public.events_for_range(
      v_group_id,
      '2026-05-01T00:00:00Z', '2026-05-02T00:00:00Z',
      'UTC', 200, v_cursor, null
    );
    v_page := v_page + 1;
    insert into range_seen(event_id, first_page)
    select (row_value->>'id')::uuid, v_page
    from jsonb_array_elements(v_payload->'events') as rows(row_value)
    on conflict (event_id) do nothing;
    get diagnostics v_inserted = row_count;
    if not coalesce((v_payload->>'has_more')::boolean, false) then
      exit;
    end if;
    if v_payload->>'next_cursor' is null or v_inserted = 0 then
      raise exception 'pagination did not advance';
    end if;
    v_cursor := v_payload->>'next_cursor';
    if v_page > 10 then
      raise exception 'pagination exceeded expected page bound';
    end if;
  end loop;
end;
$$;
select is(
  (select count(*)::integer from range_seen),
  1001,
  '1001 events paginate without duplicate rows or omissions'
);
select is(
  (select count(*)::integer from range_bulk_events b
   where not exists (select 1 from range_seen s where s.event_id = b.event_id)),
  0,
  'every bulk event appears in exactly one keyset page'
);
select ok(
  (select count(*) from range_seen where first_page = 6) = 1,
  'the final one-row page is preserved after five full pages'
);

select * from finish();
rollback;
