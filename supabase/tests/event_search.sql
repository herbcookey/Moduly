-- 기능 G의 범위 제한 그룹 단위 일정 검색 RPC용 pgTAP 픽스처다.
--
-- 설정은 마이그레이션 소유자로, 조회 호출은 authenticated로 실행한다. 전체
-- 픽스처가 트랜잭션 안에서 동작하므로 일회용 Supabase/PostgreSQL 데이터베이스에서
-- 안전하게 실행할 수 있다.

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

-- 운영 중인 단일 일정 행이다. 설명에는 의도적으로 와일드카드, 백슬래시, 따옴표 및
-- SQL과 비슷한 텍스트를 넣는다. position/lower는 각각을 SQL 패턴 문법이 아니라
-- 리터럴 부분 문자열로 처리해야 한다.
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

-- 반복 행과 완전한 유효 재정의를 통해 검색이 기준 일정뿐 아니라 구체화된 발생의
-- 제목/설명도 사용하는지 확인한다.
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

-- 대량 행은 의도적으로 1,000개를 넘긴다. 각 행의 starts_at 값이 고유하므로 아래
-- 반복문에서 키셋 중복이나 누락이 없음을 확인할 수 있다.
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

-- 행을 만든 뒤 그룹 하나를 보관한다. 함수는 없거나 접근할 수 없는 그룹과 같은
-- 중립적인 권한 오류를 반환해야 한다.
update public.groups
   set deleted_at = '2026-02-01T00:00:00Z', version = 2
 where id = (select archive_group_id from event_search_fixture);

-- 역할을 바꾸기 전에 카탈로그/ACL/보안 검사를 수행한다.
select ok(
  exists (
    select 1 from pg_catalog.pg_class c
     where c.oid = 'public.events_group_creator_start_id_live_idx'::regclass
       and c.relkind = 'i'
  ),
  '생성자 필터용 부분 B-tree 인덱스가 있다'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)',
    'execute'
  ),
  'authenticated 역할은 search_events_v1을 실행할 수 있다'
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
  'anon 및 PUBLIC 역할은 search_events_v1을 실행할 수 없다'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_proc p
     where p.oid = 'public.search_events_v1(uuid,timestamptz,timestamptz,text,text,uuid,uuid,integer,text)'::regprocedure
       and p.prosecdef
       and p.proconfig @> array['search_path=""']::text[]
  ),
  '검색 함수는 빈 search_path를 사용하는 SECURITY DEFINER 함수다'
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

-- 필터만 사용하는 조회에서는 빈 쿼리도 유효하다. 응답 봉투에는 count 필드가 없고
-- 완전한 발생 행 형태를 사용한다.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, null, 100, null
  )->'events')),
  4,
  '빈 검색어는 제한된 기간의 모든 활성 행을 반환한다'
);
select ok(
  not ((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, null, 100, null
  )) ? 'count'),
  '검색 응답은 RLS 적용 전 개수를 노출하지 않는다'
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
  '검색 행에는 완전한 이벤트 및 발생 항목 필드가 포함된다'
);

select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '회의',
    null, null, 100, null
  )->'events')),
  1,
  '한국어 제목의 부분 문자열이 대소문자 구분 없이 일치한다'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '🍕 SPECIAL',
    null, null, 100, null
  )->'events')),
  1,
  '이모지 및 대소문자를 정규화한 유니코드 설명 검색이 동작한다'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', '%_',
    null, null, 100, null
  )->'events')),
  1,
  '퍼센트 기호와 밑줄은 부분 문자열의 리터럴 문자로 처리된다'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 'SELECT *',
    null, null, 100, null
  )->'events')),
  1,
  'SQL 형태의 입력과 문장 부호는 SQL로 해석되지 않는다'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', 'O''Reilly',
    null, null, 100, null
  )->'events')),
  1,
  '따옴표는 검색용 리터럴 문자로 처리된다'
);

-- NFC와 NFD는 의도적으로 서로 다른 리터럴 형태다. 서버 전용 정규화로 한 쿼리가
-- 다른 형태와 일치하게 해서는 안 된다.
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', U&'Caf\00E9',
    null, null, 100, null
  )->'events'->0->>'id'),
  (select nfc_event_id::text from event_search_fixture),
  'NFC 검색어는 NFC 형식의 제목과 일치한다'
);
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', U&'Cafe\0301',
    null, null, 100, null
  )->'events'->0->>'id'),
  (select nfd_event_id::text from event_search_fixture),
  'NFD 검색어는 NFD 형식의 제목과 일치한다'
);

select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    (select member_id from event_search_fixture), null, 100, null
  )->'events')),
  1,
  '생성자 필터는 같은 그룹의 활성 생성자만 반환한다'
);
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'UTC', null,
    null, (select member_id from event_search_fixture), 100, null
  )->'events')),
  4,
  '참여자 필터는 서버에서 event_members를 통해 평가된다'
);

-- 뉴욕에서 서머타임이 시작되는 날은 UTC 길이가 23시간이어도 유효한 현지 자정 기간이다.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z',
    'America/New_York', 'DST', null, null, 100, null
  )->'events')),
  1,
  'DST가 적용되는 현지 자정 기간도 허용된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T01:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'range must be local-midnight and at most 366 days',
  '자정이 아닌 기간은 거부된다'
);

-- 반복 텍스트는 유효 규칙/재정의 스냅샷에서 가져온다.
select is(
  jsonb_array_length((public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', '오버라이드',
    null, null, 100, null
  )->'events')),
  1,
  '반복 발생 항목의 재정의 제목을 검색할 수 있다'
);
select is(
  (public.search_events_v1(
    (select group_id from event_search_fixture),
    '2026-03-10T00:00:00Z', '2026-03-12T00:00:00Z', 'UTC', '오버라이드',
    null, null, 100, null
  )->'events'->0->>'occurrence_key'),
  'o00000000000000000001',
  '재정의 결과는 안정적인 발생 항목 키를 유지한다'
);

-- 반복 묶음의 한 행짜리 페이지는 event_id가 같아도 occurrence_key를 기준으로
-- 이어져야 한다. 확인한 키로 event_id만 사용하면 같은 묶음의 두 번째 발생이 숨겨진다.
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
    raise exception '반복 일정의 첫 커서 페이지가 불완전합니다';
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
    raise exception '반복 일정의 두 번째 커서 페이지가 불완전합니다';
  end if;
  v_second_event := (v_second->'events'->0->>'event_id')::uuid;
  v_second_key := v_second->'events'->0->>'occurrence_key';
  if v_first_event <> (select recurring_event_id from event_search_fixture)
     or v_second_event <> v_first_event
     or v_first_key = v_second_key
     or v_first_key is null
     or v_second_key is null then
    raise exception '반복 일정 커서가 서로 다른 발생 키에서 이어지지 않았습니다';
  end if;
end;
$$;
select ok(
  true,
  '반복 일정의 한 행짜리 페이지는 서로 다른 occurrence_key로 같은 event_id를 이어 간다'
);

-- 쿼리 및 서버 제한은 실패 시 차단한다. 두 코드 포인트 최소 길이보다 짧으면서
-- 허용되는 쿼리 값은 빈 문자열뿐이다.
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', %L, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', 'x'
  ),
  '22023', 'query must contain 2 to 100 characters and at most 400 bytes',
  '코드 포인트 하나인 검색어는 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', %L, null, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z', repeat('界', 101)
  ),
  '22023', 'query must contain 2 to 100 characters and at most 400 bytes',
  '유니코드 문자 최대 길이를 넘는 검색어는 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 0, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 100',
  '0인 제한값은 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, null, 101, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '22023', 'limit must be between 1 and 100',
  '서버 최대값을 넘는 제한값은 거부된다'
);

-- 비활성, 외부 및 다른 그룹 사용자를 작성자/참여자로 탐색해도 멤버십 상태를
-- 노출하지 않고 모두 같은 권한 결과를 반환한다.
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, %L::uuid, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select inactive_id from event_search_fixture)
  ),
  '42501', 'creator is not an active member of this group',
  '비활성 생성자 대상은 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, null, %L::uuid, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select outsider_id from event_search_fixture)
  ),
  '42501', 'participant is not an active member of this group',
  '외부 사용자 참여자 대상은 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', null, %L::uuid, null, 100, null)',
    (select group_id from event_search_fixture),
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z',
    (select other_owner_id from event_search_fixture)
  ),
  '42501', 'creator is not an active member of this group',
  '다른 그룹의 생성자 대상은 거부된다'
);

-- 접근할 수 없는 그룹은 없거나 보관되었거나 다른 호출자가 소유했는지와 관계없이
-- 같은 중립 결과를 사용한다.
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
  '외부 사용자는 그룹을 검색할 수 없다'
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
  '비활성 구성원은 그룹을 검색할 수 없다'
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
  '보관된 그룹은 사용할 수 없는 그룹과 구분되지 않는다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz)',
    '00000000-0000-4000-8000-00000000ffff',
    '2026-03-01T00:00:00Z', '2026-03-02T00:00:00Z'
  ),
  '42501', 'group is unavailable',
  '존재하지 않는 그룹은 사용할 수 없는 그룹과 구분되지 않는다'
);

-- 익명 JWT 또는 인증 없음 상태에서는 정의자 함수를 호출할 수 없다.
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
  '익명 JWT는 거부된다'
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
  'JWT subject가 없으면 거부된다'
);

-- 커서 및 대량 테스트를 위해 소유자 클레임을 복원한다.
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
  '검색은 패딩 없는 URL 안전 v2 커서를 반환한다'
);
select is(
  (public.search_events_v1(
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'UTC', 'Bulk',
    null, null, 37, (select canonical_cursor from event_search_fixture)
  )->'events'->0->>'title'),
  'Bulk event 37',
  'v2 커서는 정확한 starts_at/event_id/occurrence_key 튜플 다음부터 재개한다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', ''Bulk'', null, null, 37, %L)',
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z',
    rtrim(translate(replace(encode(convert_to('[]', 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=')
  ),
  '22023', 'cursor has an invalid shape',
  '객체가 아닌 커서는 거부된다'
);
select throws_ok(
  format(
    'select public.search_events_v1(%L::uuid, %L::timestamptz, %L::timestamptz, ''UTC'', ''Bulk'', null, null, 37, %L)',
    (select bulk_group_id from event_search_fixture),
    '2026-04-01T00:00:00Z', '2026-04-02T00:00:00Z', 'not-a-cursor!'
  ),
  '22023', 'cursor is malformed',
  '잘못된 문자 집합을 사용한 커서는 거부된다'
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
        raise exception 'has_more 페이지가 next_cursor를 누락했습니다';
      end if;
    else
      exit;
    end if;
  end loop;
  if v_total <> 1001 then
    raise exception '대량 행 1,001개를 기대했지만 %개입니다', v_total;
  end if;
end;
$$;
select is(
  (select count(*) from event_search_seen),
  1001::bigint,
  '대량 이벤트 1001개가 중복이나 누락 없이 페이지로 나뉜다'
);

select * from finish();
commit;
