-- 일정 참여자 할당용 pgTAP 픽스처다.
--
-- 조회/RPC 호출은 실제 authenticated 역할로 실행한다. 설정 전용 쓰기는 세션
-- 소유자를 사용하고 한 트랜잭션 안에서 유지하므로 이 파일은 일회용 로컬
-- 데이터베이스에서 반복 실행해도 안전하다.

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

-- 소유자가 운영 픽스처 그룹을 만들고 두 번째 소유자는 교차 그룹 대상 및 하드
-- 연쇄 작업 검증에 사용할 관계없는 그룹을 만든다.
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

-- 멤버십 행은 설정 데이터다. 비활성 행은 의도적으로 이력에 남지만 일정 대상으로
-- 선택할 수 없다.
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

-- 일정 작성자는 일반 멤버다. 참여자 교체와 본문 편집 모두에서 그룹 소유자와
-- 작성자의 차이를 명확히 한다.
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

-- 활성 작성자에게는 이전/Data API INSERT를 계속 지원한다. 새 AFTER INSERT 트리거는
-- 작성자 행 하나만 채우고 버전을 1로 유지하며 두 번째 상위 갱신을 출력하지 않는다.
-- 이 경로는 아래 참여자 인식 RPC와 의도적으로 분리해 테스트한다.
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
  '레거시 직접 INSERT는 이벤트의 초기 버전을 1로 유지한다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select legacy_event_id from event_members_fixture)),
  1,
  '레거시 직접 INSERT는 중복 없이 생성자 할당 하나를 만든다'
);
reset role;

-- RLS는 초기화 트리거가 실행되기 전에 외부 사용자의 직접 일정 INSERT를 거부한다.
-- 잘못된 활성 작성자 INSERT는 기존 일정 검사에서 실패한다. 어느 실패도 하위 행을
-- 남겨서는 안 된다.
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
  'RLS는 외부 사용자의 직접 이벤트 INSERT를 거부한다'
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id in (select e.id from public.events e where e.title = 'Unauthorized direct event')),
  0,
  '권한 없는 직접 INSERT는 참여자 행을 남기지 않는다'
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
  '기존 이벤트 검사는 잘못된 직접 INSERT를 거부한다'
);
reset role;
select is(
  (select count(*)::integer from public.event_members
   where event_id in (select e.id from public.events e where e.title = 'Malformed direct event')),
  0,
  '잘못된 직접 INSERT는 참여자 행을 남기지 않는다'
);

select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);

-- 기본 카탈로그, 키, 인덱스, RLS, ACL 및 publication을 검증한다.
select ok(
  exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.event_members'::regclass
      and relrowsecurity
  ),
  'event_members에 RLS가 활성화되어 있다'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.event_members'::regclass and contype = 'p'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%(event_id, user_id)%'
  ),
  'event_members에 복합 기본 키가 있다'
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
  '이벤트를 하드 삭제하면 event_id가 연쇄 삭제된다'
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
  '계정을 삭제하면 user_id가 연쇄 삭제된다'
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
  'user_id가 선두인 event_members 인덱스가 있다'
);
select ok(
  has_table_privilege('authenticated', 'public.event_members', 'select')
    and not has_table_privilege('authenticated', 'public.event_members', 'insert')
    and not has_table_privilege('authenticated', 'public.event_members', 'update')
    and not has_table_privilege('authenticated', 'public.event_members', 'delete'),
  'authenticated 역할에는 SELECT 권한만 있고 하위 행 직접 쓰기 권한은 없다'
);
select ok(
  not has_table_privilege('anon', 'public.event_members', 'select')
    and not has_table_privilege('anon', 'public.event_members', 'insert'),
  'anon 역할에는 event_members 테이블 권한이 없다'
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
  '참여자 교체 RPC는 authenticated 역할만 실행할 수 있다'
);
select ok(
  not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'event_members'
  ),
  'event_members는 supabase_realtime에 추가되지 않는다'
);

set local role authenticated;

select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  3,
  '활성 그룹 소유자는 현재 참여자 할당을 볼 수 있다'
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
  '활성 일반 구성원은 공유 그룹의 할당을 볼 수 있다'
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
  '외부 사용자는 다른 그룹의 할당을 볼 수 없다'
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from event_members_fixture),
  true
);

-- 생성 RPC는 결정적으로 중복을 제거하고 작성자/멤버 ID를 정규 순서로 반환한다.
-- NULL 입력은 작성자를 기본값으로 사용하며 명시적인 빈 배열은 실제 빈 할당 집합이다.
select is(
  (select cardinality(created.member_ids)
   from public.create_event_with_members(
     (select group_id from event_members_fixture),
     'Creator default', '',
     '2026-02-02T00:00:00Z', '2026-02-02T01:00:00Z',
     'UTC', false, null, null, 305419896, null
   ) as created),
  1,
  'member_ids가 NULL인 생성 요청은 생성자를 기본값으로 사용한다'
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
  '명시적인 빈 배열로 생성하면 참여자가 남지 않는다'
);
select is(
  (select e.version from public.events e
   where e.id = (select empty_event_id from event_members_fixture)),
  1,
  '명시적인 빈 배열 생성은 버전 1에서 시작한다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select empty_event_id from event_members_fixture)),
  0,
  '명시적인 빈 배열 생성에는 트리거가 만든 생성자 행이 없다'
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
  '일반 구성원은 다른 구성원이 소유한 이벤트를 교체할 수 없다'
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
  '생성 시 중복 UUID가 제거된다'
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
  '사용자 지정 목록 생성은 요청에 따라 생성자를 제외한다'
);
select ok(
  not exists (
    select 1 from public.event_members
    where event_id = (select custom_event_id from event_members_fixture)
      and user_id = (select owner_id from event_members_fixture)
  ),
  '사용자 지정 목록 생성은 트리거가 만든 생성자를 다시 추가하지 않는다'
);

-- 멤버가 만든 일정에서도 소유자 교체를 허용하며 본문은 그대로 두고 버전을 정확히
-- 한 번 올리며 빈 목록을 허용한다.
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
  '그룹 소유자는 생성자 소유의 참여자 목록을 한 번 교체할 수 있다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  1,
  '소유자 교체 시 중복이 제거되어 행 하나만 남는다'
);
select is(
  (select e.description from public.events e
   where e.id = (select event_id from event_members_fixture)),
  'Initial description',
  '참여자 교체는 이벤트 본문을 변경하지 않는다'
);
select is(
  (select replaced.version
   from public.replace_event_members_if_version(
     (select event_id from event_members_fixture), 2, '{}'::uuid[]
   ) as replaced),
  3,
  '빈 목록으로 교체하면 모든 참여자가 제거되고 버전이 한 번 증가한다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  0,
  '빈 목록으로 교체할 수 있다'
);

-- 수명 주기 및 권한 검사를 위해 일정을 활성 사용자에게 다시 할당한다.
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
  '재할당은 예상 버전에서 증가한다'
);

-- 잘못된 대상, 다른 그룹 대상, 중복 멤버십, 오래된 버전 및 외부 사용자 권한은 모두
-- 하위 행을 부분 교체하지 않고 실패한다.
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[%L::uuid]::uuid[])',
    (select event_id from event_members_fixture),
    (select inactive_id from event_members_fixture)
  ),
  '42501',
  'all event members must be active members of the group',
  '비활성 대상은 거부된다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select event_id from event_members_fixture)),
  3,
  '실패한 비활성 대상 교체는 원자성을 유지한다'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[%L::uuid]::uuid[])',
    (select event_id from event_members_fixture),
    (select second_owner_id from event_members_fixture)
  ),
  '42501',
  'all event members must be active members of the group',
  '다른 그룹의 대상은 거부된다'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 4, array[null]::uuid[])',
    (select event_id from event_members_fixture)
  ),
  '22023',
  'member_ids cannot contain null',
  'NULL 참여자 ID는 거부된다'
);
select throws_ok(
  format(
    'select public.replace_event_members_if_version(%L::uuid, 3, ''{}''::uuid[])',
    (select event_id from event_members_fixture)
  ),
  '40001',
  'event was changed, deleted, or is unavailable',
  '오래된 버전의 참여자 교체는 거부된다'
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
  '외부 사용자는 참여자를 교체할 수 없다'
);

-- 본문 갱신은 계속 작성자 전용이다. 그룹 소유자는 목록을 교체할 수 있지만 결합
-- 작성자 RPC를 통해 제목/본문을 갱신할 수 없다.
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
  '그룹 소유자는 자신이 소유하지 않은 이벤트 본문을 편집할 수 없다'
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
  '생성자는 본문과 참여자 목록을 원자적으로 업데이트할 수 있다'
);

-- 멤버십 비활성화는 각 할당을 정리하고 영향을 받은 각 일정의 버전을 한 번 올린다.
-- 재활성화해도 제거된 행을 복원하지 않는다.
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
  '비활성화하면 현재 이벤트 할당이 제거된다'
);
select is(
  (select e.version from public.events e
   where e.id = (select event_id from event_members_fixture)),
  6,
  '비활성화하면 상위 이벤트 버전이 정확히 한 번 증가한다'
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
  '다시 활성화해도 제거된 할당은 복원되지 않는다'
);

-- 인증된 호출자에게도 직접 하위 쓰기를 거부하며 트리거 함수와 내부 도우미는 계속
-- 직접 실행할 수 없다.
select throws_ok(
  format(
    'insert into public.event_members(event_id, user_id) values (%L::uuid, %L::uuid)',
    (select event_id from event_members_fixture),
    (select owner_id from event_members_fixture)
  ),
  '42501',
  null,
  'authenticated 역할은 event_members에 직접 INSERT할 수 없다'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.enforce_event_member_integrity()',
    'execute'
  ),
  'authenticated 역할은 트리거 전용 무결성 함수를 호출할 수 없다'
);
select throws_ok(
  'select public.seed_event_creator_member()',
  '42501',
  null,
  'authenticated 역할은 레거시 이벤트 초기화 트리거 함수를 직접 호출할 수 없다'
);

-- 소프트 삭제/보관된 일정은 행을 유지하지만 RLS가 숨긴다. 일정 하드 삭제는 행을
-- 연쇄 삭제하고 그룹 하드 삭제는 하위 일정을 연쇄 삭제한다.
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
  '소프트 삭제는 할당 행을 보존한다'
);
set local role authenticated;
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  0,
  '소프트 삭제된 할당은 authenticated 조회자에게 보이지 않는다'
);

-- 비활성화는 운영 중인 할당을 정확히 한 번 정리하지만 이미 소프트 삭제된 이력
-- 행과 버전은 건드리지 않는다. 재활성화해도 어느 할당도 복원하지 않는다.
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
  '비활성화하면 활성 할당이 정확히 한 번 제거된다'
);
select is(
  (select e.version from public.events e
   where e.id = (select deactivation_event_id from event_members_fixture)),
  2,
  '비활성화하면 활성 이벤트 버전이 한 번 증가한다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  '비활성화해도 소프트 삭제된 할당 행은 보존된다'
);
select is(
  (select e.version from public.events e
   where e.id = (select soft_deleted_event_id from event_members_fixture)),
  2,
  '비활성화해도 소프트 삭제된 이벤트 버전은 변경되지 않는다'
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
  '다시 활성화해도 비활성화로 제거된 할당은 복원되지 않는다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  '다시 활성화해도 소프트 삭제된 과거 할당은 보존된다'
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
  '그룹을 보관 처리해도 할당 행은 보존된다'
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
  'RLS는 소프트 삭제된 이벤트의 할당을 숨긴다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select archive_event_id from event_members_fixture)),
  0,
  'RLS는 보관된 그룹의 할당을 숨긴다'
);

reset role;
select ok(
  (select count(*) from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)) = 1
    and (select count(*) from public.event_members
         where event_id = (select archive_event_id from event_members_fixture)) = 1,
  '설정용 소유자는 보존된 최종 상태 행을 확인할 수 있다'
);
delete from public.events
where id = (select default_event_id from event_members_fixture);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select default_event_id from event_members_fixture)),
  0,
  '이벤트 하드 삭제는 event_members를 연쇄 삭제한다'
);

-- 작성자가 아닌 대상의 계정을 삭제하면 할당을 연쇄 삭제하고 남은 상위 행의 버전을
-- 정확히 한 번 올린다. 일정 작성자는 그대로 유지한다.
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
  '계정 연쇄 삭제용 이벤트는 생성 시 버전 1에서 시작한다'
);
delete from auth.users
where id = (select deleting_id from event_members_fixture);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select account_event_id from event_members_fixture)),
  0,
  '계정 삭제는 참여자 할당을 연쇄 삭제한다'
);
select is(
  (select e.version from public.events e
   where e.id = (select account_event_id from event_members_fixture)),
  2,
  '계정 연쇄 삭제는 남은 이벤트 버전을 정확히 한 번 증가시킨다'
);

-- 탈퇴는 소유자 비활성화와 같은 현재 할당 규칙을 따르지만 본인만 수행할 수 있고
-- 일반 멤버만 호출할 수 있다.
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
  'leave_group은 탈퇴하는 구성원의 할당을 제거한다'
);
select is(
  (select e.version from public.events e
   where e.id = (select leave_event_id from event_members_fixture)),
  2,
  'leave_group은 상위 이벤트 버전을 정확히 한 번 증가시킨다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select soft_deleted_event_id from event_members_fixture)),
  1,
  'leave_group은 소프트 삭제된 할당 이력을 보존한다'
);
select is(
  (select e.version from public.events e
   where e.id = (select soft_deleted_event_id from event_members_fixture)),
  2,
  'leave_group은 소프트 삭제된 이벤트 버전을 변경하지 않는다'
);
select is(
  (select count(*)::integer from public.event_members
   where event_id = (select archive_event_id from event_members_fixture)),
  1,
  'leave_group은 보관된 그룹의 할당 이력을 그대로 보존한다'
);

-- 관계없는 그룹을 하드 삭제하면 소유자 멤버십, 일정 및 event_members 행이 연쇄
-- 삭제된다. 이는 설정 전용이며 API 삭제를 나타내지 않는다.
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
  '그룹 하드 삭제는 event_members를 연쇄 삭제한다'
);

-- 감사 행에는 참여자 UUID/이름을 기록하지 않는다. 기존 일정 감사 항목에는 일정 ID와
-- 버전 메타데이터만 포함할 수 있다.
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'events'
      and a.metadata::text like '%' || (select deleting_id::text from event_members_fixture) || '%'
  ),
  '이벤트 참여자 변경 시 감사 메타데이터에 구성원 UUID를 넣지 않는다'
);

select * from finish();
rollback;
