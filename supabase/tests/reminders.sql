-- Feature 3 SQL fixture. The companion runner creates the deterministic rows
-- below before executing this file. Assertions use only PostgreSQL/DO blocks,
-- so the runner works without a pgTAP installation.
--
-- owner f101, member f102, inactive f103, outsider f104; group f201;
-- events f301 (legacy), f302 (timed), f303 (all-day), f304 (daily x2).

begin;
set local timezone = 'UTC';

do $$
begin
  if (select title from public.events where id = '00000000-0000-4000-8000-00000000f301') <> 'Legacy reminder event' then
    raise exception 'neighbor event was changed during reminder migration';
  end if;
  if (select description from public.groups where id = '00000000-0000-4000-8000-00000000f201') <> 'legacy group data' then
    raise exception 'neighbor group was changed during reminder migration';
  end if;
  if exists (select 1 from public.notification_preferences) then
    raise exception 'reminder migration synthesized account preference rows';
  end if;
  if exists (select 1 from public.event_reminder_settings) then
    raise exception 'reminder migration synthesized setting rows';
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
    raise exception 'event reminder read envelope is not the fixed all-day contract';
  end if;
end;
$$;

-- Strict limit+1 keyset paging and singleton occurrence_index normalization.
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
    raise exception 'candidate page did not use strict limit+1 keyset semantics';
  end if;
  v_first := v_page->'candidates'->0;
  if v_first->>'occurrence_key' = 'single'
     and (v_first->>'occurrence_index')::integer <> 0 then
    raise exception 'singleton candidate occurrence_index must be zero';
  end if;
  v_cursor := v_page->>'next_cursor';
  v_next := public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 2, v_cursor);
  if jsonb_array_length(v_next->'candidates') = 0
     or (v_next->'candidates'->0->>'fire_at')::timestamptz < (v_first->>'fire_at')::timestamptz then
    raise exception 'candidate cursor did not advance';
  end if;
  if v_next->>'capability' <> 'client_local_scheduler' then
    raise exception 'local candidate capability is not explicit';
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
    raise exception 'all-day candidate was not returned in its local civil window';
  end if;
  v_row := v_page->'candidates'->0;
  if v_row->>'event_id' <> '00000000-0000-4000-8000-00000000f303'
     or (v_row->>'fire_at')::timestamptz <> '2026-03-08T13:00:00Z'::timestamptz
     or v_row->>'all_day_local_time' <> '09:00:00'
     or v_row->>'occurrence_index' <> '0' then
    raise exception 'all-day fire_at does not use event-zone 09:00 civil policy';
  end if;
end;
$$;

-- Dart parity: spring gaps move forward and autumn folds choose the later UTC.
reset role;
do $$
begin
  if private.wall_time_to_instant(timestamp '2024-03-10 02:30:00', 'America/New_York') <> '2024-03-10T07:30:00Z'::timestamptz then
    raise exception 'spring gap did not move forward';
  end if;
  if private.wall_time_to_instant(timestamp '2024-11-03 01:30:00', 'America/New_York') <> '2024-11-03T06:30:00Z'::timestamptz then
    raise exception 'autumn fold did not choose the later instant';
  end if;
end;
$$;

-- An inactive membership cannot create or read a setting/candidate.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f103', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f103","role":"authenticated"}', false);
do $$
begin
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 900, 0::smallint, 2, 0);
    raise exception 'inactive member was allowed to set a reminder';
  exception when sqlstate '42501' then
    null;
  end;
end;
$$;
select public.set_notification_preferences(true, false, 0);
do $$
begin
  if jsonb_array_length(public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 10, null)->'candidates') <> 0 then
    raise exception 'inactive member received a reminder candidate';
  end if;
end;
$$;

-- Malformed cursors and stale optimistic-lock versions fail closed.
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000f101', false);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000f101","role":"authenticated"}', false);
do $$
begin
  begin
    perform public.reminder_candidates_for_user('2026-03-09T00:00:00Z', '2026-03-13T00:00:00Z', 10, 'not a cursor');
    raise exception 'malformed cursor was accepted';
  exception when sqlstate '22023' then
    null;
  end;
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 900, 0::smallint, 2, 99);
    raise exception 'stale setting version was accepted';
  exception when sqlstate '40001' then
    null;
  end;
  begin
    perform public.set_event_reminder('00000000-0000-4000-8000-00000000f301', 'local', true, 604801, 0::smallint, 2, 1);
    raise exception 'timed lead beyond seven days was accepted';
  exception when sqlstate '22023' then
    null;
  end;
end;
$$;

-- API roles cannot select tables; authenticated receives client RPC execution,
-- and only service_role receives worker wrappers.
reset role;
do $$
begin
  if has_table_privilege('authenticated', 'public.notification_preferences', 'select')
     or has_table_privilege('authenticated', 'public.event_reminder_settings', 'select')
     or has_table_privilege('anon', 'public.notification_preferences', 'select') then
    raise exception 'client table ACL unexpectedly exposed reminder rows';
  end if;
  if not has_function_privilege('authenticated', 'public.get_notification_preferences()', 'execute')
     or has_function_privilege('anon', 'public.get_notification_preferences()', 'execute')
     or has_function_privilege('authenticated', 'public.worker_claim_event_reminder_jobs(uuid,integer,timestamptz,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.worker_claim_event_reminder_jobs(uuid,integer,timestamptz,integer)', 'execute') then
    raise exception 'reminder function ACL boundary is incorrect';
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
    raise exception 'anonymous preference read was accepted';
  exception when insufficient_privilege or sqlstate '28000' then
    null;
  end;
end;
$$;
reset role;

-- Capability metadata is separate from provider credentials; no secret enters SQL.
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
    raise exception 'device registration leaked a bearer value';
  end if;
end;
$$;
select public.set_event_reminder('00000000-0000-4000-8000-00000000f304', 'push', true, 900, 0::smallint, 1, 0);
-- Two active devices exercise revocation scoping: removing one must preserve
-- pending work, while removing the last one must cancel it.
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
    raise exception 'device registration did not persist both private active tokens';
  end if;
end;
$$;

-- Prepare one push job for the device-revocation assertions before claiming
-- any worker rows. The temporary ID map lets an authenticated role revoke
-- exact rows without exposing private token data.
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
    raise exception 'revoking one of two active devices cancelled shared jobs';
  end if;
  select public.revoke_push_device(device_id) into v_second
  from reminder_fixture_devices where label = 'second';
  if v_second->>'cancelled_jobs' <> '1' then
    raise exception 'revoking the last active device did not cancel its jobs';
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
    raise exception 'last-device revocation left a nonterminal job or wrong reason';
  end if;
end;
$$;
-- A later device registration can reconcile a fresh pending revision; this
-- also leaves the recurring f304 rows below with an active delivery target.
set local role authenticated;
select public.register_push_device(
  'fcm', 'android', 'production', 'fixture-token-owner-3', 'fixture-install-owner-3'
);
reset role;

-- Participant lifecycle is terminal for reminder intent.  The f301 event
-- already has f102 in event_members from the runner's legacy setup.  Give that
-- participant a push setting/job, deactivate the membership, and verify the
-- composite event_members FK removes both the setting and its private jobs.
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
    raise exception 'participant reminder fixture did not create its setting/job';
  end if;
end;
$$;

-- Deactivation deletes event_members in the group-management RPC.  The
-- composite FK must cascade the setting and setting-owned jobs; no stale
-- enabled intent may survive to be restored by a later reactivation.
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
    raise exception 'participant removal did not cascade event reminder rows';
  end if;
end;
$$;

-- Reactivation changes only membership state.  It must not recreate the
-- removed event_members assignment or silently resurrect reminder intent.
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
    raise exception 'participant reactivation restored deleted reminder state';
  end if;
end;
$$;

-- Group leave follows the same path after a participant assignment is
-- explicitly added again.  Leaving removes the assignment and cascades its
-- setting/jobs; owner reactivation still does not restore either row.
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
    raise exception 'group leave did not cascade event reminder rows';
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
    raise exception 'group-leave reactivation restored reminder state';
  end if;
end;
$$;

-- Soft-deleting an event is terminal in the existing event integrity contract;
-- the reminder trigger therefore removes series-wide settings itself (the
-- setting_id FK removes any private jobs) rather than retaining intent that
-- could never be restored.
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
    raise exception 'soft-deleted event retained reminder state';
  end if;
end;
$$;

-- Reconciliation is idempotent and creates one job per recurrence occurrence.
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
    raise exception 'recurrence jobs were not deduplicated/claimed as expected';
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
    raise exception 'retry/dead-letter transition did not terminate both jobs';
  end if;
end;
$$;

-- A reconcile worker can be preparing T1 while a trigger enqueues T2 for the
-- same event. The dirty bit must cause T1 completion to requeue T2 rather than
-- losing the newer request (and the next claim must be able to take it).
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
    raise exception 'reconcile race fixture did not claim the target event';
  end if;
end;
$$;
-- Simulate the T2 event/setting trigger after T1 has claimed its lease.
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
    raise exception 'dirty reconcile completion lost the newer request';
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
    raise exception 'requeued reconcile request was not reclaimed';
  end if;
end;
$$;

-- An eighth-attempt worker crash must be terminalized even when its lease
-- expires before the occurrence fire_at. Otherwise the attempts<8 reclaim
-- guard would strand processing rows forever.
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
    raise exception 'expired eighth-attempt reconcile lease was not terminalized';
  end if;
  if (select count(*) from private.event_reminder_jobs
      where event_id = '00000000-0000-4000-8000-00000000f302'
        and status = 'dead_letter' and attempts = 8
        and lease_owner is null and lease_until is null
        and last_error_code = 'retry_exhausted') <> 1 then
    raise exception 'expired eighth-attempt job lease was not dead-lettered';
  end if;
end;
$$;

-- Account deletion cascades all reminder rows while preserving the old preflight shape.
delete from auth.users where id = '00000000-0000-4000-8000-00000000f101'::uuid;
do $$
begin
  if exists (select 1 from public.groups where id = '00000000-0000-4000-8000-00000000f201')
     or exists (select 1 from public.events where group_id = '00000000-0000-4000-8000-00000000f201')
     or exists (select 1 from public.notification_preferences where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from public.event_reminder_settings where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from private.push_device_tokens where user_id = '00000000-0000-4000-8000-00000000f101')
     or exists (select 1 from private.event_reminder_jobs where user_id = '00000000-0000-4000-8000-00000000f101') then
    raise exception 'account deletion did not cascade reminder data';
  end if;
end;
$$;

rollback;
