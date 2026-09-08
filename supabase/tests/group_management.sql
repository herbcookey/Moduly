-- 그룹 관리 수직 기능 조각용 pgTAP 픽스처다.
--
-- 이 픽스처는 request.jwt.claims를 설정한 실제 `authenticated` 데이터베이스
-- 역할로 의도적으로 API를 실행한다. 설정 전용 쓰기는 세션 소유자로 돌아가서
-- 수행하고 전체 테스트는 끝에 롤백한다.

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
-- 픽스처 키는 민감하지 않은 테스트 메타데이터이며 아래 API 역할 갱신은 생성된 그룹
-- ID만 채운다. 이 임시 테이블에 권한을 주면 모든 애플리케이션 테이블 쓰기의 범위를
-- 유지하면서 권한 오류를 피할 수 있다.
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

-- Auth 행은 설정 데이터다. Auth 트리거가 해당 프로필을 만든다.
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

-- 소유자가 기존 RPC를 통해 초기 그룹 두 개를 만든다. PostgREST와 pgTAP 스택이
-- 다르므로 지원하는 두 형식으로 클레임을 설정한다.
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

-- 멤버십 설정은 의도적으로 API 쓰기 표면 밖에서 수행한다.
insert into public.memberships (group_id, user_id, role, is_active, removed_at)
select group_id, member_id, 'member', true, null
from group_management_fixture;

-- 관계없는 그룹은 원래 소유자를 삭제해도 남는다. 해당 멤버십에는
-- invited_by=owner가 있어 FK SET NULL 경로를 확인할 수 있다.
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

-- 연쇄 작업용 소유자는 별도 그룹을 소유한다. auth.users가 삭제되면 해당 소유자
-- 행과 모든 하위 행이 사라져야 한다.
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

-- 기본 카탈로그/ACL/RLS 검증은 세션 소유자로 수행한다.
select ok(
  has_table_privilege('authenticated', 'public.groups', 'select'),
  'authenticated 호출자는 그룹 SELECT 권한을 유지한다'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_class c
    where c.oid = 'public.groups'::regclass
      and c.relrowsecurity
  ),
  'groups에 RLS가 활성화되어 있다'
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
  '활성 소유자용 부분 고유 인덱스가 예상한 정의로 존재한다'
);
select ok(
  not has_column_privilege('authenticated', 'public.groups', 'owner_id', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.groups', 'name', 'UPDATE'),
  'authenticated 호출자는 그룹 소유권이나 세부 정보를 직접 업데이트할 수 없다'
);
select ok(
  not has_column_privilege('authenticated', 'public.memberships', 'role', 'UPDATE'),
  'authenticated 호출자는 멤버십 역할을 직접 업데이트할 수 없다'
);
select ok(
  not has_column_privilege('authenticated', 'public.memberships', 'is_active', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.memberships', 'removed_at', 'UPDATE'),
  'authenticated 호출자는 멤버십 상태를 직접 업데이트할 수 없으며 관리 작업은 RPC로만 가능하다'
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
  '사용 가능한 경우 supabase_realtime에 events, groups 및 memberships가 포함된다'
);

-- RLS는 테스트 슈퍼유저가 아니라 실제 API 역할에서 평가한다.
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
  '소유자 RLS는 활성 그룹만 유지하고 보관된 그룹은 숨긴다'
);
select is(
  (select count(*)::integer
   from public.memberships
   where group_id = (select group_id from group_management_fixture)),
  2,
  '소유자 RLS는 활성 그룹의 모든 활성 멤버십을 노출한다'
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
  '활성 일반 구성원은 활성 그룹을 볼 수 있다'
);
select is(
  (select count(*)::integer
   from public.groups
   where id = (select archived_group_id from group_management_fixture)),
  0,
  '활성 일반 구성원은 보관된 그룹을 볼 수 없다'
);
select is(
  (select count(*)::integer
   from public.memberships
   where group_id = (select group_id from group_management_fixture)),
  2,
  '활성 일반 구성원은 공유 그룹의 활성 멤버십을 볼 수 있다'
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
  '외부 사용자 RLS는 어느 픽스처 그룹도 볼 수 없다'
);
reset role;

-- 갱신은 이름의 공백을 제거하고 정확한 시간대를 검증하며 버전을 한 번 올린다.
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
  'update_group_if_version은 그룹 이름의 앞뒤 공백을 제거한다'
);
select is(
  (select g.description
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  'Description'::text,
  'update_group_if_version은 길이가 제한된 설명을 저장한다'
);
select is(
  (select g.version
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  2,
  'update_group_if_version은 버전을 증가시킨다'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 2, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Next', '', 'Not/A/Timezone'
  ),
  '22023',
  'timezone must be an exact IANA timezone name',
  '잘못된 IANA 시간대는 거부된다'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 1, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Stale', '', 'UTC'
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '오래된 버전의 그룹 업데이트는 거부된다'
);
select throws_ok(
  format(
    'select public.update_group_if_version(%L::uuid, 2, %L, %L, %L)',
    (select group_id from group_management_fixture),
    'Too long', repeat('x', 10001), 'UTC'
  ),
  '22023',
  'group description must be at most 10000 characters',
  '그룹 설명 길이는 제한된다'
);

-- 이전과 보관을 포함한 모든 소유자 전용 종료/소유권 RPC는 오래된 버전을 거부한다.
-- 각 실패한 시도 뒤에도 소유자는 바뀌지 않는다.
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '소유자는 오래된 버전으로 소유권을 이전할 수 없다'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '소유자는 오래된 버전으로 그룹을 보관 처리할 수 없다'
);

-- 활성 멤버와 외부 사용자는 이전/오래된 버전을 제시해도 소유자 전용 RPC를 사용할
-- 수 없다. 모든 실패는 같은 안전한 충돌 코드를 사용한다.
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
  '활성 구성원은 오래된 버전으로 그룹을 업데이트할 수 없다'
);
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select outsider_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '활성 구성원은 오래된 버전으로 소유권을 이전할 수 없다'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '활성 구성원은 오래된 버전으로 그룹을 보관 처리할 수 없다'
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
  '외부 사용자는 오래된 버전으로 그룹을 업데이트할 수 없다'
);
select throws_ok(
  format(
    'select public.transfer_group_ownership(%L::uuid, %L::uuid, 1)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '외부 사용자는 오래된 버전으로 소유권을 이전할 수 없다'
);
select throws_ok(
  format(
    'select public.archive_group_if_version(%L::uuid, 1)',
    (select group_id from group_management_fixture)
  ),
  '40001',
  'group was changed, archived, or is not yours',
  '외부 사용자는 오래된 버전으로 그룹을 보관 처리할 수 없다'
);

-- 탈퇴는 본인만 할 수 있고 일반 멤버만 비활성화한다. 소유자와 외부 사용자의 시도도
-- 같은 authenticated 역할을 통해 수행한다.
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
-- 호출자는 탈퇴 직후 비활성 상태라 더 이상 일반 멤버 SELECT 정책을 통과하지 못한다.
-- 설정 역할로 이력 행을 확인한 다음 거부 경로를 위해 authenticated로 돌아간다.
reset role;
select is(
  (select m.is_active
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  false,
  'leave_group은 호출자를 비활성 상태로 표시한다'
);
select ok(
  (select m.removed_at is not null
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  'leave_group은 removed_at을 기록한다'
);
set local role authenticated;
select throws_ok(
  format('select public.leave_group(%L::uuid)', (select archived_group_id from group_management_fixture)),
  '42501',
  'only an active ordinary member can leave this group',
  '구성원은 보관된 그룹에서 탈퇴할 수 없다'
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
  '그룹 소유자는 탈퇴할 수 없다'
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
  '외부 사용자는 탈퇴할 수 없다'
);

-- 이전 전에 설정 역할을 통해 픽스처 멤버 상태만 복원한다.
reset role;
update public.memberships m
set is_active = true, removed_at = null
where m.group_id = (select group_id from group_management_fixture)
  and m.user_id = (select member_id from group_management_fixture);

-- 이전은 소유자 -> 멤버 / 멤버 -> 소유자의 원자적 작업 하나다.
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
  'transfer_group_ownership은 새 소유자를 반환한다'
);
select is(
  (select g.version
   from public.groups g
   where g.id = (select group_id from group_management_fixture)),
  3,
  '소유권 이전은 그룹 버전을 원자적으로 증가시킨다'
);
select is(
  (select count(*)::integer
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.role = 'owner' and m.is_active and m.removed_at is null),
  1,
  '소유권 이전 후 활성 소유자가 정확히 한 명 남는다'
);
select is(
  (select m.role::text
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select owner_id from group_management_fixture)),
  'member'::text,
  '이전 소유자는 일반 구성원으로 강등된다'
);
select is(
  (select m.role::text
   from public.memberships m
   where m.group_id = (select group_id from group_management_fixture)
     and m.user_id = (select member_id from group_management_fixture)),
  'owner'::text,
  '대상 구성원은 소유자로 승격된다'
);

-- 현재(새) 소유자는 스스로 탈퇴하거나 비활성화할 수 없다. 인위적인 직접 역할
-- 갱신이 아니라 마지막 소유자 경로다.
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
  '새 소유자는 본인 전용 RPC를 통해 탈퇴할 수 없다'
);
select throws_ok(
  format(
    'select public.set_member_active(%L::uuid, %L::uuid, false)',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '42501',
  'only the owner can change another member',
  '새 소유자는 관리 RPC를 통해 자신을 비활성화할 수 없다'
);

-- 사전 검사를 위해 새 소유자가 소유한 활성 그룹과 보관 그룹을 하나씩 추가한다.
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

-- 작성한 하위 행은 사전 검사에서 개수를 세며 소프트 보관 뒤에도 유지한다.
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

-- 정확한 사전 검사 요약이다. 소유 그룹 세 개(활성 둘, 보관 하나), 작성한 일정/초대
-- 하나, 소유 그룹 전체의 멤버십 네 개다.
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
  '사전 점검은 호출자가 소유한 모든 활성 및 보관 그룹을 나열한다'
);
select is(
  jsonb_array_length(public.account_deletion_preflight() -> 'active_owned_groups'),
  2,
  '사전 점검은 소유한 활성 그룹 두 개를 나열한다'
);
select is(
  jsonb_array_length(public.account_deletion_preflight() -> 'archived_owned_groups'),
  1,
  '사전 점검은 소유한 보관 그룹을 나열한다'
);
select is(
  (public.account_deletion_preflight() ->> 'groups')::bigint,
  3::bigint,
  '사전 점검의 그룹 수가 정확하다'
);
select is(
  (public.account_deletion_preflight() ->> 'events')::bigint,
  1::bigint,
  '사전 점검의 이벤트 연쇄 삭제 수가 정확하다'
);
select is(
  (public.account_deletion_preflight() ->> 'invites')::bigint,
  1::bigint,
  '사전 점검의 초대 연쇄 삭제 수가 정확하다'
);
select is(
  (public.account_deletion_preflight() ->> 'memberships')::bigint,
  4::bigint,
  '사전 점검의 멤버십 연쇄 삭제 수가 정확하다'
);
select ok(
  (public.account_deletion_preflight() ->> 'owned_groups') not like '%' || (select member_id::text from group_management_fixture) || '%'
    and (public.account_deletion_preflight() ->> 'owned_groups') not like '%' || (select owner_id::text from group_management_fixture) || '%',
  '사전 점검 요약은 사용자 UUID나 개인 식별 정보를 노출하지 않는다'
);

-- 소유자도 ACL 때문에 직접 테이블 쓰기는 실패하지만 RPC는 계속 사용할 수 있다.
select throws_ok(
  format(
    'update public.groups set name = %L where id = %L::uuid',
    'bypass',
    (select group_id from group_management_fixture)
  ),
  '42501',
  'ACL은 groups 직접 UPDATE를 거부한다'
);
select throws_ok(
  format(
    'update public.memberships set role = %L where group_id = %L::uuid and user_id = %L::uuid',
    'member',
    (select group_id from group_management_fixture),
    (select member_id from group_management_fixture)
  ),
  '42501',
  'ACL은 멤버십 역할 직접 UPDATE를 거부한다'
);
reset role;

-- 잘못된 이전 표시로 불변 소유권 트리거를 우회할 수 없다.
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
  '잘못된 이전 표식은 거부된다'
);
select set_config('moduly.transfer_marker', '', true);

-- 보관은 버전이 있는 종료 상태다. 하위 행은 RLS가 숨기지만 삭제하지 않는다.
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
  '보관된 그룹은 최종 상태다'
);
select is(
  (select count(*)::integer from public.groups where id = (select group_id from group_management_fixture)),
  0,
  'RLS는 이전 소유자에게 보관된 그룹을 숨긴다'
);
select is(
  (select count(*)::integer from public.events where id = '00000000-0000-4000-8000-000000009201'),
  0,
  'RLS는 보관된 이벤트를 숨긴다'
);
select is(
  (select count(*)::integer from public.invite_codes where id = '00000000-0000-4000-8000-000000009301'),
  0,
  'RLS는 보관된 초대를 숨긴다'
);
select is(
  (select count(*)::integer from public.memberships where group_id = (select group_id from group_management_fixture)),
  0,
  'RLS는 보관된 멤버십을 숨긴다'
);
reset role;

select is(
  (select count(*)::integer from public.groups where id = (select group_id from group_management_fixture)),
  1,
  '보관된 그룹 행은 계정 삭제 연쇄 처리를 위해 저장된 채로 남는다'
);
select is(
  (select count(*)::integer from public.events where id = '00000000-0000-4000-8000-000000009201'),
  1,
  '보관된 하위 이벤트는 저장된 채로 남는다'
);
select is(
  (select count(*)::integer from public.invite_codes where id = '00000000-0000-4000-8000-000000009301'),
  1,
  '보관된 하위 초대는 저장된 채로 남는다'
);
select ok(
  exists (
    select 1
    from public.audit_logs a
    where a.group_id = (select group_id from group_management_fixture)
      and a.entity_type = 'groups'
      and a.action = 'soft_delete'
  ),
  '보관 처리는 soft_delete 감사 작업을 기록한다'
);

-- 원래 소유자를 삭제한다. 소유하던 보관 그룹은 연쇄 삭제되지만 이전된 그룹과 다른
-- 그룹은 남는다. 남은 행의 invited_by는 SET NULL된다.
delete from auth.users
where id = (select owner_id from group_management_fixture);
select is(
  (select count(*)::integer from public.groups where id = (select archived_group_id from group_management_fixture)),
  0,
  '소유자를 삭제하면 그 소유자의 보관 그룹이 연쇄 삭제된다'
);
select is(
  (select invited_by
   from public.memberships
   where group_id = (select other_group_id from group_management_fixture)
     and user_id = (select cascade_owner_id from group_management_fixture)),
  null::uuid,
  '초대자를 삭제하면 남은 그룹의 invited_by가 NULL이 된다'
);
select is(
  (select count(*)::integer
   from public.groups
   where id = (select group_id from group_management_fixture)),
  1,
  '소유권 이전 후 이전 소유자를 삭제해도 그룹은 유지된다'
);
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'memberships'
      and a.entity_id is not null
  ),
  '멤버십 감사 행은 사용자 UUID를 보존하지 않는다'
);
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'memberships'
      and a.metadata::text ~ '9901|9902|9903|9904'
  ),
  '멤버십 감사 메타데이터에는 사용자 UUID나 개인 식별 정보가 없다'
);

delete from auth.users
where id = (select cascade_owner_id from group_management_fixture);
select is(
  (select count(*)::integer from public.groups where id = (select cascade_group_id from group_management_fixture)),
  0,
  '다른 소유자를 삭제하면 해당 그룹과 멤버십이 연쇄 삭제된다'
);

select * from finish();
rollback;
