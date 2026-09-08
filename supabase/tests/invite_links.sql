-- 인증된 초대 미리 보기/수락용 pgTAP 픽스처다.
--
-- 모든 API 검증은 JWT 클레임을 가진 실제 authenticated/anon 역할로 실행한다.
-- 설정 쓰기는 세션 소유자를 사용하고 트랜잭션을 롤백하므로 이 픽스처는 일회용
-- 로컬 데이터베이스에서 안전하게 실행할 수 있다.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table invite_links_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  outsider_id uuid not null,
  inactive_id uuid not null,
  group_id uuid,
  archived_group_id uuid,
  short_invite_id uuid,
  legacy_invite_id uuid,
  expired_invite_id uuid,
  revoked_invite_id uuid,
  exhausted_invite_id uuid,
  archived_invite_id uuid,
  transfer_invite_id uuid
) on commit drop;
grant all on invite_links_fixture to authenticated;

insert into invite_links_fixture (
  owner_id, member_id, outsider_id, inactive_id
) values (
  '00000000-0000-4000-8000-00000000a501',
  '00000000-0000-4000-8000-00000000a502',
  '00000000-0000-4000-8000-00000000a503',
  '00000000-0000-4000-8000-00000000a504'
);

-- Auth 행은 픽스처 설정용이다. 기존 Auth 트리거가 프로필을 만든다.
reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    (select owner_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Invite owner"}'::jsonb
  ),
  (
    (select member_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-member@example.test', '',
    now(), now(), now(), '{"display_name":"Invite member"}'::jsonb
  ),
  (
    (select outsider_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-outsider@example.test', '',
    now(), now(), now(), '{"display_name":"Invite outsider"}'::jsonb
  ),
  (
    (select inactive_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Invite inactive"}'::jsonb
  )
on conflict (id) do nothing;

-- 소유자가 인증된 API를 통해 운영 그룹과 보관 그룹을 하나씩 만든다.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from invite_links_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

update invite_links_fixture f
set group_id = created.id
from public.create_group('Invite fixture', 'Asia/Seoul', 'Private fixture description') as created;

update invite_links_fixture f
set archived_group_id = created.id
from public.create_group('Archived invite fixture', 'UTC', 'Archived description') as created;

select public.archive_group_if_version(
  (select archived_group_id from invite_links_fixture), 1
);
reset role;

-- 활성, 과거 비활성 및 직접 초대 행은 설정 데이터다. 아래 모든 초대 값은 이
-- 트랜잭션 안에서만 알 수 있으며 invite_codes에는 다이제스트만 삽입한다.
insert into public.memberships (
  group_id, user_id, role, is_active, removed_at
) values
  (
    (select group_id from invite_links_fixture),
    (select member_id from invite_links_fixture),
    'member', true, null
  ),
  (
    (select group_id from invite_links_fixture),
    (select inactive_id from invite_links_fixture),
    'member', false, now()
  );

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version,
  created_at, updated_at
) values (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345ABCDEFGH', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 3, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('0123456789abcdef0123456789abcdef0123456789abcdef', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 2, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345JKLMNPQR', 'utf8'), 'sha256'), 'hex'),
  now() - interval '1 minute', 1, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345STUVWXYZ', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('6789ABCDEFGH', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 1, 1,
  now() - interval '2 hours', now() - interval '2 hours'
)
returning id;

-- 다이제스트로 결정적인 초대 ID를 캡처한다. 애플리케이션 테이블이나 감사 행에
-- 평문 값을 영속화하지 않는다.
update invite_links_fixture f
set short_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345ABCDEFGH', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set legacy_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('0123456789abcdef0123456789abcdef0123456789abcdef', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set expired_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345JKLMNPQR', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set revoked_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345STUVWXYZ', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set exhausted_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('6789ABCDEFGH', 'utf8'), 'sha256'), 'hex');

update public.invite_codes
set revoked_at = now(), version = 2
where id = (select revoked_invite_id from invite_links_fixture);

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version
)
values (
  (select archived_group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('7892JKLMNPQR', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1
)
;

-- 이 설정 전용 삽입에서는 생성된 UUID에 의존하지 않고 결정적인 다이제스트로
-- 보관된 행을 기록한다.
update invite_links_fixture f
set archived_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('7892JKLMNPQR', 'utf8'), 'sha256'), 'hex');

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version
)
values (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('7892STUVWXYZ', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1
);
update invite_links_fixture f
set transfer_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('7892STUVWXYZ', 'utf8'), 'sha256'), 'hex');

-- 카탈로그/ACL/RLS 검사는 세션 소유자로 수행한다.
select ok(
  exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.invite_preview_attempts'::regclass
      and relrowsecurity
  ),
  '미리보기 시도 원장에 RLS가 활성화되어 있다'
);
select ok(
  not has_table_privilege('authenticated', 'public.invite_preview_attempts', 'select')
    and not has_table_privilege('authenticated', 'public.invite_preview_attempts', 'insert'),
  'authenticated 역할에는 미리보기 시도 원장의 직접 테이블 권한이 없다'
);
select ok(
  not has_function_privilege('anon', 'public.preview_invite(text)', 'execute')
    and has_function_privilege('authenticated', 'public.preview_invite(text)', 'execute'),
  '미리보기 RPC는 authenticated 역할만 실행할 수 있다'
);
select ok(
  not has_table_privilege('authenticated', 'public.invite_codes', 'update')
    and not has_column_privilege('authenticated', 'public.invite_codes', 'revoked_at', 'update'),
  '초대 테이블 UPDATE는 RPC로만 가능하다'
);
select ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'invite_codes'
      and column_name in ('token', 'plaintext_token')
  ),
  'invite_codes에는 평문 토큰 열이 없다'
);

-- 활성 일반 멤버의 미리 보기는 승인된 필드 집합만 반환하고 already_member로
-- 표시하며 사용 횟수를 소비하지 않는다.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  public.preview_invite('2345-abcd-efgh') ->> 'valid',
  'true',
  '유효한 짧은 코드는 클라이언트 방식 정규화 후 미리보기에 성공한다'
);
select is(
  public.preview_invite('2345-abcd-efgh') ->> 'already_member',
  'true',
  '미리보기는 유효한 토큰에 대해서만 활성 멤버십을 알린다'
);
select ok(
  (select array_agg(key order by key)
   from jsonb_object_keys(public.preview_invite('2345ABCDEFGH')) as key)
  = array['already_member','expires_at','group_description','group_id','group_name','group_timezone','valid']::text[],
  '유효한 미리보기 객체에는 정제된 필드만 정확히 포함된다'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  0,
  '미리보기는 사용 횟수를 소비하지 않는다'
);
set local role authenticated;

-- 기존 활성 멤버는 초대 수명 주기의 각 종료 상태 뒤에도 토큰을 재시도할 수 있다.
-- 정확한 토큰/그룹 일치 및 운영 그룹이 확인되므로 이 분기는 비활성 멤버나 외부
-- 사용자에게 아무 정보도 노출하지 않는다.
select is(
  public.preview_invite('2345-JKLM-NPQR') ->> 'already_member',
  'true',
  '활성 구성원의 만료 토큰 미리보기는 멱등성을 유지한다'
);
select is(
  public.preview_invite('2345-STUV-WXYZ') ->> 'already_member',
  'true',
  '활성 구성원의 취소된 토큰 미리보기는 멱등성을 유지한다'
);
select is(
  public.preview_invite('6789-ABCD-EFGH') ->> 'already_member',
  'true',
  '활성 구성원의 소진된 토큰 미리보기는 멱등성을 유지한다'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-JKLM-NPQR') as j),
  'already_member',
  '활성 구성원의 수락은 만료 후에도 멱등성을 유지한다'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-STUV-WXYZ') as j),
  'already_member',
  '활성 구성원의 수락은 취소 후에도 멱등성을 유지한다'
);
select is(
  (select j.reason from public.join_group_with_invite('6789-ABCD-EFGH') as j),
  'already_member',
  '활성 구성원의 수락은 소진 후에도 멱등성을 유지한다'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select exhausted_invite_id from invite_links_fixture)),
  1,
  '최종 상태에서 활성 구성원이 재시도해도 사용 횟수를 추가로 소비하지 않는다'
);
set local role authenticated;

-- 유효하지 않음, 만료, 취소, 소진, 보관, 잘못된 형식 및 너무 긴 값은 모두 같은
-- 그룹 없음 응답으로 합쳐진다.
reset role;
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  public.preview_invite('not-a-token'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '누락되었거나 잘못된 토큰의 미리보기 응답은 동일하다'
);
select is(
  public.preview_invite('2345-JKLM-NPQR'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '만료된 토큰의 미리보기 응답은 동일하다'
);
select is(
  public.preview_invite('2345-STUV-WXYZ'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '취소된 토큰의 미리보기 응답은 동일하다'
);
select is(
  public.preview_invite('6789-ABCD-EFGH'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '소진된 토큰의 미리보기 응답은 동일하다'
);
select is(
  public.preview_invite('7892-JKLM-NPQR'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '보관된 그룹의 미리보기 응답은 동일하다'
);
select is(
  public.preview_invite(repeat('A', 257)),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  '너무 긴 미리보기 토큰은 앞부분 절삭 없이 거부된다'
);

-- 모든 호출자는 범위를 제한한 전체 오래된 행 정리도 수행한다. 비활성 요청자의 행은
-- attempted_at 인덱스를 통해 기회적으로 제거하며, 위 요청자별 이동 창이 계속 최종 기준이다.
reset role;
insert into public.invite_preview_attempts (actor_id, attempted_at)
values (
  (select inactive_id from invite_links_fixture),
  now() - interval '2 hours'
);
insert into public.invite_join_attempts (
  actor_id, token_hash, attempted_at, succeeded, reason
)
values (
  (select inactive_id from invite_links_fixture),
  encode(extensions.digest(convert_to('stale-row', 'utf8'), 'sha256'), 'hex'),
  now() - interval '2 hours', false, 'invalid_or_expired'
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.preview_invite('not-a-token');
reset role;
select is(
  (select count(*)::integer from public.invite_preview_attempts
   where actor_id = (select inactive_id from invite_links_fixture)
     and attempted_at <= now() - interval '1 hour'),
  0,
  '미리보기 정리 작업은 비활성 행위자의 오래된 행을 제거한다'
);
set local role authenticated;
select public.join_group_with_invite('not-a-token');
reset role;
select is(
  (select count(*)::integer from public.invite_join_attempts
   where actor_id = (select inactive_id from invite_links_fixture)
     and attempted_at <= now() - interval '1 hour'),
  0,
  '가입 정리 작업은 비활성 행위자의 오래된 행을 제거한다'
);

-- 속도가 제한된 미리 보기에는 그룹 데이터가 없고 자체 원장 기간을 늘리지 않는다.
delete from public.invite_preview_attempts
where actor_id = (select member_id from invite_links_fixture);
set local role authenticated;
select public.preview_invite('not-a-token') from generate_series(1, 60);
select is(
  public.preview_invite('2345ABCDEFGH'),
  '{"reason":"rate_limited","valid":false}'::jsonb,
  '미리보기 요청 제한 응답에는 그룹 데이터가 없다'
);
reset role;
select is(
  (select count(*)::integer from public.invite_preview_attempts
   where actor_id = (select member_id from invite_links_fixture)),
  60,
  '차단된 미리보기는 원장 행을 추가로 삽입하지 않는다'
);
delete from public.invite_preview_attempts
where actor_id = (select member_id from invite_links_fixture);

-- 호출자가 authenticated 역할과 null이 아닌 subject를 제공해도 익명 JWT는 거부한다.
-- Supabase는 이 세션에 is_anonymous를 설정한다.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from invite_links_fixture),
    'role', 'authenticated',
    'is_anonymous', true
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select throws_ok(
  'select public.preview_invite(''2345ABCDEFGH'')',
  '28000',
  'authentication is required',
  '익명 JWT는 authenticated 역할이어도 미리보기를 실행할 수 없다'
);
select throws_ok(
  'select public.join_group_with_invite(''2345ABCDEFGH'')',
  '28000',
  'authentication is required',
  '익명 JWT는 authenticated 역할이어도 가입을 실행할 수 없다'
);
reset role;

-- anon 역할은 미리 보거나 수락할 수 없다. 데이터베이스는 인증되지 않은 토큰
-- 조회를 수행하지 않는다.
set request.jwt.claim.sub = '';
set request.jwt.claim.role = 'anon';
set local role anon;
select throws_ok(
  'select public.preview_invite(''2345ABCDEFGH'')',
  '42501',
  null,
  'anon 역할은 preview_invite를 실행할 수 없다'
);
select throws_ok(
  'select public.join_group_with_invite(''2345ABCDEFGH'')',
  '42501',
  null,
  'anon 역할은 join_group_with_invite를 실행할 수 없다'
);
reset role;

-- 유효한 외부 사용자는 형식화된 짧은 코드로 가입한다. 같은 요청을 반복해도
-- 멱등적이며 사용 횟수를 추가로 소비하지 않는다.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345-abcd-efgh') as j),
  'joined',
  '외부 사용자는 유효한 형식의 짧은 코드를 수락할 수 있다'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  1,
  '새 멤버십은 사용 횟수를 정확히 한 번 소비한다'
);
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345ABCDEFGH') as j),
  'already_member',
  '중복 수락은 멱등성을 유지한다'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  1,
  '중복 수락은 사용 횟수를 추가로 소비하지 않는다'
);
set local role authenticated;

-- 비활성화된 멤버십은 다시 가입할 수 있고 사용 횟수 하나를 추가로 소비한다. 이전
-- 48자 16진수 코드도 대문자/구분자 변형을 허용한다.
reset role;
update public.memberships
set is_active = false, removed_at = now()
where group_id = (select group_id from invite_links_fixture)
  and user_id = (select outsider_id from invite_links_fixture);
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('01234567-89ABCDEF-01234567-89ABCDEF-01234567-89ABCDEF') as j),
  'joined',
  '레거시 48자리 16진수 초대는 정규 소문자 형식을 허용한다'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select legacy_invite_id from invite_links_fixture)),
  1,
  '레거시 수락은 사용 횟수를 한 번 소비한다'
);
set local role authenticated;

-- 동일한 수락 실패와 최대 사용 횟수 종료 동작이다.
-- 종료 초대 상태가 동일하게 유지되도록 비활성화된 외부 사용자를 쓴다. 비활성
-- 픽스처 요청자는 방금 위의 이전 코드로 재가입했으므로 멱등성 의미에서 활성 멤버다.
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345-JKLM-NPQR') as j),
  'invalid_or_expired',
  '만료된 토큰의 수락 응답은 동일하다'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-STUV-WXYZ') as j),
  'invalid_or_expired',
  '취소된 토큰의 수락 응답은 동일하다'
);
select is(
  (select j.reason from public.join_group_with_invite('6789-ABCD-EFGH') as j),
  'invalid_or_expired',
  '소진된 토큰의 수락 응답은 동일하다'
);
select is(
  (select j.reason from public.join_group_with_invite(repeat('A', 257)) as j),
  'invalid_or_expired',
  '너무 긴 수락 토큰은 절삭 없이 거부된다'
);
reset role;
select is(
  (
    select token_hash
    from public.invite_join_attempts
    where actor_id = (select outsider_id from invite_links_fixture)
    order by id desc
    limit 1
  ),
  encode(
    extensions.digest(
      convert_to('invalid-invite-token-sentinel', 'utf8'),
      'sha256'
    ),
    'hex'
  ),
  '잘못된 수락 토큰은 고정 센티널 다이제스트만 저장한다'
);
set local role authenticated;

-- 가입 창을 실제 시도로 채운 뒤 차단된 호출이 rate_limited 행을 추가하지 않아 잠금
-- 시간을 늘릴 수 없는지 확인한다.
reset role;
delete from public.invite_join_attempts
where actor_id = (select inactive_id from invite_links_fixture);
insert into public.invite_join_attempts (actor_id, token_hash, attempted_at, succeeded, reason)
select
  (select inactive_id from invite_links_fixture),
  encode(extensions.digest(convert_to('rate-' || n::text, 'utf8'), 'sha256'), 'hex'),
  now() - interval '1 minute', false, 'invalid_or_expired'
from generate_series(1, 20) as n;
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345ABCDEFGH') as j),
  'rate_limited',
  '가입 요청 제한은 유형이 지정되지만 토큰이나 그룹 상태를 공개하지 않는다'
);
reset role;
select is(
  (select count(*)::integer from public.invite_join_attempts
   where actor_id = (select inactive_id from invite_links_fixture)),
  20,
  '차단된 가입은 rate_limited 원장 행을 추가하지 않는다'
);

-- 소유권 이전은 권한 주체만 바꾼다. 새 소유자는 같은 낙관적 버전 계약을 사용해
-- 이전 소유자가 만든 초대를 취소할 수 있다.
delete from public.invite_join_attempts
where actor_id = (select member_id from invite_links_fixture);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.transfer_group_ownership(
  (select group_id from invite_links_fixture),
  (select member_id from invite_links_fixture),
  1
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
select is(
  (select r.invite_id from public.revoke_invite_code(
    (select transfer_invite_id from invite_links_fixture), 1
  ) as r),
  (select transfer_invite_id from invite_links_fixture),
  '현재 소유자는 소유권 이전 전에 생성된 초대를 취소할 수 있다'
);
select throws_ok(
  format(
    'select * from public.revoke_invite_code(%L::uuid, 2)',
    (select transfer_invite_id from invite_links_fixture)
  ),
  '40001',
  'invite was changed, revoked, or is not yours',
  '최종 상태의 초대를 다시 취소하면 일반 충돌이 발생한다'
);
reset role;
select is(
  (select version from public.invite_codes
   where id = (select transfer_invite_id from invite_links_fixture)),
  2,
  '재취소는 최종 상태 초대의 버전을 증가시키지 않는다'
);

-- 현재 소유자도 직접 UPDATE는 계속 거부된다. RLS는 관계없는 인증된 외부
-- 사용자에게도 초대 행을 숨긴다.
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select throws_ok(
  format(
    'update public.invite_codes set revoked_at = now() where id = %L::uuid',
    (select short_invite_id from invite_links_fixture)
  ),
  '42501',
  null,
  'ACL은 초대 직접 UPDATE를 거부한다'
);
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.invite_codes
   where group_id = (select group_id from invite_links_fixture)),
  0,
  '외부 사용자 RLS는 초대 메타데이터를 나열할 수 없다'
);
reset role;

-- 감사 행에는 수명 주기/버전 메타데이터만 포함한다. 토큰이나 다이제스트는 공개
-- 감사 테이블로 복사하지 않는다.
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'invite_codes'
      and (a.metadata::text like '%2345ABCDEFGH%'
           or a.metadata::text like '%token_hash%'
           or a.metadata::text like '%2345JKLMNPQR%')
  ),
  '초대 감사 메타데이터에는 평문 토큰이나 토큰 해시가 포함되지 않는다'
);
select ok(
  not exists (
    select 1
    from public.invite_join_attempts a
    where a.token_hash = '2345ABCDEFGH'
  ),
  '가입 원장은 평문 토큰 대신 다이제스트를 저장한다'
);

select 'invite-links pgTAP checks passed' as result;
rollback;
