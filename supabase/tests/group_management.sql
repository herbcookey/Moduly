-- pgTAP fixture for the group-management vertical slice.
--
-- This fixture deliberately exercises the API as the real `authenticated`
-- database role with request.jwt.claims set.  Setup-only writes switch back to
-- the session owner, and the whole test is rolled back at the end.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table group_management_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  outsider_id uuid not null,
  cascade_owner_id uuid not null,
  group_id uuid,
  archived_group_id uuid,
  other_group_id uuid,
  cascade_group_id uuid,
  target_active_group_id uuid,
  target_archived_group_id uuid
) on commit drop;
-- The fixture key is non-sensitive test metadata, and API-role updates below
-- only fill generated group IDs. Granting this temporary table avoids a
-- privilege error while still keeping every application-table write scoped.
grant all on group_management_fixture to authenticated;

insert into group_management_fixture (
  owner_id,
  member_id,
  outsider_id,
  cascade_owner_id
) values (
  '00000000-0000-4000-8000-000000009901',
  '00000000-0000-4000-8000-000000009902',
  '00000000-0000-4000-8000-000000009903',
  '00000000-0000-4000-8000-000000009904'
);

-- Auth rows are setup data. The auth trigger creates corresponding profiles.
reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at
) values
  (
    (select owner_id from group_management_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'group-owner@example.test', '',
    now(), now(), now()
  ),
  (
    (select member_id from group_management_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'group-member@example.test', '',
    now(), now(), now()
  ),
  (
    (select outsider_id from group_management_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'group-outsider@example.test', '',
    now(), now(), now()
  ),
  (
    (select cascade_owner_id from group_management_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'group-cascade@example.test', '',
    now(), now(), now()
  )
on conflict (id) do nothing;

-- The owner creates the two initial groups through the existing RPC.  Claims
-- are set in both supported forms because PostgREST and pgTAP stacks differ.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from group_management_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

update group_management_fixture f
set group_id = created.id
from public.create_group('Fixture active', 'Asia/Seoul', 'Fixture group') as created;

update group_management_fixture f
set archived_group_id = created.id
from public.create_group('Fixture archived', 'UTC', '') as created;

select public.archive_group_if_version(
  (select archived_group_id from group_management_fixture),
  1
);

reset role;

-- Membership setup is intentionally outside the API write surface.
insert into public.memberships (group_id, user_id, role, is_active, removed_at)
select group_id, member_id, 'member', true, null
from group_management_fixture;

-- An unrelated group survives deletion of the original owner. Its membership
-- carries invited_by=owner so the FK SET NULL path is covered.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from group_management_fixture),
  true
);
set local role authenticated;
update group_management_fixture f
set other_group_id = created.id
from public.create_group('Fixture other', 'UTC', '') as created;
reset role;

insert into public.memberships (
  group_id, user_id, role, is_active, removed_at, invited_by
)
select other_group_id, cascade_owner_id, 'member', true, null, owner_id
from group_management_fixture;

-- The cascade owner owns a separate group; its owner row and any children must
-- disappear when auth.users is deleted.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select cascade_owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select cascade_owner_id::text from group_management_fixture),
  true
);
set local role authenticated;
update group_management_fixture f
set cascade_group_id = created.id
from public.create_group('Fixture cascade', 'UTC', '') as created;
reset role;

-- Basic catalog/ACL/RLS assertions are made as the session owner.
select ok(
  has_table_privilege('authenticated', 'public.groups', 'select'),
  'authenticated callers retain group SELECT access'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_class c
    where c.oid = 'public.groups'::regclass
      and c.relrowsecurity
  ),
  'groups has RLS enabled'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_index i on i.indexrelid = c.oid
    where c.oid = 'public.memberships_one_active_owner_idx'::regclass
      and i.indrelid = 'public.memberships'::regclass
      and i.indisunique
      and i.indisvalid
      and i.indnkeyatts = 1
      and i.indnatts = 1
      and i.indkey[0] = (
        select a.attnum
        from pg_catalog.pg_attribute a
        where a.attrelid = 'public.memberships'::regclass
          and a.attname = 'group_id'
      )
      and i.indexprs is null
      and pg_catalog.regexp_replace(
        pg_catalog.regexp_replace(
          pg_catalog.lower(pg_catalog.pg_get_expr(i.indpred, i.indrelid)),
          '::public.group_member_role', '::group_member_role', 'g'
        ),
        '[[:space:]]+', '', 'g'
      ) = '((role=''owner''::group_member_role)andis_active)'
  ),
  'active owner partial unique index exists with the expected definition'
);
select ok(
  not has_column_privilege('authenticated', 'public.groups', 'owner_id', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.groups', 'name', 'UPDATE'),
  'authenticated callers cannot update group ownership or details directly'
);
select ok(
  not has_column_privilege('authenticated', 'public.memberships', 'role', 'UPDATE'),
  'authenticated callers cannot update membership roles directly'
);
select ok(
  not has_column_privilege('authenticated', 'public.memberships', 'is_active', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.memberships', 'removed_at', 'UPDATE'),
  'authenticated callers cannot update membership status directly; moderation is RPC-only'
);
select ok(
  not exists (
    select 1
    from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  )
  or (
    exists (
      select 1 from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public' and tablename = 'events'
    )
    and exists (
      select 1 from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public' and tablename = 'groups'
    )
    and exists (
      select 1 from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public' and tablename = 'memberships'
    )
  ),
  'supabase_realtime includes events, groups, and memberships when available'
);

-- RLS is evaluated under the actual API role, not the test superuser.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from group_management_fixture),
  true
);
set local role authenticated;
select is(
  (select count(*)::integer
   from public.groups
   where id in (
     (select group_id from group_management_fixture),
     (select archived_group_id from group_management_fixture)
   )),
  1,
  'owner RLS hides the archived group while retaining the active group'
);
select is(
  (select count(*)::integer
   from public.memberships
   where group_id = (select group_id from group_management_fixture)),
  2,
  'owner RLS exposes all active memberships in the active group'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
  true
);
select is(
  (select count(*)::integer
   from public.groups
   where id = (select group_id from group_management_fixture)),
  1,
  'active ordinary member can see the active group'
);
select is(
  (select count(*)::integer
   from public.groups
   where id = (select archived_group_id from group_management_fixture)),
  0,
  'active ordinary member cannot see an archived group'
);
select is(
  (select count(*)::integer
   from public.memberships
   where group_id = (select group_id from group_management_fixture)),
  2,
  'active ordinary member sees active memberships in the shared group'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from group_management_fixture),
  true
);
select is(
  (select count(*)::integer
   from public.groups
   where id in (
     (select group_id from group_management_fixture),
     (select archived_group_id from group_management_fixture)
   )),
  0,
  'outsider RLS cannot see either fixture group'
);
reset role;

-- Update trims the name, validates the exact timezone, and increments once.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from group_management_fixture),
  true
);
set local role authenticated;
select is(
  (select g.name
   from public.update_group_if_version(
     (select group_id from group_management_fixture),
     1,
     '  Renamed fixture  ',
     'Description',
     'Asia/Seoul'
   ) as g),
  'Renamed fixture'::text,
  'update_group_if_version trims the group name'
);
select is(
  (select g.description
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  'Description'::text,
  'update_group_if_version stores the bounded description'
);
select is(
  (select g.version
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  2,
  'update_group_if_version increments version'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 2, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Next', '', 'Not/A/Timezone'
  ),
  '22023',
  'timezone must be an exact IANA timezone name',
  'invalid IANA timezone is rejected'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 1, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Stale', '', 'UTC'
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'stale group update is rejected'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 2, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Too long', repeat('x', 10001), 'UTC'
  ),
  '22023',
  'group description must be at most 10000 characters',
  'group description length is bounded'
);

-- A stale version is rejected for every owner-only terminal/ownership RPC,
-- including transfer and archive. The owner remains unchanged after each
-- failed attempt.
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'owner cannot transfer with a stale version'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'owner cannot archive with a stale version'
);

-- Active members and outsiders cannot use any owner-only RPC, even when they
-- present an old/stale version. All failures use the same safe conflict code.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
  true
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 1, %L, %L, %L)',
    (select group_id from group_management_fixture), 'Member update', '', 'UTC'
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'active members cannot perform stale group updates'
);
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select outsider_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'active members cannot perform stale ownership transfers'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'active members cannot perform stale archives'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from group_management_fixture),
  true
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 1, %L, %L, %L)',
    (select group_id from group_management_fixture), 'Outsider update', '', 'UTC'
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'outsiders cannot perform stale group updates'
);
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'outsiders cannot perform stale ownership transfers'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  'outsiders cannot perform stale archives'
);

-- Leave is self-only and only deactivates an ordinary member.  The owner and
-- outsider attempts are made through the same authenticated role.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
true
);
select public.leave_group((select group_id from group_management_fixture));
-- The caller is inactive immediately after leaving and therefore no longer
-- passes the ordinary-member SELECT policy. Inspect the historical row as
-- the setup role, then return to authenticated for the rejection path.
reset role;
select is(
  (select m.is_active
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  false,
  'leave_group marks the caller inactive'
);
select ok(
  (select m.removed_at is not null
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  'leave_group records removed_at'
);
set local role authenticated;
select throws_ok(
  format('select public.leave_group(%L::uuid)', (select archived_group_id from group_management_fixture)),
  '42501',
  'only an active ordinary member can leave this group',
  'members cannot leave archived groups'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from group_management_fixture),
  true
);
select throws_ok(
  format('select public.leave_group(%L::uuid)', (select group_id from group_management_fixture)),
  '42501',
  'only an active ordinary member can leave this group',
  'group owners cannot leave'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from group_management_fixture),
  true
);
select throws_ok(
  format('select public.leave_group(%L::uuid)', (select group_id from group_management_fixture)),
  '42501',
  'only an active ordinary member can leave this group',
  'outsiders cannot leave'
);

-- Restore only the fixture member status through the setup role before transfer.
reset role;
update public.memberships m
set is_active = true, removed_at = null
where m.group_id = (select group_id from group_management_fixture)
  and m.user_id = (select member_id from group_management_fixture);

-- Transfer is one atomic owner -> member / member -> owner operation.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from group_management_fixture),
  true
);
set local role authenticated;
select is(
  (select g.owner_id
   from public.transfer_group_ownership(
     (select group_id from group_management_fixture),
     (select member_id from group_management_fixture),
     2
   ) as g),
  (select member_id from group_management_fixture),
  'transfer_group_ownership returns the new owner'
);
select is(
  (select g.version
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  3,
  'ownership transfer increments group version atomically'
);
select is(
  (select count(*)::integer
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.role = 'owner' and m.is_active and m.removed_at is null),
  1,
  'transfer leaves exactly one active owner'
);
select is(
  (select m.role::text
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select owner_id from group_management_fixture)),
  'member'::text,
  'old owner is demoted to member'
);
select is(
  (select m.role::text
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  'owner'::text,
  'target member is promoted to owner'
);

-- The current (new) owner cannot self-leave or self-deactivate. These are the
-- last-owner paths rather than an artificial direct role update.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
  true
);
select throws_ok(
  format('select public.leave_group(%L::uuid)', (select group_id from group_management_fixture)),
  '42501',
  'only an active ordinary member can leave this group',
  'the new owner cannot leave through the self-only RPC'
);
select throws_ok(
  format(
    'select public.set_member_active(%L::uuid, %L::uuid, false)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '42501',
  'only the owner can change another member',
  'the new owner cannot self-deactivate through moderation RPC'
);

-- Add one active and one archived group owned by the new owner for preflight.
update group_management_fixture f
set target_active_group_id = created.id
from public.create_group('Fixture target active', 'UTC', '') as created;
update group_management_fixture f
set target_archived_group_id = created.id
from public.create_group('Fixture target archived', 'UTC', '') as created;
select public.archive_group_if_version(
  (select target_archived_group_id from group_management_fixture),
  1
);
reset role;

-- Authored children are counted by preflight and retained by soft archive.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at,
  timezone, is_all_day, all_day_start, all_day_end, version
) values (
  '00000000-0000-4000-8000-000000009201',
  (select group_id from group_management_fixture),
  (select member_id from group_management_fixture),
  'Fixture event', '', now() + interval '1 day', now() + interval '1 day 1 hour',
  'UTC', false, null, null, 1
);
insert into public.invite_codes (
  id, group_id, created_by, token_hash, expires_at, max_uses, uses_count, version
) values (
  '00000000-0000-4000-8000-000000009301',
  (select group_id from group_management_fixture),
  (select member_id from group_management_fixture),
  repeat('a', 64), now() + interval '1 day', 2, 0, 1
);

-- Exact preflight summary: three owned groups (two active, one archived), one
-- authored event/invite, and four memberships across owned groups.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
  true
);
set local role authenticated;
select is(
  jsonb_array_length(public.account_deletion_preflight() -> 'owned_groups'),
  3,
  'preflight lists all active and archived groups owned by the caller'
);
select is(
  jsonb_array_length(public.account_deletion_preflight() -> 'active_owned_groups'),
  2,
  'preflight lists the two active owned groups'
);
select is(
  jsonb_array_length(public.account_deletion_preflight() -> 'archived_owned_groups'),
  1,
  'preflight lists the archived owned group'
);
select is(
  (public.account_deletion_preflight() ->> 'groups')::bigint,
  3::bigint,
  'preflight group count is exact'
);
select is(
  (public.account_deletion_preflight() ->> 'events')::bigint,
  1::bigint,
  'preflight event cascade count is exact'
);
select is(
  (public.account_deletion_preflight() ->> 'invites')::bigint,
  1::bigint,
  'preflight invite cascade count is exact'
);
select is(
  (public.account_deletion_preflight() ->> 'memberships')::bigint,
  4::bigint,
  'preflight membership cascade count is exact'
);
select ok(
  (public.account_deletion_preflight() ->> 'owned_groups') not like '%' || (select member_id::text from group_management_fixture) || '%'
    and (public.account_deletion_preflight() ->> 'owned_groups') not like '%' || (select owner_id::text from group_management_fixture) || '%',
  'preflight summary does not expose user UUIDs or PII'
);

-- Direct table writes fail with ACLs even for the owner; RPCs remain usable.
select throws_ok(
  format(
    'update public.groups set name = %L where id = %L::uuid',
    'bypass',
    (select group_id from group_management_fixture)
  ),
  '42501',
  'direct groups UPDATE is denied by ACL'
);
select throws_ok(
  format(
    'update public.memberships set role = %L where group_id = %L::uuid and user_id = %L::uuid',
    'member',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '42501',
  'direct membership role UPDATE is denied by ACL'
);
reset role;

-- A malformed transfer marker cannot bypass immutable ownership triggers.
select set_config(
  'moduly.transfer_marker',
  json_build_object('group_id', (select target_active_group_id::text from group_management_fixture))::text,
  true
);
select throws_ok(
  format(
    'update public.groups set owner_id = %L::uuid where id = %L::uuid',
    (select owner_id from group_management_fixture),
    (select target_active_group_id from group_management_fixture)
  ),
  '42501',
  'group owner_id is immutable outside transfer_group_ownership',
  'malformed transfer marker is rejected'
);
select set_config('moduly.transfer_marker', '', true);

-- Archive is terminal/versioned. Child rows are hidden by RLS but not deleted.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from group_management_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from group_management_fixture),
  true
);
set local role authenticated;
select public.archive_group_if_version(
  (select group_id from group_management_fixture),
  3
);
select throws_ok(
  format('select public.archive_group_if_version(%L::uuid, 4)', (select group_id from group_management_fixture)),
  '40001',
  'group was changed, archived, or is not yours',
  'archived group is terminal'
);
select is(
  (select count(*)::integer from public.groups where id = (select group_id from group_management_fixture)),
  0,
  'RLS hides an archived group from its former owner'
);
select is(
  (select count(*)::integer from public.events where id = '00000000-0000-4000-8000-000000009201'),
  0,
  'RLS hides archived events'
);
select is(
  (select count(*)::integer from public.invite_codes where id = '00000000-0000-4000-8000-000000009301'),
  0,
  'RLS hides archived invites'
);
select is(
  (select count(*)::integer from public.memberships where group_id = (select group_id from group_management_fixture)),
  0,
  'RLS hides archived memberships'
);
reset role;

select is(
  (select count(*)::integer from public.groups where id = (select group_id from group_management_fixture)),
  1,
  'archived group row remains stored for account-deletion cascade'
);
select is(
  (select count(*)::integer from public.events where id = '00000000-0000-4000-8000-000000009201'),
  1,
  'archived event child remains stored'
);
select is(
  (select count(*)::integer from public.invite_codes where id = '00000000-0000-4000-8000-000000009301'),
  1,
  'archived invite child remains stored'
);
select ok(
  exists (
    select 1
    from public.audit_logs a
    where a.group_id = (select group_id from group_management_fixture)
      and a.entity_type = 'groups'
      and a.action = 'soft_delete'
  ),
  'archive records a soft_delete audit action'
);

-- Delete the original owner. Its archived owned group is cascaded, while the
-- transferred/other groups survive. invited_by is SET NULL in the survivor.
delete from auth.users
where id = (select owner_id from group_management_fixture);
select is(
  (select count(*)::integer from public.groups where id = (select archived_group_id from group_management_fixture)),
  0,
  'deleting an owner cascades its archived owned group'
);
select is(
  (select invited_by
   from public.memberships
   where group_id = (select other_group_id from group_management_fixture)
     and user_id = (select cascade_owner_id from group_management_fixture)),
  null::uuid,
  'invited_by is nulled in a surviving group when inviter is deleted'
);
select is(
  (select count(*)::integer
   from public.groups
   where id = (select group_id from group_management_fixture)),
  1,
  'ownership transfer keeps the surviving group after old owner deletion'
);
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'memberships'
      and a.entity_id is not null
  ),
  'membership audit rows never retain a user UUID'
);
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'memberships'
      and a.metadata::text ~ '9901|9902|9903|9904'
  ),
  'membership audit metadata contains no user UUID or PII'
);

delete from auth.users
where id = (select cascade_owner_id from group_management_fixture);
select is(
  (select count(*)::integer from public.groups where id = (select cascade_group_id from group_management_fixture)),
  0,
  'deleting another owner cascades its group and memberships'
);

select * from finish();
rollback;
