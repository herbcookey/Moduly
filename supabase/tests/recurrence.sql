-- pgTAP fixture for Feature 2 recurrence rules.
--
-- Setup writes are performed as the local migration owner.  RPC calls run as
-- the real authenticated role so RLS, author-only policy, and bounded cursor
-- contracts are exercised together.

begin;
create extension if not exists pgtap;
select no_plan();

create temporary table recurrence_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  outsider_id uuid not null,
  inactive_id uuid not null,
  group_id uuid,
  event_id uuid,
  monthly_id uuid,
  dst_id uuid,
  all_day_id uuid
) on commit drop;
grant all on recurrence_fixture to authenticated;
insert into recurrence_fixture values (
  '00000000-0000-4000-8000-00000000e101',
  '00000000-0000-4000-8000-00000000e102',
  '00000000-0000-4000-8000-00000000e103',
  '00000000-0000-4000-8000-00000000e104',
  null, null, null, null, null
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) select owner_id, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'rec-owner@example.test', '', now(), now(),
  '{}'::jsonb from recurrence_fixture
union all select member_id, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'rec-member@example.test', '', now(), now(),
  '{}'::jsonb from recurrence_fixture
union all select outsider_id, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'rec-outsider@example.test', '', now(), now(),
  '{}'::jsonb from recurrence_fixture
union all select inactive_id, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'rec-inactive@example.test', '', now(), now(),
  '{}'::jsonb from recurrence_fixture
on conflict (id) do nothing;

select set_config('request.jwt.claims', json_build_object(
  'sub', (select owner_id::text from recurrence_fixture), 'role', 'authenticated'
)::text, true);
select set_config('request.jwt.claim.sub', (select owner_id::text from recurrence_fixture), true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
update recurrence_fixture f set group_id = created.id
from public.create_group('Recurrence fixture', 'UTC', '') as created;
reset role;

insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
values
  ((select group_id from recurrence_fixture), (select member_id from recurrence_fixture), 'member', true, now(), null),
  ((select group_id from recurrence_fixture), (select inactive_id from recurrence_fixture), 'member', false, now(), now());

-- Creator, participant, and an explicit empty assignment list are all covered
-- by the RPC contract; NULL member_ids defaults to the creator.
set local role authenticated;
update recurrence_fixture f set event_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'Daily series', 'base note',
  '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
  305419896::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 3, null, null
) as created;
reset role;

select is((select count(*)::integer from public.event_recurrence_rules
           where event_id = (select event_id from recurrence_fixture)), 1,
          'recurring create stores one additive root segment');
select is((select count(*)::integer from public.event_members
           where event_id = (select event_id from recurrence_fixture)), 1,
          'participants inherit from the series event_members relation');

set local role authenticated;
select throws_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'invalid interval zero', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'daily', 0, '{}'::smallint[], 'never', null, null, null)$$,
  '22023', null, 'interval zero is rejected');
select throws_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'invalid interval thousand', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'daily', 1000, '{}'::smallint[], 'never', null, null)$$,
  '22023', null, 'interval 1000 is rejected');
reset role;

set local role authenticated;
select is(
  jsonb_array_length((public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
  )->'events')),
  3,
  'daily count expansion is finite and bounded'
);
select is((select occurrence_key from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'o00000000000000000001',
  'point reads resolve the stable ordinal key');
reset role;

-- A page of two rows returns a strict v2 cursor and the next page has one row.
set local role authenticated;
select is((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 2, null, null
)->>'has_more')::boolean, true, 'v2 range uses limit+1 keyset pagination');
select isnt(public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 2, null, null
)->>'next_cursor', null, 'v2 page carries an opaque cursor');
reset role;

-- This-scope update creates a full snapshot and bumps the anchor once.
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 1, 'o00000000000000000001', 'this',
  'Changed occurrence', 'changed note', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 7::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'committed')::boolean, 'this-scope update commits a sparse full snapshot');
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 2, 'o00000000000000000001', 'this',
  'Changed occurrence', 'changed note', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 7::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, false, 'identical this-scope replay is a no-op');
select is((select version from public.events where id = (select event_id from recurrence_fixture)), 2,
          'this-scope update bumps the parent version exactly once');
select is((select title from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'Changed occurrence', 'this override inherits no stale title');
reset role;

set local role authenticated;
select ok((public.delete_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 2, 'o00000000000000000000', 'this'
)->>'committed')::boolean, 'this-scope delete commits an exception cancellation');
select is((public.delete_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 3, 'o00000000000000000000', 'this'
)->>'changed')::boolean, false, 'replaying a cancellation is an idempotent no-op');
reset role;
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 3, 'o00000000000000000002', 'this',
  'Later exception', 'later note', '2026-01-03T14:00:00Z',
  '2026-01-03T15:00:00Z', 'UTC', false, null, null, 6::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, 'second sparse exception is recorded');
reset role;
set local role authenticated;
select is(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
)->'events')), 2, 'cancelled occurrence is omitted without deleting the series');
reset role;

-- Future edits split at the selected ordinal, clear later sparse exceptions,
-- and retain the global occurrence key.
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 4, 'o00000000000000000002', 'future',
  'Future title', 'future note', '2026-01-03T08:00:00Z',
  '2026-01-03T09:00:00Z', 'UTC', false, null, null, 8::bigint,
  null::uuid[], 'daily', 2, '{}'::smallint[], 'never', null, null, null
)->>'committed')::boolean, 'future-scope update splits the series');
reset role;
select is((select count(*)::integer from public.event_recurrence_rules
           where event_id = (select event_id from recurrence_fixture)), 2,
          'future split leaves two non-overlapping segments');
select is((select occurrence_key from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000002'
)), 'o00000000000000000002', 'future split preserves the selected key');

-- All-scope replacement atomically resets sparse exceptions and participants;
-- replaying the same payload is an explicit changed=false no-op.
set local role authenticated;
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 5, 'o00000000000000000002', 'all',
  'All reset', 'all note', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z',
  'UTC', false, null, null, 10::bigint,
  array[(select owner_id from recurrence_fixture)]::uuid[],
  'daily', 1, '{}'::smallint[], 'never', null, null, null
)->>'changed')::boolean, true, 'all-scope replacement commits one parent mutation');
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 6, 'o00000000000000000002', 'all',
  'All reset', 'all note', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z',
  'UTC', false, null, null, 10::bigint,
  array[(select owner_id from recurrence_fixture)]::uuid[],
  'daily', 1, '{}'::smallint[], 'never', null, null, null
)->>'changed')::boolean, false, 'all-scope identical replay is a no-op');
reset role;
select is((select title from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'All reset', 'all-scope replacement clears earlier sparse exception');
select is((select occurrence_version from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 0, 'all-scope replacement clears occurrence version');
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 6, 'o00000000000000000001', 'this',
  'Post-reset exception', 'post reset', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 11::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, true, 'exceptions can be recreated after an all reset');
reset role;

-- Monthly clamp and all-day half-open projection.
set local role authenticated;
update recurrence_fixture f set monthly_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'Month end', '',
  '2026-01-31T09:00:00Z', '2026-01-31T10:00:00Z', 'UTC', false, null, null,
  1::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 31::smallint
) as created;
update recurrence_fixture f set dst_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'DST', '',
  '2026-03-07T09:00:00-05:00', '2026-03-07T10:00:00-05:00',
  'America/New_York', false, null, null, 1::bigint, null,
  'daily', 1, '{}'::smallint[], 'count', 5, null, null
) as created;
update recurrence_fixture f set all_day_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'All day', '',
  '2026-01-01T00:00:00Z', '2026-01-03T00:00:00Z', 'UTC', true,
  '2026-01-01', '2026-01-03', 1::bigint, null,
  'daily', 1, '{}'::smallint[], 'count', 2, null, null
) as created;
reset role;

select is((select starts_at::date from public.event_occurrence_by_key(
  (select monthly_id from recurrence_fixture), 'o00000000000000000001'
)), '2026-02-28'::date, 'monthly day 31 clamps to February end');
select is(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-03-06T00:00:00Z', '2026-03-13T00:00:00Z', 'UTC', 100, null, null
)->'events')), 5, 'DST rule expands only the finite requested count');
select is((select all_day_end from public.event_occurrence_by_key(
  (select all_day_id from recurrence_fixture), 'o00000000000000000001'
)), '2026-01-04'::date, 'all-day occurrence uses a local half-open end date');

-- Author-only and optimistic version boundaries.
set local role authenticated;
select set_config('request.jwt.claim.sub', (select member_id::text from recurrence_fixture), true);
select ok(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null
)->'events')) > 0, 'active group members can read the range');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', 'this',
    'member cannot edit', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '40001', null, 'active non-author cannot mutate recurrence');
reset role;

select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 999, 'o00000000000000000001', 'this',
    'bad', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '40001', null, 'stale parent version is rejected'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', (select outsider_id::text from recurrence_fixture), true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '42501', null, 'outsider cannot read a group range'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', (select inactive_id::text from recurrence_fixture), true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '42501', null, 'deactivated member cannot read a group range'
);
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '28000', null, 'anonymous caller is rejected before group lookup'
);
reset role;

-- Additional boundary contracts: recurring singleton aliases, inherited
-- future counts, moved-in sparse snapshots, NULL scope, and anonymous guards.
create temporary table recurrence_extra (event_id uuid not null, moved_id uuid not null) on commit drop;
grant all on recurrence_extra to authenticated;
set local role authenticated;
insert into recurrence_extra(event_id, moved_id)
select
  (select id from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'Future inherited count', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    12::bigint, null, 'daily', 1, '{}'::smallint[], 'count', 5, null, null)),
  (select id from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'Moved far', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    13::bigint, null, 'daily', 1, '{}'::smallint[], 'never', null, null, null));
select is((select occurrence_key from public.event_occurrence_by_key(
  (select event_id from recurrence_extra), 'single')),
  'o00000000000000000000', 'recurring point aliases the legacy single sentinel to ordinal zero');
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_extra), 1, 'o00000000000000000001', 'future',
  null, null, null, null, null, null, null, null, null, null,
  null, null, null, null, null, null, null
)->>'changed')::boolean, 'future split with inherited count commits');
select is(((select recurrence_rule from public.event_occurrence_by_key(
  (select event_id from recurrence_extra), 'o00000000000000000001'))->>'count')::integer),
  4, 'future inherited count subtracts consumed ordinals');
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_extra), 2, 'o00000000000000000002', 'future',
  null, null, null, null, null, null, null, null, null, null,
  null, null, null, null, null, null, null
)->>'changed')::boolean, 'sequential future split commits');
select is(((select recurrence_rule from public.event_occurrence_by_key(
  (select event_id from recurrence_extra), 'o00000000000000000002'))->>'count')::integer),
  3, 'sequential future inheritance retains remaining count');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_extra), 3, 'o00000000000000000002', 'future',
    null, null, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, 4::smallint)$$,
  '22023', null, 'inherited non-monthly future rule rejects monthly_day');
select ok((public.update_event_occurrence_scope_if_version(
  (select moved_id from recurrence_extra), 1, 'o00000000000000000000', 'this',
  'Moved far', '', '2027-06-10T09:00:00Z', '2027-06-10T10:00:00Z', 'UTC', false,
  null, null, 13::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, 'far moved override commits');
select ok(exists (select 1 from jsonb_array_elements((public.events_for_range_v2(
  (select group_id from recurrence_fixture), '2027-06-01T00:00:00Z',
  '2027-06-30T00:00:00Z', 'UTC', 100, null, null))->'events') e
  where e->>'event_id' = (select moved_id::text from recurrence_extra)
    and e->>'occurrence_key' = 'o00000000000000000000'),
  'range union discovers far moved override');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', null::text,
    'bad scope', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '22023', null, 'NULL update scope is rejected');
select throws_ok(
  $$select public.delete_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', null::text)$$,
  '22023', null, 'NULL delete scope is rejected');
reset role;

-- Participant-only recurring replacement has a dedicated receipt RPC.  The
-- creator is mandatory even for a group-owner caller; canonical input is a
-- no-op when it already matches, and anonymous callers are rejected first.
select set_config('request.jwt.claims', json_build_object(
  'sub', (select owner_id::text from recurrence_fixture), 'role', 'authenticated'
)::text, true);
select set_config('request.jwt.claim.sub', (select owner_id::text from recurrence_fixture), true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select throws_ok(
  $$select public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select member_id from recurrence_fixture)]::uuid[])$$,
  '42501', null, 'recurring member replacement rejects creator omission');
select is(
  (public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[]
  )->>'changed')::boolean,
  false,
  'recurring member replacement canonical no-op keeps the version');
select is(
  public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[]
  )->>'occurrence_key',
  'o00000000000000000000',
  'recurring member replacement canonicalizes single to ordinal zero');
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[])$$,
  '28000', null, 'anonymous recurring member replacement is rejected');
reset role;

select has_function_privilege(
  'authenticated',
  'public.replace_recurring_event_members_if_version(uuid,integer,text,uuid[])',
  'execute'
), 'dedicated recurring member RPC is executable only through authenticated role';
select ok(
  not has_function_privilege(
    'anon',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ),
  'compatibility wrapper public ACL is revoked'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ),
  'compatibility wrapper authenticated ACL is granted'
);
select ok(
  case when exists (
    select 1 from pg_catalog.pg_roles where rolname = 'service_role'
  ) then not has_function_privilege(
    'service_role',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ) else true end,
  'compatibility wrapper service_role ACL is revoked'
);

-- Direct child access is revoked even for an authenticated caller.
set local role authenticated;
select throws_ok(
  $$select count(*) from public.event_recurrence_rules$$,
  '42501', null, 'direct recurrence rule reads are denied by ACL'
);
reset role;

-- Hard deletion must cascade both sparse children and recurrence segments.
delete from public.events where id = (select monthly_id from recurrence_fixture);
select is((select count(*)::integer from public.event_recurrence_rules
           where event_id = (select monthly_id from recurrence_fixture)), 0,
          'event hard delete cascades recurrence segments');
select is((select count(*)::integer from public.event_occurrence_overrides
           where event_id = (select event_id from recurrence_fixture)), 1,
          'unrelated series exceptions remain intact after cascade');

select * from finish();
rollback;
