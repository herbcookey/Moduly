-- 기능 3 SQL 픽스처다. 함께 사용하는 실행기가 이 파일을 실행하기 전에 아래의
-- 결정적 행을 만든다. 검증은 PostgreSQL/DO 블록만 사용하므로 pgTAP을 설치하지
-- 않아도 실행기가 동작한다.
--
-- 소유자 f101, 멤버 f102, 비활성 f103, 외부 사용자 f104, 그룹 f201,
-- 일정 f301(이전), f302(시간 지정), f303(종일), f304(매일 2회)다.

begin;
set local timezone = 'UTC';

do $$
begin
  if (select title from public.events where id = '00000000-0000-4000-8000-00000000f301') <> 'Legacy reminder event' then
    raise exception '미리 알림 마이그레이션 중 인접 일정이 변경되었습니다';
  end if;
  if (select description from public.groups where id = '00000000-0000-4000-8000-00000000f201') <> 'legacy group data' then
    raise exception '미리 알림 마이그레이션 중 인접 그룹이 변경되었습니다';
  end if;
  if exists (select 1 from public.notification_preferences) then
    raise exception '미리 알림 마이그레이션이 계정 환경 설정 행을 만들어 냈습니다';
  end if;
  if exists (select 1 from public.event_reminder_settings) then
    raise exception '미리 알림 마이그레이션이 설정 행을 만들어 냈습니다';
  end if;
end;
$$;

select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select pg_catalog.set_config('request.jwt.claim.role', 'authenticated', false);
set local role authenticated;

select public.set_notification_preferences(true, false, 0);
select public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 900, 0::smallint, 2, 0);
select public.set_event_reminder('00000000-0000-4000-8000-00000000f302', 'local', true, 900, 0::smallint, 1, 0);
select public.set_event_reminder('00000000-0000-4000-8000-00000000f303', 'local', true, 900, 0::smallint, 1, 0);
select public.set_event_reminder('00000000-0000-4000-8000-00000000f304', 'local', true, 900, 0::smallint, 1, 0);

do $$
declare
  v jsonb;
begin
  v := public.get_event_reminder('00000000-0000-4000-8000-00000000f303');
  if v->>'event_id' <> '00000000-0000-4000-8000-00000000f303'
     or jsonb_array_length(v->'settings') <> 1
     or v->'settings'->0->>'all_day_local_time' <> '09:00:00' then
    raise exception '일정 미리 알림 조회 봉투가 고정 종일 계약과 다릅니다';
  end if;
end;
$$;

-- 엄격한 limit+1 키셋 페이지네이션과 단일 일정 occurrence_index 정규화다.
do $$
declare
  v_page jsonb;
  v_next jsonb;
  v_cursor text;
  v_first jsonb;
begin
  v_page := public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 2, null);
  if jsonb_array_length(v_page->'candidates') <> 2
     or (v_page->>'has_more')::boolean is not true
     or v_page->>'next_cursor' is null then
    raise exception '후보 페이지가 엄격한 limit+1 키셋 의미를 사용하지 않았습니다';
  end if;
  v_first := v_page->'candidates'->0;
  if v_first->>'occurrence_key' = 'single'
     and (v_first->>'occurrence_index')::integer <> 0 then
    raise exception '단일 일정 후보 occurrence_index는 0이어야 합니다';
  end if;
  v_cursor := v_page->>'next_cursor';
  v_next := public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 2, v_cursor);
  if jsonb_array_length(v_next->'candidates') = 0
     or (v_next->'candidates'->0->>'fire_at')::timestamptz < (v_first->>'fire_at')::timestamptz then
    raise exception '후보 커서가 진행되지 않았습니다';
  end if;
  if v_next->>'capability' <> 'client_local_scheduler' then
    raise exception '로컬 후보 기능이 명시적이지 않습니다';
  end if;
end;
$$;

do $$
declare
  v_page jsonb;
  v_row jsonb;
begin
  v_page := public.reminder_candidates_for_user('2026-03-08T12:00:00Z', '2026-03-08T14:00:00Z', 10, null);
  if jsonb_array_length(v_page->'candidates') <> 1 then
    raise exception '종일 후보가 현지 시간 창에서 반환되지 않았습니다';
  end if;
  v_row := v_page->'candidates'->0;
  if v_row->>'event_id' <> '00000000-0000-4000-8000-00000000f303'
     or (v_row->>'fire_at')::timestamptz <> '2026-03-08T13:00:00Z'::timestamptz
     or v_row->>'all_day_local_time' <> '09:00:00'
     or v_row->>'occurrence_index' <> '0' then
    raise exception '종일 fire_at이 일정 시간대 09:00 현지 시각 정책을 사용하지 않습니다';
  end if;
end;
$$;

-- Dart와 동작을 맞춘다. 봄 누락 시각은 앞으로 이동하고 가을 중복 시각은 더 늦은 UTC를 선택한다.
reset role;
do $$
begin
  if private.wall_time_to_instant(timestamp '2024-03-10 02:30:00', 'America/New_York') <> '2024-03-10T07:30:00Z'::timestamptz then
    raise exception '봄 누락 시각을 앞으로 이동하지 않았습니다';
  end if;
  if private.wall_time_to_instant(timestamp '2024-11-03 01:30:00', 'America/New_York') <> '2024-11-03T06:30:00Z'::timestamptz then
    raise exception '가을 중복 시각에서 더 늦은 시각을 선택하지 않았습니다';
  end if;
end;
$$;

-- 비활성 멤버십은 설정/후보를 만들거나 읽을 수 없다.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f103', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f103","role":"authenticated"}', false);
do $$
begin
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 900, 0::smallint, 2, 0);
    raise exception '비활성 멤버에게 미리 알림 설정이 허용되었습니다';
  exception when sqlstate '42501' then
    null;
  end;
end;
$$;
select public.set_notification_preferences(true, false, 0);
do $$
begin
  if jsonb_array_length(public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 10, null)->'candidates') <> 0 then
    raise exception '비활성 멤버가 미리 알림 후보를 받았습니다';
  end if;
end;
$$;

-- 잘못된 커서와 오래된 낙관적 잠금 버전은 실패 시 차단한다.
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
do $$
begin
  begin
    perform public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 10, 'not a cursor');
    raise exception '잘못된 커서를 허용했습니다';
  exception when sqlstate '22023' then
    null;
  end;
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 900, 0::smallint, 2, 99);
    raise exception '오래된 설정 버전을 허용했습니다';
  exception when sqlstate '40001' then
    null;
  end;
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 604801, 0::smallint, 2, 1);
    raise exception '7일을 넘는 시간 지정 사전 알림을 허용했습니다';
  exception when sqlstate '22023' then
    null;
  end;
end;
$$;

-- API 역할은 테이블을 조회할 수 없다. authenticated에는 클라이언트 RPC 실행
-- 권한을 주고 service_role에만 작업자 래퍼 권한을 준다.
reset role;
do $$
begin
  if has_table_privilege('authenticated', 'public.notification_preferences', 'select')
     or has_table_privilege('authenticated', 'public.event_reminder_settings', 'select')
     or has_table_privilege('anon', 'public.notification_preferences', 'select') then
    raise exception '클라이언트 테이블 ACL이 예기치 않게 미리 알림 행을 노출했습니다';
  end if;
  if not has_function_privilege('authenticated', 'public.get_notification_preferences()', 'execute')
     or has_function_privilege('anon', 'public.get_notification_preferences()', 'execute')
     or has_function_privilege('authenticated', 'public.worker_claim_event_reminder_jobs(uuid,integer,timestamptz,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.worker_claim_event_reminder_jobs(uuid,integer,timestamptz,integer)', 'execute') then
    raise exception '미리 알림 함수 ACL 경계가 올바르지 않습니다';
  end if;
end;
$$;
set local role anon;
select pg_catalog.set_config('request.jwt.claim.sub', '', false);
select pg_catalog.set_config('request.jwt.claims', '{}', false);
do $$
begin
  begin
    perform public.get_notification_preferences();
    raise exception '익명 환경 설정 조회를 허용했습니다';
  exception when insufficient_privilege or sqlstate '28000' then
    null;
  end;
end;
$$;
reset role;

-- 기능 메타데이터는 제공자 자격 증명과 별개이며 어떤 비밀 값도 SQL에 들어오지 않는다.
select public.worker_set_push_capability('fcm', true);
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select public.set_notification_preferences(true, true, 1);
do $$
declare
  v jsonb;
begin
  v := public.register_push_device('fcm', 'android', 'production', 'fixture-token-owner', 'fixture-install-owner');
  if v ? 'token' or v ? 'token_hash' then
    raise exception '기기 등록이 Bearer 값을 노출했습니다';
  end if;
end;
$$;
select public.set_event_reminder('00000000-0000-4000-8000-00000000f304', 'push', true, 900, 0::smallint, 1, 0);
-- 활성 기기 두 개로 취소 범위를 검사한다. 하나를 제거하면 대기 작업을 유지해야
-- 하고 마지막 기기를 제거하면 취소해야 한다.
select public.register_push_device(
  'fcm', 'android', 'production', 'fixture-token-owner-2', 'fixture-install-owner-2'
);
select public.set_event_reminder(
  '00000000-0000-4000-8000-00000000f302', 'push', true, 900, 0::smallint, 1, 0
);
reset role;

do $$
begin
  if (select count(*) from private.push_device_tokens where user_id = '00000000-0000-4000-8000-00000000f101'::uuid and is_active) <> 2 then
    raise exception '기기 등록이 비공개 활성 토큰 두 개를 모두 영속화하지 않았습니다';
  end if;
end;
$$;

-- 작업자 행을 가져오기 전에 기기 취소 검증용 푸시 작업 하나를 준비한다. 임시 ID
-- 맵을 사용하면 authenticated 역할이 비공개 토큰 데이터를 노출하지 않고 정확한
-- 행을 취소할 수 있다.
create temporary table reminder_fixture_devices (
  label text primary key,
  device_id uuid not null
);
insert into reminder_fixture_devices(label, device_id)
select case when d.token_hash = encode(
           extensions.digest(pg_catalog.convert_to('fixture-token-owner', 'utf8'), 'sha256'), 'hex'
         ) then 'first' else 'second' end,
       d.id
from private.push_device_tokens d
where d.user_id = '00000000-0000-4000-8000-00000000f101'::uuid
  and d.is_active;
grant select on reminder_fixture_devices to authenticated;
set local role service_role;
select public.worker_prepare_event_reminder_jobs(
  '00000000-0000-4000-8000-00000000f302', '2026-03-09T00:00:00Z', 3
);
reset role;
set local role authenticated;
do $$
declare
  v_first jsonb;
  v_second jsonb;
begin
  select public.revoke_push_device(device_id) into v_first
  from reminder_fixture_devices where label = 'first';
  if v_first->>'cancelled_jobs' <> '0' then
    raise exception '활성 기기 둘 중 하나를 취소했을 때 공유 작업도 취소되었습니다';
  end if;
  select public.revoke_push_device(device_id) into v_second
  from reminder_fixture_devices where label = 'second';
  if v_second->>'cancelled_jobs' <> '1' then
    raise exception '마지막 활성 기기를 취소했지만 해당 작업이 취소되지 않았습니다';
  end if;
end;
$$;
reset role;
do $$
begin
  if (select count(*) from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f302'
        and status in ('pending', 'processing', 'retry')) <> 0
     or (select count(*) from private.event_reminder_jobs
         where event_id = '00000000-0000-4000-8000-00000000f302'
           and status = 'cancelled' and cancel_reason = 'device_revoked') <> 1 then
    raise exception '마지막 기기 취소 뒤 종료되지 않은 작업이 남았거나 사유가 올바르지 않습니다';
  end if;
end;
$$;
-- 이후 기기 등록은 새 대기 리비전을 조정할 수 있다. 아래 반복 f304 행에도 활성
-- 전송 대상을 남긴다.
set local role authenticated;
select public.register_push_device(
  'fcm', 'android', 'production', 'fixture-token-owner-3', 'fixture-install-owner-3'
);
reset role;

-- 참여자 수명 주기의 종료는 미리 알림 의도에도 종료 상태다. 실행기의 이전 설정으로
-- f301 일정은 이미 event_members에 f102를 갖는다. 해당 참여자에게 푸시 설정/작업을
-- 주고 멤버십을 비활성화한 뒤 복합 event_members FK가 설정과 비공개 작업을 모두
-- 제거하는지 확인한다.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f102', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f102","role":"authenticated"}', false);
select public.set_notification_preferences(false, true, 0);
select public.register_push_device(
  'fcm', 'android', 'production', 'fixture-token-member', 'fixture-install-member'
);
select public.set_event_reminder(
  '00000000-0000-4000-8000-00000000f301', 'push', true, 900, 0::smallint,
  (select version from public.events where id = '00000000-0000-4000-8000-00000000f301'), 0
);
reset role;
set local role service_role;
select public.worker_prepare_event_reminder_jobs(
  '00000000-0000-4000-8000-00000000f301', '2026-03-09T00:00:00Z', 3
);
reset role;
do $$
begin
  if (select count(*) from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
        and channel = 'push') <> 1
     or (select count(*) from private.event_reminder_jobs
         where event_id = '00000000-0000-4000-8000-00000000f301'
           and user_id = '00000000-0000-4000-8000-00000000f102') <> 1 then
    raise exception '참여자 미리 알림 픽스처가 설정/작업을 만들지 않았습니다';
  end if;
end;
$$;

-- 비활성화는 그룹 관리 RPC에서 event_members를 삭제한다. 복합 FK는 설정과 설정
-- 소유 작업을 연쇄 삭제해야 한다. 오래된 활성 의도가 남았다가 이후 재활성화로
-- 복원되어서는 안 된다.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select public.set_member_active(
  '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f102',
  false
);
reset role;
do $$
begin
  if exists (
      select 1 from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    ) then
    raise exception '참여자 제거가 일정 미리 알림 행을 연쇄 삭제하지 않았습니다';
  end if;
end;
$$;

-- 재활성화는 멤버십 상태만 바꾼다. 제거된 event_members 할당을 다시 만들거나
-- 미리 알림 의도를 조용히 되살려서는 안 된다.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select public.set_member_active(
  '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f102',
  true
);
reset role;
do $$
begin
  if exists (
      select 1 from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    ) then
    raise exception '참여자 재활성화가 삭제된 미리 알림 상태를 복원했습니다';
  end if;
end;
$$;

-- 참여자 할당을 명시적으로 다시 추가한 뒤 그룹 탈퇴도 같은 경로를 따른다. 탈퇴는
-- 할당을 제거하고 설정/작업을 연쇄 삭제한다. 소유자가 재활성화해도 어느 행도 복원하지 않는다.
insert into public.event_members (event_id, user_id)
values (
  '00000000-0000-4000-8000-00000000f301',
  '00000000-0000-4000-8000-00000000f102'
)
on conflict (event_id, user_id) do nothing;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f102', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f102","role":"authenticated"}', false);
select public.set_event_reminder(
  '00000000-0000-4000-8000-00000000f301', 'push', true, 900, 0::smallint,
  (select version from public.events where id = '00000000-0000-4000-8000-00000000f301'), 0
);
reset role;
set local role service_role;
select public.worker_prepare_event_reminder_jobs(
  '00000000-0000-4000-8000-00000000f301', '2026-03-09T00:00:00Z', 3
);
reset role;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f102', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f102","role":"authenticated"}', false);
select public.leave_group('00000000-0000-4000-8000-00000000f201');
reset role;
do $$
begin
  if exists (
      select 1 from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    ) then
    raise exception '그룹 탈퇴가 일정 미리 알림 행을 연쇄 삭제하지 않았습니다';
  end if;
end;
$$;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select public.set_member_active(
  '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f102',
  true
);
reset role;
do $$
begin
  if exists (
      select 1 from public.event_members
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    )
     or exists (
      select 1 from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f301'
        and user_id = '00000000-0000-4000-8000-00000000f102'
    ) then
    raise exception '그룹 탈퇴 뒤 재활성화가 미리 알림 상태를 복원했습니다';
  end if;
end;
$$;

-- 기존 일정 무결성 계약에서 일정 소프트 삭제는 종료 상태다. 따라서 미리 알림
-- 트리거는 절대 복원할 수 없는 의도를 보존하지 않고 묶음 전체 설정을 직접 제거한다.
-- setting_id FK가 모든 비공개 작업을 제거한다.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
select public.soft_delete_event_if_version(
  '00000000-0000-4000-8000-00000000f301',
  (select version from public.events where id = '00000000-0000-4000-8000-00000000f301')
);
reset role;
do $$
begin
  if not exists (
      select 1 from public.events
      where id = '00000000-0000-4000-8000-00000000f301'
        and deleted_at is not null
    )
     or exists (
      select 1 from public.event_reminder_settings
      where event_id = '00000000-0000-4000-8000-00000000f301'
    )
     or exists (
      select 1 from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f301'
    ) then
    raise exception '소프트 삭제된 일정이 미리 알림 상태를 유지했습니다';
  end if;
end;
$$;

-- 조정은 멱등적이며 반복 발생마다 작업 하나를 만든다.
set local role service_role;
select public.worker_prepare_event_reminder_jobs('00000000-0000-4000-8000-00000000f304', '2026-03-09T00:00:00Z', 3);
select public.worker_prepare_event_reminder_jobs('00000000-0000-4000-8000-00000000f304', '2026-03-09T00:00:00Z', 3);
create temporary table reminder_claim_response as
select public.worker_claim_event_reminder_jobs('00000000-0000-4000-8000-00000000f901'::uuid, 2, '2100-01-01T00:00:00Z', 300) as payload;
create temporary table reminder_claimed_jobs(id uuid primary key);
insert into reminder_claimed_jobs(id)
select (row->>'id')::uuid from reminder_claim_response, jsonb_array_elements(payload->'jobs') row;
reset role;
do $$
begin
  if (select count(*) from private.event_reminder_jobs where event_id = '00000000-0000-4000-8000-00000000f304') <> 2
     or (select count(*) from reminder_claimed_jobs) <> 2 then
    raise exception '반복 일정 작업의 중복 제거/가져오기가 예상대로 수행되지 않았습니다';
  end if;
end;
$$;
set local role service_role;
select public.worker_complete_event_reminder_job((select id from reminder_claimed_jobs order by id limit 1), '00000000-0000-4000-8000-00000000f901'::uuid, 'retryable', 'provider_timeout');
select public.worker_complete_event_reminder_job((select id from reminder_claimed_jobs order by id desc limit 1), '00000000-0000-4000-8000-00000000f901'::uuid, 'permanent', 'provider_rejected');
reset role;
create temporary table reminder_retry_job as select id from private.event_reminder_jobs where status = 'retry';
grant all on reminder_retry_job to service_role;
set local role service_role;
create temporary table reminder_retry_claim_response as
select public.worker_claim_event_reminder_jobs('00000000-0000-4000-8000-00000000f901'::uuid, 1, '2100-01-01T00:00:00Z', 300) as payload;
select public.worker_complete_event_reminder_job((select (row->>'id')::uuid from reminder_retry_claim_response, jsonb_array_elements(payload->'jobs') row limit 1), '00000000-0000-4000-8000-00000000f901'::uuid, 'permanent', 'adapter_unavailable');
reset role;
do $$
begin
  if (select count(*) from private.event_reminder_jobs where event_id = '00000000-0000-4000-8000-00000000f304' and status = 'dead_letter') <> 2 then
    raise exception '재시도/배달 실패 전환이 두 작업을 모두 종료하지 않았습니다';
  end if;
end;
$$;

-- 조정 작업자가 T1을 준비하는 동안 트리거가 같은 일정의 T2를 큐에 넣을 수 있다.
-- dirty 비트는 T1 완료 시 더 새로운 요청을 잃지 않고 T2를 다시 큐에 넣게 해야 하며,
-- 다음 가져오기가 이를 가져갈 수 있어야 한다.
reset role;
update private.event_reminder_reconcile_queue
set status = 'pending', attempts = 0, dirty = false,
    next_attempt_at = '2999-01-01T00:00:00Z',
    lease_owner = null, lease_until = null, completed_at = null,
    last_error_code = null
where event_id <> '00000000-0000-4000-8000-00000000f302';
insert into private.event_reminder_reconcile_queue(
  event_id, group_id, reason, status, attempts, dirty, next_attempt_at,
  lease_owner, lease_until, completed_at, last_error_code
) values (
  '00000000-0000-4000-8000-00000000f302',
  '00000000-0000-4000-8000-00000000f201',
  'event_changed', 'pending', 0, false, '2100-01-01T00:00:00Z',
  null, null, null, null
)
on conflict (event_id) do update set
  reason = excluded.reason, status = excluded.status, attempts = excluded.attempts,
  dirty = excluded.dirty, next_attempt_at = excluded.next_attempt_at,
  lease_owner = null, lease_until = null, completed_at = null,
  last_error_code = null;
set local role service_role;
create temporary table reminder_reconcile_race_claim as
select public.worker_claim_reconcile_requests(
  '00000000-0000-4000-8000-00000000f901'::uuid, 1,
  '2100-01-01T00:00:00Z', 300
) as payload;
reset role;
do $$
begin
  if (select payload->'requests'->0->>'event_id' from reminder_reconcile_race_claim)
      is distinct from '00000000-0000-4000-8000-00000000f302' then
    raise exception '조정 경합 픽스처가 대상 일정을 가져오지 않았습니다';
  end if;
end;
$$;
-- T1이 임대를 가져간 뒤 T2 일정/설정 트리거를 모의 실행한다.
select private.enqueue_event_reminder_reconcile(
  '00000000-0000-4000-8000-00000000f302', 'event_changed'
);
set local role service_role;
create temporary table reminder_reconcile_race_completion as
select public.worker_complete_reconcile_request(
  '00000000-0000-4000-8000-00000000f302',
  '00000000-0000-4000-8000-00000000f901'::uuid,
  'done'
) as payload;
reset role;
do $$
begin
  if (select payload->>'status' from reminder_reconcile_race_completion)
         is distinct from 'pending'
     or (select status from private.event_reminder_reconcile_queue
         where event_id = '00000000-0000-4000-8000-00000000f302')
         is distinct from 'pending'
     or (select attempts from private.event_reminder_reconcile_queue
         where event_id = '00000000-0000-4000-8000-00000000f302')
         is distinct from 0
     or (select dirty from private.event_reminder_reconcile_queue
         where event_id = '00000000-0000-4000-8000-00000000f302') is not false
     or exists (select 1 from private.event_reminder_reconcile_queue
                where event_id = '00000000-0000-4000-8000-00000000f302'
                  and (lease_owner is not null or lease_until is not null or completed_at is not null)) then
    raise exception 'dirty 조정 완료가 더 새로운 요청을 잃었습니다';
  end if;
end;
$$;
set local role service_role;
create temporary table reminder_reconcile_race_reclaim as
select public.worker_claim_reconcile_requests(
  '00000000-0000-4000-8000-00000000f902'::uuid, 1,
  '2100-01-02T00:00:00Z', 300
) as payload;
select public.worker_complete_reconcile_request(
  '00000000-0000-4000-8000-00000000f302',
  '00000000-0000-4000-8000-00000000f902'::uuid,
  'done'
);
reset role;
do $$
begin
  if (select payload->'requests'->0->>'event_id' from reminder_reconcile_race_reclaim)
      is distinct from '00000000-0000-4000-8000-00000000f302'
     or (select attempts from private.event_reminder_reconcile_queue
         where event_id = '00000000-0000-4000-8000-00000000f302')
         is distinct from 1
     or (select status from private.event_reminder_reconcile_queue
         where event_id = '00000000-0000-4000-8000-00000000f302')
         is distinct from 'done' then
    raise exception '다시 큐에 넣은 조정 요청을 다시 가져오지 않았습니다';
  end if;
end;
$$;

-- 여덟 번째 시도의 작업자 중단은 발생 fire_at 전에 임대가 만료되어도 종료 처리해야
-- 한다. 그렇지 않으면 attempts<8 다시 가져오기 보호가 처리 중 행을 영원히 남긴다.
set local role service_role;
select public.worker_prepare_event_reminder_jobs(
  '00000000-0000-4000-8000-00000000f302', '2026-03-09T00:00:00Z', 3
);
reset role;
insert into private.event_reminder_reconcile_queue(
  event_id, group_id, reason, status, attempts, next_attempt_at,
  lease_owner, lease_until, completed_at, last_error_code
) values (
  '00000000-0000-4000-8000-00000000f302',
  '00000000-0000-4000-8000-00000000f201',
  'event_changed', 'processing', 8, '2026-03-08T00:00:00Z',
  '00000000-0000-4000-8000-00000000f902'::uuid,
  '2026-03-08T00:00:00Z', null, null
)
on conflict (event_id) do update set
  reason = excluded.reason, status = excluded.status,
  attempts = excluded.attempts, next_attempt_at = excluded.next_attempt_at,
  lease_owner = excluded.lease_owner, lease_until = excluded.lease_until,
  completed_at = null, last_error_code = null;
with target as (
  select id
  from private.event_reminder_jobs
  where event_id = '00000000-0000-4000-8000-00000000f302'
    and status = 'pending'
  order by id
  limit 1
)
update private.event_reminder_jobs j
set status = 'processing', attempts = 8,
    lease_owner = '00000000-0000-4000-8000-00000000f902'::uuid,
    lease_until = '2026-03-08T00:00:00Z',
    last_error_code = null, sent_at = null, cancelled_at = null,
    dead_letter_at = null
from target
where j.id = target.id;
set local role service_role;
select public.worker_claim_reconcile_requests(
  '00000000-0000-4000-8000-00000000f903'::uuid, 10, '2026-03-09T00:00:00Z', 300
);
select public.worker_claim_event_reminder_jobs(
  '00000000-0000-4000-8000-00000000f903'::uuid, 10, '2026-03-09T00:00:00Z', 300
);
reset role;
do $$
begin
  if (select count(*) from private.event_reminder_reconcile_queue
      where event_id = '00000000-0000-4000-8000-00000000f302'
        and status = 'done' and attempts = 8
        and lease_owner is null and lease_until is null
        and last_error_code = 'retry_exhausted') <> 1 then
    raise exception '만료된 여덟 번째 시도 조정 임대를 종료 처리하지 않았습니다';
  end if;
  if (select count(*) from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f302'
        and status = 'dead_letter' and attempts = 8
        and lease_owner is null and lease_until is null
        and last_error_code = 'retry_exhausted') <> 1 then
    raise exception '만료된 여덟 번째 시도 작업 임대를 배달 실패 처리하지 않았습니다';
  end if;
end;
$$;

-- 계정 삭제는 이전 사전 검사 형태를 보존하면서 모든 미리 알림 행을 연쇄 삭제한다.
delete from auth.users where id = '00000000-0000-4000-8000-00000000f101'::uuid;
do $$
begin
  if exists (select 1 from public.groups where id = '00000000-0000-4000-8000-00000000f201')
     or exists (select 1 from public.events where group_id = '00000000-0000-4000-8000-00000000f201')
     or exists (select 1 from public.notification_preferences where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from public.event_reminder_settings where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from private.push_device_tokens where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from private.event_reminder_jobs where user_id = '00000000-0000-4000-8000-00000000f101') then
    raise exception '계정 삭제가 미리 알림 데이터를 연쇄 삭제하지 않았습니다';
  end if;
end;
$$;

rollback;
