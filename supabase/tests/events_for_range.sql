-- 범위 제한 키셋 페이지네이션 캘린더 조회용 pgTAP 픽스처다.
--
-- 픽스처는 의도적으로 실제 authenticated 역할로 범위 RPC를 호출한다. 설정 쓰기는
-- 세션 소유자를 사용하고 전체 테스트를 롤백하므로 일회용 로컬 Supabase
-- 데이터베이스에서 안전하게 실행할 수 있다.

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

-- 고정 ID는 개인정보 보호 및 교차 그룹 검사를 결정적으로 만든다. 그룹 삽입은 기존
-- 트리거를 통해 소유자 멤버십을 만든다.
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

-- 아래 모든 일정은 참여자를 인식하는 RPC를 통해 만들므로 이 픽스처는 조회 계약이
-- 기능 5의 행 형태를 사용하는지도 확인한다. 명시적 멤버 목록은 해당 RPC가 정렬하고
-- 중복을 제거한다.
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

-- 2026년 뉴욕의 서머타임 시작일은 23시간짜리 UTC 구간이다. p_view_timezone이
-- 뉴욕이면 해당 현지 자정 끝점도 계속 허용한다.
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

-- 보관된 그룹의 일정은 데이터베이스에 남지만 archive_group_if_version이 그룹을
-- 종료 상태로 바꾼 뒤에는 이 RPC에 보이지 않아야 한다.
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

-- 카탈로그 및 권한 검증은 마이그레이션 소유자로 실행한다.
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
    where c.oid = 'public.events_group_start_id_live_idx'::regclass
      and c.relkind = 'i'
  ),
  '활성 이벤트용 결정적 키셋 인덱스가 있다'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
    where c.oid = 'public.events_group_allday_dates_live_idx'::regclass
      and c.relkind = 'i'
  ),
  '종일 일정의 날짜 겹침 인덱스가 있다'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)',
    'execute'
  ),
  'authenticated 역할은 events_for_range를 실행할 수 있다'
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
  'anon 및 PUBLIC 역할은 events_for_range를 실행할 수 없다'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_proc p
    where p.oid = 'public.events_for_range(uuid,timestamptz,timestamptz,text,integer,text,uuid)'::regprocedure
      and p.prosecdef
      and p.proconfig @> array['search_path=""']::text[]
  ),
  '범위 함수는 빈 search_path를 사용하는 SECURITY DEFINER 함수다'
);
select ok(
  not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'event_members'
  ),
  'event_members는 실시간 publication에 포함되지 않는다'
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
  '실시간 기능이 구성되면 상위 events 테이블이 계속 무효화 신호 역할을 한다'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.events'::pg_catalog.regclass
      and c.conname = 'events_finite_time_bounds'
      and c.contype = 'c'
      and c.convalidated
  ),
  '일정 타임스탬프 유한성 검사는 검증된 상태다'
);

select throws_ok(
  $$
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value
    ) values (
      '00000000-0000-4000-8000-00000000f201',
      '00000000-0000-4000-8000-00000000f101',
      'Invalid negative infinity start', '', '-infinity',
      '2026-03-01T01:00:00Z', 'UTC', false, null, null, 1, 305419896
    )
  $$,
  '23514', null,
  'starts_at이 -infinity인 일정은 테이블 경계에서 거부된다'
);
select throws_ok(
  $$
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value
    ) values (
      '00000000-0000-4000-8000-00000000f201',
      '00000000-0000-4000-8000-00000000f101',
      'Invalid positive infinity end', '', '2026-03-01T00:00:00Z',
      'infinity', 'UTC', false, null, null, 1, 305419896
    )
  $$,
  '23514', null,
  'ends_at이 infinity인 일정은 테이블 경계에서 거부된다'
);
select throws_ok(
  $$
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value,
      created_at, updated_at
    ) values (
      '00000000-0000-4000-8000-00000000f201',
      '00000000-0000-4000-8000-00000000f101',
      'Invalid negative infinity created', '', '2026-03-01T00:00:00Z',
      '2026-03-01T01:00:00Z', 'UTC', false, null, null, 1, 305419896,
      '-infinity', '2026-01-01T00:00:00Z'
    )
  $$,
  '23514', null,
  'created_at이 -infinity인 일정은 테이블 경계에서 거부된다'
);
select throws_ok(
  $$
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value,
      created_at, updated_at
    ) values (
      '00000000-0000-4000-8000-00000000f201',
      '00000000-0000-4000-8000-00000000f101',
      'Invalid positive infinity updated', '', '2026-03-01T00:00:00Z',
      '2026-03-01T01:00:00Z', 'UTC', false, null, null, 1, 305419896,
      '2026-01-01T00:00:00Z', 'infinity'
    )
  $$,
  '23514', null,
  'updated_at이 infinity인 일정은 테이블 경계에서 거부된다'
);
select throws_ok(
  $$
    insert into public.events (
      group_id, created_by, title, description, starts_at, ends_at, timezone,
      is_all_day, all_day_start, all_day_end, version, color_value,
      deleted_at, created_at, updated_at
    ) values (
      '00000000-0000-4000-8000-00000000f201',
      '00000000-0000-4000-8000-00000000f101',
      'Invalid positive infinity deleted', '', '2026-03-01T00:00:00Z',
      '2026-03-01T01:00:00Z', 'UTC', false, null, null, 1, 305419896,
      'infinity', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
    )
  $$,
  '23514', null,
  'deleted_at이 infinity인 일정은 테이블 경계에서 거부된다'
);

-- 소유자와 활성 멤버는 기능 5의 모든 일정 필드와 정규 member_ids 배열을 포함한
-- 동일한 운영 그룹 행을 본다.
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
  '유효한 정규 커서는 패딩 없는 URL 안전 base64로 반환된다'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 1, (select canonical_cursor from events_for_range_fixture), null
  )->'events')),
  1,
  'RPC가 반환한 정규 커서는 다음 페이지 요청에 허용된다'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  2,
  '소유자는 정확한 반개방 일 범위에서 겹치는 일정과 종일 일정 행을 볼 수 있다'
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
  '소프트 삭제된 이벤트는 활성 범위에서 제외된다'
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
  '범위 행에는 완전한 이벤트 구조와 member_ids가 포함된다'
);
select is(
  (select public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events'->0->>'title'),
  'Range overlap',
  '시간 지정 일정과 종일 일정 행은 결정적인 starts_at, id 순서를 사용한다'
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
  '활성 일반 구성원은 고정된 시간대와 함께 활성 그룹을 조회할 수 있다'
);

-- 시간/날짜의 정확한 반열린 경계다. 시작점에 끝나거나 끝점에 시작하는 일정은
-- 제외하고 전체에 걸친 행은 유지한다.
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  2,
  '범위는 시간 경계에서 반개방 구간으로 동작한다'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-03T00:00:00Z', '2026-03-04T00:00:00Z',
    'UTC', 100, null, null
  )->'events')),
  0,
  'range_start에 끝나는 종일 일정은 제외된다'
);

-- 참여자 필터링은 서버 측에서 수행하며 같은 그룹의 활성 대상이 필요하다. 비활성,
-- 외부 또는 다른 그룹 UUID를 구분 가능한 목록 응답으로 바꾸지 않는다.
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    'UTC', 100, null, (select member_id from events_for_range_fixture)
  )->'events')),
  1,
  '참여자 필터는 활성 대상에게 할당된 행만 반환한다'
);
select is(
  (public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-04T00:00:00Z', '2026-03-05T00:00:00Z',
    'UTC', 100, null, (select member_id from events_for_range_fixture)
  )->'events'->0->>'id'),
  (select assigned_event_id::text from events_for_range_fixture),
  '참여자 필터는 대상에게 할당되지 않은 소유자 전용 이벤트를 반환하지 않는다'
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
  '비활성 참여자 대상은 목록을 노출하지 않고 거부된다'
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
  '외부 사용자 참여자 대상은 목록을 노출하지 않고 거부된다'
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
  '다른 그룹의 참여자 대상은 상태를 노출하지 않고 거부된다'
);

-- 외부 사용자, 비활성 멤버, 없는 그룹 및 보관된 그룹은 모두 같은 그룹 사용 불가
-- 코드/메시지로 실패 시 차단한다.
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
  '외부 사용자는 그룹 이벤트 범위를 조회할 수 없다'
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
  '비활성 구성원은 그룹 이벤트 범위를 조회할 수 없다'
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
  '보관된 그룹은 과거 행을 반환하지 않고 접근을 차단한다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz)',
    '00000000-0000-4000-8000-00000000ffff',
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  '존재하지 않는 그룹도 같은 권한 결과로 접근을 차단한다'
);

-- 날짜/시간 검증은 엄격하며 실패 시 차단한다. 현지 날짜 범위는 시간대 변환 뒤에
-- 측정하므로 서머타임 종료/짧은 UTC 구간도 유효한 달력 날짜 하루다.
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'')',
    (select group_id from events_for_range_fixture),
    '2026-03-01T01:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'range endpoints must be local midnight in the view timezone',
  'UTC 자정이 아닌 끝점은 거부된다'
);
select is(
  jsonb_array_length((public.events_for_range(
    (select group_id from events_for_range_fixture),
    '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z',
    'America/New_York', 100, null, null
  )->'events')),
  1,
  'DST 현지 자정 검증은 23시간짜리 UTC 날짜를 허용한다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, null, null)',
    (select group_id from events_for_range_fixture),
    '2025-01-01T00:00:00Z', '2026-01-03T00:00:00Z'
  ),
  '22023', 'range must not exceed 366 calendar days',
  '현지 달력 기준 366일을 넘는 범위는 거부된다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 0)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 200',
  '0인 제한값은 거부된다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 201)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 200',
  '정해진 최대값을 넘는 제한값은 거부된다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'not-a-cursor!'
  ),
  '22023', 'cursor must be an unpadded URL-safe base64 event cursor',
  '잘못된 커서는 행을 조회하기 전에 거부된다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    repeat('A', 4097)
  ),
  '22023', 'cursor must be an unpadded URL-safe base64 event cursor',
  '너무 긴 커서는 base64 디코딩 전에 거부된다'
);
select throws_ok(
  format(
    'select public.events_for_range(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', 100, %L)',
    (select group_id from events_for_range_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to('[]', 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  '객체가 아닌 커서 페이로드는 거부된다'
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
  '다른 버전의 커서는 거부된다'
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
  '문자열 형식의 커서 버전은 거부된다'
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
  '부동소수점 형식의 커서 버전은 거부된다'
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
  '시간대가 없는 커서 타임스탬프는 거부된다'
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
  '커서 타임스탬프에는 초가 필요하다'
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
  '소수 부분이 여섯 자리를 넘는 커서는 거부된다'
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
  '존재할 수 없는 달력 날짜를 담은 커서는 거부된다'
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
  '잘못된 시각 요소를 담은 커서는 거부된다'
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
  '잘못된 오프셋을 담은 커서는 거부된다'
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
      raise exception '유효한 소수 커서가 예기치 않게 행을 반환했습니다';
    end if;
  end loop;
end;
$$;
select ok(
  true,
  '한 자리부터 여섯 자리까지의 유효한 커서 소수 부분은 허용된다'
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
  '명시적 오프셋이 있는 유효한 여섯 자리 커서 소수 부분은 허용된다'
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
  '알 수 없는 커서 키는 거부된다'
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
  '유한하지 않은 커서 튜플은 타임스탬프 변환 전에 거부된다'
);

-- range_end 뒤의 커서 튜플도 튜플 전용 계약에서는 유효하다. 종일 행에 저장된
-- starts_at은 자체 시간대로 표현된다. 정보를 노출하거나 실패하지 않고 단순히 빈
-- 다음 페이지를 반환한다.
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
  'range_end 뒤의 유한한 튜플은 빈 연속 페이지로 허용된다'
);

-- 시작 시각이 같은 일정 1,001개의 키셋 페이지네이션에는 중복이나 누락이 없어야
-- 한다. 직접 설정 INSERT로 이전 일정 초기화 트리거를 실행한다. 각 일정은 초기
-- 버전을 유지하고 작성자만 정확히 할당받는다.
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
  '대량 페이지네이션 픽스처에는 이벤트 1001개가 있다'
);
select ok(
  not exists (
    select 1 from public.events e
    where e.id in (select event_id from range_bulk_events)
      and e.version <> 1
  ),
  '레거시 이벤트 초기화는 대량 이벤트의 초기 버전을 증가시키지 않는다'
);
select ok(
  not exists (
    select 1
    from public.event_members em
    where em.event_id in (select event_id from range_bulk_events)
    group by em.event_id
    having count(*) <> 1
  ),
  '레거시 대량 INSERT는 이벤트마다 생성자 참여자 한 명을 정확히 만든다'
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
      raise exception '페이지네이션이 진행되지 않았습니다';
    end if;
    v_cursor := v_payload->>'next_cursor';
    if v_page > 10 then
      raise exception '페이지네이션이 예상 페이지 범위를 초과했습니다';
    end if;
  end loop;
end;
$$;
select is(
  (select count(*)::integer from range_seen),
  1001,
  '이벤트 1001개가 중복 행이나 누락 없이 페이지로 나뉜다'
);
select is(
  (select count(*)::integer from range_bulk_events b
   where not exists (select 1 from range_seen s where s.event_id = b.event_id)),
  0,
  '모든 대량 이벤트가 정확히 하나의 키셋 페이지에 나타난다'
);
select ok(
  (select count(*) from range_seen where first_page = 6) = 1,
  '다섯 개의 가득 찬 페이지 뒤에 마지막 한 행짜리 페이지가 유지된다'
);

select * from finish();
rollback;
