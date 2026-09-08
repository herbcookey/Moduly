-- 기능 3: 사용자가 동의한 미리 알림과 서버 소유의 비공개 전송 큐다.
--
-- 이 마이그레이션은 의도적으로 기존 기능에 추가만 한다. 기존 일정/멤버/반복 행을
-- 다시 쓰지 않으며 이전 데이터에 미리 알림 행을 만들어 내지 않는다. 클라이언트
-- 쓰기는 아래 인증된 RPC를 거친다. 기기 Bearer 값, 큐 임대 및 조정 요청은 PostgREST
-- API 스키마 목록에 없는 스키마에 둔다. Edge 작업자는 이 마이그레이션 끝의 서비스
-- 역할 전용 래퍼를 사용한다. 제공자 자격 증명은 Edge 환경 비밀 값으로 유지하며
-- SQL이나 Flutter에 절대 나타내지 않는다.

begin;

create schema if not exists private;

-- `private`은 의도적으로 supabase/config.toml의 [api].schemas에 넣지 않는다. 이후
-- API 설정이 실수로 스키마를 추가해도 명시적인 ACL 경계를 유지한다. 마이그레이션
-- 역할은 계속 소유자이며 아래 SECURITY DEFINER 함수는 테이블을 읽을 수 있다.
revoke all on schema private from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    execute 'revoke all on schema private from service_role';
  end if;
end;
$$;

-- 행 형식을 사용하는 함수를 정의하기 전에 먼저 선언한다. 완전한 멱등 DDL(주석,
-- 인덱스, 정책 및 비공개 ACL)은 이 선언 뒤에 나온다. 선언을 여기에 두면
-- check_function_bodies에 의존하지 않고 부분 생성된 마이그레이션을 안전하게 재적용할 수 있다.
create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  local_enabled boolean not null default false,
  push_enabled boolean not null default false,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);
create table if not exists public.event_reminder_settings (
  id uuid primary key default extensions.gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  channel text not null check (channel in ('local', 'push')),
  enabled boolean not null default false,
  lead_seconds integer not null default 900 check (lead_seconds between 0 and 604800),
  all_day_days_before smallint not null default 0 check (all_day_days_before between 0 and 366),
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (user_id, event_id, channel)
);
create table if not exists private.push_device_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('apns', 'fcm')),
  platform text not null check (platform in ('ios', 'android')),
  environment text not null check (environment in ('sandbox', 'production')),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  token text not null check (pg_catalog.octet_length(token) between 1 and 4096),
  installation_hash text check (installation_hash is null or installation_hash ~ '^[0-9a-f]{64}$'),
  is_active boolean not null default true,
  last_seen_at timestamptz not null default pg_catalog.clock_timestamp(),
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (provider, token_hash),
  check ((is_active and revoked_at is null) or (not is_active and revoked_at is not null))
);
create table if not exists private.push_provider_capability (
  singleton boolean primary key default true check (singleton),
  provider text not null check (provider in ('none', 'apns', 'fcm')),
  enabled boolean not null default false,
  updated_at timestamptz not null default pg_catalog.clock_timestamp()
);
create table if not exists private.event_reminder_jobs (
  id uuid primary key default extensions.gen_random_uuid(),
  setting_id uuid not null references public.event_reminder_settings(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  occurrence_key text not null check (occurrence_key = 'single' or occurrence_key ~ '^o[0-9]{20}$'),
  fire_at timestamptz not null check (pg_catalog.isfinite(fire_at)),
  event_version integer not null check (event_version > 0),
  occurrence_version integer not null check (occurrence_version >= 0),
  setting_version integer not null check (setting_version > 0),
  status text not null default 'pending' check (status in ('pending','processing','retry','sent','cancelled','dead_letter')),
  attempts integer not null default 0 check (attempts between 0 and 8),
  -- 작업자가 현재 세대를 가져온 뒤 트리거/갱신이 들어오면 설정한다. 완료 처리는
  -- 행 잠금 아래에서 이 비트를 확인하고 이전 임대를 잘못 완료로 표시하는 대신
  -- 새로운 세대를 다시 큐에 넣는다.
  dirty boolean not null default false,
  next_attempt_at timestamptz not null check (pg_catalog.isfinite(next_attempt_at)),
  lease_owner uuid,
  lease_until timestamptz,
  sent_at timestamptz,
  cancelled_at timestamptz,
  dead_letter_at timestamptz,
  cancel_reason text check (cancel_reason is null or cancel_reason in (
    'event_changed','event_deleted','group_archived','membership_removed',
    'setting_disabled','rescheduled','provider_unconfigured','device_revoked'
  )),
  last_error_code text check (
    last_error_code is null or last_error_code ~ '^[a-z0-9_.:-]{1,64}$'
  ),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  check ((status = 'processing' and lease_owner is not null and lease_until is not null) or (status <> 'processing' and lease_owner is null and lease_until is null)),
  check ((status = 'sent') = (sent_at is not null)),
  check ((status = 'cancelled') = (cancelled_at is not null)),
  check ((status = 'dead_letter') = (dead_letter_at is not null)),
  check (status not in ('sent','cancelled','dead_letter') or
    (case when sent_at is not null then 1 else 0 end)
      + (case when cancelled_at is not null then 1 else 0 end)
      + (case when dead_letter_at is not null then 1 else 0 end) = 1)
);
create table if not exists private.event_reminder_reconcile_queue (
  event_id uuid primary key references public.events(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  reason text not null check (reason in ('event_changed','setting_changed','participant_changed','device_registered','provider_enabled')),
  status text not null default 'pending' check (status in ('pending','processing','done')),
  attempts integer not null default 0 check (attempts between 0 and 8),
  next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  lease_owner uuid,
  lease_until timestamptz,
  requested_at timestamptz not null default pg_catalog.clock_timestamp(),
  completed_at timestamptz,
  last_error_code text check (
    last_error_code is null or last_error_code ~ '^[a-z0-9_.:-]{1,64}$'
  ),
  check ((status = 'processing' and lease_owner is not null and lease_until is not null) or (status <> 'processing' and lease_owner is null and lease_until is null)),
  check ((status = 'done') = (completed_at is not null))
);

-- 재적용 시 부분 적용되었거나 이전 사본이 만든 큐 테이블도 업그레이드해야 한다.
-- 기본값/기존 데이터 채우기는 상태, 임대 또는 시도 이력을 바꾸지 않고 기존 행의
-- 처리 가능 상태를 유지한다.
alter table private.event_reminder_reconcile_queue
  add column if not exists dirty boolean;
update private.event_reminder_reconcile_queue
set dirty = false
where dirty is null;
alter table private.event_reminder_reconcile_queue
  alter column dirty set default false,
  alter column dirty set not null;

create or replace function public.get_notification_preferences()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_preferences public.notification_preferences;
  v_push_capability text;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  select p.* into v_preferences
  from public.notification_preferences p
  where p.user_id = v_actor;
  select case when c.enabled and c.provider <> 'none'
              then 'push_configured' else 'push_unconfigured' end
    into v_push_capability
  from private.push_provider_capability c
  where c.singleton;
  if v_push_capability is null then
    v_push_capability := 'push_unconfigured';
  end if;
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', false,
    'version', coalesce(v_preferences.version, 0),
    'local_enabled', coalesce(v_preferences.local_enabled, false),
    'push_enabled', coalesce(v_preferences.push_enabled, false),
    'capability_local', case when coalesce(v_preferences.local_enabled, false)
      then 'client_local_scheduler' else 'disabled' end,
    'capability_push', case when coalesce(v_preferences.push_enabled, false)
      then v_push_capability else 'disabled' end
  );
end;
$$;

create or replace function public.set_notification_preferences(
  p_local_enabled boolean,
  p_push_enabled boolean,
  p_expected_version integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_preferences public.notification_preferences;
  v_changed boolean := false;
  v_version integer;
  v_push_capability text;
  v_cancelled integer := 0;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_local_enabled is null or p_push_enabled is null
     or p_expected_version is null or p_expected_version < 0 then
    raise exception using errcode = '22023', message = 'notification preference values are invalid';
  end if;

  -- 계정 삭제도 Auth 행을 지우기 전에 같은 KEY SHARE 잠금을 얻는다. 전체 upsert
  -- 동안 호출자 행도 유지한다.
  perform 1 from auth.users u where u.id = v_actor for key share;
  if not found then
    raise exception using errcode = '42501', message = 'account is unavailable';
  end if;

  select p.* into v_preferences
  from public.notification_preferences p
  where p.user_id = v_actor
  for update;
  if not found then
    if p_expected_version <> 0 then
      raise exception using errcode = '40001', message = 'notification preferences changed';
    end if;
    if p_push_enabled then
      select case when c.enabled and c.provider <> 'none'
                  then 'push_configured' else 'push_unconfigured' end
        into v_push_capability
      from private.push_provider_capability c
      where c.singleton;
      if coalesce(v_push_capability, 'push_unconfigured') <> 'push_configured' then
        raise exception using errcode = '55000', message = 'push is not configured';
      end if;
    end if;
    insert into public.notification_preferences (
      user_id, local_enabled, push_enabled, version
    ) values (v_actor, p_local_enabled, p_push_enabled, 1)
    returning * into v_preferences;
    v_changed := true;
  else
    if v_preferences.version <> p_expected_version then
      raise exception using errcode = '40001', message = 'notification preferences changed';
    end if;
    if p_push_enabled and not v_preferences.push_enabled then
      select case when c.enabled and c.provider <> 'none'
                  then 'push_configured' else 'push_unconfigured' end
        into v_push_capability
      from private.push_provider_capability c
      where c.singleton;
      if coalesce(v_push_capability, 'push_unconfigured') <> 'push_configured' then
        raise exception using errcode = '55000', message = 'push is not configured';
      end if;
    end if;
    if v_preferences.local_enabled is distinct from p_local_enabled
       or v_preferences.push_enabled is distinct from p_push_enabled then
      update public.notification_preferences p
      set local_enabled = p_local_enabled,
          push_enabled = p_push_enabled,
          version = p.version + 1,
          updated_at = pg_catalog.clock_timestamp()
      where p.user_id = v_actor
      returning * into v_preferences;
      v_changed := true;
    end if;
  end if;

  if v_changed and not v_preferences.push_enabled then
    v_cancelled := private.cancel_user_event_reminder_jobs(v_actor, 'setting_disabled');
  end if;
  select case when c.enabled and c.provider <> 'none'
              then 'push_configured' else 'push_unconfigured' end
    into v_push_capability
  from private.push_provider_capability c where c.singleton;
  if v_push_capability is null then v_push_capability := 'push_unconfigured'; end if;
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', v_changed,
    'version', v_preferences.version,
    'local_enabled', v_preferences.local_enabled,
    'push_enabled', v_preferences.push_enabled,
    'cancelled_jobs', v_cancelled,
    'capability_local', case when v_preferences.local_enabled
      then 'client_local_scheduler' else 'disabled' end,
    'capability_push', case when v_preferences.push_enabled
      then v_push_capability else 'disabled' end
  );
end;
$$;

create or replace function public.get_event_reminder(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_push_capability text;
  v_settings jsonb;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  select e.* into v_event
  from public.events e
  where e.id = p_event_id;
  if not found or v_event.deleted_at is not null then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  if not exists (
    select 1
    from public.groups g
    join public.memberships m on m.group_id = g.id and m.user_id = v_actor
      and m.is_active and m.removed_at is null
    join public.event_members em on em.event_id = p_event_id and em.user_id = v_actor
    where g.id = v_event.group_id and g.deleted_at is null
  ) then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', s.id,
        'channel', s.channel,
        'enabled', s.enabled,
        'lead_seconds', s.lead_seconds,
        'all_day_days_before', s.all_day_days_before,
        'all_day_local_time', '09:00:00',
        'version', s.version,
        'created_at', s.created_at,
        'updated_at', s.updated_at
      ) order by s.channel
    ),
    '[]'::jsonb
  ) into v_settings
  from public.event_reminder_settings s
  where s.event_id = p_event_id and s.user_id = v_actor;
  select case when c.enabled and c.provider <> 'none'
              then 'push_configured' else 'push_unconfigured' end
    into v_push_capability
  from private.push_provider_capability c where c.singleton;
  if v_push_capability is null then v_push_capability := 'push_unconfigured'; end if;
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', false,
    'event_id', p_event_id,
    'event_version', v_event.version,
    'settings', v_settings,
    'capabilities', pg_catalog.jsonb_build_object(
      'local', case when coalesce((select p.local_enabled from public.notification_preferences p where p.user_id = v_actor), false)
        then 'client_local_scheduler' else 'disabled' end,
      'push', case when coalesce((select p.push_enabled from public.notification_preferences p where p.user_id = v_actor), false)
        then v_push_capability else 'disabled' end
    )
  );
end;
$$;

-- 이전 UI 코드는 이 조회를 list_event_reminders라고 불렀다. 버전이 섞인 클라이언트가
-- 테이블 권한 없이 전환할 수 있도록 추가 별칭을 유지한다.
create or replace function public.list_event_reminders(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return public.get_event_reminder(p_event_id);
end;
$$;

create or replace function public.set_event_reminder(
  p_event_id uuid,
  p_channel text,
  p_enabled boolean,
  p_lead_seconds integer,
  p_all_day_days_before smallint,
  p_expected_event_version integer,
  p_expected_setting_version integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_group public.groups;
  v_setting public.event_reminder_settings;
  v_preferences public.notification_preferences;
  v_push_capability text;
  v_changed boolean := false;
  v_queued integer := 0;
  v_cancelled integer := 0;
  v_version integer;
  v_capability text;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_event_id is null or p_channel is null
     or p_channel not in ('local', 'push') or p_enabled is null
     or p_lead_seconds is null or p_lead_seconds not between 0 and 604800
     or p_all_day_days_before is null
     or p_all_day_days_before not between 0 and 366
     or p_expected_event_version is null or p_expected_event_version < 1
     or p_expected_setting_version is null or p_expected_setting_version < 0 then
    raise exception using errcode = '22023', message = 'event reminder values are invalid';
  end if;

  perform 1 from auth.users u where u.id = v_actor for key share;
  if not found then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  select g.* into v_group
  from public.groups g where g.id = v_event.group_id for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  select e.* into v_event from public.events e where e.id = p_event_id for update;
  if not found or v_event.deleted_at is not null
     or v_event.version <> p_expected_event_version then
    raise exception using errcode = '40001', message = 'event was changed or deleted';
  end if;
  if not exists (
    select 1
    from public.memberships m
    join public.event_members em on em.event_id = p_event_id and em.user_id = v_actor
    where m.group_id = v_event.group_id and m.user_id = v_actor
      and m.is_active and m.removed_at is null
  ) then
    raise exception using errcode = '42501', message = 'event is unavailable';
  end if;
  select p.* into v_preferences
  from public.notification_preferences p where p.user_id = v_actor;
  select s.* into v_setting
  from public.event_reminder_settings s
  where s.event_id = p_event_id and s.user_id = v_actor and s.channel = p_channel
  for update;
  if not found then
    if p_expected_setting_version <> 0 then
      raise exception using errcode = '40001', message = 'event reminder was changed';
    end if;
    insert into public.event_reminder_settings (
      event_id, user_id, channel, enabled, lead_seconds, all_day_days_before, version
    ) values (
      p_event_id, v_actor, p_channel, p_enabled, p_lead_seconds,
      p_all_day_days_before, 1
    ) returning * into v_setting;
    v_changed := true;
  else
    if v_setting.version <> p_expected_setting_version then
      raise exception using errcode = '40001', message = 'event reminder was changed';
    end if;
    if v_setting.enabled is distinct from p_enabled
       or v_setting.lead_seconds is distinct from p_lead_seconds
       or v_setting.all_day_days_before is distinct from p_all_day_days_before then
      update public.event_reminder_settings s
      set enabled = p_enabled,
          lead_seconds = p_lead_seconds,
          all_day_days_before = p_all_day_days_before,
          version = s.version + 1,
          updated_at = pg_catalog.clock_timestamp()
      where s.id = v_setting.id
      returning * into v_setting;
      v_changed := true;
    end if;
  end if;

  if v_changed and (not v_setting.enabled or p_channel = 'push') then
    -- 작업은 푸시 전용이다. 설정이 바뀌면 새 setting_version을 받으므로 전송 완료/
    -- 배달 실패 응답을 건드리지 않고 오래된 행을 취소한다.
    v_cancelled := private.cancel_event_reminder_jobs(
      p_event_id, case when v_setting.enabled then 'rescheduled' else 'setting_disabled' end,
      null, v_actor
    );
  end if;
  if v_changed then
    perform private.enqueue_event_reminder_reconcile(p_event_id, 'setting_changed');
  end if;
  select case when c.enabled and c.provider <> 'none'
              then 'push_configured' else 'push_unconfigured' end
    into v_push_capability
  from private.push_provider_capability c where c.singleton;
  if v_push_capability is null then v_push_capability := 'push_unconfigured'; end if;
  v_capability := case
    when p_channel = 'local' then case
      when coalesce(v_preferences.local_enabled, false) and p_enabled
        then 'client_local_scheduler' else 'disabled' end
    else case
      when not p_enabled then 'disabled'
      when not coalesce(v_preferences.push_enabled, false) then 'disabled'
      else v_push_capability end
  end;
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', v_changed,
    'event_id', p_event_id,
    'channel', p_channel,
    'enabled', v_setting.enabled,
    'lead_seconds', v_setting.lead_seconds,
    'all_day_days_before', v_setting.all_day_days_before,
    'all_day_local_time', '09:00:00',
    'setting_version', v_setting.version,
    'event_version', v_event.version,
    'queued_jobs', v_queued,
    'cancelled_jobs', v_cancelled,
    'skipped_past', 0,
    'capability', v_capability
  );
end;
$$;

create or replace function private.enqueue_event_reminder_reconcile(
  p_event_id uuid,
  p_reason text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
begin
  if p_event_id is null or p_reason is null
     or p_reason not in (
       'event_changed', 'setting_changed', 'participant_changed',
       'device_registered', 'provider_enabled'
     ) then
    raise exception using errcode = '22023', message = 'invalid reconcile request';
  end if;
  select e.group_id into v_group_id
  from public.events e
  where e.id = p_event_id;
  if v_group_id is null then
    return;
  end if;
  insert into private.event_reminder_reconcile_queue (
    event_id, group_id, reason, status, attempts, next_attempt_at,
    lease_owner, lease_until, completed_at, last_error_code, requested_at
  ) values (
    p_event_id, v_group_id, p_reason, 'pending', 0,
    pg_catalog.clock_timestamp(), null, null, null, null,
    pg_catalog.clock_timestamp()
  )
  on conflict (event_id) do update set
    group_id = excluded.group_id,
    reason = excluded.reason,
    status = case
      when private.event_reminder_reconcile_queue.status = 'processing'
        then private.event_reminder_reconcile_queue.status
      else 'pending'
    end,
    dirty = case
      when private.event_reminder_reconcile_queue.status = 'processing'
        then true
      else false
    end,
    next_attempt_at = case
      when private.event_reminder_reconcile_queue.status = 'processing'
        then private.event_reminder_reconcile_queue.next_attempt_at
      else excluded.next_attempt_at
    end,
    lease_owner = case
      when private.event_reminder_reconcile_queue.status = 'processing'
        then private.event_reminder_reconcile_queue.lease_owner
      else null
    end,
    lease_until = case
      when private.event_reminder_reconcile_queue.status = 'processing'
        then private.event_reminder_reconcile_queue.lease_until
      else null
    end,
    completed_at = null,
    last_error_code = null,
    requested_at = excluded.requested_at;
end;
$$;

create or replace function private.cancel_event_reminder_jobs(
  p_event_id uuid,
  p_reason text,
  p_occurrence_key text default null,
  p_user_id uuid default null
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_reason is null or p_reason not in (
    'event_changed', 'event_deleted', 'group_archived', 'membership_removed',
    'setting_disabled', 'rescheduled', 'provider_unconfigured', 'device_revoked'
  ) then
    raise exception using errcode = '22023', message = 'invalid cancellation reason';
  end if;
  if p_occurrence_key is not null
     and p_occurrence_key <> 'single'
     and p_occurrence_key !~ '^o[0-9]{20}$' then
    raise exception using errcode = '22023', message = 'occurrence key is invalid';
  end if;
  with locked as (
    select j.id
    from private.event_reminder_jobs j
    where (p_event_id is null or j.event_id = p_event_id)
      and (p_user_id is null or j.user_id = p_user_id)
      and (p_occurrence_key is null or j.occurrence_key = p_occurrence_key)
      and j.status in ('pending', 'processing', 'retry')
    order by j.id
    for update
  )
  update private.event_reminder_jobs j
  set status = 'cancelled',
      cancelled_at = pg_catalog.clock_timestamp(),
      cancel_reason = p_reason,
      lease_owner = null,
      lease_until = null,
      updated_at = pg_catalog.clock_timestamp()
  from locked
  where j.id = locked.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function private.cancel_group_event_reminder_jobs(
  p_group_id uuid,
  p_reason text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_group_id is null or p_reason not in ('group_archived', 'membership_removed') then
    raise exception using errcode = '22023', message = 'invalid group cancellation';
  end if;
  with locked as (
    select j.id
    from private.event_reminder_jobs j
    where j.group_id = p_group_id
      and j.status in ('pending', 'processing', 'retry')
    order by j.id
    for update
  )
  update private.event_reminder_jobs j
  set status = 'cancelled', cancelled_at = pg_catalog.clock_timestamp(),
      cancel_reason = p_reason, lease_owner = null, lease_until = null,
      updated_at = pg_catalog.clock_timestamp()
  from locked where j.id = locked.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function private.cancel_user_event_reminder_jobs(
  p_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return private.cancel_event_reminder_jobs(null, p_reason, null, p_user_id);
end;
$$;

-- 멤버십 수명 주기 변경은 그룹 범위다. 사용자는 여러 그룹에 속할 수 있으므로 한
-- 그룹 탈퇴가 관계없는 그룹의 미리 알림을 취소해서는 안 된다. 이 도우미는 일정
-- 전체 취소 경로와 같은 종료 상태 및 결정적 잠금 의미를 유지하면서 트리거를 영향
-- 받은 그룹/사용자 쌍으로 제한한다.
create or replace function private.cancel_group_user_event_reminder_jobs(
  p_group_id uuid,
  p_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_group_id is null or p_user_id is null
     or p_reason not in ('membership_removed', 'group_archived') then
    raise exception using errcode = '22023', message = 'invalid group user cancellation';
  end if;
  with locked as (
    select j.id
    from private.event_reminder_jobs j
    where j.group_id = p_group_id
      and j.user_id = p_user_id
      and j.status in ('pending', 'processing', 'retry')
    order by j.id
    for update
  )
  update private.event_reminder_jobs j
  set status = 'cancelled',
      cancelled_at = pg_catalog.clock_timestamp(),
      cancel_reason = p_reason,
      lease_owner = null,
      lease_until = null,
      updated_at = pg_catalog.clock_timestamp()
  from locked
  where j.id = locked.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function private.enqueue_user_event_reminder_reconcile(
  p_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_user_id is null or p_reason not in ('device_registered', 'provider_enabled') then
    raise exception using errcode = '22023', message = 'invalid user reconcile request';
  end if;
  insert into private.event_reminder_reconcile_queue (event_id, group_id, reason)
  select e.id, e.group_id, p_reason
  from public.events e
  join public.event_reminder_settings s on s.event_id = e.id
    and s.user_id = p_user_id and s.channel = 'push' and s.enabled
  join public.event_members em on em.event_id = e.id and em.user_id = p_user_id
  join public.memberships m on m.group_id = e.group_id and m.user_id = p_user_id
    and m.is_active and m.removed_at is null
  join public.groups g on g.id = e.group_id and g.deleted_at is null
  where e.deleted_at is null
  on conflict (event_id) do update set
    reason = excluded.reason,
    status = case when private.event_reminder_reconcile_queue.status = 'processing'
      then private.event_reminder_reconcile_queue.status else 'pending' end,
    next_attempt_at = case when private.event_reminder_reconcile_queue.status = 'processing'
      then private.event_reminder_reconcile_queue.next_attempt_at
      else pg_catalog.clock_timestamp() end,
    completed_at = null,
    requested_at = pg_catalog.clock_timestamp();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 계정 전체 스위치는 일정 행과 별개다. 행이 없으면 동의하지 않은 상태를 뜻하며,
-- 이전 애플리케이션 동작을 보존하고 기존 데이터 채우기에서 모든 계정에 행을 만들지 않는다.
create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  local_enabled boolean not null default false,
  push_enabled boolean not null default false,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

comment on table public.notification_preferences is
  '계정 전체 동의 스위치다. 행이 없으면 두 스위치가 모두 false인 것과 같다.';

create table if not exists public.event_reminder_settings (
  id uuid primary key default extensions.gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  channel text not null check (channel in ('local', 'push')),
  enabled boolean not null default false,
  -- 시간 지정 일정은 경과 UTC 초를 사용한다. 종일 일정은 all_day_days_before
  -- 달력 날짜와 기능 3 계약에 명시된 일정 현지 고정 벽시계 시각 09:00을 사용한다.
  lead_seconds integer not null default 900
    check (lead_seconds between 0 and 604800),
  all_day_days_before smallint not null default 0
    check (all_day_days_before between 0 and 366),
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (user_id, event_id, channel)
);

-- 미리 알림 의도는 현재 일정 참여자에게만 유효하다. 이전의 부분/초기 설치는 멤버십
-- 정리 뒤에도 설정을 남겼을 수 있으므로 강제 FK를 추가하기 전에 해당 고아 행과
-- 종료되어 소프트 삭제된 일정의 모든 행을 정리한다. 설정을 삭제하면 비공개 전송
-- 작업이 연쇄 삭제되며 유효한 참여자 행은 건드리지 않는다. 이름 있는 제약과 검증은
-- 중단된 배포가 이미 NOT VALID로 추가했어도 재적용을 안전하게 만든다.
delete from public.event_reminder_settings s
where not exists (
  select 1
  from public.event_members em
  where em.event_id = s.event_id
    and em.user_id = s.user_id
)
or exists (
  select 1
  from public.events e
  where e.id = s.event_id
    and e.deleted_at is not null
);

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.event_reminder_settings'::pg_catalog.regclass
      and c.conname = 'event_reminder_settings_event_member_fk'
  ) then
    alter table public.event_reminder_settings
      add constraint event_reminder_settings_event_member_fk
      foreign key (event_id, user_id)
      references public.event_members(event_id, user_id)
      on delete cascade;
  end if;
end;
$$;

-- 이전의 부분 사본이 FK를 NOT VALID로 설치했을 수 있다. 고아 행 정리 뒤에 검증하여
-- 이후 모든 참여자 삭제가 신규 설치와 같은 연쇄 의미를 갖게 한다.
alter table public.event_reminder_settings
  validate constraint event_reminder_settings_event_member_fk;

comment on table public.event_reminder_settings is
  '묶음 전체에 적용하는 사용자별 미리 알림 의도다. 발생 식별자는 전송 작업에만 속한다.';
comment on column public.event_reminder_settings.lead_seconds is
  '시간 지정 발생의 UTC 경과 기준 사전 알림 시간이다. 종일 발생에는 사용하지 않는다.';
comment on column public.event_reminder_settings.all_day_days_before is
  '유효 IANA 시간대의 09:00에 알리는 종일 발생의 현지 날짜 기준 사전 일수다. UI 기본값은 0/1/7이며 서버는 명시적 장기 정책에 0..366을 허용한다.';

create index if not exists event_reminder_settings_user_event_idx
  on public.event_reminder_settings (user_id, event_id, channel);
create index if not exists event_reminder_settings_enabled_idx
  on public.event_reminder_settings (event_id, user_id, channel)
  where enabled;

alter table public.notification_preferences enable row level security;
alter table public.event_reminder_settings enable row level security;

drop policy if exists notification_preferences_select on public.notification_preferences;
create policy notification_preferences_select
on public.notification_preferences
for select to authenticated
using ((select auth.uid()) = user_id);
drop policy if exists notification_preferences_write_deny on public.notification_preferences;
create policy notification_preferences_write_deny
on public.notification_preferences
for all to authenticated
using (false)
with check (false);

drop policy if exists event_reminder_settings_select on public.event_reminder_settings;
create policy event_reminder_settings_select
on public.event_reminder_settings
for select to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.events e
    join public.groups g on g.id = e.group_id
    join public.event_members em on em.event_id = e.id
      and em.user_id = event_reminder_settings.user_id
    join public.memberships m on m.group_id = e.group_id
      and m.user_id = event_reminder_settings.user_id
      and m.is_active
      and m.removed_at is null
    where e.id = event_reminder_settings.event_id
      and e.deleted_at is null
      and g.deleted_at is null
  )
);
drop policy if exists event_reminder_settings_write_deny on public.event_reminder_settings;
create policy event_reminder_settings_write_deny
on public.event_reminder_settings
for all to authenticated
using (false)
with check (false);

revoke all on table public.notification_preferences from public, anon, authenticated;
revoke all on table public.event_reminder_settings from public, anon, authenticated;

-- 비공개 기기 값은 서버 측 페이로드 로더만 읽는다. 토큰 해시는 실수로 중복 등록하는
-- 것을 막으며 원본 Bearer 값은 공개 열로 복사하거나 클라이언트 RPC로 반환하지 않는다.
create table if not exists private.push_device_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('apns', 'fcm')),
  platform text not null check (platform in ('ios', 'android')),
  environment text not null check (environment in ('sandbox', 'production')),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  token text not null check (pg_catalog.octet_length(token) between 1 and 4096),
  installation_hash text check (
    installation_hash is null or installation_hash ~ '^[0-9a-f]{64}$'
  ),
  is_active boolean not null default true,
  last_seen_at timestamptz not null default pg_catalog.clock_timestamp(),
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (provider, token_hash),
  check ((is_active and revoked_at is null) or (not is_active and revoked_at is not null))
);

comment on table private.push_device_tokens is
  '서버 비공개 푸시 Bearer 저장소다. 원본 토큰은 PostgREST, RLS, Realtime 또는 클라이언트 응답을 통해 절대 노출하지 않는다.';

create index if not exists push_device_tokens_user_active_idx
  on private.push_device_tokens (user_id, provider, last_seen_at desc)
  where is_active;

create table if not exists private.push_provider_capability (
  singleton boolean primary key default true check (singleton),
  provider text not null check (provider in ('none', 'apns', 'fcm')),
  enabled boolean not null default false,
  updated_at timestamptz not null default pg_catalog.clock_timestamp()
);
insert into private.push_provider_capability(singleton, provider, enabled)
values (true, 'none', false)
on conflict (singleton) do nothing;

comment on table private.push_provider_capability is
  '기능 스위치 전용이다. 제공자 자격 증명은 Edge 비밀 값이며 여기에 저장하지 않는다.';

create table if not exists private.event_reminder_jobs (
  id uuid primary key default extensions.gen_random_uuid(),
  setting_id uuid not null references public.event_reminder_settings(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  occurrence_key text not null check (
    occurrence_key = 'single' or occurrence_key ~ '^o[0-9]{20}$'
  ),
  fire_at timestamptz not null check (pg_catalog.isfinite(fire_at)),
  event_version integer not null check (event_version > 0),
  occurrence_version integer not null check (occurrence_version >= 0),
  setting_version integer not null check (setting_version > 0),
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'retry', 'sent', 'cancelled', 'dead_letter')
  ),
  attempts integer not null default 0 check (attempts between 0 and 8),
  next_attempt_at timestamptz not null check (pg_catalog.isfinite(next_attempt_at)),
  lease_owner uuid,
  lease_until timestamptz,
  sent_at timestamptz,
  cancelled_at timestamptz,
  dead_letter_at timestamptz,
  cancel_reason text check (cancel_reason is null or cancel_reason in (
    'event_changed', 'event_deleted', 'group_archived', 'membership_removed',
    'setting_disabled', 'rescheduled', 'provider_unconfigured', 'device_revoked'
  )),
  last_error_code text check (
    last_error_code is null or last_error_code ~ '^[a-z0-9_.:-]{1,64}$'
  ),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  -- 리비전은 일정/발생/설정의 세 값이다. 고유 키에 이를 포함하면 재시도와 작업자
  -- 중단이 논리적 전송 하나에 두 번째 행을 만들 수 없고, 변경된 일정은 새 리비전을 받는다.
  check (
    (status = 'processing' and lease_owner is not null and lease_until is not null)
    or (status <> 'processing' and lease_owner is null and lease_until is null)
  ),
  check ((status = 'sent') = (sent_at is not null)),
  check ((status = 'cancelled') = (cancelled_at is not null)),
  check ((status = 'dead_letter') = (dead_letter_at is not null)),
  check (status not in ('sent', 'cancelled', 'dead_letter')
         or (case when sent_at is not null then 1 else 0 end)
            + (case when cancelled_at is not null then 1 else 0 end)
            + (case when dead_letter_at is not null then 1 else 0 end) = 1)
);

-- 대기/처리/재시도 작업과 성공적으로 전송한 리비전은 중복 제거에 참여한다. 종료된
-- 취소/배달 실패 응답은 변경 불가 이력으로 유지한다. 이후 멤버십/기기/제공자를
-- 재활성화하면 해당 응답을 되살리지 않고 같은 발생에 새 대기 리비전을 만들 수 있다.
create unique index if not exists event_reminder_jobs_active_revision_idx
  on private.event_reminder_jobs (
    setting_id, event_id, user_id, occurrence_key,
    event_version, occurrence_version, setting_version
  ) where status in ('pending', 'processing', 'retry', 'sent');

comment on table private.event_reminder_jobs is
  '최소 한 번 방식으로 처리하는 비공개 전송 큐다. occurrence_key는 발생별 유일한 식별자이며 id는 제공자 멱등성 키다.';

create index if not exists event_reminder_jobs_due_idx
  on private.event_reminder_jobs (next_attempt_at, fire_at, id)
  where status in ('pending', 'retry');
create index if not exists event_reminder_jobs_lease_idx
  on private.event_reminder_jobs (lease_until, id)
  where status = 'processing';
create index if not exists event_reminder_jobs_event_idx
  on private.event_reminder_jobs (event_id, status, occurrence_key);
create index if not exists event_reminder_jobs_group_user_idx
  on private.event_reminder_jobs (group_id, user_id, status);

-- 트리거가 수행하는 작업은 범위를 제한한 큐 삽입뿐이다. 반복 확장은 일정/멤버
-- 쓰기가 상위 잠금을 유지하는 동안이 아니라 작업자에서 수행한다.
create table if not exists private.event_reminder_reconcile_queue (
  event_id uuid primary key references public.events(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  reason text not null check (reason in (
    'event_changed', 'setting_changed', 'participant_changed', 'device_registered',
    'provider_enabled'
  )),
  status text not null default 'pending' check (status in ('pending', 'processing', 'done')),
  attempts integer not null default 0 check (attempts between 0 and 8),
  next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  lease_owner uuid,
  lease_until timestamptz,
  requested_at timestamptz not null default pg_catalog.clock_timestamp(),
  completed_at timestamptz,
  last_error_code text check (
    last_error_code is null or last_error_code ~ '^[a-z0-9_.:-]{1,64}$'
  ),
  check (
    (status = 'processing' and lease_owner is not null and lease_until is not null)
    or (status <> 'processing' and lease_owner is null and lease_until is null)
  ),
  check ((status = 'done') = (completed_at is not null))
);

create index if not exists event_reminder_reconcile_due_idx
  on private.event_reminder_reconcile_queue (next_attempt_at, event_id)
  where status in ('pending', 'processing');

alter table private.push_device_tokens enable row level security;
alter table private.push_provider_capability enable row level security;
alter table private.event_reminder_jobs enable row level security;
alter table private.event_reminder_reconcile_queue enable row level security;
-- 어떤 비공개 정책도 의도적으로 허용적이지 않다. API 역할에는 스키마나 테이블
-- 권한이 없으며 소유자 전용 SECURITY DEFINER 함수가 유일한 경로다.
revoke all on table private.push_device_tokens from public, anon, authenticated;
revoke all on table private.push_provider_capability from public, anon, authenticated;
revoke all on table private.event_reminder_jobs from public, anon, authenticated;
revoke all on table private.event_reminder_reconcile_queue from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    execute 'revoke all on table private.push_device_tokens from service_role';
    execute 'revoke all on table private.push_provider_capability from service_role';
    execute 'revoke all on table private.event_reminder_jobs from service_role';
    execute 'revoke all on table private.event_reminder_reconcile_queue from service_role';
  end if;
end;
$$;

-- lib/core/timezone_utils.dart와 정확히 같은 방식으로 현지 타임스탬프를 확인한다.
-- 인접 오프셋을 열거하고 정확히 왕복되는 값을 유지하며 중복 시각에는 가장 늦은
-- UTC 시각을 선택한다. 정확히 왕복되는 값이 없는 누락 시각에만 PostgreSQL 내장
-- 변환을 사용하며, 이때 문서화된 순방향 해석이 원하는 정책이다.
create or replace function private.wall_time_to_instant(
  p_local timestamp without time zone,
  p_timezone text
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_naive timestamptz;
  v_probe timestamptz;
  v_candidate timestamptz;
  v_best timestamptz;
  v_offset bigint;
  v_offsets bigint[] := '{}'::bigint[];
  v_hour integer;
begin
  if p_local is null or p_timezone is null
     or not exists (
       select 1 from pg_catalog.pg_timezone_names t where t.name = p_timezone
     ) then
    raise exception using errcode = '22023', message = 'invalid timezone or local time';
  end if;
  v_naive := p_local at time zone 'UTC';
  for v_hour in -48..48 loop
    v_probe := v_naive + v_hour * interval '1 hour';
    v_offset := extract(epoch from (
      ((v_probe at time zone p_timezone) at time zone 'UTC') - v_probe
    ))::bigint;
    if not (v_offset = any(v_offsets)) then
      v_offsets := pg_catalog.array_append(v_offsets, v_offset);
    end if;
  end loop;
  for v_offset in select value from pg_catalog.unnest(v_offsets) as u(value) loop
    v_candidate := v_naive - v_offset * interval '1 second';
    if (v_candidate at time zone p_timezone) = p_local
       and (v_best is null or v_candidate > v_best) then
      v_best := v_candidate;
    end if;
  end loop;
  if v_best is not null then
    return v_best;
  end if;
  return p_local at time zone p_timezone;
end;
$$;

comment on function private.wall_time_to_instant(timestamp without time zone, text) is
  '미리 알림용 현지 시각 변환이다. 봄 누락 시각은 앞으로 이동하고 가을 중복 시각은 가장 늦은 UTC 시각을 선택한다.';

create or replace function private.reminder_fire_at(
  p_starts_at timestamptz,
  p_is_all_day boolean,
  p_all_day_start date,
  p_timezone text,
  p_lead_seconds integer,
  p_all_day_days_before smallint
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_starts_at is null or p_timezone is null
     or not pg_catalog.isfinite(p_starts_at)
     or p_lead_seconds is null or p_lead_seconds not between 0 and 604800
     or p_all_day_days_before is null or p_all_day_days_before not between 0 and 366 then
    raise exception using errcode = '22023', message = 'invalid reminder timing';
  end if;
  if p_is_all_day then
    if p_all_day_start is null then
      raise exception using errcode = '22023', message = 'all-day reminder requires a start date';
    end if;
    return private.wall_time_to_instant(
      ((p_all_day_start - p_all_day_days_before)::timestamp
        + time '09:00:00'), p_timezone
    );
  end if;
  return p_starts_at - p_lead_seconds * interval '1 second';
end;
$$;

-- 도우미는 비공개지만 의도적으로 행 형태를 사용한다. 공개 로컬 후보 RPC와 비공개
-- 푸시 준비 경로가 활성 참여자 검사, 반복 구체화 및 fire_at에 하나의 최종 기준을
-- 사용하게 한다.
create or replace function private.prepare_reminder_candidates(
  p_user_id uuid,
  p_fire_at_start timestamptz,
  p_fire_at_end timestamptz,
  p_channel text,
  p_after_fire_at timestamptz default null,
  p_after_event_id uuid default null,
  p_after_occurrence_key text default null,
  p_limit integer default 200,
  p_only_event_id uuid default null
)
returns table (
  event_id uuid,
  group_id uuid,
  occurrence_key text,
  occurrence_index bigint,
  fire_at timestamptz,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  title text,
  setting_id uuid,
  setting_version integer,
  event_version integer,
  occurrence_version integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_events as (
    select distinct e.id, e.group_id, s.id as setting_id,
      s.version as setting_version, s.lead_seconds, s.all_day_days_before,
      e.timezone as anchor_timezone
    from public.event_reminder_settings s
    join public.events e on e.id = s.event_id and e.deleted_at is null
    join public.groups g on g.id = e.group_id and g.deleted_at is null
    join public.event_members em on em.event_id = e.id and em.user_id = p_user_id
    join public.memberships m on m.group_id = e.group_id and m.user_id = p_user_id
      and m.is_active and m.removed_at is null
    left join public.notification_preferences np on np.user_id = p_user_id
    where s.user_id = p_user_id
      and s.channel = p_channel
      and s.enabled
      and (case when p_channel = 'local' then coalesce(np.local_enabled, false)
               else coalesce(np.push_enabled, false) end)
      and (p_only_event_id is null or e.id = p_only_event_id)
  ),
  expanded as (
    select a.*, o.occurrence_key, o.occurrence_index,
      o.starts_at, o.ends_at, o.timezone, o.is_all_day,
      o.all_day_start, o.all_day_end, o.title,
      o.version as event_version, o.occurrence_version,
      private.reminder_fire_at(
        o.starts_at, o.is_all_day, o.all_day_start, o.timezone,
        a.lead_seconds, a.all_day_days_before
      ) as fire_at
    from active_events a
    cross join lateral public._event_occurrences_for_range(
      a.id,
      p_fire_at_start - greatest(
        interval '604800 seconds',
        a.all_day_days_before * interval '1 day'
      ),
      p_fire_at_end + greatest(
        interval '604800 seconds',
        a.all_day_days_before * interval '1 day'
      ),
      a.anchor_timezone
    ) o
  ),
  filtered as (
    select x.* from expanded x
    where x.fire_at >= p_fire_at_start
      and x.fire_at < p_fire_at_end
      and (
        p_after_fire_at is null
        or x.fire_at > p_after_fire_at
        or (x.fire_at = p_after_fire_at and x.id > p_after_event_id)
        or (x.fire_at = p_after_fire_at and x.id = p_after_event_id
            and x.occurrence_key > p_after_occurrence_key)
      )
  )
  select id, group_id, occurrence_key, coalesce(occurrence_index, 0)::bigint, fire_at,
    starts_at, ends_at, timezone, is_all_day, all_day_start, all_day_end,
    title, setting_id, setting_version, event_version, occurrence_version
  from filtered
  order by fire_at, id, occurrence_key
  limit (p_limit + 1);
$$;

create or replace function public.reminder_candidates_for_user(
  p_fire_at_start timestamptz,
  p_fire_at_end timestamptz,
  p_limit integer default 100,
  p_cursor text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_cursor jsonb;
  v_cursor_wire json;
  v_cursor_text text;
  v_after_fire_at timestamptz;
  v_after_event_id uuid;
  v_after_occurrence_key text;
  v_rows jsonb := '[]'::jsonb;
  v_row record;
  v_seen integer := 0;
  v_has_more boolean := false;
  v_last record;
  v_local_enabled boolean;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_fire_at_start is null or p_fire_at_end is null
     or not pg_catalog.isfinite(p_fire_at_start)
     or not pg_catalog.isfinite(p_fire_at_end)
     or p_fire_at_end <= p_fire_at_start
     or p_fire_at_end - p_fire_at_start > interval '60 days' then
    raise exception using errcode = '22023', message = 'fire_at range must be finite and at most 60 days';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception using errcode = '22023', message = 'limit must be between 1 and 200';
  end if;
  select coalesce(p.local_enabled, false) into v_local_enabled
  from public.notification_preferences p where p.user_id = v_actor;

  if p_cursor is not null then
    if pg_catalog.length(p_cursor) > 4096
       or pg_catalog.btrim(p_cursor) = ''
       or p_cursor !~ '^[A-Za-z0-9_-]+$' then
      raise exception using errcode = '22023', message = 'cursor is malformed';
    end if;
    begin
      v_cursor_text := pg_catalog.convert_from(
        pg_catalog.decode(
          pg_catalog.translate(p_cursor, '-_', '+/') ||
            pg_catalog.repeat('=', (4 - (pg_catalog.length(p_cursor) % 4)) % 4),
          'base64'
        ), 'UTF8'
      );
      v_cursor_wire := v_cursor_text::json;
      v_cursor := v_cursor_text::jsonb;
    exception when others then
      raise exception using errcode = '22023', message = 'cursor is malformed';
    end;
    if pg_catalog.jsonb_typeof(v_cursor) <> 'object'
       or v_cursor - 'v' - 'fire_at' - 'event_id' - 'occurrence_key' - 'channel' <> '{}'::jsonb
       or v_cursor->>'v' is null or v_cursor->>'fire_at' is null
       or v_cursor->>'event_id' is null or v_cursor->>'occurrence_key' is null
       or v_cursor->>'channel' is null then
      raise exception using errcode = '22023', message = 'cursor has an invalid shape';
    end if;
    if pg_catalog.json_typeof(v_cursor_wire -> 'v') <> 'number'
       or (v_cursor_wire -> 'v')::text !~ '^[0-9]+$'
       or v_cursor->>'v' <> '1'
       or pg_catalog.json_typeof(v_cursor_wire -> 'fire_at') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'event_id') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'occurrence_key') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'channel') <> 'string'
       or v_cursor->>'channel' <> 'local'
       or (v_cursor->>'occurrence_key') !~ '^(single|o[0-9]{20})$' then
      raise exception using errcode = '22023', message = 'cursor has an invalid version or key';
    end if;
    begin
      v_after_fire_at := (v_cursor->>'fire_at')::timestamptz;
      v_after_event_id := (v_cursor->>'event_id')::uuid;
      if not pg_catalog.isfinite(v_after_fire_at) then
        raise exception using errcode = '22023', message = 'cursor timestamp is not finite';
      end if;
    exception when others then
      raise exception using errcode = '22023', message = 'cursor tuple is invalid';
    end;
    v_after_occurrence_key := v_cursor->>'occurrence_key';
  end if;

  for v_row in
    select * from private.prepare_reminder_candidates(
      v_actor, p_fire_at_start, p_fire_at_end, 'local',
      v_after_fire_at, v_after_event_id, v_after_occurrence_key, p_limit,
      null
    )
  loop
    if v_seen >= p_limit then
      v_has_more := true;
      exit;
    end if;
    v_rows := v_rows || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'event_id', v_row.event_id,
      'group_id', v_row.group_id,
      'occurrence_key', v_row.occurrence_key,
      'occurrence_index', v_row.occurrence_index,
      'fire_at', v_row.fire_at,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at,
      'timezone', v_row.timezone,
      'is_all_day', v_row.is_all_day,
      'all_day_start', v_row.all_day_start,
      'all_day_end', v_row.all_day_end,
      'title', v_row.title,
      'setting_id', v_row.setting_id,
      'setting_version', v_row.setting_version,
      'event_version', v_row.event_version,
      'occurrence_version', v_row.occurrence_version,
      'channel', 'local',
      'capability', 'client_local_scheduler',
      'all_day_local_time', '09:00:00'
    ));
    v_seen := v_seen + 1;
    v_last := v_row;
  end loop;
  if v_has_more then
    v_cursor := pg_catalog.jsonb_build_object(
      'v', 1,
      'fire_at', v_last.fire_at,
      'event_id', v_last.event_id,
      'occurrence_key', v_last.occurrence_key,
      'channel', 'local'
    );
    v_cursor_text := pg_catalog.rtrim(
      pg_catalog.translate(
        pg_catalog.replace(
          pg_catalog.encode(pg_catalog.convert_to(v_cursor::text, 'UTF8'), 'base64'),
          E'\n', ''
        ), '+/', '-_'
      ), '='
    );
  else
    v_cursor_text := null;
  end if;
  return pg_catalog.jsonb_build_object(
    'candidates', v_rows,
    'next_cursor', v_cursor_text,
    'has_more', v_has_more,
    'capability', case when v_local_enabled
      then 'client_local_scheduler' else 'disabled' end
  );
end;
$$;

create or replace function public.register_push_device(
  p_provider text,
  p_platform text,
  p_environment text,
  p_token text,
  p_installation_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_token_hash text;
  v_installation_hash text;
  v_device private.push_device_tokens;
  v_changed boolean := false;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_conflict uuid;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_provider is null or p_provider not in ('apns', 'fcm')
     or p_platform is null or p_platform not in ('ios', 'android')
     or p_environment is null or p_environment not in ('sandbox', 'production')
     or p_token is null or pg_catalog.octet_length(p_token) not between 1 and 4096
     or (p_provider = 'apns' and p_platform <> 'ios')
     or (p_provider = 'fcm' and p_platform <> 'android')
     or (p_installation_id is not null and pg_catalog.octet_length(p_installation_id) > 256) then
    raise exception using errcode = '22023', message = 'device values are invalid';
  end if;
  perform 1 from auth.users u where u.id = v_actor for key share;
  if not found then
    raise exception using errcode = '42501', message = 'account is unavailable';
  end if;
  v_token_hash := encode(
    extensions.digest(pg_catalog.convert_to(p_token, 'utf8'), 'sha256'), 'hex'
  );
  if p_installation_id is not null then
    v_installation_hash := encode(
      extensions.digest(pg_catalog.convert_to(p_installation_id, 'utf8'), 'sha256'), 'hex'
    );
  end if;
  -- 계정 간 토큰 고유성 검사를 직렬화한다. 계정 삭제와 맞도록 위의 요청자 잠금이
  -- 계속 먼저다. 이 advisory 잠금은 동시 사용자 둘이 제공자/토큰 고유 제약에서
  -- 경합하여 의도한 권한 응답 대신 구현 오류를 노출하는 것을 막는다.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_token_hash, 0)
  );
  select d.id into v_conflict
  from private.push_device_tokens d
  where d.provider = p_provider and d.token_hash = v_token_hash
    and d.user_id <> v_actor
  for update;
  if v_conflict is not null then
    raise exception using errcode = '42501', message = 'device is already registered';
  end if;
  select d.* into v_device
  from private.push_device_tokens d
  where d.user_id = v_actor and d.provider = p_provider
    and d.token_hash = v_token_hash
  for update;
  if not found then
    insert into private.push_device_tokens (
      user_id, provider, platform, environment, token_hash, token,
      installation_hash, is_active, last_seen_at, revoked_at,
      created_at, updated_at
    ) values (
      v_actor, p_provider, p_platform, p_environment, v_token_hash, p_token,
      v_installation_hash, true, v_now, null, v_now, v_now
    ) returning * into v_device;
    v_changed := true;
  else
    if v_device.platform is distinct from p_platform
       or v_device.environment is distinct from p_environment
       or v_device.installation_hash is distinct from v_installation_hash
       or not v_device.is_active then
      update private.push_device_tokens d
      set platform = p_platform,
          environment = p_environment,
          installation_hash = v_installation_hash,
          is_active = true,
          revoked_at = null,
          last_seen_at = v_now,
          updated_at = v_now
      where d.id = v_device.id
      returning * into v_device;
      v_changed := true;
    else
      update private.push_device_tokens d
      set last_seen_at = v_now, updated_at = v_now
      where d.id = v_device.id
      returning * into v_device;
    end if;
  end if;
  -- 등록은 범위를 제한한 조정 요청을 큐에 넣을 뿐이다. 인증된 RPC가 계정 잠금을
  -- 유지하는 동안 반복 일정을 확장하지 않는다.
  perform private.enqueue_user_event_reminder_reconcile(v_actor, 'device_registered');
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', v_changed,
    'device_id', v_device.id,
    'provider', v_device.provider,
    'platform', v_device.platform,
    'environment', v_device.environment,
    'capability', 'push_unconfigured'
  );
end;
$$;

create or replace function public.revoke_push_device(p_device_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_device private.push_device_tokens;
  v_changed boolean := false;
  v_cancelled integer := 0;
begin
  if v_actor is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_device_id is null then
    raise exception using errcode = '22023', message = 'device id is invalid';
  end if;
  perform 1 from auth.users u where u.id = v_actor for key share;
  select d.* into v_device
  from private.push_device_tokens d
  where d.id = p_device_id and d.user_id = v_actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'device is unavailable';
  end if;
  if v_device.is_active then
    update private.push_device_tokens d
    set is_active = false,
        revoked_at = pg_catalog.clock_timestamp(),
        updated_at = pg_catalog.clock_timestamp()
    where d.id = v_device.id
    returning * into v_device;
    v_changed := true;
  end if;
  -- 활성 기기가 하나 이상 수신할 수 있을 때만 작업이 유용하다. 이 취소로 사용자의
  -- 마지막 활성 기기가 제거되면 종료되지 않은 모든 푸시 작업을 명시적인 응답과
  -- 함께 취소한다. 다른 기기가 활성 상태면 해당 기기로 전송을 계속할 수 있도록
  -- 작업을 그대로 둔다.
  if not exists (
    select 1
    from private.push_device_tokens d
    where d.user_id = v_actor and d.is_active
  ) then
    v_cancelled := private.cancel_user_event_reminder_jobs(
      v_actor, 'device_revoked'
    );
  end if;
  -- 다른 기기가 활성 상태로 남아 있으면 해당 기기로 전송을 계속할 수 있도록 기존
  -- 작업을 대기 상태로 둔다. 마지막 기기였다면 위 분기에서 종료되지 않은 행을 이미
  -- 취소했다. 이후 등록은 취소 응답을 되살리지 않고 새 리비전을 만들 수 있다.
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'changed', v_changed,
    'device_id', p_device_id,
    'cancelled_jobs', v_cancelled,
    'capability', 'disabled'
  );
end;
$$;

create or replace function private.reconcile_event_reminders(
  p_event_id uuid,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_horizon_days integer default 366
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_configured boolean := false;
  v_user_id uuid;
  v_row record;
  v_inserted integer := 0;
  v_cancelled integer := 0;
  v_skipped integer := 0;
  v_horizon_end timestamptz;
  v_capability text;
begin
  if p_event_id is null or p_now is null or not pg_catalog.isfinite(p_now)
     or p_horizon_days is null or p_horizon_days < 1 or p_horizon_days > 366 then
    raise exception using errcode = '22023', message = 'invalid reconcile window';
  end if;
  v_horizon_end := p_now + p_horizon_days * interval '1 day';
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'committed', true, 'event_id', p_event_id, 'queued_jobs', 0,
      'cancelled_jobs', 0, 'skipped_past', 0, 'capability', 'event_deleted'
    );
  end if;
  if v_event.deleted_at is not null
     or not exists (
       select 1 from public.groups g where g.id = v_event.group_id and g.deleted_at is null
     ) then
    v_cancelled := private.cancel_event_reminder_jobs(p_event_id, 'event_deleted');
    return pg_catalog.jsonb_build_object(
      'committed', true, 'event_id', p_event_id, 'queued_jobs', 0,
      'cancelled_jobs', v_cancelled, 'skipped_past', 0, 'capability', 'disabled'
    );
  end if;
  select c.enabled and c.provider <> 'none' into v_configured
  from private.push_provider_capability c where c.singleton;
  if not coalesce(v_configured, false) then
    v_cancelled := private.cancel_event_reminder_jobs(
      p_event_id, 'provider_unconfigured'
    );
    return pg_catalog.jsonb_build_object(
      'committed', true, 'event_id', p_event_id, 'queued_jobs', 0,
      'cancelled_jobs', v_cancelled, 'skipped_past', 0, 'capability', 'push_unconfigured'
    );
  end if;

  drop table if exists pg_temp.reminder_desired_jobs;
  create temporary table pg_temp.reminder_desired_jobs (
    setting_id uuid not null,
    event_id uuid not null,
    group_id uuid not null,
    user_id uuid not null,
    occurrence_key text not null,
    fire_at timestamptz not null,
    event_version integer not null,
    occurrence_version integer not null,
    setting_version integer not null,
    primary key (setting_id, event_id, user_id, occurrence_key,
                 event_version, occurrence_version, setting_version)
  ) on commit drop;

  for v_user_id in
    select distinct s.user_id
    from public.event_reminder_settings s
    join public.event_members em on em.event_id = p_event_id and em.user_id = s.user_id
    join public.memberships m on m.group_id = v_event.group_id and m.user_id = s.user_id
      and m.is_active and m.removed_at is null
    where s.event_id = p_event_id and s.channel = 'push' and s.enabled
  loop
    insert into pg_temp.reminder_desired_jobs (
      setting_id, event_id, group_id, user_id, occurrence_key, fire_at,
      event_version, occurrence_version, setting_version
    )
    select c.setting_id, c.event_id, c.group_id, v_user_id, c.occurrence_key,
      c.fire_at, c.event_version, c.occurrence_version, c.setting_version
    from private.prepare_reminder_candidates(
      v_user_id, p_now, v_horizon_end, 'push', null, null, null, 2000, p_event_id
    ) c
    where c.fire_at > p_now;
  end loop;

  insert into private.event_reminder_jobs (
    setting_id, event_id, group_id, user_id, occurrence_key, fire_at,
    event_version, occurrence_version, setting_version, status, attempts,
    next_attempt_at
  )
  select d.setting_id, d.event_id, d.group_id, d.user_id, d.occurrence_key,
    d.fire_at, d.event_version, d.occurrence_version, d.setting_version,
    'pending', 0, d.fire_at
  from pg_temp.reminder_desired_jobs d
  on conflict do nothing;
  get diagnostics v_inserted = row_count;

  with locked as (
    select j.id
    from private.event_reminder_jobs j
    where j.event_id = p_event_id
      and j.status in ('pending', 'processing', 'retry')
      and not exists (
        select 1 from pg_temp.reminder_desired_jobs d
        where d.setting_id = j.setting_id and d.event_id = j.event_id
          and d.user_id = j.user_id and d.occurrence_key = j.occurrence_key
          and d.event_version = j.event_version
          and d.occurrence_version = j.occurrence_version
          and d.setting_version = j.setting_version
      )
    order by j.id
    for update
  )
  update private.event_reminder_jobs j
  set status = 'cancelled', cancelled_at = pg_catalog.clock_timestamp(),
      cancel_reason = 'rescheduled', lease_owner = null, lease_until = null,
      updated_at = pg_catalog.clock_timestamp()
  from locked where j.id = locked.id;
  get diagnostics v_cancelled = row_count;
  select case when c.enabled and c.provider <> 'none'
              then 'push_configured' else 'push_unconfigured' end
    into v_capability from private.push_provider_capability c where c.singleton;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'event_id', p_event_id,
    'queued_jobs', v_inserted, 'cancelled_jobs', v_cancelled,
    'skipped_past', v_skipped, 'capability', coalesce(v_capability, 'push_unconfigured')
  );
end;
$$;

create or replace function private.reconcile_all_event_reminders(
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_limit integer default 100
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  v_done integer := 0;
  v_queued integer := 0;
begin
  if p_now is null or not pg_catalog.isfinite(p_now)
     or p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception using errcode = '22023', message = 'invalid reconcile batch';
  end if;
  for v_event_id in
    select e.id
    from public.events e
    join public.event_reminder_settings s on s.event_id = e.id
      and s.channel = 'push' and s.enabled
    join public.groups g on g.id = e.group_id and g.deleted_at is null
    where e.deleted_at is null
    order by e.id
    limit p_limit
  loop
    perform private.reconcile_event_reminders(v_event_id, p_now, 366);
    v_done := v_done + 1;
  end loop;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'events_reconciled', v_done,
    'queued_jobs', v_queued, 'capability', 'push_configured'
  );
end;
$$;

create or replace function private.claim_event_reminder_reconcile_requests(
  p_worker_id uuid,
  p_limit integer default 50,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_lease_seconds integer default 300
)
returns table (
  event_id uuid,
  group_id uuid,
  reason text,
  attempts integer,
  lease_until timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_worker_id is null or p_now is null or not pg_catalog.isfinite(p_now)
     or p_limit is null or p_limit < 1 or p_limit > 100
     or p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 3600 then
    raise exception using errcode = '22023', message = 'invalid reconcile lease';
  end if;
  -- 작업자는 여덟 번째로 가져간 뒤 중단될 수 있다. 그런 행은 더 이상 다시 가져올
  -- 수 없으므로(아래 `attempts < 8`) 처리할 작업을 선택하기 전에 만료된 처리 임대를
  -- 종료하지 않으면 영원히 `processing`에 머문다. 더 새로운 트리거가 변경한 행은
  -- 대신 새 세대용으로 재설정한다. 현재 잠글 수 있는 행만 가져와 동시 작업자에게
  -- 범위가 제한되고 차단되지 않게 한다.
  with exhausted as (
    select q.event_id, q.dirty
    from private.event_reminder_reconcile_queue q
    where q.status = 'processing'
      and q.attempts >= 8
      and q.lease_until <= p_now
      for update skip locked
  )
  update private.event_reminder_reconcile_queue q
  set status = case when exhausted.dirty then 'pending' else 'done' end,
      attempts = case when exhausted.dirty then 0 else q.attempts end,
      next_attempt_at = case when exhausted.dirty then p_now else q.next_attempt_at end,
      completed_at = case when exhausted.dirty then null else p_now end,
      lease_owner = null, lease_until = null,
      dirty = false,
      last_error_code = case when exhausted.dirty then null else 'retry_exhausted' end
  from exhausted
  where q.event_id = exhausted.event_id;
  return query
  with due as (
    select q.event_id
    from private.event_reminder_reconcile_queue q
    where (
      q.status = 'pending' and q.next_attempt_at <= p_now
    ) or (
      q.status = 'processing' and q.lease_until <= p_now
    )
    order by q.next_attempt_at, q.event_id
    for update skip locked
    limit p_limit
  ), claimed as (
    update private.event_reminder_reconcile_queue q
    set status = 'processing', lease_owner = p_worker_id,
        lease_until = p_now + p_lease_seconds * interval '1 second',
        attempts = q.attempts + 1,
        dirty = false,
        completed_at = null,
        last_error_code = null
    from due
    where q.event_id = due.event_id
      and q.attempts < 8
    returning q.event_id, q.group_id, q.reason, q.attempts, q.lease_until
  )
  select c.event_id, c.group_id, c.reason, c.attempts, c.lease_until
  from claimed c
  order by c.event_id;
  -- 제한된 큐 시도를 모두 사용한 행은 종료 상태이며 Edge 작업자에게 반환하지 않는다.
  update private.event_reminder_reconcile_queue q
  set status = 'done', completed_at = p_now, lease_owner = null, lease_until = null,
      dirty = false,
      last_error_code = 'retry_exhausted'
  where q.status = 'pending' and q.attempts >= 8
    and q.next_attempt_at <= p_now;
end;
$$;

create or replace function private.complete_event_reminder_reconcile_request(
  p_event_id uuid,
  p_worker_id uuid,
  p_outcome text,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_queue private.event_reminder_reconcile_queue;
  v_status text;
begin
  if p_event_id is null or p_worker_id is null
     or p_outcome is null or p_outcome not in ('done', 'retryable', 'permanent')
     or (p_error_code is not null and p_error_code !~ '^[a-z0-9_.:-]{1,64}$') then
    raise exception using errcode = '22023', message = 'invalid reconcile completion';
  end if;
  select q.* into v_queue
  from private.event_reminder_reconcile_queue q
  where q.event_id = p_event_id
  for update;
  if not found or v_queue.status <> 'processing'
     or v_queue.lease_owner <> p_worker_id
     or v_queue.lease_until < pg_catalog.clock_timestamp() then
    raise exception using errcode = '40001', message = 'reconcile lease is stale';
  end if;
  -- 이 임대를 준비하는 동안 트리거가 더 새로운 일정/설정 세대를 합쳤을 수 있다.
  -- 위의 행 잠금이 선형화 지점을 제공한다. `dirty`가 설정되어 있으면 이전 세대를
  -- 절대 종료하지 않는다. 새로운 세대는 새 제한 시도 횟수로 시작하고 이 완료가
  -- 커밋된 뒤 다음 작업자가 가져가게 한다.
  if v_queue.dirty then
    v_status := 'pending';
    update private.event_reminder_reconcile_queue q
    set status = 'pending', attempts = 0, next_attempt_at = pg_catalog.clock_timestamp(),
        completed_at = null, lease_owner = null, lease_until = null,
        dirty = false, last_error_code = null
    where q.event_id = p_event_id;
  elsif p_outcome = 'done' then
    v_status := 'done';
    update private.event_reminder_reconcile_queue q
    set status = 'done', completed_at = pg_catalog.clock_timestamp(),
        lease_owner = null, lease_until = null, dirty = false,
        last_error_code = null
    where q.event_id = p_event_id;
  elsif p_outcome = 'permanent' or v_queue.attempts >= 8 then
    v_status := 'done';
    update private.event_reminder_reconcile_queue q
    set status = 'done', completed_at = pg_catalog.clock_timestamp(),
        lease_owner = null, lease_until = null,
        dirty = false,
        last_error_code = coalesce(p_error_code, 'permanent')
    where q.event_id = p_event_id;
  else
    v_status := 'pending';
    update private.event_reminder_reconcile_queue q
    set status = 'pending', lease_owner = null, lease_until = null,
        next_attempt_at = pg_catalog.clock_timestamp()
          + least(3600, 30 * (2 ^ greatest(v_queue.attempts - 1, 0))) * interval '1 second',
        dirty = false,
        last_error_code = coalesce(p_error_code, 'retryable')
    where q.event_id = p_event_id;
  end if;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'event_id', p_event_id, 'status', v_status,
    'attempts', v_queue.attempts, 'error_code', p_error_code
  );
end;
$$;

create or replace function private.claim_event_reminder_jobs(
  p_worker_id uuid,
  p_limit integer default 100,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_lease_seconds integer default 300
)
returns table (
  id uuid,
  setting_id uuid,
  event_id uuid,
  group_id uuid,
  user_id uuid,
  occurrence_key text,
  fire_at timestamptz,
  event_version integer,
  occurrence_version integer,
  setting_version integer,
  attempts integer,
  lease_until timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_configured boolean;
begin
  if p_worker_id is null or p_now is null or not pg_catalog.isfinite(p_now)
     or p_limit is null or p_limit < 1 or p_limit > 200
     or p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 3600 then
    raise exception using errcode = '22023', message = 'invalid worker lease';
  end if;
  select c.enabled and c.provider <> 'none' into v_configured
  from private.push_provider_capability c where c.singleton;
  if not coalesce(v_configured, false) then
    raise exception using errcode = '55000', message = 'push_unconfigured';
  end if;
  -- 위 조정 큐 가져오기를 참고한다. 만료된 여덟 번째 시도 임대는 다시 가져오기
  -- 조건자에서 제외되므로 처리할 작업을 선택하기 전에 종료한다. 의도적으로 fire_at
  -- 검사보다도 먼저 실행하여 중단된 작업자가 미래 발생을 처리 중 상태에 남기지 못하게 한다.
  with exhausted as (
    select j.id
    from private.event_reminder_jobs j
    where j.status = 'processing'
      and j.attempts >= 8
      and j.lease_until <= p_now
    for update skip locked
  )
  update private.event_reminder_jobs j
  set status = 'dead_letter', dead_letter_at = p_now,
      last_error_code = 'retry_exhausted', lease_owner = null,
      lease_until = null, updated_at = p_now
  from exhausted
  where j.id = exhausted.id;
  return query
  with due as (
    select j.id
    from private.event_reminder_jobs j
    join public.events e on e.id = j.event_id and e.deleted_at is null
    join public.groups g on g.id = j.group_id and g.deleted_at is null
    join public.event_members em on em.event_id = j.event_id and em.user_id = j.user_id
    join public.memberships m on m.group_id = j.group_id and m.user_id = j.user_id
      and m.is_active and m.removed_at is null
    join public.notification_preferences np on np.user_id = j.user_id and np.push_enabled
    join public.event_reminder_settings s on s.id = j.setting_id
      and s.user_id = j.user_id
      and s.event_id = j.event_id
      and s.enabled and s.channel = 'push' and s.version = j.setting_version
    where (
      (j.status in ('pending', 'retry') and j.next_attempt_at <= p_now and j.fire_at <= p_now)
      or (j.status = 'processing' and j.lease_until <= p_now and j.fire_at <= p_now)
    )
    order by j.next_attempt_at, j.fire_at, j.id
    for update of j skip locked
    limit p_limit
  ), claimed as (
    update private.event_reminder_jobs j
    set status = 'processing', lease_owner = p_worker_id,
        lease_until = p_now + p_lease_seconds * interval '1 second',
        attempts = j.attempts + 1,
        updated_at = pg_catalog.clock_timestamp()
    from due
    where j.id = due.id and j.attempts < 8
    returning j.*
  )
  select c.id, c.setting_id, c.event_id, c.group_id, c.user_id,
    c.occurrence_key, c.fire_at, c.event_version, c.occurrence_version,
    c.setting_version, c.attempts, c.lease_until
  from claimed c
  order by c.fire_at, c.id;
  update private.event_reminder_jobs j
  set status = 'dead_letter', dead_letter_at = p_now,
      last_error_code = 'retry_exhausted', updated_at = p_now
  where j.status in ('pending', 'retry')
    and j.attempts >= 8 and j.next_attempt_at <= p_now;
end;
$$;

create or replace function private.complete_event_reminder_job(
  p_job_id uuid,
  p_worker_id uuid,
  p_outcome text,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_job private.event_reminder_jobs;
  v_status text;
  v_next_attempt timestamptz;
begin
  if p_job_id is null or p_worker_id is null
     or p_outcome is null or p_outcome not in ('sent', 'retryable', 'permanent')
     or (p_error_code is not null and p_error_code !~ '^[a-z0-9_.:-]{1,64}$') then
    raise exception using errcode = '22023', message = 'invalid job completion';
  end if;
  select j.* into v_job from private.event_reminder_jobs j
  where j.id = p_job_id for update;
  if not found or v_job.status <> 'processing'
     or v_job.lease_owner <> p_worker_id
     or v_job.lease_until < pg_catalog.clock_timestamp() then
    raise exception using errcode = '40001', message = 'job lease is stale';
  end if;
  if p_outcome = 'sent' then
    v_status := 'sent';
    update private.event_reminder_jobs j
    set status = 'sent', sent_at = pg_catalog.clock_timestamp(),
        lease_owner = null, lease_until = null, updated_at = pg_catalog.clock_timestamp()
    where j.id = p_job_id;
  elsif p_outcome = 'permanent' or v_job.attempts >= 8 then
    v_status := 'dead_letter';
    update private.event_reminder_jobs j
    set status = 'dead_letter', dead_letter_at = pg_catalog.clock_timestamp(),
        last_error_code = coalesce(p_error_code, 'permanent'),
        lease_owner = null, lease_until = null, updated_at = pg_catalog.clock_timestamp()
    where j.id = p_job_id;
  else
    v_next_attempt := pg_catalog.clock_timestamp()
      + least(3600, 30 * (2 ^ greatest(v_job.attempts - 1, 0))) * interval '1 second';
    v_status := 'retry';
    update private.event_reminder_jobs j
    set status = 'retry', next_attempt_at = v_next_attempt,
        last_error_code = coalesce(p_error_code, 'retryable'),
        lease_owner = null, lease_until = null, updated_at = pg_catalog.clock_timestamp()
    where j.id = p_job_id;
  end if;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'job_id', p_job_id, 'status', v_status,
    'attempts', v_job.attempts, 'next_attempt_at', v_next_attempt,
    'error_code', p_error_code
  );
end;
$$;

create or replace function private.load_event_reminder_payload(
  p_job_id uuid,
  p_worker_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_job private.event_reminder_jobs;
  v_event public.events;
  v_occurrence record;
  v_index bigint;
  v_tokens jsonb;
begin
  if p_job_id is null or p_worker_id is null then
    raise exception using errcode = '22023', message = 'job payload values are invalid';
  end if;
  select j.* into v_job from private.event_reminder_jobs j
  where j.id = p_job_id for share;
  if not found or v_job.status <> 'processing' or v_job.lease_owner <> p_worker_id
     or v_job.lease_until < pg_catalog.clock_timestamp() then
    raise exception using errcode = '40001', message = 'job lease is stale';
  end if;
  select e.* into v_event from public.events e where e.id = v_job.event_id;
  if not found or v_event.deleted_at is not null or v_event.version <> v_job.event_version
     or v_event.group_id <> v_job.group_id then
    return pg_catalog.jsonb_build_object(
      'valid', false, 'job_id', p_job_id, 'reason', 'stale'
    );
  end if;
  if not exists (
    select 1 from public.groups g where g.id = v_event.group_id and g.deleted_at is null
  ) or not exists (
    select 1 from public.event_members em
    join public.memberships m on m.group_id = v_event.group_id and m.user_id = v_job.user_id
      and m.is_active and m.removed_at is null
    where em.event_id = v_event.id and em.user_id = v_job.user_id
  ) or not exists (
    select 1 from public.notification_preferences np
    where np.user_id = v_job.user_id and np.push_enabled
  ) or not exists (
    select 1 from public.event_reminder_settings s
    where s.id = v_job.setting_id and s.user_id = v_job.user_id
      and s.event_id = v_job.event_id and s.channel = 'push'
      and s.enabled and s.version = v_job.setting_version
  ) then
    return pg_catalog.jsonb_build_object(
      'valid', false, 'job_id', p_job_id, 'reason', 'stale'
    );
  end if;
  if v_job.occurrence_key = 'single' then
    v_index := -1;
  else
    begin
      v_index := pg_catalog.substr(v_job.occurrence_key, 2)::bigint;
      if public.recurrence_occurrence_key(v_index) <> v_job.occurrence_key then
        raise exception using errcode = '22023', message = 'occurrence key is invalid';
      end if;
    exception when others then
      return pg_catalog.jsonb_build_object(
        'valid', false, 'job_id', p_job_id, 'reason', 'stale'
      );
    end;
  end if;
  select * into v_occurrence
  from public._event_occurrence_at_index(v_event.id, v_index);
  if not found or v_occurrence.occurrence_key <> v_job.occurrence_key
     or v_occurrence.occurrence_version <> v_job.occurrence_version then
    return pg_catalog.jsonb_build_object(
      'valid', false, 'job_id', p_job_id, 'reason', 'stale'
    );
  end if;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', d.id, 'provider', d.provider, 'platform', d.platform,
        'environment', d.environment, 'token', d.token
      ) order by d.id
    ), '[]'::jsonb
  ) into v_tokens
  from private.push_device_tokens d
  where d.user_id = v_job.user_id and d.is_active;
  if pg_catalog.jsonb_array_length(v_tokens) = 0 then
    return pg_catalog.jsonb_build_object(
      'valid', false, 'job_id', p_job_id, 'reason', 'no_device'
    );
  end if;
  return pg_catalog.jsonb_build_object(
    'valid', true,
    'job_id', p_job_id,
    'event_id', v_event.id,
    'group_id', v_event.group_id,
    'user_id', v_job.user_id,
    'occurrence_key', v_job.occurrence_key,
    'fire_at', v_job.fire_at,
    'title', v_occurrence.title,
    'description', v_occurrence.description,
    'starts_at', v_occurrence.starts_at,
    'ends_at', v_occurrence.ends_at,
    'timezone', v_occurrence.timezone,
    'is_all_day', v_occurrence.is_all_day,
    'tokens', v_tokens
  );
end;
$$;

-- 수명 주기 훅은 의도적으로 범위가 제한된 취소/큐 쓰기만 수행한다. 일정, 그룹 또는
-- 멤버십 잠금을 유지하는 동안 반복 행을 확장하지 않는다. 작업자가 비공개 조정
-- 함수를 통해 해당 작업을 수행한다.
create or replace function private.reminder_events_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is not null then
    -- 일정 삭제는 종료 상태다(일정 무결성 트리거가 복원을 거부한다). 묶음 전체의
    -- 의도 자체를 제거한다. 복합 참여자 FK와 setting_id FK가 이미 종료 응답인 행을
    -- 포함한 모든 비공개 작업을 연쇄 삭제한다. 연쇄 작업 전에 종료되지 않은 행을
    -- 명시적으로 무효화하도록 범위 제한 취소를 먼저 수행한다.
    perform private.cancel_event_reminder_jobs(new.id, 'event_deleted');
    delete from public.event_reminder_settings
    where event_id = new.id;
  else
    if tg_op = 'UPDATE' and old.version is distinct from new.version then
      perform private.cancel_event_reminder_jobs(new.id, 'rescheduled');
    end if;
    perform private.enqueue_event_reminder_reconcile(new.id, 'event_changed');
  end if;
  return new;
end;
$$;

create or replace function private.reminder_settings_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.enqueue_event_reminder_reconcile(new.event_id, 'setting_changed');
  return new;
end;
$$;

create or replace function private.reminder_groups_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
begin
  if old.deleted_at is null and new.deleted_at is not null then
    perform private.cancel_group_event_reminder_jobs(new.id, 'group_archived');
  elsif old.deleted_at is not null and new.deleted_at is null then
    for v_event_id in
      select e.id
      from public.events e
      where e.group_id = new.id and e.deleted_at is null
      order by e.id
    loop
      perform private.enqueue_event_reminder_reconcile(v_event_id, 'event_changed');
    end loop;
  end if;
  return new;
end;
$$;

create or replace function private.reminder_memberships_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.cancel_group_user_event_reminder_jobs(
      old.group_id, old.user_id, 'membership_removed'
    );
    return old;
  elsif old.is_active and old.removed_at is null
        and (not new.is_active or new.removed_at is not null) then
    perform private.cancel_group_user_event_reminder_jobs(
      new.group_id, new.user_id, 'membership_removed'
    );
  elsif (not old.is_active or old.removed_at is not null)
        and new.is_active and new.removed_at is null then
    perform private.enqueue_user_event_reminder_reconcile(new.user_id, 'participant_changed');
  end if;
  return new;
end;
$$;

create or replace function private.reminder_preferences_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.push_enabled then
    perform private.enqueue_user_event_reminder_reconcile(new.user_id, 'provider_enabled');
  else
    perform private.cancel_user_event_reminder_jobs(new.user_id, 'setting_disabled');
  end if;
  return new;
end;
$$;

drop trigger if exists reminders_events_after_change on public.events;
create trigger reminders_events_after_change
after insert or update on public.events
for each row execute function private.reminder_events_after_change();

drop trigger if exists reminders_settings_after_change on public.event_reminder_settings;
create trigger reminders_settings_after_change
after insert or update on public.event_reminder_settings
for each row execute function private.reminder_settings_after_change();

drop trigger if exists reminders_groups_after_change on public.groups;
create trigger reminders_groups_after_change
after update on public.groups
for each row execute function private.reminder_groups_after_change();

drop trigger if exists reminders_memberships_after_change on public.memberships;
create trigger reminders_memberships_after_change
after update or delete on public.memberships
for each row execute function private.reminder_memberships_after_change();

drop trigger if exists reminders_preferences_after_change on public.notification_preferences;
create trigger reminders_preferences_after_change
after insert or update on public.notification_preferences
for each row execute function private.reminder_preferences_after_change();

-- Data API에는 비공개 스키마 권한을 절대 주지 않는다. Edge Function은 제한된 이
-- 서비스 역할 래퍼만 호출한다. 래퍼 함수는 의도적으로 JSON 봉투를 반환하여 작업자가
-- 각 호출을 짧은 데이터베이스 트랜잭션 하나로 처리하고 커밋 뒤 제공자 I/O를 수행하게 한다.
create or replace function public.worker_push_capability()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_provider text := 'none';
  v_enabled boolean := false;
begin
  select c.provider, c.enabled into v_provider, v_enabled
  from private.push_provider_capability c where c.singleton;
  return pg_catalog.jsonb_build_object(
    'committed', true,
    'provider', coalesce(v_provider, 'none'),
    'enabled', coalesce(v_enabled, false),
    'capability', case when coalesce(v_enabled, false) and coalesce(v_provider, 'none') <> 'none'
      then 'push_configured' else 'push_unconfigured' end
  );
end;
$$;

create or replace function public.worker_claim_reconcile_requests(
  p_worker_id uuid,
  p_limit integer default 50,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_lease_seconds integer default 300
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_requests jsonb;
begin
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'event_id', q.event_id, 'group_id', q.group_id,
        'reason', q.reason, 'attempts', q.attempts,
        'lease_until', q.lease_until
      ) order by q.event_id
    ), '[]'::jsonb
  ) into v_requests
  from private.claim_event_reminder_reconcile_requests(
    p_worker_id, p_limit, p_now, p_lease_seconds
  ) q;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'requests', v_requests,
    'count', pg_catalog.jsonb_array_length(v_requests)
  );
end;
$$;

create or replace function public.worker_prepare_event_reminder_jobs(
  p_event_id uuid,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_horizon_days integer default 366
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return private.reconcile_event_reminders(p_event_id, p_now, p_horizon_days);
end;
$$;

create or replace function public.worker_complete_reconcile_request(
  p_event_id uuid,
  p_worker_id uuid,
  p_outcome text,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return private.complete_event_reminder_reconcile_request(
    p_event_id, p_worker_id, p_outcome, p_error_code
  );
end;
$$;

create or replace function public.worker_claim_event_reminder_jobs(
  p_worker_id uuid,
  p_limit integer default 100,
  p_now timestamptz default pg_catalog.clock_timestamp(),
  p_lease_seconds integer default 300
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_jobs jsonb;
begin
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', j.id, 'setting_id', j.setting_id, 'event_id', j.event_id,
        'group_id', j.group_id, 'user_id', j.user_id,
        'occurrence_key', j.occurrence_key, 'fire_at', j.fire_at,
        'event_version', j.event_version,
        'occurrence_version', j.occurrence_version,
        'setting_version', j.setting_version, 'attempts', j.attempts,
        'lease_until', j.lease_until
      ) order by j.fire_at, j.id
    ), '[]'::jsonb
  ) into v_jobs
  from private.claim_event_reminder_jobs(
    p_worker_id, p_limit, p_now, p_lease_seconds
  ) j;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'jobs', v_jobs,
    'count', pg_catalog.jsonb_array_length(v_jobs), 'capability', 'push_configured'
  );
end;
$$;

create or replace function public.worker_load_event_reminder_payload(
  p_job_id uuid,
  p_worker_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.load_event_reminder_payload(p_job_id, p_worker_id);
end;
$$;

create or replace function public.worker_complete_event_reminder_job(
  p_job_id uuid,
  p_worker_id uuid,
  p_outcome text,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return private.complete_event_reminder_job(
    p_job_id, p_worker_id, p_outcome, p_error_code
  );
end;
$$;

-- 배포는 제공자 자격 증명과 별개로 기능을 설정할 수 있다. 작업자는 가져오기 전에
-- 계속 Edge 비밀 값을 확인하므로 이 스위치 때문에 미구성 배포가 실수로 Bearer 값을
-- 전송하거나 기록할 수 없다.
create or replace function public.worker_set_push_capability(
  p_provider text,
  p_enabled boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_enabled boolean := coalesce(p_enabled, false);
  v_count integer := 0;
  v_cancelled integer := 0;
begin
  if p_provider is null or p_provider not in ('none', 'apns', 'fcm') then
    raise exception using errcode = '22023', message = 'invalid push provider';
  end if;
  if p_provider = 'none' then
    v_enabled := false;
  end if;
  insert into private.push_provider_capability(singleton, provider, enabled, updated_at)
  values (true, p_provider, v_enabled, pg_catalog.clock_timestamp())
  on conflict (singleton) do update set
    provider = excluded.provider, enabled = excluded.enabled,
    updated_at = pg_catalog.clock_timestamp();
  if v_enabled then
    v_count := private.enqueue_user_event_reminder_reconcile(
      null, 'provider_enabled'
    );
  else
    v_cancelled := private.cancel_event_reminder_jobs(
      null, 'provider_unconfigured', null, null
    );
  end if;
  return pg_catalog.jsonb_build_object(
    'committed', true, 'provider', p_provider, 'enabled', v_enabled,
    'queued_reconcile', v_count, 'cancelled_jobs', v_cancelled,
    'capability', case when v_enabled then 'push_configured' else 'push_unconfigured' end
  );
end;
$$;

-- `enqueue_user_event_reminder_reconcile`은 사용자 범위다. null 사용자는 기능 변경을
-- 위한 의도적인 운영자 경로다. 반복 행을 건드리지 않고 여기에서 확장하여 함수가
-- 큐 행 범위로 제한되게 한다.
create or replace function private.enqueue_user_event_reminder_reconcile(
  p_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_event_id uuid;
begin
  if p_reason is null or p_reason not in ('device_registered', 'provider_enabled', 'participant_changed') then
    raise exception using errcode = '22023', message = 'invalid user reconcile reason';
  end if;
  for v_event_id in
    select distinct e.id
    from public.events e
    join public.groups g on g.id = e.group_id and g.deleted_at is null
    join public.event_members em on em.event_id = e.id
    join public.memberships m on m.group_id = e.group_id and m.user_id = em.user_id
      and m.is_active and m.removed_at is null
    join public.event_reminder_settings s on s.event_id = e.id
      and s.user_id = em.user_id and s.channel = 'push' and s.enabled
    where e.deleted_at is null
      and (p_user_id is null or em.user_id = p_user_id)
    order by e.id
  loop
    perform private.enqueue_event_reminder_reconcile(v_event_id, p_reason);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- 공개 클라이언트 RPC만 인증된 진입점이다. 정확한 인증 집합에 권한을 주기 전에
-- 기본 PUBLIC 실행 권한을 회수한다. service_role 역할이 있으면 작업자 래퍼는 해당
-- 역할 전용이다.
revoke all on function public.get_notification_preferences() from public, anon, authenticated;
revoke all on function public.set_notification_preferences(boolean, boolean, integer) from public, anon, authenticated;
revoke all on function public.get_event_reminder(uuid) from public, anon, authenticated;
revoke all on function public.list_event_reminders(uuid) from public, anon, authenticated;
revoke all on function public.set_event_reminder(uuid, text, boolean, integer, smallint, integer, integer) from public, anon, authenticated;
revoke all on function public.reminder_candidates_for_user(timestamptz, timestamptz, integer, text) from public, anon, authenticated;
revoke all on function public.register_push_device(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.revoke_push_device(uuid) from public, anon, authenticated;
grant execute on function public.get_notification_preferences() to authenticated;
grant execute on function public.set_notification_preferences(boolean, boolean, integer) to authenticated;
grant execute on function public.get_event_reminder(uuid) to authenticated;
grant execute on function public.list_event_reminders(uuid) to authenticated;
grant execute on function public.set_event_reminder(uuid, text, boolean, integer, smallint, integer, integer) to authenticated;
grant execute on function public.reminder_candidates_for_user(timestamptz, timestamptz, integer, text) to authenticated;
grant execute on function public.register_push_device(text, text, text, text, text) to authenticated;
grant execute on function public.revoke_push_device(uuid) to authenticated;

revoke all on function public.worker_push_capability() from public, anon, authenticated;
revoke all on function public.worker_claim_reconcile_requests(uuid, integer, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.worker_prepare_event_reminder_jobs(uuid, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.worker_complete_reconcile_request(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.worker_claim_event_reminder_jobs(uuid, integer, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.worker_load_event_reminder_payload(uuid, uuid) from public, anon, authenticated;
revoke all on function public.worker_complete_event_reminder_job(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.worker_set_push_capability(text, boolean) from public, anon, authenticated;

revoke all on function private.enqueue_event_reminder_reconcile(uuid, text) from public, anon, authenticated;
revoke all on function private.cancel_event_reminder_jobs(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function private.cancel_group_event_reminder_jobs(uuid, text) from public, anon, authenticated;
revoke all on function private.cancel_user_event_reminder_jobs(uuid, text) from public, anon, authenticated;
revoke all on function private.cancel_group_user_event_reminder_jobs(uuid, uuid, text) from public, anon, authenticated;
revoke all on function private.enqueue_user_event_reminder_reconcile(uuid, text) from public, anon, authenticated;
revoke all on function private.wall_time_to_instant(timestamp, text) from public, anon, authenticated;
revoke all on function private.reminder_fire_at(timestamptz, boolean, date, text, integer, smallint) from public, anon, authenticated;
revoke all on function private.prepare_reminder_candidates(uuid, timestamptz, timestamptz, text, timestamptz, uuid, text, integer, uuid) from public, anon, authenticated;
revoke all on function private.reconcile_event_reminders(uuid, timestamptz, integer) from public, anon, authenticated;
revoke all on function private.reconcile_all_event_reminders(timestamptz, integer) from public, anon, authenticated;
revoke all on function private.claim_event_reminder_reconcile_requests(uuid, integer, timestamptz, integer) from public, anon, authenticated;
revoke all on function private.complete_event_reminder_reconcile_request(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function private.claim_event_reminder_jobs(uuid, integer, timestamptz, integer) from public, anon, authenticated;
revoke all on function private.complete_event_reminder_job(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function private.load_event_reminder_payload(uuid, uuid) from public, anon, authenticated;
revoke all on function private.reminder_events_after_change() from public, anon, authenticated;
revoke all on function private.reminder_settings_after_change() from public, anon, authenticated;
revoke all on function private.reminder_groups_after_change() from public, anon, authenticated;
revoke all on function private.reminder_memberships_after_change() from public, anon, authenticated;
revoke all on function private.reminder_preferences_after_change() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.worker_push_capability() to service_role';
    execute 'grant execute on function public.worker_claim_reconcile_requests(uuid, integer, timestamptz, integer) to service_role';
    execute 'grant execute on function public.worker_prepare_event_reminder_jobs(uuid, timestamptz, integer) to service_role';
    execute 'grant execute on function public.worker_complete_reconcile_request(uuid, uuid, text, text) to service_role';
    execute 'grant execute on function public.worker_claim_event_reminder_jobs(uuid, integer, timestamptz, integer) to service_role';
    execute 'grant execute on function public.worker_load_event_reminder_payload(uuid, uuid) to service_role';
    execute 'grant execute on function public.worker_complete_event_reminder_job(uuid, uuid, text, text) to service_role';
    execute 'grant execute on function public.worker_set_push_capability(text, boolean) to service_role';
  end if;
end;
$$;

commit;
