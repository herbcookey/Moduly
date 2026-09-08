-- 기능 2 반복 규칙용 pgTAP 픽스처다.
--
-- 설정 쓰기는 로컬 마이그레이션 소유자로 수행한다. RPC 호출은 실제
-- authenticated 역할로 실행하여 RLS, 작성자 전용 정책 및 범위 제한 커서 계약을
-- 함께 검사한다.

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
  monthly_after_anchor_id uuid,
  dst_id uuid,
  all_day_id uuid
) on commit drop;
grant all on recurrence_fixture to authenticated;
insert into recurrence_fixture values (
  '00000000-0000-4000-8000-00000000e101',
  '00000000-0000-4000-8000-00000000e102',
  '00000000-0000-4000-8000-00000000e103',
  '00000000-0000-4000-8000-00000000e104',
  null, null, null, null, null, null
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

-- RPC 계약은 작성자, 참여자 및 명시적인 빈 할당 목록을 모두 다룬다. NULL
-- member_ids는 작성자를 기본값으로 사용한다.
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
          '반복 일정 생성은 하나의 추가형 루트 구간을 저장한다');
select is((select count(*)::integer from public.event_members
           where event_id = (select event_id from recurrence_fixture)), 1,
          '참여자는 반복 일정의 event_members 관계를 상속한다');

set local role authenticated;
select throws_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'invalid interval zero', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'daily', 0, '{}'::smallint[], 'never', null, null, null)$$,
  '22023', null, '간격이 0이면 거부된다');
select throws_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'invalid interval thousand', '',
    '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'daily', 1000, '{}'::smallint[], 'never', null, null)$$,
  '22023', null, '간격이 1000이면 거부된다');
select throws_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'Until before occurrence zero', '',
    '2030-01-20T09:00:00Z', '2030-01-20T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'monthly', 2, '{}'::smallint[],
    'until', null, '2030-01-20', 15::smallint)$$,
  '22023', 'until_date precedes the first occurrence',
  '월간 종료일은 정규화된 순번 0보다 이를 수 없다');
select lives_ok(
  $$select * from public.create_recurring_event_with_members(
    (select group_id from recurrence_fixture), 'Until at occurrence zero', '',
    '2030-01-20T09:00:00Z', '2030-01-20T10:00:00Z', 'UTC', false, null, null,
    1::bigint, null::uuid[], 'monthly', 2, '{}'::smallint[],
    'until', null, '2030-02-15', 15::smallint)$$,
  '월간 종료일은 정규화된 순번 0과 같을 수 있다');
reset role;

select is((
  select count(*)::integer
  from public.events
  where title = 'Until before occurrence zero'
), 0, '거부된 월간 생성은 부분 이벤트를 남기지 않는다');

set local role authenticated;
select is(
  jsonb_array_length((public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
  )->'events')),
  3,
  '일별 횟수 확장은 유한하며 범위가 제한된다'
);
select is((select occurrence_key from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'o00000000000000000001',
  '단일 항목 조회는 안정적인 순번 키를 확인한다');
reset role;

-- 두 행짜리 페이지는 엄격한 v2 커서를 반환하며 다음 페이지에는 행 하나가 있다.
set local role authenticated;
select is((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 2, null, null
)->>'has_more')::boolean, true, 'v2 범위는 limit+1 키셋 페이지네이션을 사용한다');
select isnt(public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 2, null, null
)->>'next_cursor', null, 'v2 페이지는 불투명 커서를 포함한다');
reset role;

-- 현재 범위 갱신은 전체 스냅샷을 만들고 기준점 버전을 한 번 올린다.
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 1, 'o00000000000000000001', 'this',
  'Changed occurrence', 'changed note', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 7::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'committed')::boolean, 'this 범위 업데이트는 희소 전체 스냅샷을 커밋한다');
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 2, 'o00000000000000000001', 'this',
  'Changed occurrence', 'changed note', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 7::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, false, '동일한 this 범위 재실행은 아무 작업도 하지 않는다');
select is((select version from public.events where id = (select event_id from recurrence_fixture)), 2,
          'this 범위 업데이트는 상위 버전을 정확히 한 번 증가시킨다');
select is((select title from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'Changed occurrence', 'this 재정의는 오래된 제목을 상속하지 않는다');
reset role;

set local role authenticated;
select ok((public.delete_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 2, 'o00000000000000000000', 'this'
)->>'committed')::boolean, 'this 범위 삭제는 예외 취소를 커밋한다');
select is((public.delete_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 3, 'o00000000000000000000', 'this'
)->>'changed')::boolean, false, '취소 재실행은 멱등적으로 아무 작업도 하지 않는다');
reset role;
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 3, 'o00000000000000000002', 'this',
  'Later exception', 'later note', '2026-01-03T14:00:00Z',
  '2026-01-03T15:00:00Z', 'UTC', false, null, null, 6::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, '두 번째 희소 예외가 기록된다');
reset role;
set local role authenticated;
select is(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-10T00:00:00Z', 'UTC', 100, null, null
)->'events')), 2, '취소된 발생 항목은 반복 일정을 삭제하지 않고 제외된다');
reset role;

-- 향후 편집은 선택한 순번에서 분할하고 이후 희소 예외를 지우며 전체 발생 키를 유지한다.
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 4, 'o00000000000000000002', 'future',
  'Future title', 'future note', '2026-01-03T08:00:00Z',
  '2026-01-03T09:00:00Z', 'UTC', false, null, null, 8::bigint,
  null::uuid[], 'daily', 2, '{}'::smallint[], 'never', null, null, null
)->>'committed')::boolean, 'future 범위 업데이트는 반복 일정을 분할한다');
reset role;
select is((select count(*)::integer from public.event_recurrence_rules
           where event_id = (select event_id from recurrence_fixture)), 2,
          'future 분할 후 겹치지 않는 구간 두 개가 남는다');
select is((select occurrence_key from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000002'
)), 'o00000000000000000002', 'future 분할은 선택한 키를 보존한다');

-- 전체 범위 교체는 희소 예외와 참여자를 원자적으로 재설정한다. 같은 페이로드를
-- 재실행하면 명시적인 changed=false 무동작이다.
set local role authenticated;
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 5, 'o00000000000000000002', 'all',
  'All reset', 'all note', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z',
  'UTC', false, null, null, 10::bigint,
  array[(select owner_id from recurrence_fixture)]::uuid[],
  'daily', 1, '{}'::smallint[], 'never', null, null, null
)->>'changed')::boolean, true, 'all 범위 교체는 상위 항목 변경을 한 번 커밋한다');
select is((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 6, 'o00000000000000000002', 'all',
  'All reset', 'all note', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z',
  'UTC', false, null, null, 10::bigint,
  array[(select owner_id from recurrence_fixture)]::uuid[],
  'daily', 1, '{}'::smallint[], 'never', null, null, null
)->>'changed')::boolean, false, '동일한 all 범위 재실행은 아무 작업도 하지 않는다');
reset role;
select is((select title from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 'All reset', 'all 범위 교체는 이전 희소 예외를 제거한다');
select is((select occurrence_version from public.event_occurrence_by_key(
  (select event_id from recurrence_fixture), 'o00000000000000000001'
)), 0, 'all 범위 교체는 발생 항목 버전을 초기화한다');
set local role authenticated;
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_fixture), 6, 'o00000000000000000001', 'this',
  'Post-reset exception', 'post reset', '2026-01-02T12:00:00Z',
  '2026-01-02T13:00:00Z', 'UTC', false, null, null, 11::bigint,
  null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, true, 'all 초기화 후 예외를 다시 만들 수 있다');
reset role;

-- 월간 범위 제한과 종일 일정 반열린 투영이다.
set local role authenticated;
update recurrence_fixture f set monthly_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'Month end', '',
  '2026-01-31T09:00:00Z', '2026-01-31T10:00:00Z', 'UTC', false, null, null,
  1::bigint, null, 'monthly', 1, '{}'::smallint[], 'count', 3, null, 31::smallint
) as created;
update recurrence_fixture f set monthly_after_anchor_id = created.id
from public.create_recurring_event_with_members(
  (select group_id from recurrence_fixture), 'Month after anchor', '',
  '2030-01-20T09:00:00Z', '2030-01-20T10:00:00Z', 'UTC', false, null, null,
  1::bigint, null, 'monthly', 2, '{}'::smallint[], 'count', 3, null, 15::smallint
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
)), '2026-02-28'::date, '월간 31일은 2월 말일로 조정된다');
select is((select starts_at from public.event_occurrence_by_key(
  (select monthly_after_anchor_id from recurrence_fixture),
  'o00000000000000000000'
)), '2030-02-15T09:00:00Z'::timestamptz,
  '월간 순번 0은 기준 시각 이후의 첫 유효한 날짜다');
select is((select starts_at from public.event_occurrence_by_key(
  (select monthly_after_anchor_id from recurrence_fixture),
  'o00000000000000000001'
)), '2030-04-15T09:00:00Z'::timestamptz,
  '월간 간격은 정규화된 순번 0에서부터 계산된다');
select is((
  select pg_catalog.array_agg(o.occurrence_index order by o.occurrence_index)
  from public._event_occurrences_for_range(
    (select monthly_after_anchor_id from recurrence_fixture),
    '2030-02-01T00:00:00Z', '2030-07-01T00:00:00Z', 'UTC'
  ) o
), array[0, 1, 2]::bigint[],
  '월간 범위 확장도 정규화된 순번과 횟수를 유지한다');
select is(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-03-06T00:00:00Z', '2026-03-13T00:00:00Z', 'UTC', 100, null, null
)->'events')), 5, 'DST 규칙은 요청한 유한 횟수만큼만 확장된다');
select is((select all_day_end from public.event_occurrence_by_key(
  (select all_day_id from recurrence_fixture), 'o00000000000000000001'
)), '2026-01-04'::date, '종일 발생 항목은 현지 날짜 기준 반개방 종료일을 사용한다');

-- 작성자 전용 및 낙관적 버전 경계다.
set local role authenticated;
select set_config('request.jwt.claim.sub', (select member_id::text from recurrence_fixture), true);
select ok(jsonb_array_length((public.events_for_range_v2(
  (select group_id from recurrence_fixture),
  '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null
)->'events')) > 0, '활성 그룹 구성원은 범위를 조회할 수 있다');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', 'this',
    'member cannot edit', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '40001', null, '활성 비작성자는 반복 일정을 변경할 수 없다');
reset role;

select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 999, 'o00000000000000000001', 'this',
    'bad', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '40001', null, '오래된 상위 버전은 거부된다'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', (select outsider_id::text from recurrence_fixture), true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '42501', null, '외부 사용자는 그룹 범위를 조회할 수 없다'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', (select inactive_id::text from recurrence_fixture), true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '42501', null, '비활성화된 구성원은 그룹 범위를 조회할 수 없다'
);
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select public.events_for_range_v2(
    (select group_id from recurrence_fixture),
    '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'UTC', 10, null, null)$$,
  '28000', null, '익명 호출자는 그룹 조회 전에 거부된다'
);
reset role;

-- 추가 경계 계약은 반복 단일 일정 별칭, 상속된 향후 횟수, 범위 안으로 이동한 희소
-- 스냅샷, NULL 범위 및 익명 보호다.
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
  'o00000000000000000000', '반복 단일 항목은 레거시 single 센티널을 순번 0의 별칭으로 사용한다');
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_extra), 1, 'o00000000000000000001', 'future',
  null, null, null, null, null, null, null, null, null, null,
  null, null, null, null, null, null, null
)->>'changed')::boolean, '상속된 횟수를 사용한 future 분할이 커밋된다');
select is(((select recurrence_rule from public.event_occurrence_by_key(
  (select event_id from recurrence_extra), 'o00000000000000000001'))->>'count')::integer),
  4, 'future 상속 횟수는 소비된 순번 수를 차감한다');
select ok((public.update_event_occurrence_scope_if_version(
  (select event_id from recurrence_extra), 2, 'o00000000000000000002', 'future',
  null, null, null, null, null, null, null, null, null, null,
  null, null, null, null, null, null, null
)->>'changed')::boolean, '연속된 future 분할이 커밋된다');
select is(((select recurrence_rule from public.event_occurrence_by_key(
  (select event_id from recurrence_extra), 'o00000000000000000002'))->>'count')::integer),
  3, '연속된 future 상속은 남은 횟수를 유지한다');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_extra), 3, 'o00000000000000000002', 'future',
    null, null, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, 4::smallint)$$,
  '22023', null, '상속된 비월간 future 규칙은 monthly_day를 거부한다');
select ok((public.update_event_occurrence_scope_if_version(
  (select moved_id from recurrence_extra), 1, 'o00000000000000000000', 'this',
  'Moved far', '', '2027-06-10T09:00:00Z', '2027-06-10T10:00:00Z', 'UTC', false,
  null, null, 13::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null
)->>'changed')::boolean, '멀리 이동한 재정의가 커밋된다');
select ok(exists (select 1 from jsonb_array_elements((public.events_for_range_v2(
  (select group_id from recurrence_fixture), '2027-06-01T00:00:00Z',
  '2027-06-30T00:00:00Z', 'UTC', 100, null, null))->'events') e
  where e->>'event_id' = (select moved_id::text from recurrence_extra)
    and e->>'occurrence_key' = 'o00000000000000000000'),
  '범위 합집합은 멀리 이동한 재정의를 찾아낸다');
select throws_ok(
  $$select public.update_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', null::text,
    'bad scope', '', '2026-01-02T12:00:00Z', '2026-01-02T13:00:00Z', 'UTC', false,
    null, null, 1::bigint, null::uuid[], null, null, null::smallint[], null, null, null, null)$$,
  '22023', null, 'NULL 업데이트 범위는 거부된다');
select throws_ok(
  $$select public.delete_event_occurrence_scope_if_version(
    (select event_id from recurrence_fixture), 7, 'o00000000000000000001', null::text)$$,
  '22023', null, 'NULL 삭제 범위는 거부된다');
reset role;

-- 반복 일정에서 참여자만 교체할 때는 전용 응답 RPC를 사용한다. 그룹 소유자
-- 호출자라도 작성자는 필수이며, 정규 입력이 이미 일치하면 무동작이고 익명
-- 호출자는 먼저 거부한다.
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
  '42501', null, '반복 일정 구성원 교체는 생성자 누락을 거부한다');
select is(
  (public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[]
  )->>'changed')::boolean,
  false,
  '반복 일정 구성원의 정규화된 무변경 교체는 버전을 유지한다');
select is(
  public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[]
  )->>'occurrence_key',
  'o00000000000000000000',
  '반복 일정 구성원 교체는 single을 순번 0으로 정규화한다');
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select public.replace_recurring_event_members_if_version(
    (select event_id from recurrence_fixture), 7, 'single',
    array[(select owner_id from recurrence_fixture)]::uuid[])$$,
  '28000', null, '익명 반복 일정 구성원 교체는 거부된다');
reset role;

select has_function_privilege(
  'authenticated',
  'public.replace_recurring_event_members_if_version(uuid,integer,text,uuid[])',
  'execute'
), '반복 일정 구성원 전용 RPC는 authenticated 역할을 통해서만 실행할 수 있다';
select ok(
  not has_function_privilege(
    'anon',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ),
  '호환성 래퍼의 public ACL 권한이 회수되어 있다'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ),
  '호환성 래퍼의 authenticated ACL 권한이 부여되어 있다'
);
select ok(
  case when exists (
    select 1 from pg_catalog.pg_roles where rolname = 'service_role'
  ) then not has_function_privilege(
    'service_role',
    'public.replace_event_members_if_version(uuid,integer,uuid[])',
    'execute'
  ) else true end,
  '호환성 래퍼의 service_role ACL 권한이 회수되어 있다'
);

-- 인증된 호출자에게도 직접 하위 접근 권한을 회수한다.
set local role authenticated;
select throws_ok(
  $$select count(*) from public.event_recurrence_rules$$,
  '42501', null, 'ACL은 반복 규칙 직접 조회를 거부한다'
);
reset role;

-- 하드 삭제는 희소 하위 행과 반복 구간을 모두 연쇄 삭제해야 한다.
delete from public.events where id = (select monthly_id from recurrence_fixture);
select is((select count(*)::integer from public.event_recurrence_rules
           where event_id = (select monthly_id from recurrence_fixture)), 0,
          '이벤트 하드 삭제는 반복 구간을 연쇄 삭제한다');
select is((select count(*)::integer from public.event_occurrence_overrides
           where event_id = (select event_id from recurrence_fixture)), 1,
          '관련 없는 반복 일정 예외는 연쇄 삭제 후에도 그대로 유지된다');

select * from finish();
rollback;
