-- pgTAP fixture for Feature G's bounded, group-scoped event search RPC.
--
-- Setup runs as the migration owner; read calls run as authenticated.  The
-- entire fixture is transactional and is safe to run against a disposable
-- Supabase/PostgreSQL database.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table event_search_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  inactive_id uuid not null,
  outsider_id uuid not null,
  other_owner_id uuid not null,
  group_id uuid not null,
  archive_group_id uuid not null,
  other_group_id uuid not null,
  korean_event_id uuid not null,
  member_event_id uuid not null,
  nfc_event_id uuid not null,
  nfd_event_id uuid not null,
  dst_event_id uuid not null,
  recurring_event_id uuid not null,
  bulk_group_id uuid not null,
  canonical_cursor text
) on commit drop;
grant all on event_search_fixture to authenticated;

insert into event_search_fixture (
  owner_id, member_id, inactive_id, outsider_id, other_owner_id,
  group_id, archive_group_id, other_group_id,
  korean_event_id, member_event_id, nfc_event_id, nfd_event_id,
  dst_event_id, recurring_event_id, bulk_group_id
) values (
  '00000000-0000-4000-8000-00000000a101',
  '00000000-0000-4000-8000-00000000a102',
  '00000000-0000-4000-8000-00000000a103',
  '00000000-0000-4000-8000-00000000a104',
  '00000000-0000-4000-8000-00000000a105',
  '00000000-0000-4000-8000-00000000a201',
  '00000000-0000-4000-8000-00000000a202',
  '00000000-0000-4000-8000-00000000a203',
  '00000000-0000-4000-8000-00000000a301',
  '00000000-0000-4000-8000-00000000a302',
  '00000000-0000-4000-8000-00000000a303',
  '00000000-0000-4000-8000-00000000a304',
  '00000000-0000-4000-8000-00000000a305',
  '00000000-0000-4000-8000-00000000a306',
  '00000000-0000-4000-8000-00000000a307'
);

reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  ((select owner_id from event_search_fixture),
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-owner@example.test', '', now(), now(), now(),
   '{"display_name":"Search owner"}'::jsonb),
  ((select member_id from event_search_fixture),
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-member@example.test', '', now(), now(), now(),
   '{"display_name":"Search member"}'::jsonb),
  ((select inactive_id from event_search_fixture),
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-inactive@example.test', '', now(), now(), now(),
   '{"display_name":"Search inactive"}'::jsonb),
  ((select outsider_id from event_search_fixture),
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-outsider@example.test', '', now(), now(), now(),
   '{"display_name":"Search outsider"}'::jsonb),
  ((select other_owner_id from event_search_fixture),
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'search-other-owner@example.test', '', now(), now(), now(),
   '{"display_name":"Other owner"}'::jsonb)
on conflict (id) do nothing;

insert into public.groups (
  id, owner_id, name, description, timezone, version, deleted_at,
  created_at, updated_at
) values
  ((select group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   'Search fixture', 'Search fixture group', 'UTC', 1, null,
   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select archive_group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   'Archived search fixture', '', 'UTC', 1, null,
   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select other_group_id from event_search_fixture),
   (select other_owner_id from event_search_fixture),
   'Other search fixture', '', 'UTC', 1, null,
   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select bulk_group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   'Bulk search fixture', '', 'UTC', 1, null,
   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');

insert into public.memberships (
  group_id, user_id, role, is_active, joined_at, removed_at
) values
  ((select group_id from event_search_fixture),
   (select member_id from event_search_fixture),
   'member', true, '2026-01-01T00:00:00Z', null),
  ((select group_id from event_search_fixture),
   (select inactive_id from event_search_fixture),
   'member', false, '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'),
  ((select bulk_group_id from event_search_fixture),
   (select member_id from event_search_fixture),
   'member', true, '2026-01-01T00:00:00Z', null);

-- Live singleton rows.  The description deliberately includes wildcard,
-- backslash, quote, and SQL-like text; position/lower must treat each as a
-- literal substring rather than SQL pattern syntax.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values
  ((select korean_event_id from event_search_fixture),
   (select group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   '회의 일정',
   '🍕 Special %_\\ "O''Reilly" SELECT * FROM events WHERE id = 1',
   '2026-03-01T09:00:00Z', '2026-03-01T10:00:00Z', 'UTC', false,
   null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select member_event_id from event_search_fixture),
   (select group_id from event_search_fixture),
   (select member_id from event_search_fixture),
   'Member-created planning', 'Active creator filter',
   '2026-03-01T11:00:00Z', '2026-03-01T12:00:00Z', 'UTC', false,
   null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select nfc_event_id from event_search_fixture),
   (select group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   U&'Caf\00E9', 'NFC title',
   '2026-03-01T13:00:00Z', '2026-03-01T14:00:00Z', 'UTC', false,
   null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select nfd_event_id from event_search_fixture),
   (select group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   U&'Cafe\0301', 'NFD title',
   '2026-03-01T15:00:00Z', '2026-03-01T16:00:00Z', 'UTC', false,
   null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ((select dst_event_id from event_search_fixture),
   (select group_id from event_search_fixture),
   (select owner_id from event_search_fixture),
   'DST event', 'New York daylight transition',
   '2026-03-08T15:00:00Z', '2026-03-08T16:00:00Z', 'America/New_York', false,
   null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');

insert into public.event_members (event_id, user_id)
select e.id, (select member_id from event_search_fixture)
  from public.events e
 where e.id in (
   (select korean_event_id from event_search_fixture),
   (select member_event_id from event_search_fixture),
   (select nfc_event_id from event_search_fixture),
   (select nfd_event_id from event_search_fixture),
   (select dst_event_id from event_search_fixture)
 )
on conflict (event_id, user_id) do nothing;

-- A recurring row and a full effective override prove that search uses the
-- materialized occurrence title/description, not only the anchor event.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
) values (
  (select recurring_event_id from event_search_fixture),
  (select group_id from event_search_fixture),
  (select owner_id from event_search_fixture),
  'Series anchor', 'Series anchor description',
  '2026-03-10T09:00:00Z', '2026-03-10T10:00:00Z', 'UTC', false,
  null, null, 1, 305419896, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
);
insert into public.event_members (event_id, user_id)
values (
  (select recurring_event_id from event_search_fixture),
  (select member_id from event_search_fixture)
)
on conflict (event_id, user_id) do nothing;
insert into public.event_recurrence_rules (
  event_id, segment_no, start_occurrence_index, end_occurrence_index,
  frequency, interval_value, weekdays, monthly_day, end_mode, occurrence_count,
  until_date, anchor_local_date, anchor_local_time, timezone, is_all_day,
  duration_seconds, duration_days, title, description, color_value, version,
  created_at, updated_at
) values (
  (select recurring_event_id from event_search_fixture), 0, 0, null,
  'daily', 1, '{}'::smallint[], null, 'count', 2, null,
  '2026-03-10', '09:00:00', 'UTC', false, 3600, null,
  '반복 회의', '기본 설명', 305419896, 1,
  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
);
insert into public.event_occurrence_overrides (
  event_id, occurrence_index, occurrence_key, is_cancelled,
  title, description, starts_at, ends_at, timezone, is_all_day,
  all_day_start, all_day_end, color_value, version, created_at, updated_at
) values (
  (select recurring_event_id from event_search_fixture), 1,
  'o00000000000000000001', false,
  '오버라이드 회의', '오버라이드 🎯 %_\\',
  '2026-03-11T09:00:00Z', '2026-03-11T10:00:00Z', 'UTC', false,
  null, null, 305419896, 1,
  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
);

-- Bulk rows are intentionally >1000.  Each row has a unique starts_at value,
-- allowing the loop below to prove no keyset duplicate or omission.
insert into public.events (
  id, group_id, created_by, title, description, starts_at, ends_at, timezone,
  is_all_day, all_day_start, all_day_end, version, color_value,
  created_at, updated_at
)
select extensions.gen_random_uuid(),
       (select bulk_group_id from event_search_fixture),
       (select owner_id from event_search_fixture),
       'Bulk event ' || g::text, 'bulk payload',
       '2026-04-01T00:00:00Z'::timestamptz + make_interval(mins => g),
       '2026-04-01T00:01:00Z'::timestamptz + make_interval(mins => g),
       'UTC', false, null, null, 1, 305419896,
       '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
  from generate_series(0, 1000) as g;
insert into public.event_members (event_id, user_id)
select e.id, (select member_id from event_search_fixture)
  from public.events e
 where e.group_id = (select bulk_group_id from event_search_fixture)
on conflict (event_id, user_id) do nothing;

-- Archive one group after its rows exist; the function must return the same
-- neutral authorization error as a missing or inaccessible group.
update public.groups
   set deleted_at = '2026-02-01T00:00:00Z', version = 2
 where id = (select archive_group_id from event_search_fixture);

-- Catalog/ACL/security checks are performed before changing role.
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
     where c.oid = 'public.events_group_creator_start_id_live_idx'::regclass
       and c.relkind = 'i'
  ),
  'creator-filter partial B-tree index exists'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)',
    'execute'
  ),
  'authenticated can execute search_events_v1'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)',
    'execute'
  )
  and not has_function_privilege(
    'public',
    'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)',
    'execute'
  ),
  'anon and PUBLIC cannot execute search_events_v1'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_proc p
     where p.oid = 'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)'::regprocedure
       and p.prosecdef
       and p.proconfig @> array['search_path=""']::text[]
  ),
  'search function is SECURITY DEFINER with an empty search_path'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from event_search_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_search_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

-- Empty query is valid for filter-only reads.  The response envelope has no
-- count field and uses the complete occurrence row shape.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, null, 100, null
  )->'events')),
  4,
  'empty query returns all live rows in the bounded period'
);
select ok(
  not ((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, null, 100, null
  )) ? 'count'),
  'search envelope does not expose a pre-RLS count'
);
select ok(
  exists (
    select 1
      from jsonb_array_elements((public.search_events_v1(
        (select group_id from event_search_fixture),
        '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
        null, null, 100, null
      )->'events')) row_data
     where row_data->>'id' = (select korean_event_id::text from event_search_fixture)
       and row_data ? 'member_ids'
       and row_data ? 'occurrence_key'
  ),
  'search rows include complete event and occurrence fields'
);

select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '회의',
    null, null, 100, null
  )->'events')),
  1,
  'Korean title substring is matched case-insensitively'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '🍕 SPECIAL',
    null, null, 100, null
  )->'events')),
  1,
  'emoji and case-folded Unicode description search works'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '%_',
    null, null, 100, null
  )->'events')),
  1,
  'percent and underscore are literal substring characters'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 'SELECT *',
    null, null, 100, null
  )->'events')),
  1,
  'SQL-like input and punctuation are not interpreted as SQL'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 'O''Reilly',
    null, null, 100, null
  )->'events')),
  1,
  'quotes are literal search characters'
);

-- NFC and NFD are deliberately distinct literal forms; no server-only
-- normalization may make one query match the other.
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', U&'Caf\00E9',
    null, null, 100, null
  )->'events'->0->>'id'),
  (select nfc_event_id::text from event_search_fixture),
  'NFC query matches the NFC title form'
);
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', U&'Cafe\0301',
    null, null, 100, null
  )->'events'->0->>'id'),
  (select nfd_event_id::text from event_search_fixture),
  'NFD query matches the NFD title form'
);

select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    (select member_id from event_search_fixture), null, 100, null
  )->'events')),
  1,
  'creator filter returns only an active same-group creator'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, (select member_id from event_search_fixture), 100, null
  )->'events')),
  4,
  'participant filter is evaluated server-side through event_members'
);

-- The New York spring-forward day is a valid local-midnight period even though
-- its UTC length is 23 hours.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z',
    'America/New_York', 'DST', null, null, 100, null
  )->'events')),
  1,
  'DST local-midnight period is accepted'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T01:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'range must be local-midnight and at most 366 days',
  'non-midnight period is rejected'
);

-- Recurrence text comes from the effective rule/override snapshot.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', '오버라이드',
    null, null, 100, null
  )->'events')),
  1,
  'recurring occurrence override title is searchable'
);
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', '오버라이드',
    null, null, 100, null
  )->'events'->0->>'occurrence_key'),
  'o00000000000000000001',
  'override result keeps its stable occurrence key'
);

-- A one-row page from a recurring series must resume on occurrence_key even
-- when event_id is unchanged; using event_id alone as a seen key would hide
-- this same-series second occurrence.
do $$
declare
  v_first jsonb;
  v_second jsonb;
  v_cursor text;
  v_first_event uuid;
  v_second_event uuid;
  v_first_key text;
  v_second_key text;
begin
  v_first := public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', null,
    null, null, 1, null
  );
  if jsonb_array_length(v_first->'events') <> 1
     or v_first->>'has_more' <> 'true'
     or v_first->>'next_cursor' is null then
    raise exception 'recurring first cursor page is incomplete';
  end if;
  v_first_event := (v_first->'events'->0->>'event_id')::uuid;
  v_first_key := v_first->'events'->0->>'occurrence_key';
  v_cursor := v_first->>'next_cursor';

  v_second := public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', null,
    null, null, 1, v_cursor
  );
  if jsonb_array_length(v_second->'events') <> 1
     or v_second->>'has_more' <> 'false'
     or v_second->>'next_cursor' is not null then
    raise exception 'recurring second cursor page is incomplete';
  end if;
  v_second_event := (v_second->'events'->0->>'event_id')::uuid;
  v_second_key := v_second->'events'->0->>'occurrence_key';
  if v_first_event <> (select recurring_event_id from event_search_fixture)
     or v_second_event <> v_first_event
     or v_first_key = v_second_key
     or v_first_key is null
     or v_second_key is null then
    raise exception 'recurring cursor did not resume on a distinct occurrence key';
  end if;
end;
$$;
select ok(
  true,
  'recurring limit-one pages resume same event_id by distinct occurrence_key'
);

-- Query and server limits fail closed.  Empty is the only query value below
-- the two-codepoint minimum that is accepted.
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', %L, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'x'
  ),
  '22023', 'query must contain 2 to 100 characters and at most 400 bytes',
  'one-codepoint query is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', %L, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', repeat('界', 101)
  ),
  '22023', 'query must contain 2 to 100 characters and at most 400 bytes',
  'query above the Unicode character maximum is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 0, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 100',
  'zero limit is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 101, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 100',
  'limit above the server maximum is rejected'
);

-- Creator/participant probes for inactive, outsider, and cross-group users all
-- return the same authorization result without revealing membership state.
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, %L::uuid, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select inactive_id from event_search_fixture)
  ),
  '42501', 'creator is not an active member of this group',
  'inactive creator target is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, %L::uuid, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select outsider_id from event_search_fixture)
  ),
  '42501', 'participant is not an active member of this group',
  'outsider participant target is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, %L::uuid, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select other_owner_id from event_search_fixture)
  ),
  '42501', 'creator is not an active member of this group',
  'cross-group creator target is rejected'
);

-- All inaccessible groups use the same neutral result, whether missing,
-- archived, or owned by a different caller.
select set_config(
  'request.jwt.claim.sub', (select outsider_id::text from event_search_fixture), true
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'outsider cannot search the group'
);
select set_config(
  'request.jwt.claim.sub', (select inactive_id::text from event_search_fixture), true
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'inactive member cannot search the group'
);
select set_config(
  'request.jwt.claim.sub', (select owner_id::text from event_search_fixture), true
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select archive_group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'archived group is indistinguishable from an unavailable group'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    '00000000-0000-4000-8000-00000000ffff',
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  'missing group is indistinguishable from an unavailable group'
);

-- Anonymous JWTs and missing authentication cannot invoke the definer.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from event_search_fixture),
    'role', 'authenticated', 'is_anonymous', true
  )::text,
  true
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '28000', 'authentication is required',
  'anonymous JWT is rejected'
);
select set_config('request.jwt.claims', '{}', true);
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '28000', 'authentication is required',
  'missing JWT subject is rejected'
);

-- Restore owner claims for cursor and bulk tests.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from event_search_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub', (select owner_id::text from event_search_fixture), true
);

update event_search_fixture f
   set canonical_cursor = public.search_events_v1(
     (select bulk_group_id from event_search_fixture),
     '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'UTC', 'Bulk',
     null, null, 37, null
   )->>'next_cursor';
select ok(
  (select canonical_cursor from event_search_fixture) is not null
    and (select canonical_cursor from event_search_fixture) !~ '='
    and (select canonical_cursor from event_search_fixture) ~ '^[A-Za-z0-9_-]+$',
  'search emits an unpadded URL-safe v2 cursor'
);
select is(
  (public.search_events_v1(
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'UTC', 'Bulk',
    null, null, 37, (select canonical_cursor from event_search_fixture)
  )->'events'->0->>'title'),
  'Bulk event 37',
  'v2 cursor resumes after the exact starts_at/event_id/occurrence_key tuple'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', ''Bulk'', null, null, 37, %L)',
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to('[]', 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  'non-object cursor is rejected'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', ''Bulk'', null, null, 37, %L)',
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'not-a-cursor!'
  ),
  '22023', 'cursor is malformed',
  'malformed cursor alphabet is rejected'
);

create temporary table event_search_seen (
  event_id uuid not null,
  occurrence_key text not null,
  primary key (event_id, occurrence_key)
) on commit drop;
do $$
declare
  v_payload jsonb;
  v_cursor text := null;
  v_page_count integer;
  v_total integer := 0;
  v_row jsonb;
begin
  loop
    v_payload := public.search_events_v1(
      (select bulk_group_id from event_search_fixture),
      '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'UTC', 'Bulk',
      null, null, 37, v_cursor
    );
    v_page_count := jsonb_array_length(v_payload->'events');
    if v_page_count = 0 then
      exit;
    end if;
    for v_row in select value from jsonb_array_elements(v_payload->'events') loop
      insert into event_search_seen(event_id, occurrence_key)
      values ((v_row->>'event_id')::uuid, v_row->>'occurrence_key');
      v_total := v_total + 1;
    end loop;
    if v_payload->>'has_more' = 'true' then
      v_cursor := v_payload->>'next_cursor';
      if v_cursor is null then
        raise exception 'has_more page omitted next_cursor';
      end if;
    else
      exit;
    end if;
  end loop;
  if v_total <> 1001 then
    raise exception 'expected 1001 bulk rows, got %', v_total;
  end if;
end;
$$;
select is(
  (select count(*) from event_search_seen),
  1001::bigint,
  '1001 bulk events paginate without duplicate rows or omissions'
);

select * from finish();
commit;
