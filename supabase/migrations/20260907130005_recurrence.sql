-- 기능 2: 범위와 순번이 제한된 반복 일정 묶음이다.
--
-- 기존 public.events 행은 변경할 수 없는 논리적 묶음 기준점으로 유지한다. 단일
-- 일정은 event_recurrence_rules에 행이 없으며 계속 기능 5 events_for_range RPC를
-- 사용한다. 반복 일정은 호출자가 제공한 범위에 대해서만 확장하며 발생 행을
-- 구체화하지 않는다.
--
-- 이 마이그레이션은 Supabase CLI로 생성했으며 기존 일정/멤버/범위 마이그레이션
-- 뒤에 실행한다. 테이블은 기존 기능에 추가만 하며 모든 RPC는 이미 설치된
-- event_members 관계를 통해 참여자 상태를 확인한다.

begin;

create or replace function public.recurrence_occurrence_key(p_index bigint)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  -- 발생 도우미는 PostgreSQL 날짜/정수 연산을 사용한다. 공개 키 계약을 부호 있는
  -- 32비트 순번 범위로 제한해 불투명한 20자리 키가 날짜 오프셋을 넘치게 하거나
  -- 커서를 조용히 순환시키지 못하게 한다.
  if p_index is null or p_index < 0 or p_index > 2147483647::bigint then
    raise exception using errcode = '22023', message = 'occurrence index is outside the supported range';
  end if;
  return 'o' || pg_catalog.lpad(p_index::text, 20, '0');
end;
$$;

comment on function public.recurrence_occurrence_key(bigint) is
  '안정적인 반복 일정 식별자다. o 접두사가 붙은 ASCII 10진수 순번을 사용하며 단일 일정은 리터럴 single 키를 사용한다.';

create table if not exists public.event_recurrence_rules (
  id uuid primary key default extensions.gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  segment_no integer not null check (segment_no >= 0),
  start_occurrence_index bigint not null check (start_occurrence_index between 0 and 2147483647::bigint),
  end_occurrence_index bigint check (end_occurrence_index is null or end_occurrence_index between 1 and 2147483648::bigint),
  frequency text not null check (frequency in ('daily', 'weekly', 'monthly')),
  interval_value integer not null check (interval_value between 1 and 999),
  weekdays smallint[] not null default '{}'::smallint[],
  monthly_day smallint,
  end_mode text not null default 'never' check (end_mode in ('never', 'count', 'until')),
  occurrence_count integer,
  until_date date,
  anchor_local_date date not null,
  anchor_local_time time without time zone not null default '00:00:00',
  timezone text not null check (public.is_valid_timezone(timezone)),
  is_all_day boolean not null default false,
  duration_seconds bigint,
  duration_days integer,
  title text not null check (char_length(btrim(title)) between 1 and 240),
  description text not null default '' check (char_length(description) <= 10000),
  color_value bigint not null default 4282874742
    check (color_value between 0 and 4294967295),
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (event_id, segment_no),
  unique (event_id, start_occurrence_index),
  check (end_occurrence_index is null or end_occurrence_index > start_occurrence_index),
  check (
    (end_mode = 'never' and occurrence_count is null and until_date is null)
    or (end_mode = 'count' and occurrence_count is not null
      and occurrence_count between 1 and 1000000 and until_date is null)
    or (end_mode = 'until' and occurrence_count is null and until_date is not null)
  ),
  check (
    (is_all_day and duration_days is not null and duration_days between 1 and 366
      and duration_seconds is null)
    or (not is_all_day and duration_seconds is not null
      and duration_seconds between 1 and 31622400 and duration_days is null)
  ),
  check (
    (frequency = 'weekly' and pg_catalog.cardinality(weekdays) between 1 and 7)
    or (frequency <> 'weekly' and pg_catalog.cardinality(weekdays) = 0)
  ),
  check ((frequency = 'monthly' and monthly_day is not null and monthly_day between 1 and 31) or (frequency <> 'monthly' and monthly_day is null))
);

comment on table public.event_recurrence_rules is
  '변경할 수 없고 이력을 보존하는 반복 일정 구간이다. start/end 인덱스는 발생 키를 바꾸지 않고 향후 편집을 위해 묶음을 분할한다.';
comment on column public.event_recurrence_rules.start_occurrence_index is
  '이 구간 첫 발생의 포함형 전체 순번이다. 루트 구간은 0에서 시작한다.';
comment on column public.event_recurrence_rules.end_occurrence_index is
  '배타적 순번 경계다. NULL이면 이 구간에 끝이 없음을 뜻한다.';
comment on column public.event_recurrence_rules.anchor_local_time is
  'timezone의 현지 벽시계 시각이다. PostgreSQL은 DST 누락 시각을 앞으로 이동하고 중복 시각은 표준(첫 번째) 오프셋으로 해석한다.';

create index if not exists event_recurrence_rules_event_start_idx
  on public.event_recurrence_rules (event_id, start_occurrence_index, segment_no);
create index if not exists event_recurrence_rules_event_end_idx
  on public.event_recurrence_rules (event_id, end_occurrence_index);

create table if not exists public.event_occurrence_overrides (
  event_id uuid not null references public.events(id) on delete cascade,
  occurrence_index bigint not null check (occurrence_index between 0 and 2147483647::bigint),
  occurrence_key text not null,
  is_cancelled boolean not null default false,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  color_value bigint,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  primary key (event_id, occurrence_index),
  unique (event_id, occurrence_key),
  check (occurrence_key = public.recurrence_occurrence_key(occurrence_index)),
  check (
    (is_cancelled and title is null and description is null and starts_at is null and ends_at is null
      and timezone is null and is_all_day is null and all_day_start is null and all_day_end is null and color_value is null)
    or
    (not is_cancelled and title is not null and char_length(btrim(title)) between 1 and 240
      and description is not null and starts_at is not null and ends_at is not null and ends_at > starts_at
      and timezone is not null and public.is_valid_timezone(timezone)
      and is_all_day is not null
      and ((is_all_day and all_day_start is not null and all_day_end is not null and all_day_end > all_day_start)
        or (not is_all_day and all_day_start is null and all_day_end is null))
      and color_value is not null and color_value between 0 and 4294967295)
  )
);

comment on table public.event_occurrence_overrides is
  '안정적인 묶음 순번을 키로 사용하는 희소 전체 스냅샷/취소다. 행이 없으면 구간과 일정 표시 값을 상속한다.';

create index if not exists event_occurrence_overrides_event_key_idx
  on public.event_occurrence_overrides (event_id, occurrence_index);

-- 전체 스냅샷 예외는 발생을 제한된 예정 시각 조회 범위보다 더 멀리 옮길 수 있다.
-- 이 부분 인덱스를 사용하면 _event_occurrences_for_range의 유효 시각 합집합이
-- 취소되거나 불완전한 항목을 스캔하지 않고 해당 행을 찾을 수 있다.
create index if not exists event_occurrence_overrides_effective_start_idx
  on public.event_occurrence_overrides (starts_at, event_id, occurrence_index)
  where not is_cancelled and starts_at is not null and ends_at is not null;
create index if not exists event_occurrence_overrides_effective_end_idx
  on public.event_occurrence_overrides (ends_at, event_id, occurrence_index)
  where not is_cancelled and starts_at is not null and ends_at is not null;
create index if not exists event_occurrence_overrides_effective_all_day_start_idx
  on public.event_occurrence_overrides (all_day_start, event_id, occurrence_index)
  where not is_cancelled and is_all_day and all_day_start is not null and all_day_end is not null;
create index if not exists event_occurrence_overrides_effective_all_day_end_idx
  on public.event_occurrence_overrides (all_day_end, event_id, occurrence_index)
  where not is_cancelled and is_all_day and all_day_start is not null and all_day_end is not null;

-- 재정의 페이로드는 전체 스냅샷이다. 종일 예외에는 기준 일정과 같은 현지 날짜
-- 불변 조건을 유지하고 종일 및 시간 지정 기간을 모두 제한한다. 따라서 악의적인
-- 소유자/서비스 직접 쓰기가 범위 제한 발생 계약을 우회할 수 없다. 클라이언트
-- 역할에는 테이블 권한이 없다.
create or replace function public.enforce_occurrence_override_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not new.is_cancelled then
    if new.is_all_day
       and ((new.starts_at at time zone new.timezone) <> new.all_day_start::timestamp
         or (new.ends_at at time zone new.timezone) <> new.all_day_end::timestamp) then
      raise exception using errcode = '22023', message = 'all-day override dates must match local timestamps';
    end if;
    if new.is_all_day and new.all_day_end - new.all_day_start > 366 then
      raise exception using errcode = '22023', message = 'all-day override duration must not exceed 366 days';
    end if;
    if not new.is_all_day and
       (extract(epoch from ((new.ends_at at time zone new.timezone)
                            - (new.starts_at at time zone new.timezone))) is null
        or extract(epoch from ((new.ends_at at time zone new.timezone)
                               - (new.starts_at at time zone new.timezone))) not between 1 and 31622400) then
      raise exception using errcode = '22023', message = 'timed override duration must not exceed 366 days';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists event_occurrence_override_integrity on public.event_occurrence_overrides;
create trigger event_occurrence_override_integrity
before insert or update on public.event_occurrence_overrides
for each row execute function public.enforce_occurrence_override_integrity();

-- 정규 요일 배열과 겹치지 않는 구간 범위를 트리거 하나에서 강제한다. CHECK 식에는
-- 하위 쿼리를 넣을 수 없으므로 하위 쓰기 경계를 약화하지 않고 트리거에 둔다.
create or replace function public.enforce_recurrence_rule_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_weekdays smallint[];
  v_event_group uuid;
begin
  if new.start_occurrence_index < 0 or new.start_occurrence_index > 2147483647::bigint
     or (new.end_occurrence_index is not null
         and (new.end_occurrence_index <= new.start_occurrence_index
              or new.end_occurrence_index > 2147483648::bigint)) then
    raise exception using errcode = '22023', message = 'recurrence ordinal is outside the supported range';
  end if;
  if new.weekdays is null then
    raise exception using errcode = '22023', message = 'weekdays cannot be null';
  end if;
  if exists (
    select 1 from pg_catalog.unnest(new.weekdays) as supplied(value)
    where supplied.value is null
  ) then
    raise exception using errcode = '22023', message = 'weekdays cannot contain null';
  end if;

  select coalesce(pg_catalog.array_agg(day_value order by day_value), '{}'::smallint[])
    into v_weekdays
  from (
    select distinct value::smallint as day_value
    from pg_catalog.unnest(new.weekdays) as supplied(value)
  ) days;
  if v_weekdays <> new.weekdays then
    raise exception using errcode = '22023', message = 'weekdays must be sorted and distinct ISO values';
  end if;
  if exists (
    select 1 from pg_catalog.unnest(new.weekdays) as supplied(value)
    where supplied.value < 1 or supplied.value > 7
  ) then
    raise exception using errcode = '22023', message = 'weekdays must contain ISO values 1 through 7';
  end if;

  if new.frequency = 'weekly'
     and not exists (
       select 1
       from pg_catalog.unnest(new.weekdays) as supplied(value)
       where supplied.value = extract(isodow from new.anchor_local_date)::smallint
     ) then
    raise exception using errcode = '22023', message = 'weekly weekdays must include the anchor day';
  end if;

  select e.group_id into v_event_group
  from public.events e
  where e.id = new.event_id;
  if v_event_group is null then
    raise exception using errcode = '23503', message = 'recurrence event does not exist';
  end if;

  if exists (
    select 1
    from public.event_recurrence_rules other_rule
    where other_rule.event_id = new.event_id
      and other_rule.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
      and int8range(other_rule.start_occurrence_index,
                    coalesce(other_rule.end_occurrence_index, 9223372036854775807::bigint), '[)')
          && int8range(new.start_occurrence_index,
                       coalesce(new.end_occurrence_index, 9223372036854775807::bigint), '[)')
  ) then
    raise exception using errcode = '23514', message = 'recurrence segments overlap';
  end if;
  return new;
end;
$$;

drop trigger if exists event_recurrence_rule_integrity on public.event_recurrence_rules;
create trigger event_recurrence_rule_integrity
before insert or update on public.event_recurrence_rules
for each row execute function public.enforce_recurrence_rule_integrity();

create or replace function public.touch_recurrence_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

drop trigger if exists event_recurrence_rules_touch_updated_at on public.event_recurrence_rules;
create trigger event_recurrence_rules_touch_updated_at
before update on public.event_recurrence_rules
for each row execute function public.touch_recurrence_updated_at();
drop trigger if exists event_occurrence_overrides_touch_updated_at on public.event_occurrence_overrides;
create trigger event_occurrence_overrides_touch_updated_at
before update on public.event_occurrence_overrides
for each row execute function public.touch_recurrence_updated_at();

-- 하위 테이블을 public에 노출한 것은 방어 목적일 뿐이다. 호출자에게 직접 권한이
-- 없고 이후 마이그레이션이 권한을 추가해도 정책은 실패 시 차단한다. 참여자 할당은
-- 계속 묶음의 event_members 하위 테이블에 둔다.
alter table public.event_recurrence_rules enable row level security;
alter table public.event_occurrence_overrides enable row level security;
drop policy if exists event_recurrence_rules_select on public.event_recurrence_rules;
drop policy if exists event_recurrence_rules_write_deny on public.event_recurrence_rules;
drop policy if exists event_occurrence_overrides_select on public.event_occurrence_overrides;
drop policy if exists event_occurrence_overrides_write_deny on public.event_occurrence_overrides;

create policy event_recurrence_rules_select
on public.event_recurrence_rules
for select to authenticated
using (
  (select auth.uid()) is not null
  and exists (
    select 1
    from public.events e
    join public.groups g on g.id = e.group_id
    where e.id = event_recurrence_rules.event_id
      and e.deleted_at is null
      and g.deleted_at is null
      and public.is_active_member(e.group_id)
  )
);
create policy event_recurrence_rules_write_deny
on public.event_recurrence_rules
for all to authenticated
using (false)
with check (false);
create policy event_occurrence_overrides_select
on public.event_occurrence_overrides
for select to authenticated
using (
  (select auth.uid()) is not null
  and exists (
    select 1
    from public.events e
    join public.groups g on g.id = e.group_id
    where e.id = event_occurrence_overrides.event_id
      and e.deleted_at is null
      and g.deleted_at is null
      and public.is_active_member(e.group_id)
  )
);
create policy event_occurrence_overrides_write_deny
on public.event_occurrence_overrides
for all to authenticated
using (false)
with check (false);

revoke all on table public.event_recurrence_rules from public, anon, authenticated;
revoke all on table public.event_occurrence_overrides from public, anon, authenticated;

-- 어느 하위 테이블도 supabase_realtime에 추가하지 않는다. 허용된 모든 범위 변경은
-- 게시된 상위 events.version을 한 번 올려 무효화 신호로 사용하며, DELETE 페이로드를
-- 통해 희소 예외 행이 노출되는 것을 막는다.

-- 지점/범위 행은 이전 일정 열에 명시적인 묶음 및 발생 식별자를 더한다. 재정의가
-- 없으면 occurrence_version은 0이다. recurrence_rule은 정확히 {frequency,
-- interval,weekdays,end,count,until_date,monthly_day}를 사용하며 멤버는 묶음 전체의
-- event_members 행으로 유지한다.
create or replace function public._event_occurrence_at_index(
  p_event_id uuid,
  p_occurrence_index bigint
)
returns table (
  id uuid,
  event_id uuid,
  series_id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[],
  occurrence_key text,
  occurrence_index bigint,
  occurrence_version integer,
  is_occurrence boolean,
  scheduled_starts_at timestamptz,
  scheduled_ends_at timestamptz,
  recurrence_rule jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_rule public.event_recurrence_rules;
  v_override public.event_occurrence_overrides;
  v_offset bigint;
  v_week_count integer;
  v_week_position integer;
  v_week_number bigint;
  v_anchor_weekday_position integer;
  v_week_sequence bigint;
  v_week_start date;
  v_month_offset bigint;
  v_month_start date;
  v_month_last date;
  v_occurrence_date date;
  v_local_start timestamp;
  v_local_end timestamp;
  v_scheduled_start timestamptz;
  v_scheduled_end timestamptz;
  v_effective_start timestamptz;
  v_effective_end timestamptz;
  v_occurrence_key text;
  v_member_ids uuid[];
begin
  select e.* into v_event
  from public.events e
  where e.id = p_event_id;
  if not found or v_event.deleted_at is not null then
    return;
  end if;

  -- 구체화기는 의도적으로 부호 있는 int4/날짜 오프셋 범위 안에서 동작한다. 해당
  -- 범위 밖의 불투명한 20자리 키는 날짜 연산을 넘치게 하지 않고 존재하지 않는
  -- 발생으로 취급한다.
  if p_occurrence_index is not null and p_occurrence_index > 2147483647::bigint then
    return;
  end if;

  -- 음수 표식은 이 도우미 전용이며 이전 단일 일정을 나타낸다. 반복 순번은 항상
  -- 음이 아니다.
  if p_occurrence_index = -1
     and not exists (select 1 from public.event_recurrence_rules r where r.event_id = p_event_id) then
    return query
    select v_event.id, v_event.id, v_event.id, v_event.group_id, v_event.created_by,
           v_event.title, v_event.description, v_event.starts_at, v_event.ends_at,
           v_event.timezone, v_event.is_all_day, v_event.all_day_start,
           v_event.all_day_end, v_event.version, v_event.deleted_at,
           v_event.created_at, v_event.updated_at, v_event.color_value,
           coalesce((select pg_catalog.array_agg(em.user_id order by em.user_id)
                     from public.event_members em
                     join public.memberships m on m.group_id = v_event.group_id
                       and m.user_id = em.user_id and m.is_active and m.removed_at is null
                     where em.event_id = v_event.id), '{}'::uuid[]),
           'single'::text, null::bigint, 0, false,
           v_event.starts_at, v_event.ends_at, null::jsonb;
    return;
  end if;
  if p_occurrence_index is null or p_occurrence_index < 0 then
    return;
  end if;

  for v_rule in
    select r.*
    from public.event_recurrence_rules r
    where r.event_id = p_event_id
      and p_occurrence_index >= r.start_occurrence_index
      and (r.end_occurrence_index is null or p_occurrence_index < r.end_occurrence_index)
    order by r.start_occurrence_index, r.segment_no
  loop
    v_offset := p_occurrence_index - v_rule.start_occurrence_index;
    if v_rule.end_mode = 'count' and v_offset >= v_rule.occurrence_count then
      continue;
    end if;

    -- 순번 자체가 지원하는 int4 키 범위 안이어도 날짜, 월, 타임스탬프 및 시간대
    -- 연산은 넘칠 수 있다. 예를 들어 9999-12-31을 기준으로 한 순번 2147483647이
    -- 그렇다. PostgreSQL 22008/22003을 호출자에게 노출하지 않고 해당 행이 없는
    -- 것으로 취급한다.
    begin
      if v_rule.frequency = 'daily' then
        if v_offset::numeric * v_rule.interval_value > 2147483647
           or v_offset::numeric * v_rule.interval_value < -2147483648 then
          continue;
        end if;
        v_occurrence_date := v_rule.anchor_local_date
          + (v_offset * v_rule.interval_value)::integer;
      elsif v_rule.frequency = 'weekly' then
        v_week_count := pg_catalog.cardinality(v_rule.weekdays);
        -- 선택한 요일이 정렬된 요일 목록 중간에 있어도 첫 순번이 구간 기준점이다.
        -- 순번 0인 더 이른 발생을 만들지 말고 해당 기준점부터 순서를 회전한다.
        v_anchor_weekday_position := pg_catalog.array_position(
          v_rule.weekdays,
          extract(isodow from v_rule.anchor_local_date)::smallint
        ) - 1;
        v_week_sequence := v_anchor_weekday_position + v_offset;
        v_week_position := (v_week_sequence % v_week_count)::integer;
        v_week_number := v_week_sequence / v_week_count;
        v_week_start := v_rule.anchor_local_date
          - (extract(isodow from v_rule.anchor_local_date)::integer - 1);
        if v_week_number::numeric * v_rule.interval_value * 7
             + v_rule.weekdays[v_week_position + 1] - 1 > 2147483647
           or v_week_number::numeric * v_rule.interval_value * 7
             + v_rule.weekdays[v_week_position + 1] - 1 < -2147483648 then
          continue;
        end if;
        v_occurrence_date := v_week_start
          + (v_week_number * v_rule.interval_value * 7
             + v_rule.weekdays[v_week_position + 1] - 1)::integer;
        if v_occurrence_date < v_rule.anchor_local_date then
          continue;
        end if;
      else
        v_month_offset := v_offset * v_rule.interval_value;
        if v_month_offset > 2147483647::bigint or v_month_offset < -2147483648::bigint then
          continue;
        end if;
        v_month_start := (date_trunc('month', v_rule.anchor_local_date)
          + (v_month_offset::integer * interval '1 month'))::date;
        v_month_last := (date_trunc('month', v_month_start)
          + interval '1 month - 1 day')::date;
        v_occurrence_date := v_month_start
          + least(v_rule.monthly_day, extract(day from v_month_last)::integer) - 1;
      end if;

      if v_rule.end_mode = 'until' and v_occurrence_date > v_rule.until_date then
        continue;
      end if;

      if v_rule.is_all_day then
        v_local_start := v_occurrence_date::timestamp;
        v_local_end := (v_occurrence_date + v_rule.duration_days)::timestamp;
      else
        v_local_start := v_occurrence_date::timestamp + v_rule.anchor_local_time;
        v_local_end := v_local_start + (v_rule.duration_seconds * interval '1 second');
      end if;
      v_scheduled_start := v_local_start at time zone v_rule.timezone;
      v_scheduled_end := v_local_end at time zone v_rule.timezone;
    exception
      when sqlstate '22008' then
        return;
      when sqlstate '22003' then
        return;
    end;
    v_occurrence_key := public.recurrence_occurrence_key(p_occurrence_index);

    select o.* into v_override
    from public.event_occurrence_overrides o
    where o.event_id = p_event_id
      and o.occurrence_index = p_occurrence_index;
    if found and v_override.is_cancelled then
      return;
    end if;

    select coalesce(pg_catalog.array_agg(em.user_id order by em.user_id), '{}'::uuid[])
      into v_member_ids
    from public.event_members em
    join public.memberships m on m.group_id = v_event.group_id
      and m.user_id = em.user_id and m.is_active and m.removed_at is null
    where em.event_id = v_event.id;

    v_effective_start := coalesce(v_override.starts_at, v_scheduled_start);
    v_effective_end := coalesce(v_override.ends_at, v_scheduled_end);
    return query
    select v_event.id, v_event.id, v_event.id, v_event.group_id, v_event.created_by,
           coalesce(v_override.title, v_rule.title),
           coalesce(v_override.description, v_rule.description),
           v_effective_start, v_effective_end,
           coalesce(v_override.timezone, v_rule.timezone),
           coalesce(v_override.is_all_day, v_rule.is_all_day),
           coalesce(v_override.all_day_start,
             case when v_rule.is_all_day then v_occurrence_date end),
           coalesce(v_override.all_day_end,
             case when v_rule.is_all_day then v_occurrence_date + v_rule.duration_days end),
           v_event.version, v_event.deleted_at, v_event.created_at,
           v_event.updated_at, coalesce(v_override.color_value, v_rule.color_value),
           v_member_ids, v_occurrence_key, p_occurrence_index,
           coalesce(v_override.version, 0), true, v_scheduled_start,
           v_scheduled_end,
           pg_catalog.jsonb_build_object(
             'frequency', v_rule.frequency,
             'interval', v_rule.interval_value,
             'weekdays', to_jsonb(v_rule.weekdays),
             'end', v_rule.end_mode,
             'count', v_rule.occurrence_count,
             'until_date', v_rule.until_date,
             'monthly_day', v_rule.monthly_day
           );
    return;
  end loop;
end;
$$;

create or replace function public._event_occurrences_for_range(
  p_event_id uuid,
  p_range_start timestamptz,
  p_range_end timestamptz,
  p_view_timezone text
)
returns table (
  id uuid,
  event_id uuid,
  series_id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[],
  occurrence_key text,
  occurrence_index bigint,
  occurrence_version integer,
  is_occurrence boolean,
  scheduled_starts_at timestamptz,
  scheduled_ends_at timestamptz,
  recurrence_rule jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_rule public.event_recurrence_rules;
  v_first bigint;
  v_last bigint;
  v_offset_start bigint;
  v_offset_end bigint;
  v_week_start date;
  v_week_first bigint;
  v_week_last bigint;
  v_month_start date;
  v_month_end date;
  v_anchor_month integer;
  v_range_month integer;
  v_i bigint;
  v_row record;
  v_override record;
  v_seen_indexes bigint[] := '{}'::bigint[];
begin
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found or v_event.deleted_at is not null then
    return;
  end if;

  if not exists (select 1 from public.event_recurrence_rules r where r.event_id = p_event_id) then
    for v_row in
      select * from public._event_occurrence_at_index(p_event_id, -1)
    loop
      if ((not v_row.is_all_day and v_row.starts_at < p_range_end and v_row.ends_at > p_range_start)
          or (v_row.is_all_day
            and v_row.all_day_start < (p_range_end at time zone p_view_timezone)::date
            and v_row.all_day_end > (p_range_start at time zone p_view_timezone)::date)) then
        return query select v_row.id, v_row.event_id, v_row.series_id,
          v_row.group_id, v_row.created_by, v_row.title, v_row.description,
          v_row.starts_at, v_row.ends_at, v_row.timezone, v_row.is_all_day,
          v_row.all_day_start, v_row.all_day_end, v_row.version,
          v_row.deleted_at, v_row.created_at, v_row.updated_at,
          v_row.color_value, v_row.member_ids, v_row.occurrence_key,
          v_row.occurrence_index, v_row.occurrence_version, v_row.is_occurrence,
          v_row.scheduled_starts_at, v_row.scheduled_ends_at,
          v_row.recurrence_rule;
      end if;
    end loop;
    return;
  end if;

  for v_rule in
    select r.* from public.event_recurrence_rules r
    where r.event_id = p_event_id
    order by r.start_occurrence_index, r.segment_no
  loop
    -- 범위는 요청한 현지 시간 창에서 구한다. 가능한 기간별 하루 단위 이전 조회를
    -- 366일로 제한하므로 아주 오래된 기준점이 있는 일정도 제한 없는 묶음 스캔을
    -- 일으키지 않는다.
    v_month_start := (p_range_start at time zone v_rule.timezone)::date - 366;
    v_month_end := (p_range_end at time zone v_rule.timezone)::date + 1;
    if v_rule.frequency = 'daily' then
      v_offset_start := floor(((v_month_start - v_rule.anchor_local_date)::numeric)
        / v_rule.interval_value)::bigint - 1;
      v_offset_end := ceil(((v_month_end - v_rule.anchor_local_date)::numeric)
        / v_rule.interval_value)::bigint + 1;
      v_first := greatest(v_rule.start_occurrence_index,
        v_rule.start_occurrence_index + greatest(v_offset_start, 0));
      v_last := v_rule.start_occurrence_index + greatest(v_offset_end, 0);
    elsif v_rule.frequency = 'weekly' then
      v_week_start := v_rule.anchor_local_date
        - (extract(isodow from v_rule.anchor_local_date)::integer - 1);
      v_week_first := floor(((v_month_start - v_week_start)::numeric)
        / (7 * v_rule.interval_value))::bigint - 1;
      v_week_last := ceil(((v_month_end - v_week_start)::numeric)
        / (7 * v_rule.interval_value))::bigint + 1;
      v_first := greatest(v_rule.start_occurrence_index,
        v_rule.start_occurrence_index + greatest(v_week_first, 0)
          * pg_catalog.cardinality(v_rule.weekdays) - pg_catalog.cardinality(v_rule.weekdays));
      v_last := v_rule.start_occurrence_index
        + greatest(v_week_last, 0) * pg_catalog.cardinality(v_rule.weekdays)
        + pg_catalog.cardinality(v_rule.weekdays);
    else
      v_anchor_month := extract(year from v_rule.anchor_local_date)::integer * 12
        + extract(month from v_rule.anchor_local_date)::integer;
      v_range_month := extract(year from v_month_start)::integer * 12
        + extract(month from v_month_start)::integer;
      v_offset_start := floor(((v_range_month - v_anchor_month)::numeric)
        / v_rule.interval_value)::bigint - 1;
      v_range_month := extract(year from v_month_end)::integer * 12
        + extract(month from v_month_end)::integer;
      v_offset_end := ceil(((v_range_month - v_anchor_month)::numeric)
        / v_rule.interval_value)::bigint + 1;
      v_first := greatest(v_rule.start_occurrence_index,
        v_rule.start_occurrence_index + greatest(v_offset_start, 0));
      v_last := v_rule.start_occurrence_index + greatest(v_offset_end, 0);
    end if;
    if v_rule.end_mode = 'count' then
      v_last := least(v_last, v_rule.start_occurrence_index + v_rule.occurrence_count - 1);
    end if;
    if v_rule.end_occurrence_index is not null then
      v_last := least(v_last, v_rule.end_occurrence_index - 1);
    end if;
    if v_last < v_first then
      continue;
    end if;
    -- 방어적 상한이다. 매주 요일 일곱 개여도 위 수식은 366일 창보다 조금 큰
    -- 정도여야 한다. 잘못된 이전 행이 범위 조회를 무한 반복으로 바꾸는 것을 막는다.
    if v_last - v_first > 2000 then
      v_last := v_first + 2000;
    end if;
    for v_i in v_first..v_last loop
      for v_row in select * from public._event_occurrence_at_index(p_event_id, v_i)
      loop
        if (not v_row.is_all_day and v_row.starts_at < p_range_end and v_row.ends_at > p_range_start)
           or (v_row.is_all_day
             and v_row.all_day_start < (p_range_end at time zone p_view_timezone)::date
             and v_row.all_day_end > (p_range_start at time zone p_view_timezone)::date) then
          v_seen_indexes := pg_catalog.array_append(v_seen_indexes, v_row.occurrence_index);
          return query select v_row.id, v_row.event_id, v_row.series_id,
            v_row.group_id, v_row.created_by, v_row.title, v_row.description,
            v_row.starts_at, v_row.ends_at, v_row.timezone, v_row.is_all_day,
            v_row.all_day_start, v_row.all_day_end, v_row.version,
            v_row.deleted_at, v_row.created_at, v_row.updated_at,
            v_row.color_value, v_row.member_ids, v_row.occurrence_key,
            v_row.occurrence_index, v_row.occurrence_version, v_row.is_occurrence,
            v_row.scheduled_starts_at, v_row.scheduled_ends_at,
            v_row.recurrence_rule;
        end if;
      end loop;
    end loop;
  end loop;

  -- 이동한 전체 스냅샷 재정의는 예정 순번에서 여러 해 떨어져 있을 수 있다. 요청
  -- 창 안의 인덱싱된 시각으로 유효한 미취소 스냅샷을 찾은 다음 같은 형식의 행을
  -- 구체화기에 요청하여 상속, 취소 및 키 식별을 중앙화한다. 확인한 집합은 예정/
  -- 재정의 중복과 창 밖으로 이동한 행을 억제한다.
  for v_override in
    select o.*
    from public.event_occurrence_overrides o
    where o.event_id = p_event_id
      and not o.is_cancelled
      and o.starts_at is not null and o.ends_at is not null
      and (
        (not o.is_all_day and o.starts_at < p_range_end and o.ends_at > p_range_start)
        or (o.is_all_day
          and o.all_day_start < (p_range_end at time zone p_view_timezone)::date
          and o.all_day_end > (p_range_start at time zone p_view_timezone)::date)
      )
    order by o.starts_at, o.event_id, o.occurrence_index
  loop
    if v_override.occurrence_index = any(v_seen_indexes) then
      continue;
    end if;
    for v_row in
      select * from public._event_occurrence_at_index(p_event_id, v_override.occurrence_index)
    loop
      if v_row.occurrence_index = any(v_seen_indexes) then
        continue;
      end if;
      if (not v_row.is_all_day and v_row.starts_at < p_range_end and v_row.ends_at > p_range_start)
         or (v_row.is_all_day
           and v_row.all_day_start < (p_range_end at time zone p_view_timezone)::date
           and v_row.all_day_end > (p_range_start at time zone p_view_timezone)::date) then
        v_seen_indexes := pg_catalog.array_append(v_seen_indexes, v_row.occurrence_index);
        return query select v_row.id, v_row.event_id, v_row.series_id,
          v_row.group_id, v_row.created_by, v_row.title, v_row.description,
          v_row.starts_at, v_row.ends_at, v_row.timezone, v_row.is_all_day,
          v_row.all_day_start, v_row.all_day_end, v_row.version,
          v_row.deleted_at, v_row.created_at, v_row.updated_at,
          v_row.color_value, v_row.member_ids, v_row.occurrence_key,
          v_row.occurrence_index, v_row.occurrence_version, v_row.is_occurrence,
          v_row.scheduled_starts_at, v_row.scheduled_ends_at,
          v_row.recurrence_rule;
      end if;
    end loop;
  end loop;
end;
$$;

-- 반복 일정 생성은 create_event_with_members와 같은 방식이며 첫 발생 행을 반환한다.
-- 따라서 Dart에서 생성 및 지점/범위 조회에 하나의 형식화된 응답 형태를 쓸 수 있다.
create or replace function public.create_recurring_event_with_members(
  p_group_id uuid,
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_is_all_day boolean,
  p_all_day_start date,
  p_all_day_end date,
  p_color_value bigint,
  p_member_ids uuid[],
  p_frequency text,
  p_interval integer,
  p_weekdays smallint[],
  p_end text,
  p_count integer,
  p_until_date date,
  p_monthly_day smallint
)
returns table (
  id uuid, event_id uuid, series_id uuid, group_id uuid, created_by uuid,
  title text, description text, starts_at timestamptz, ends_at timestamptz,
  timezone text, is_all_day boolean, all_day_start date, all_day_end date,
  version integer, deleted_at timestamptz, created_at timestamptz,
  updated_at timestamptz, color_value bigint, member_ids uuid[],
  occurrence_key text, occurrence_index bigint, occurrence_version integer,
  is_occurrence boolean, scheduled_starts_at timestamptz,
  scheduled_ends_at timestamptz, recurrence_rule jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_group public.groups;
  v_membership public.memberships;
  v_event public.events;
  v_anchor_local timestamp;
  v_weekdays smallint[];
  v_member_ids uuid[];
  v_lock_user_ids uuid[];
  v_lock_user_id uuid;
  v_locked_user_count integer := 0;
  v_valid_count integer;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_frequency is null or p_frequency not in ('daily', 'weekly', 'monthly')
     or p_interval is null or p_interval not between 1 and 999
     or p_end is null or p_end not in ('never', 'count', 'until') then
    raise exception using errcode = '22023', message = 'invalid recurrence rule';
  end if;
  if p_end = 'count' and (p_count is null or p_count not between 1 and 1000000) then
    raise exception using errcode = '22023', message = 'count must be between 1 and 1000000';
  end if;
  if p_end = 'until' and p_until_date is null then
    raise exception using errcode = '22023', message = 'until_date is required';
  end if;
  if p_end <> 'count' and p_count is not null then
    raise exception using errcode = '22023', message = 'count is only valid with end=count';
  end if;
  if p_end <> 'until' and p_until_date is not null then
    raise exception using errcode = '22023', message = 'until_date is only valid with end=until';
  end if;
  if p_frequency <> 'monthly' and p_monthly_day is not null then
    raise exception using errcode = '22023', message = 'monthly_day is only valid with frequency=monthly';
  end if;
  if p_starts_at is null or p_ends_at is null
     or not pg_catalog.isfinite(p_starts_at) or not pg_catalog.isfinite(p_ends_at)
     or p_ends_at <= p_starts_at then
    raise exception using errcode = '22023', message = 'event boundaries are invalid';
  end if;
  if not public.is_valid_timezone(coalesce(p_timezone, 'UTC')) then
    raise exception using errcode = '22023', message = 'timezone must be an IANA timezone name';
  end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 240
     or p_description is not null and char_length(p_description) > 10000
     or p_is_all_day is null
     or p_color_value is not null and p_color_value not between 0 and 4294967295
     or (not coalesce(p_is_all_day, false)
         and (p_all_day_start is not null or p_all_day_end is not null)) then
    raise exception using errcode = '22023', message = 'event fields are invalid';
  end if;

  -- 그룹이나 일정을 잠그기 전에 전체 참여자 집합을 정규화하고 검증한다. 요청자는
  -- 항상 참여자이므로 NULL 및 명시적 목록 모두에서 기존 일정-멤버 불변 조건을 보존한다.
  if p_member_ids is null then
    v_member_ids := array[v_actor]::uuid[];
  else
    if exists (select 1 from pg_catalog.unnest(p_member_ids) x where x is null) then
      raise exception using errcode = '22023', message = 'member_ids cannot contain null';
    end if;
    select coalesce(pg_catalog.array_agg(x order by x), '{}'::uuid[]) into v_member_ids
    from (select distinct x from pg_catalog.unnest(p_member_ids) supplied(x)) ids;
  end if;
  if not (v_actor = any(v_member_ids)) then
    raise exception using errcode = '42501', message = 'event creator must remain an active participant';
  end if;
  if p_weekdays is null then
    raise exception using errcode = '22023', message = 'weekdays cannot be null';
  end if;
  if exists (select 1 from pg_catalog.unnest(p_weekdays) supplied(value)
             where supplied.value is null or supplied.value < 1 or supplied.value > 7) then
    raise exception using errcode = '22023', message = 'weekdays must contain sorted ISO values 1 through 7';
  end if;
  select coalesce(pg_catalog.array_agg(day_value order by day_value), '{}'::smallint[])
    into v_weekdays
  from (select distinct value::smallint as day_value
        from pg_catalog.unnest(p_weekdays) supplied(value)) days;
  if v_weekdays <> p_weekdays then
    raise exception using errcode = '22023', message = 'weekdays must be sorted and distinct ISO values';
  end if;

  -- 그룹, 일정 및 하위 잠금보다 먼저 요청자와 요청한 모든 auth.users 행을 UUID
  -- 순서로 잠근다. 따라서 계정 삭제가 반복 일정 생성과 경합하거나 부분 참여자
  -- 할당을 만들 수 없다.
  select coalesce(pg_catalog.array_agg(ids.id order by ids.id), '{}'::uuid[])
    into v_lock_user_ids
  from (
    select v_actor as id
    union
    select supplied.user_id from pg_catalog.unnest(v_member_ids) supplied(user_id)
  ) ids;
  v_locked_user_count := 0;
  for v_lock_user_id in
    select u.id from auth.users u
    where u.id = any(v_lock_user_ids)
    order by u.id
    for key share
  loop
    v_locked_user_count := v_locked_user_count + 1;
  end loop;
  if v_locked_user_count <> coalesce(pg_catalog.array_length(v_lock_user_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must have accounts';
  end if;

  select g.* into v_group from public.groups g where g.id = p_group_id for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'group was archived or is unavailable';
  end if;
  select m.* into v_membership from public.memberships m
  where m.group_id = p_group_id and m.user_id = v_actor for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using errcode = '42501', message = 'only an active group member can create events';
  end if;

  v_anchor_local := p_starts_at at time zone coalesce(p_timezone, 'UTC');
  if p_end = 'until' and p_until_date <
      (case when p_is_all_day then p_all_day_start else v_anchor_local::date end) then
    raise exception using errcode = '22023', message = 'until_date must include the anchor date';
  end if;
  if p_frequency = 'weekly' then
    if pg_catalog.cardinality(v_weekdays) = 0 then
      v_weekdays := array[extract(isodow from v_anchor_local::date)::smallint];
    end if;
  elsif pg_catalog.cardinality(v_weekdays) <> 0 then
    raise exception using errcode = '22023', message = 'only weekly rules accept weekdays';
  end if;
  if p_frequency = 'monthly' and coalesce(p_monthly_day, extract(day from v_anchor_local)::smallint) not between 1 and 31 then
    raise exception using errcode = '22023', message = 'monthly_day must be between 1 and 31';
  end if;
  if p_is_all_day and (p_all_day_start is null or p_all_day_end is null or p_all_day_end <= p_all_day_start) then
    raise exception using errcode = '22023', message = 'all-day dates must be a positive half-open range';
  end if;
  if p_is_all_day and p_all_day_end - p_all_day_start > 366 then
    raise exception using errcode = '22023', message = 'all-day duration must not exceed 366 days';
  end if;
  if not p_is_all_day and
     extract(epoch from ((p_ends_at at time zone coalesce(p_timezone, 'UTC'))
                         - (p_starts_at at time zone coalesce(p_timezone, 'UTC')))) not between 1 and 31622400 then
    raise exception using errcode = '22023', message = 'timed duration must not exceed 366 days';
  end if;

  perform 1 from public.memberships m
  where m.group_id = p_group_id and m.user_id = any(v_member_ids)
  order by m.user_id for update;
  select count(*)::integer into v_valid_count from public.memberships m
  where m.group_id = p_group_id and m.user_id = any(v_member_ids)
    and m.is_active and m.removed_at is null;
  if v_valid_count <> coalesce(pg_catalog.array_length(v_member_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must be active members of the group';
  end if;

  perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
  insert into public.events (
    group_id, created_by, title, description, starts_at, ends_at, timezone,
    is_all_day, all_day_start, all_day_end, color_value, version
  ) values (
    p_group_id, v_actor, p_title, coalesce(p_description, ''), p_starts_at, p_ends_at,
    coalesce(p_timezone, 'UTC'), coalesce(p_is_all_day, false), p_all_day_start,
    p_all_day_end, coalesce(p_color_value, 4282874742), 1
  ) returning * into v_event;
  insert into public.event_members(event_id, user_id)
  select v_event.id, x from pg_catalog.unnest(v_member_ids) ids(x);
  perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);

  insert into public.event_recurrence_rules (
    event_id, segment_no, start_occurrence_index, frequency, interval_value,
    weekdays, monthly_day, end_mode, occurrence_count, until_date,
    anchor_local_date, anchor_local_time, timezone, is_all_day,
    duration_seconds, duration_days, title, description, color_value
  ) values (
    v_event.id, 0, 0, p_frequency, p_interval, v_weekdays,
    case when p_frequency = 'monthly' then coalesce(p_monthly_day, extract(day from v_anchor_local)::smallint) end,
    p_end, p_count, p_until_date, v_anchor_local::date,
    v_anchor_local::time, coalesce(p_timezone, 'UTC'), coalesce(p_is_all_day, false),
    case when not p_is_all_day then
      extract(epoch from ((p_ends_at at time zone coalesce(p_timezone, 'UTC'))
                          - (p_starts_at at time zone coalesce(p_timezone, 'UTC'))))::bigint
    end,
    case when p_is_all_day then p_all_day_end - p_all_day_start end,
    p_title, coalesce(p_description, ''), coalesce(p_color_value, 4282874742)
  );
  perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
  return query select * from public._event_occurrence_at_index(v_event.id, 0);
end;
$$;

-- 범위 변경이 공유하는 응답이다. 본문은 의도적으로 작게 유지하여 클라이언트가
-- 제한 없이 영향을 받은 발생을 펼쳐 받는 대신 범위가 제한된 페이지를 무효화하고
-- 다시 가져오게 한다. `changed=false`는 멱등적인 재실행/무동작이며 의도적으로
-- 상위 버전을 그대로 둔다.
create or replace function public._recurrence_receipt(
  p_group_id uuid, p_event_id uuid, p_occurrence_key text,
  p_series_version integer, p_occurrence_version integer, p_scope text,
  p_changed boolean
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'group_id', p_group_id,
    'event_id', p_event_id,
    'occurrence_key', p_occurrence_key,
    'series_version', p_series_version,
    'occurrence_version', p_occurrence_version,
    'scope', p_scope,
    'changed', p_changed,
    'committed', true
  );
$$;

create or replace function public.update_event_occurrence_scope_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_occurrence_key text,
  p_scope text,
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_timezone text,
  p_is_all_day boolean,
  p_all_day_start date,
  p_all_day_end date,
  p_color_value bigint,
  p_member_ids uuid[],
  p_frequency text,
  p_interval integer,
  p_weekdays smallint[],
  p_end text,
  p_count integer,
  p_until_date date,
  p_monthly_day smallint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_group public.groups;
  v_membership public.memberships;
  v_rule public.event_recurrence_rules;
  v_old_override public.event_occurrence_overrides;
  v_index bigint;
  v_anchor_local timestamp;
  v_new_key text;
  v_occurrence_version integer := 0;
  v_new_segment integer;
  v_new_version integer;
  v_selected record;
  v_effective_frequency text;
  v_effective_interval integer;
  v_effective_weekdays smallint[];
  v_effective_end text;
  v_effective_count integer;
  v_effective_until date;
  v_effective_monthly_day smallint;
  v_effective_timezone text;
  v_effective_all_day boolean;
  v_target_member_ids uuid[];
  v_existing_member_ids uuid[];
  v_members_changed boolean := false;
  v_valid_member_count integer;
  v_lock_user_ids uuid[];
  v_lock_user_id uuid;
  v_locked_user_count integer := 0;
begin
  if v_actor is null then raise exception using errcode = '28000', message = 'authentication is required'; end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_scope is null or p_scope not in ('this', 'future', 'all') then raise exception using errcode = '22023', message = 'scope must be this, future, or all'; end if;
  if p_scope <> 'all' and p_member_ids is not null then
    raise exception using errcode = '22023', message = 'p_member_ids is only valid for all-scope edits';
  end if;
  if p_scope = 'all' and p_member_ids is null then
    raise exception using errcode = '22023', message = 'all-scope edits require p_member_ids';
  end if;
  if p_occurrence_key is null or p_occurrence_key !~ '^(single|o[0-9]{20})$' then
    raise exception using errcode = '22023', message = 'occurrence key is invalid';
  end if;

  -- 그룹/일정/하위 잠금보다 먼저 요청자와 모든 대상 참여자를 결정적인 UUID 순서로
  -- 잠근다. 계정 삭제 FK 잠금 순서와 맞으며 전체 범위 멤버가 부분적으로 교체되는
  -- 것을 막는다.
  if p_scope = 'all' then
    if exists (select 1 from pg_catalog.unnest(p_member_ids) supplied(user_id)
               where supplied.user_id is null) then
      raise exception using errcode = '22023', message = 'member_ids cannot contain null';
    end if;
    select coalesce(pg_catalog.array_agg(user_id order by user_id), '{}'::uuid[])
      into v_target_member_ids
    from (select distinct supplied.user_id
          from pg_catalog.unnest(p_member_ids) supplied(user_id)) ids;
    if not (v_actor = any(v_target_member_ids)) then
      raise exception using errcode = '42501', message = 'event creator must remain an active participant';
    end if;
  else
    v_target_member_ids := array[v_actor]::uuid[];
  end if;
  select coalesce(pg_catalog.array_agg(ids.id order by ids.id), '{}'::uuid[])
    into v_lock_user_ids
  from (
    select v_actor as id
    union
    select supplied.user_id from pg_catalog.unnest(v_target_member_ids) supplied(user_id)
  ) ids;
  v_locked_user_count := 0;
  for v_lock_user_id in
    select u.id from auth.users u
    where u.id = any(v_lock_user_ids)
    order by u.id
    for key share
  loop
    v_locked_user_count := v_locked_user_count + 1;
  end loop;
  if v_locked_user_count <> coalesce(pg_catalog.array_length(v_lock_user_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must have accounts';
  end if;

  select e.group_id into v_event.group_id from public.events e where e.id = p_event_id;
  if v_event.group_id is null then raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable'; end if;
  select g.* into v_group from public.groups g where g.id = v_event.group_id for update;
  if not found or v_group.deleted_at is not null then raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable'; end if;
  select e.* into v_event from public.events e where e.id = p_event_id for update;
  if not found or v_event.deleted_at is not null or v_event.created_by <> v_actor
     or p_expected_version is null or v_event.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours';
  end if;
  select m.* into v_membership from public.memberships m
  where m.group_id = v_event.group_id and m.user_id = v_actor for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using errcode = '42501', message = 'only an active event author can edit recurrence';
  end if;

  -- 전체 범위 저장은 완전한 참여자 집합을 전달하여 본문/규칙/멤버 교체를 한
  -- 트랜잭션에서 수행한다. 정규 정렬, 같은 그룹의 활성 상태 검증 및 작성자 포함
  -- 불변 조건은 행 잠금 아래에서 처리한다.
  if p_scope = 'all' then
    if exists (select 1 from pg_catalog.unnest(p_member_ids) supplied(user_id)
               where supplied.user_id is null) then
      raise exception using errcode = '22023', message = 'member_ids cannot contain null';
    end if;
    select coalesce(pg_catalog.array_agg(user_id order by user_id), '{}'::uuid[])
      into v_target_member_ids
    from (select distinct supplied.user_id
          from pg_catalog.unnest(p_member_ids) supplied(user_id)) ids;
    if not (v_event.created_by = any(v_target_member_ids)) then
      raise exception using errcode = '42501', message = 'event creator must remain an active participant';
    end if;
    perform 1 from public.memberships m
      where m.group_id = v_event.group_id and m.user_id = any(v_target_member_ids)
      order by m.user_id for update;
    select count(*)::integer into v_valid_member_count
      from public.memberships m
      where m.group_id = v_event.group_id and m.user_id = any(v_target_member_ids)
        and m.is_active and m.removed_at is null;
    if v_valid_member_count <> coalesce(pg_catalog.array_length(v_target_member_ids, 1), 0) then
      raise exception using errcode = '42501', message = 'all event members must be active members of the group';
    end if;
    perform 1 from public.event_members em
      where em.event_id = p_event_id order by em.user_id for update;
    select coalesce(pg_catalog.array_agg(em.user_id order by em.user_id), '{}'::uuid[])
      into v_existing_member_ids
      from public.event_members em where em.event_id = p_event_id;
    v_members_changed := v_existing_member_ids is distinct from v_target_member_ids;
    if v_members_changed then
      perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
      delete from public.event_members em
       where em.event_id = p_event_id and not (em.user_id = any(v_target_member_ids));
      insert into public.event_members (event_id, user_id)
      select p_event_id, supplied.user_id
        from pg_catalog.unnest(v_target_member_ids) supplied(user_id)
      on conflict (event_id, user_id) do nothing;
      perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
    end if;
  end if;

  if p_occurrence_key = 'single' then
    if exists (select 1 from public.event_recurrence_rules r where r.event_id = p_event_id)
       or p_scope <> 'all' then
      raise exception using errcode = '22023', message = 'single events support only all-scope edits';
    end if;
    if p_title is null or char_length(btrim(p_title)) not between 1 and 240
       or p_starts_at is null or p_ends_at is null
       or not pg_catalog.isfinite(p_starts_at)
       or not pg_catalog.isfinite(p_ends_at)
       or p_ends_at <= p_starts_at
       or p_timezone is null or not public.is_valid_timezone(p_timezone)
       or p_is_all_day is null or p_color_value is null
       or p_color_value not between 0 and 4294967295
       or (p_is_all_day and (p_all_day_start is null or p_all_day_end is null
         or p_all_day_end <= p_all_day_start
         or p_all_day_end - p_all_day_start > 366))
       or (not p_is_all_day and (p_all_day_start is not null or p_all_day_end is not null
         or extract(epoch from ((p_ends_at at time zone p_timezone)
                                - (p_starts_at at time zone p_timezone))) not between 1 and 31622400)) then
      raise exception using errcode = '22023', message = 'event fields are invalid';
    end if;
    -- NULL frequency는 전체 범위를 단일 일정으로 명시적으로 변환한다. 이후 편집은
    -- NULL을 "상속"으로 취급한다. 단일 일정 편집에는 상속할 기존 규칙이 없으므로
    -- 이전 일정 형태를 유지한다.
    if p_frequency is null then
      if p_interval is not null or p_weekdays is not null or p_end is not null
         or p_count is not null or p_until_date is not null or p_monthly_day is not null then
        raise exception using errcode = '22023', message = 'recurrence fields must be null when converting to a singleton';
      end if;
      if not v_members_changed
         and v_event.title is not distinct from p_title
         and v_event.description is not distinct from coalesce(p_description, '')
         and v_event.starts_at is not distinct from p_starts_at
         and v_event.ends_at is not distinct from p_ends_at
         and v_event.timezone is not distinct from p_timezone
         and v_event.is_all_day is not distinct from p_is_all_day
         and v_event.all_day_start is not distinct from p_all_day_start
         and v_event.all_day_end is not distinct from p_all_day_end
         and v_event.color_value is not distinct from p_color_value then
        return public._recurrence_receipt(v_event.group_id, p_event_id, 'single',
          v_event.version, 0, 'all', false);
      end if;
      update public.events e set title = p_title, description = coalesce(p_description, ''),
        starts_at = p_starts_at, ends_at = p_ends_at, timezone = p_timezone,
        is_all_day = p_is_all_day, all_day_start = p_all_day_start,
        all_day_end = p_all_day_end, color_value = p_color_value,
        version = e.version + 1 where e.id = p_event_id;
      return public._recurrence_receipt(v_event.group_id, p_event_id, 'single',
        v_event.version + 1, 0, 'all', true);
    end if;
    if p_frequency is null or p_frequency not in ('daily', 'weekly', 'monthly')
       or p_interval is null or p_interval not between 1 and 999
       or p_end is null or p_end not in ('never', 'count', 'until') then
      raise exception using errcode = '22023', message = 'invalid recurrence rule';
    end if;
    if p_end = 'count' and (p_count is null or p_count not between 1 and 1000000) then
      raise exception using errcode = '22023', message = 'count must be between 1 and 1000000';
    end if;
    if p_end = 'until' and (p_until_date is null or p_until_date <
        coalesce(case when p_is_all_day then p_all_day_start end,
                 (p_starts_at at time zone p_timezone)::date)) then
      raise exception using errcode = '22023', message = 'until_date must include the anchor date';
    end if;
    if p_end <> 'count' and p_count is not null then
      raise exception using errcode = '22023', message = 'count is only valid with end=count';
    end if;
    if p_end <> 'until' and p_until_date is not null then
      raise exception using errcode = '22023', message = 'until_date is only valid with end=until';
    end if;
    if p_weekdays is null then
      raise exception using errcode = '22023', message = 'weekdays cannot be null for an all-scope recurrence rule';
    end if;
    if p_frequency <> 'monthly' and p_monthly_day is not null then
      raise exception using errcode = '22023', message = 'monthly_day is only valid with frequency=monthly';
    end if;
    if exists (select 1 from pg_catalog.unnest(p_weekdays) supplied(value)
               where supplied.value is null or supplied.value < 1 or supplied.value > 7) then
      raise exception using errcode = '22023', message = 'weekdays must contain sorted ISO values 1 through 7';
    end if;
    if (select coalesce(pg_catalog.array_agg(day_value order by day_value), '{}'::smallint[])
        from (select distinct value::smallint as day_value
              from pg_catalog.unnest(p_weekdays) supplied(value)) days) <> p_weekdays then
      raise exception using errcode = '22023', message = 'weekdays must be sorted and distinct ISO values';
    end if;
    v_anchor_local := p_starts_at at time zone p_timezone;
    if p_is_all_day then
      v_anchor_local := p_all_day_start::timestamp;
      if p_all_day_end - p_all_day_start > 366 then
        raise exception using errcode = '22023', message = 'all-day duration must not exceed 366 days';
      end if;
    elsif extract(epoch from ((p_ends_at at time zone p_timezone)
                              - (p_starts_at at time zone p_timezone))) not between 1 and 31622400 then
      raise exception using errcode = '22023', message = 'timed duration must not exceed 366 days';
    end if;
    v_effective_weekdays := coalesce(p_weekdays, '{}'::smallint[]);
    if p_frequency = 'weekly' then
      if pg_catalog.cardinality(v_effective_weekdays) = 0 then
        v_effective_weekdays := array[extract(isodow from v_anchor_local::date)::smallint];
      end if;
    elsif pg_catalog.cardinality(v_effective_weekdays) <> 0 then
      raise exception using errcode = '22023', message = 'only weekly rules accept weekdays';
    end if;
    v_effective_monthly_day := case when p_frequency = 'monthly'
      then coalesce(p_monthly_day, extract(day from v_anchor_local)::smallint) end;
    if p_frequency = 'monthly' and (v_effective_monthly_day is null
        or v_effective_monthly_day not between 1 and 31) then
      raise exception using errcode = '22023', message = 'monthly_day must be between 1 and 31';
    end if;
    update public.events e set title = p_title, description = coalesce(p_description, ''),
      starts_at = p_starts_at, ends_at = p_ends_at, timezone = p_timezone,
      is_all_day = p_is_all_day, all_day_start = p_all_day_start,
      all_day_end = p_all_day_end, color_value = p_color_value,
      version = e.version + 1 where e.id = p_event_id;
    insert into public.event_recurrence_rules (
      event_id, segment_no, start_occurrence_index, frequency, interval_value,
      weekdays, monthly_day, end_mode, occurrence_count, until_date,
      anchor_local_date, anchor_local_time, timezone, is_all_day,
      duration_seconds, duration_days, title, description, color_value
    ) values (
      p_event_id, 0, 0, p_frequency, p_interval, v_effective_weekdays,
      v_effective_monthly_day, p_end, p_count, p_until_date,
      v_anchor_local::date, v_anchor_local::time, p_timezone, p_is_all_day,
      case when not p_is_all_day then
        extract(epoch from ((p_ends_at at time zone p_timezone)
                            - (p_starts_at at time zone p_timezone)))::bigint
      end,
      case when p_is_all_day then p_all_day_end - p_all_day_start end,
      p_title, coalesce(p_description, ''), p_color_value
    );
    return public._recurrence_receipt(v_event.group_id, p_event_id, 'single',
      v_event.version + 1, 0, 'all', true);
  end if;
  begin
    v_index := pg_catalog.substr(p_occurrence_key, 2)::bigint;
  exception when others then
    raise exception using errcode = '22023', message = 'occurrence key is invalid';
  end;
  if public.recurrence_occurrence_key(v_index) <> p_occurrence_key then
    raise exception using errcode = '22023', message = 'occurrence key is invalid';
  end if;
  select r.* into v_rule from public.event_recurrence_rules r
  where r.event_id = p_event_id and v_index >= r.start_occurrence_index
    and (r.end_occurrence_index is null or v_index < r.end_occurrence_index)
  order by r.start_occurrence_index desc limit 1;
  if not found
     or (not exists (select 1 from public._event_occurrence_at_index(p_event_id, v_index))
         and not exists (select 1 from public.event_occurrence_overrides o
                        where o.event_id = p_event_id
                          and o.occurrence_index = v_index
                          and o.is_cancelled)) then
    raise exception using errcode = '22023', message = 'occurrence does not exist';
  end if;
  select * into v_selected from public._event_occurrence_at_index(p_event_id, v_index);

  if p_scope = 'this' then
    if p_frequency is not null or p_interval is not null or p_weekdays is not null
       or p_end is not null or p_count is not null or p_until_date is not null
       or p_monthly_day is not null then
      raise exception using errcode = '22023', message = 'recurrence fields are only valid for future or all scope';
    end if;
    if p_title is null or char_length(btrim(p_title)) not between 1 and 240
       or p_description is not null and char_length(p_description) > 10000
       or p_starts_at is null or p_ends_at is null
       or not pg_catalog.isfinite(p_starts_at)
       or not pg_catalog.isfinite(p_ends_at)
       or p_ends_at <= p_starts_at
       or p_timezone is null or not public.is_valid_timezone(p_timezone)
       or p_is_all_day is null or p_color_value is null
       or p_color_value not between 0 and 4294967295
       or (p_is_all_day and (p_all_day_start is null or p_all_day_end is null
         or p_all_day_end <= p_all_day_start
         or p_all_day_end - p_all_day_start > 366))
       or (not p_is_all_day and (p_all_day_start is not null or p_all_day_end is not null
         or extract(epoch from ((p_ends_at at time zone p_timezone)
                                - (p_starts_at at time zone p_timezone))) not between 1 and 31622400)) then
      raise exception using errcode = '22023', message = 'occurrence fields are invalid';
    end if;
    select o.* into v_old_override from public.event_occurrence_overrides o
    where o.event_id = p_event_id and o.occurrence_index = v_index for update;
    if found and not v_old_override.is_cancelled
       and v_old_override.title is not distinct from p_title
       and v_old_override.description is not distinct from coalesce(p_description, '')
       and v_old_override.starts_at is not distinct from p_starts_at
       and v_old_override.ends_at is not distinct from p_ends_at
       and v_old_override.timezone is not distinct from p_timezone
       and v_old_override.is_all_day is not distinct from p_is_all_day
       and v_old_override.all_day_start is not distinct from p_all_day_start
       and v_old_override.all_day_end is not distinct from p_all_day_end
       and v_old_override.color_value is not distinct from p_color_value then
      return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
        v_event.version, v_old_override.version, 'this', false);
    end if;
    v_new_version := coalesce(v_old_override.version, 0) + 1;
    insert into public.event_occurrence_overrides (
      event_id, occurrence_index, occurrence_key, is_cancelled, title, description,
      starts_at, ends_at, timezone, is_all_day, all_day_start, all_day_end,
      color_value, version
    ) values (
      p_event_id, v_index, p_occurrence_key, false, p_title, coalesce(p_description, ''),
      p_starts_at, p_ends_at, p_timezone, p_is_all_day, p_all_day_start,
      p_all_day_end, p_color_value, v_new_version
    ) on conflict (event_id, occurrence_index) do update set
      is_cancelled = false, title = excluded.title, description = excluded.description,
      starts_at = excluded.starts_at, ends_at = excluded.ends_at, timezone = excluded.timezone,
      is_all_day = excluded.is_all_day, all_day_start = excluded.all_day_start,
      all_day_end = excluded.all_day_end, color_value = excluded.color_value,
      version = public.event_occurrence_overrides.version + 1;
    select o.version into v_occurrence_version from public.event_occurrence_overrides o
    where o.event_id = p_event_id and o.occurrence_index = v_index;
  elsif p_scope = 'future' then
    -- 분할 전에 모든 하위 행을 순번대로 잠근다. 위의 그룹/일정 잠금은 같은 그룹의
    -- 모든 작성자를 직렬화하고 이 순서를 결정적으로 유지한다.
    perform 1 from public.event_recurrence_rules r where r.event_id = p_event_id
      order by r.start_occurrence_index, r.segment_no for update;
    perform 1 from public.event_occurrence_overrides o where o.event_id = p_event_id
      order by o.occurrence_index for update;
    if v_index > v_rule.start_occurrence_index then
      update public.event_recurrence_rules r set end_occurrence_index = v_index,
        version = r.version + 1 where r.id = v_rule.id;
      v_new_segment := (select coalesce(max(segment_no), -1) + 1 from public.event_recurrence_rules where event_id = p_event_id);
    else
      v_new_segment := v_rule.segment_no;
      delete from public.event_recurrence_rules where id = v_rule.id;
    end if;
    delete from public.event_recurrence_rules where event_id = p_event_id
      and start_occurrence_index >= v_index;
    v_effective_frequency := coalesce(p_frequency, v_rule.frequency);
    v_effective_interval := coalesce(p_interval, v_rule.interval_value);
    v_effective_end := coalesce(p_end, v_rule.end_mode);
    -- NULL end/count/until 필드는 상속된 모드가 해당 필드를 허용할 때만 상속을
    -- 뜻한다. 명시적인 개수/날짜는 새 미래 규칙 값이며, 상속된 개수는 v_index
    -- 전에 소비한 순번만큼 줄인다.
    if p_end is null then
      if p_count is not null and v_rule.end_mode <> 'count' then
        raise exception using errcode = '22023', message = 'count requires end=count';
      end if;
      if p_until_date is not null and v_rule.end_mode <> 'until' then
        raise exception using errcode = '22023', message = 'until_date requires end=until';
      end if;
      if p_count is not null and p_until_date is not null then
        raise exception using errcode = '22023', message = 'count and until_date are mutually exclusive';
      end if;
    elsif p_end = 'count' and p_count is null then
      raise exception using errcode = '22023', message = 'count must be supplied for end=count';
    elsif p_end = 'until' and p_until_date is null then
      raise exception using errcode = '22023', message = 'until_date must be supplied for end=until';
    end if;
    if v_effective_end = 'count' then
      v_effective_count := case when p_count is not null then p_count
        else v_rule.occurrence_count - (v_index - v_rule.start_occurrence_index)::integer end;
    else
      v_effective_count := null;
    end if;
    v_effective_until := case when v_effective_end = 'until'
      then coalesce(p_until_date, v_rule.until_date) end;
    v_effective_timezone := coalesce(p_timezone, v_rule.timezone);
    v_effective_all_day := coalesce(p_is_all_day, v_rule.is_all_day);
    if (p_title is not null and (char_length(btrim(p_title)) not between 1 and 240))
       or (p_description is not null and char_length(p_description) > 10000)
       or (p_color_value is not null and p_color_value not between 0 and 4294967295)
       or (p_end is not null and p_end <> 'count' and p_count is not null)
       or (p_end is not null and p_end <> 'until' and p_until_date is not null)
       or (p_frequency is not null and p_frequency <> 'monthly' and p_monthly_day is not null) then
      raise exception using errcode = '22023', message = 'future recurrence fields are invalid';
    end if;
    if p_weekdays is not null then
      if exists (select 1 from pg_catalog.unnest(p_weekdays) supplied(value)
                 where supplied.value is null or supplied.value < 1 or supplied.value > 7) then
        raise exception using errcode = '22023', message = 'weekdays must contain sorted ISO values 1 through 7';
      end if;
      if (select coalesce(pg_catalog.array_agg(day_value order by day_value), '{}'::smallint[])
          from (select distinct value::smallint as day_value
                from pg_catalog.unnest(p_weekdays) supplied(value)) days) <> p_weekdays then
        raise exception using errcode = '22023', message = 'weekdays must be sorted and distinct ISO values';
      end if;
    elsif p_frequency is not null then
      raise exception using errcode = '22023', message = 'weekdays are required when changing frequency';
    end if;
    v_effective_weekdays := case when v_effective_frequency = 'weekly'
      then coalesce(p_weekdays, v_rule.weekdays) else '{}'::smallint[] end;
    v_effective_monthly_day := case when v_effective_frequency = 'monthly'
      then coalesce(p_monthly_day, v_rule.monthly_day) end;
    if v_effective_frequency <> 'monthly' and p_monthly_day is not null then
      raise exception using errcode = '22023', message = 'monthly_day is only valid with frequency=monthly';
    end if;
    if v_effective_frequency not in ('daily', 'weekly', 'monthly')
       or v_effective_interval is null or v_effective_interval not between 1 and 999
       or v_effective_end not in ('never', 'count', 'until')
       or not public.is_valid_timezone(v_effective_timezone)
       or v_effective_all_day is null then
      raise exception using errcode = '22023', message = 'invalid recurrence rule';
    end if;
    if v_effective_end = 'count' and (v_effective_count is null or v_effective_count < 1) then
      raise exception using errcode = '22023', message = 'count must be supplied for end=count';
    end if;
    if v_effective_end = 'count' and v_effective_count > 1000000 then
      raise exception using errcode = '22023', message = 'count must not exceed 1000000';
    end if;
    if v_effective_end = 'until' and v_effective_until is null then
      raise exception using errcode = '22023', message = 'until_date must be supplied for end=until';
    end if;
    if p_starts_at is null and v_selected.scheduled_starts_at is null then
      raise exception using errcode = '22023', message = 'future scope requires occurrence timing';
    end if;
    v_anchor_local := coalesce(
      case when p_starts_at is not null then p_starts_at end,
      v_selected.scheduled_starts_at
    ) at time zone v_effective_timezone;
    if v_effective_all_day then
      v_anchor_local := coalesce(
        case when p_all_day_start is not null then p_all_day_start::timestamp end,
        (v_selected.scheduled_starts_at at time zone v_effective_timezone)::date::timestamp
      );
    end if;
    if v_effective_frequency = 'weekly' and pg_catalog.cardinality(v_effective_weekdays) = 0 then
      v_effective_weekdays := array[extract(isodow from v_anchor_local::date)::smallint];
    elsif v_effective_frequency <> 'weekly' and pg_catalog.cardinality(v_effective_weekdays) <> 0 then
      raise exception using errcode = '22023', message = 'only weekly rules accept weekdays';
    end if;
    if v_effective_frequency = 'monthly' and v_effective_monthly_day is null then
      v_effective_monthly_day := extract(day from v_anchor_local::date)::smallint;
    end if;
    if v_effective_frequency = 'monthly' and v_effective_monthly_day not between 1 and 31 then
      raise exception using errcode = '22023', message = 'monthly_day must be between 1 and 31';
    end if;
    if v_effective_end = 'until' and (v_effective_until is null
        or v_effective_until < v_anchor_local::date) then
      raise exception using errcode = '22023', message = 'until_date must include the anchor date';
    end if;
    if v_effective_all_day then
      if (p_all_day_start is null) <> (p_all_day_end is null) then
        raise exception using errcode = '22023', message = 'all-day dates must be supplied as a pair';
      end if;
      if coalesce(p_all_day_end - p_all_day_start, v_rule.duration_days) is null
         or coalesce(p_all_day_end - p_all_day_start, v_rule.duration_days) not between 1 and 366 then
        raise exception using errcode = '22023', message = 'all-day duration must be between 1 and 366 days';
      end if;
    elsif p_all_day_start is not null or p_all_day_end is not null then
      raise exception using errcode = '22023', message = 'timed future edits cannot include all-day dates';
    elsif extract(epoch from ((coalesce(p_ends_at, v_selected.scheduled_ends_at)
                               at time zone v_effective_timezone)
                              - (coalesce(p_starts_at, v_selected.scheduled_starts_at)
                               at time zone v_effective_timezone))) not between 1 and 31622400 then
      raise exception using errcode = '22023', message = 'timed duration must be between 1 second and 366 days';
    end if;
    insert into public.event_recurrence_rules (
      event_id, segment_no, start_occurrence_index, frequency, interval_value, weekdays,
      monthly_day, end_mode, occurrence_count, until_date, anchor_local_date,
      anchor_local_time, timezone, is_all_day, duration_seconds, duration_days,
      title, description, color_value
    ) values (
      p_event_id, v_new_segment, v_index, v_effective_frequency,
      v_effective_interval, v_effective_weekdays,
      v_effective_monthly_day,
      v_effective_end, v_effective_count, v_effective_until, v_anchor_local::date,
      v_anchor_local::time, v_effective_timezone, v_effective_all_day,
      case when not v_effective_all_day
        then extract(epoch from ((coalesce(p_ends_at, v_selected.scheduled_ends_at)
                                  at time zone v_effective_timezone)
                                 - (coalesce(p_starts_at, v_selected.scheduled_starts_at)
                                  at time zone v_effective_timezone)))::bigint end,
      case when v_effective_all_day
        then coalesce(p_all_day_end - p_all_day_start, v_rule.duration_days) end,
      coalesce(p_title, v_rule.title), coalesce(p_description, v_rule.description),
      coalesce(p_color_value, v_rule.color_value)
    );
    delete from public.event_occurrence_overrides where event_id = p_event_id and occurrence_index >= v_index;
  else
    -- 전체 범위 편집은 반복 규칙을 교체하거나 반복을 명시적으로 지워(p_frequency
    -- NULL) 같은 기준 행을 다시 단일 일정으로 바꾼다. 두 경우 모두 하위 행을
    -- 교체하기 전에 잠그며 게시된 상위 버전을 정확히 한 번 올린다.
    if p_title is null or char_length(btrim(p_title)) not between 1 and 240
       or p_starts_at is null or p_ends_at is null
       or not pg_catalog.isfinite(p_starts_at)
       or not pg_catalog.isfinite(p_ends_at)
       or p_ends_at <= p_starts_at
       or p_timezone is null or not public.is_valid_timezone(p_timezone)
       or p_is_all_day is null or p_color_value is null
       or p_color_value not between 0 and 4294967295
       or (p_is_all_day and (p_all_day_start is null or p_all_day_end is null
         or p_all_day_end <= p_all_day_start))
       or (not p_is_all_day and (p_all_day_start is not null or p_all_day_end is not null)) then
      raise exception using errcode = '22023', message = 'event fields are invalid';
    end if;
    if p_frequency is null then
      if p_interval is not null or p_weekdays is not null or p_end is not null
         or p_count is not null or p_until_date is not null or p_monthly_day is not null then
        raise exception using errcode = '22023', message = 'recurrence fields must be null when converting to a singleton';
      end if;
      perform 1 from public.event_recurrence_rules r where r.event_id = p_event_id
        order by r.start_occurrence_index, r.segment_no for update;
      perform 1 from public.event_occurrence_overrides o where o.event_id = p_event_id
        order by o.occurrence_index for update;
      delete from public.event_occurrence_overrides where event_id = p_event_id;
      delete from public.event_recurrence_rules where event_id = p_event_id;
      update public.events e set title = p_title, description = coalesce(p_description, ''),
        starts_at = p_starts_at, ends_at = p_ends_at, timezone = p_timezone,
        is_all_day = p_is_all_day, all_day_start = p_all_day_start,
        all_day_end = p_all_day_end, color_value = p_color_value,
        version = e.version + 1 where e.id = p_event_id;
      return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
        v_event.version + 1, 0, 'all', true);
    end if;
    if p_frequency is null or p_frequency not in ('daily', 'weekly', 'monthly')
       or p_interval is null or p_interval not between 1 and 999
       or p_end is null or p_end not in ('never', 'count', 'until') then
      raise exception using errcode = '22023', message = 'invalid recurrence rule';
    end if;
    if p_end = 'count' and (p_count is null or p_count not between 1 and 1000000) then
      raise exception using errcode = '22023', message = 'count must be between 1 and 1000000';
    end if;
    if p_end = 'until' and (p_until_date is null or p_until_date <
        coalesce(case when p_is_all_day then p_all_day_start end,
                 (p_starts_at at time zone p_timezone)::date)) then
      raise exception using errcode = '22023', message = 'until_date must include the anchor date';
    end if;
    if p_end <> 'count' and p_count is not null then
      raise exception using errcode = '22023', message = 'count is only valid with end=count';
    end if;
    if p_end <> 'until' and p_until_date is not null then
      raise exception using errcode = '22023', message = 'until_date is only valid with end=until';
    end if;
    if p_weekdays is null then
      raise exception using errcode = '22023', message = 'weekdays cannot be null for an all-scope recurrence rule';
    end if;
    if exists (select 1 from pg_catalog.unnest(p_weekdays) supplied(value)
               where supplied.value is null or supplied.value < 1 or supplied.value > 7) then
      raise exception using errcode = '22023', message = 'weekdays must contain sorted ISO values 1 through 7';
    end if;
    if (select coalesce(pg_catalog.array_agg(day_value order by day_value), '{}'::smallint[])
        from (select distinct value::smallint as day_value
              from pg_catalog.unnest(p_weekdays) supplied(value)) days) <> p_weekdays then
      raise exception using errcode = '22023', message = 'weekdays must be sorted and distinct ISO values';
    end if;
    v_anchor_local := p_starts_at at time zone p_timezone;
    if p_is_all_day then
      v_anchor_local := p_all_day_start::timestamp;
      if p_all_day_end - p_all_day_start > 366 then
        raise exception using errcode = '22023', message = 'all-day duration must not exceed 366 days';
      end if;
    elsif extract(epoch from ((p_ends_at at time zone p_timezone)
                              - (p_starts_at at time zone p_timezone))) not between 1 and 31622400 then
      raise exception using errcode = '22023', message = 'timed duration must not exceed 366 days';
    end if;
    v_effective_weekdays := coalesce(p_weekdays, '{}'::smallint[]);
    if p_frequency = 'weekly' then
      if pg_catalog.cardinality(v_effective_weekdays) = 0 then
        v_effective_weekdays := array[extract(isodow from v_anchor_local::date)::smallint];
      end if;
    elsif pg_catalog.cardinality(v_effective_weekdays) <> 0 then
      raise exception using errcode = '22023', message = 'only weekly rules accept weekdays';
    end if;
    v_effective_monthly_day := case when p_frequency = 'monthly'
      then coalesce(p_monthly_day, extract(day from v_anchor_local)::smallint) end;
    if p_frequency = 'monthly' and (v_effective_monthly_day is null
        or v_effective_monthly_day not between 1 and 31) then
      raise exception using errcode = '22023', message = 'monthly_day must be between 1 and 31';
    end if;
    if p_frequency <> 'monthly' and p_monthly_day is not null then
      raise exception using errcode = '22023', message = 'monthly_day is only valid with frequency=monthly';
    end if;
    perform 1 from public.event_recurrence_rules r where r.event_id = p_event_id
      order by r.start_occurrence_index, r.segment_no for update;
    perform 1 from public.event_occurrence_overrides o where o.event_id = p_event_id
      order by o.occurrence_index for update;
    if (select count(*) from public.event_recurrence_rules r where r.event_id = p_event_id) = 1
       and (select count(*) from public.event_occurrence_overrides o where o.event_id = p_event_id) = 0
       and v_rule.start_occurrence_index = 0 and v_rule.end_occurrence_index is null
       and v_event.title is not distinct from p_title
       and v_event.description is not distinct from coalesce(p_description, '')
       and v_event.starts_at is not distinct from p_starts_at
       and v_event.ends_at is not distinct from p_ends_at
       and v_event.timezone is not distinct from p_timezone
       and v_event.is_all_day is not distinct from p_is_all_day
       and v_event.all_day_start is not distinct from p_all_day_start
       and v_event.all_day_end is not distinct from p_all_day_end
       and v_event.color_value is not distinct from p_color_value
       and v_rule.frequency is not distinct from p_frequency
       and v_rule.interval_value is not distinct from p_interval
       and v_rule.weekdays is not distinct from v_effective_weekdays
       and v_rule.end_mode is not distinct from p_end
       and v_rule.occurrence_count is not distinct from p_count
       and v_rule.until_date is not distinct from p_until_date
       and v_rule.monthly_day is not distinct from v_effective_monthly_day
       and not v_members_changed then
      return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
        v_event.version, 0, 'all', false);
    end if;
    delete from public.event_occurrence_overrides where event_id = p_event_id;
    delete from public.event_recurrence_rules where event_id = p_event_id;
    update public.events e set title = p_title, description = coalesce(p_description, ''),
      starts_at = p_starts_at, ends_at = p_ends_at, timezone = p_timezone,
      is_all_day = p_is_all_day, all_day_start = p_all_day_start,
      all_day_end = p_all_day_end, color_value = p_color_value,
      version = e.version + 1 where e.id = p_event_id;
    insert into public.event_recurrence_rules (
      event_id, segment_no, start_occurrence_index, frequency, interval_value, weekdays,
      monthly_day, end_mode, occurrence_count, until_date, anchor_local_date,
      anchor_local_time, timezone, is_all_day, duration_seconds, duration_days,
      title, description, color_value
    ) values (
      p_event_id, 0, 0, p_frequency, p_interval, v_effective_weekdays,
      v_effective_monthly_day, p_end, p_count,
      p_until_date, v_anchor_local::date, v_anchor_local::time, p_timezone,
      p_is_all_day, case when not p_is_all_day then
        extract(epoch from ((p_ends_at at time zone p_timezone)
                            - (p_starts_at at time zone p_timezone)))::bigint
      end,
      case when p_is_all_day then p_all_day_end-p_all_day_start end,
      p_title, coalesce(p_description, ''), p_color_value
    );
    return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
      v_event.version + 1, 0, 'all', true);
  end if;

  update public.events e set version = e.version + 1 where e.id = p_event_id;
  return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
    v_event.version + 1, v_occurrence_version, p_scope, true);
end;
$$;

create or replace function public.delete_event_occurrence_scope_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_occurrence_key text,
  p_scope text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_group public.groups;
  v_membership public.memberships;
  v_rule public.event_recurrence_rules;
  v_override public.event_occurrence_overrides;
  v_index bigint;
  v_occurrence_version integer;
  v_delete_all_future boolean := false;
begin
  if v_actor is null then raise exception using errcode = '28000', message = 'authentication is required'; end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_scope is null or p_scope not in ('this', 'future', 'all') then raise exception using errcode = '22023', message = 'scope must be this, future, or all'; end if;
  if p_occurrence_key is null or p_occurrence_key !~ '^(single|o[0-9]{20})$' then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end if;
  select e.group_id into v_event.group_id from public.events e where e.id = p_event_id;
  if v_event.group_id is null then raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable'; end if;
  select g.* into v_group from public.groups g where g.id = v_event.group_id for update;
  if not found or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable';
  end if;
  select e.* into v_event from public.events e where e.id = p_event_id for update;
  if not found or v_event.deleted_at is not null or v_event.created_by <> v_actor
     or p_expected_version is null or v_event.version <> p_expected_version then raise exception using errcode = '40001', message = 'event was changed, deleted, or is not yours'; end if;
  select m.* into v_membership from public.memberships m where m.group_id = v_event.group_id and m.user_id = v_actor for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then raise exception using errcode = '42501', message = 'only an active event author can edit recurrence'; end if;

  if p_occurrence_key = 'single' then
    if p_scope <> 'all' or exists (select 1 from public.event_recurrence_rules r where r.event_id = p_event_id) then raise exception using errcode = '22023', message = 'single events support only all-scope deletes'; end if;
    update public.events set deleted_at = pg_catalog.clock_timestamp(), version = version + 1 where id = p_event_id;
    return public._recurrence_receipt(v_event.group_id, p_event_id, 'single', v_event.version + 1, 0, 'all', true);
  end if;
  begin v_index := pg_catalog.substr(p_occurrence_key, 2)::bigint; exception when others then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end;
  if public.recurrence_occurrence_key(v_index) <> p_occurrence_key then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end if;
  select r.* into v_rule from public.event_recurrence_rules r where r.event_id = p_event_id and v_index >= r.start_occurrence_index and (r.end_occurrence_index is null or v_index < r.end_occurrence_index) order by r.start_occurrence_index desc limit 1;
  if not found then raise exception using errcode = '22023', message = 'occurrence does not exist'; end if;
  if not exists (select 1 from public._event_occurrence_at_index(p_event_id, v_index))
     and not exists (select 1 from public.event_occurrence_overrides o
                    where o.event_id = p_event_id and o.occurrence_index = v_index
                      and o.is_cancelled) then
    raise exception using errcode = '22023', message = 'occurrence does not exist';
  end if;

  if p_scope = 'this' then
    select o.* into v_override from public.event_occurrence_overrides o where o.event_id = p_event_id and o.occurrence_index = v_index for update;
    if found and v_override.is_cancelled then
      return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key, v_event.version, v_override.version, 'this', false);
    end if;
    v_occurrence_version := coalesce(v_override.version, 0) + 1;
    insert into public.event_occurrence_overrides(event_id, occurrence_index, occurrence_key, is_cancelled, version)
    values (p_event_id, v_index, p_occurrence_key, true, v_occurrence_version)
    on conflict (event_id, occurrence_index) do update set
      is_cancelled = true, title = null, description = null, starts_at = null, ends_at = null,
      timezone = null, is_all_day = null, all_day_start = null, all_day_end = null,
      color_value = null, version = public.event_occurrence_overrides.version + 1;
    select o.version into v_occurrence_version from public.event_occurrence_overrides o where o.event_id = p_event_id and o.occurrence_index = v_index;
  elsif p_scope = 'future' then
    perform 1 from public.event_recurrence_rules r where r.event_id = p_event_id order by r.start_occurrence_index, r.segment_no for update;
    perform 1 from public.event_occurrence_overrides o where o.event_id = p_event_id order by o.occurrence_index for update;
    if v_index = v_rule.start_occurrence_index then
      delete from public.event_recurrence_rules where id = v_rule.id;
      if v_index = 0 then
        -- 유지할 더 이른 순번이 없다. 따라서 루트에서의 향후 삭제는 이전 단일
        -- 일정으로 잘못 읽힐 규칙 없는 활성 행을 남기지 않고 논리 기준점을
        -- 소프트 삭제한다.
        v_delete_all_future := true;
      end if;
    else
      update public.event_recurrence_rules set end_occurrence_index = v_index, version = version + 1 where id = v_rule.id;
    end if;
    delete from public.event_recurrence_rules where event_id = p_event_id and start_occurrence_index >= v_index;
    delete from public.event_occurrence_overrides where event_id = p_event_id and occurrence_index >= v_index;
  else
    perform 1 from public.event_recurrence_rules r where r.event_id = p_event_id
      order by r.start_occurrence_index, r.segment_no for update;
    perform 1 from public.event_occurrence_overrides o where o.event_id = p_event_id
      order by o.occurrence_index for update;
    update public.events set deleted_at = pg_catalog.clock_timestamp(), version = version + 1 where id = p_event_id;
  end if;
  if v_delete_all_future then
    update public.events set deleted_at = pg_catalog.clock_timestamp(), version = version + 1 where id = p_event_id;
    return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
      v_event.version + 1, 0, 'future', true);
  end if;
  update public.events set version = version + 1 where id = p_event_id and p_scope <> 'all';
  return public._recurrence_receipt(v_event.group_id, p_event_id, p_occurrence_key,
    v_event.version + 1, coalesce(v_occurrence_version, 0), p_scope, true);
end;
$$;

-- 지점 조회는 의도적으로 v2 범위 행과 같은 행 형태다. 작성자와 무관하지만 활성
-- 그룹 멤버와 운영 중인 일정이 필요하다.
create or replace function public.event_occurrence_by_key(
  p_event_id uuid,
  p_occurrence_key text
)
returns table (
  id uuid, event_id uuid, series_id uuid, group_id uuid, created_by uuid,
  title text, description text, starts_at timestamptz, ends_at timestamptz,
  timezone text, is_all_day boolean, all_day_start date, all_day_end date,
  version integer, deleted_at timestamptz, created_at timestamptz,
  updated_at timestamptz, color_value bigint, member_ids uuid[],
  occurrence_key text, occurrence_index bigint, occurrence_version integer,
  is_occurrence boolean, scheduled_starts_at timestamptz,
  scheduled_ends_at timestamptz, recurrence_rule jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_index bigint;
  v_group public.groups;
begin
  if v_actor is null then raise exception using errcode = '28000', message = 'authentication is required'; end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found or v_event.deleted_at is not null then raise exception using errcode = '42501', message = 'event is unavailable'; end if;
  select g.* into v_group from public.groups g where g.id = v_event.group_id for share;
  if not found or v_group.deleted_at is not null or not public.is_active_member(v_event.group_id) then raise exception using errcode = '42501', message = 'event is unavailable'; end if;
  if p_occurrence_key = 'single' then
    if exists (select 1 from public.event_recurrence_rules r where r.event_id = p_event_id) then
      -- 이전 딥 링크는 단일 일정 표식을 사용한다. 기준점이 반복 일정으로 바뀌면
      -- 내부 단일 일정 식별자를 노출하지 않고 해당 표식을 안정적인 순번 0 구체화
      -- 행으로 정규화한다.
      return query select * from public._event_occurrence_at_index(p_event_id, 0);
      return;
    end if;
    return query select * from public._event_occurrence_at_index(p_event_id, -1);
    return;
  end if;
  if p_occurrence_key is null or p_occurrence_key !~ '^o[0-9]{20}$' then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end if;
  begin v_index := pg_catalog.substr(p_occurrence_key, 2)::bigint; exception when others then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end;
  if public.recurrence_occurrence_key(v_index) <> p_occurrence_key then raise exception using errcode = '22023', message = 'occurrence key is invalid'; end if;
  return query select * from public._event_occurrence_at_index(p_event_id, v_index);
end;
$$;

-- 범위를 제한한 v2 조회다. 커서 튜플 순서는 정확히 (starts_at,event_id,
-- occurrence_key)이며 이전 클라이언트를 위해 v1은 그대로 둔다.
create or replace function public.events_for_range_v2(
  p_group_id uuid,
  p_range_start timestamptz,
  p_range_end timestamptz,
  p_view_timezone text,
  p_limit integer default 100,
  p_cursor text default null,
  p_participant_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_group public.groups;
  v_view_timezone text;
  v_start_date date;
  v_end_date date;
  v_cursor jsonb;
  v_cursor_wire json;
  v_cursor_text text;
  v_cursor_start timestamptz;
  v_cursor_event uuid;
  v_cursor_key text;
  v_cursor_index bigint;
  v_limit integer;
  v_rows jsonb := '[]'::jsonb;
  v_seen integer := 0;
  v_has_more boolean := false;
  v_last record;
  v_row record;
begin
  if v_actor is null then raise exception using errcode = '28000', message = 'authentication is required'; end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_range_start is null or p_range_end is null or not pg_catalog.isfinite(p_range_start) or not pg_catalog.isfinite(p_range_end) or p_range_end <= p_range_start then raise exception using errcode = '22023', message = 'range must be a positive half-open interval'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then raise exception using errcode = '22023', message = 'limit must be between 1 and 200'; end if;
  v_limit := p_limit;
  select g.* into v_group from public.groups g where g.id = p_group_id for share;
  if not found or v_group.deleted_at is not null or not public.is_active_member(p_group_id) then raise exception using errcode = '42501', message = 'group is unavailable'; end if;
  v_view_timezone := coalesce(p_view_timezone, v_group.timezone);
  if not exists (select 1 from pg_catalog.pg_timezone_names t where t.name = v_view_timezone) then raise exception using errcode = '22023', message = 'view timezone must be an exact IANA timezone name'; end if;
  v_start_date := (p_range_start at time zone v_view_timezone)::date;
  v_end_date := (p_range_end at time zone v_view_timezone)::date;
  if (p_range_start at time zone v_view_timezone) <> pg_catalog.date_trunc('day', p_range_start at time zone v_view_timezone)
     or (p_range_end at time zone v_view_timezone) <> pg_catalog.date_trunc('day', p_range_end at time zone v_view_timezone)
     or v_end_date <= v_start_date or v_end_date - v_start_date > 366 then raise exception using errcode = '22023', message = 'range must be local-midnight and at most 366 days'; end if;
  if p_participant_id is not null and not exists (select 1 from public.memberships m where m.group_id = p_group_id and m.user_id = p_participant_id and m.is_active and m.removed_at is null) then raise exception using errcode = '42501', message = 'participant is not an active member of this group'; end if;

  if p_cursor is not null then
    if pg_catalog.length(p_cursor) > 4096 or pg_catalog.btrim(p_cursor) = '' or p_cursor !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = '22023', message = 'cursor is malformed'; end if;
    begin
      v_cursor_text := pg_catalog.convert_from(pg_catalog.decode(pg_catalog.translate(p_cursor, '-_', '+/') || pg_catalog.repeat('=', (4 - (pg_catalog.length(p_cursor) % 4)) % 4), 'base64'), 'UTF8');
      v_cursor_wire := v_cursor_text::json;
      v_cursor := v_cursor_text::jsonb;
    exception when others then raise exception using errcode = '22023', message = 'cursor is malformed'; end;
    if pg_catalog.jsonb_typeof(v_cursor) <> 'object' or v_cursor - 'v' - 'starts_at' - 'event_id' - 'occurrence_key' <> '{}'::jsonb or v_cursor->>'v' is null or v_cursor->>'starts_at' is null or v_cursor->>'event_id' is null or v_cursor->>'occurrence_key' is null then raise exception using errcode = '22023', message = 'cursor has an invalid shape'; end if;
    if pg_catalog.json_typeof(v_cursor_wire -> 'v') <> 'number'
       or (v_cursor_wire -> 'v')::text !~ '^[0-9]+$'
       or (v_cursor->>'v') <> '2'
       or pg_catalog.json_typeof(v_cursor_wire -> 'starts_at') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'event_id') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'occurrence_key') <> 'string'
       or (v_cursor->>'starts_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception using errcode = '22023', message = 'cursor has an invalid version or timestamp'; end if;
    if (v_cursor->>'occurrence_key') !~ '^(single|o[0-9]{20})$' then raise exception using errcode = '22023', message = 'cursor occurrence key is invalid'; end if;
    begin v_cursor_start := (v_cursor->>'starts_at')::timestamptz; v_cursor_event := (v_cursor->>'event_id')::uuid; exception when others then raise exception using errcode = '22023', message = 'cursor tuple is invalid'; end;
    if not pg_catalog.isfinite(v_cursor_start) then raise exception using errcode = '22023', message = 'cursor tuple is not finite'; end if;
    v_cursor_key := v_cursor->>'occurrence_key';
    if v_cursor_key <> 'single' then
      begin
        v_cursor_index := pg_catalog.substr(v_cursor_key, 2)::bigint;
        if public.recurrence_occurrence_key(v_cursor_index) <> v_cursor_key then
          raise exception using errcode = '22023', message = 'cursor occurrence key is invalid';
        end if;
      exception when others then
        raise exception using errcode = '22023', message = 'cursor occurrence key is invalid';
      end;
    end if;
  end if;

  for v_row in
    select o.*
    from public.events e
    cross join lateral public._event_occurrences_for_range(e.id, p_range_start, p_range_end, v_view_timezone) o
    where e.group_id = p_group_id and e.deleted_at is null
      and (p_participant_id is null or exists (
        select 1 from public.event_members em join public.memberships m
          on m.group_id = e.group_id and m.user_id = em.user_id
         and m.is_active and m.removed_at is null
        where em.event_id = e.id and em.user_id = p_participant_id
      ))
      and (v_cursor_start is null or o.starts_at > v_cursor_start
        or (o.starts_at = v_cursor_start and o.event_id > v_cursor_event)
        or (o.starts_at = v_cursor_start and o.event_id = v_cursor_event and o.occurrence_key > v_cursor_key))
    order by o.starts_at, o.event_id, o.occurrence_key
    limit (v_limit + 1)
  loop
    if v_seen >= v_limit then v_has_more := true; exit; end if;
    v_rows := v_rows || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', v_row.id, 'event_id', v_row.event_id, 'series_id', v_row.series_id,
      'group_id', v_row.group_id, 'created_by', v_row.created_by,
      'title', v_row.title, 'description', v_row.description,
      'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at,
      'timezone', v_row.timezone, 'is_all_day', v_row.is_all_day,
      'all_day_start', v_row.all_day_start, 'all_day_end', v_row.all_day_end,
      'version', v_row.version, 'deleted_at', v_row.deleted_at,
      'created_at', v_row.created_at, 'updated_at', v_row.updated_at,
      'color_value', v_row.color_value, 'member_ids', to_jsonb(v_row.member_ids),
      'occurrence_key', v_row.occurrence_key, 'occurrence_index', v_row.occurrence_index,
      'occurrence_version', v_row.occurrence_version, 'is_occurrence', v_row.is_occurrence,
      'scheduled_starts_at', v_row.scheduled_starts_at,
      'scheduled_ends_at', v_row.scheduled_ends_at,
      'recurrence_rule', v_row.recurrence_rule
    ));
    v_seen := v_seen + 1;
    v_last := v_row;
  end loop;
  if v_has_more then
    v_cursor := pg_catalog.jsonb_build_object('v', 2, 'starts_at', v_last.starts_at,
      'event_id', v_last.event_id, 'occurrence_key', v_last.occurrence_key);
    v_cursor_text := pg_catalog.rtrim(pg_catalog.translate(pg_catalog.replace(pg_catalog.encode(pg_catalog.convert_to(v_cursor::text, 'UTF8'), 'base64'), E'\n', ''), '+/', '-_'), '=');
  else v_cursor_text := null; end if;
  return pg_catalog.jsonb_build_object('events', v_rows, 'next_cursor', v_cursor_text, 'has_more', v_has_more);
end;
$$;

-- 반복 일정에서 참여자만 편집할 때는 전용 응답 반환 RPC를 사용한다. 이전
-- replace_event_members_if_version 테이블 응답은 단일 일정 호출자에게 그대로
-- 유지한다. 아래 반복 분기는 여기로 위임하여 직접 호출자가 작성자 불변 조건이나
-- 계정 잠금을 우회하지 못하게 한다.
create or replace function public.replace_recurring_event_members_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_occurrence_key text,
  p_member_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_event public.events;
  v_group public.groups;
  v_membership public.memberships;
  v_target_ids uuid[];
  v_lock_user_ids uuid[];
  v_lock_user_id uuid;
  v_locked_user_count integer := 0;
  v_valid_member_count integer;
  v_existing_ids uuid[];
  v_occurrence_index bigint;
  v_canonical_key text;
  v_selected record;
  v_members_changed boolean := false;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_occurrence_key is null
     or p_occurrence_key !~ '^(single|o[0-9]{20})$' then
    raise exception using errcode = '22023', message = 'occurrence key is invalid';
  end if;
  if exists (
    select 1
    from pg_catalog.unnest(coalesce(p_member_ids, '{}'::uuid[])) supplied(user_id)
    where supplied.user_id is null
  ) then
    raise exception using errcode = '22023', message = 'member_ids cannot contain null';
  end if;

  -- 계정 잠금 집합에 작성자를 포함할 수 있도록 기준점을 잠그기 전에 읽는다. 아래에서
  -- 그룹 잠금 뒤 행을 다시 잠그며 모든 하위 잠금은 결정적인 그룹 -> 일정 -> 하위
  -- 순서를 따른다.
  select e.* into v_event
  from public.events e
  where e.id = p_event_id;
  if not found or v_event.deleted_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;
  if not exists (
    select 1 from public.event_recurrence_rules r
    where r.event_id = p_event_id
  ) then
    raise exception using errcode = '22023', message = 'event is not recurring';
  end if;

  if p_occurrence_key = 'single' then
    v_occurrence_index := 0;
  else
    begin
      v_occurrence_index := pg_catalog.substr(p_occurrence_key, 2)::bigint;
    exception when others then
      raise exception using errcode = '22023', message = 'occurrence key is invalid';
    end;
    if public.recurrence_occurrence_key(v_occurrence_index) <> p_occurrence_key then
      raise exception using errcode = '22023', message = 'occurrence key is invalid';
    end if;
  end if;
  select * into v_selected
  from public._event_occurrence_at_index(p_event_id, v_occurrence_index);
  if not found then
    raise exception using errcode = '22023', message = 'occurrence does not exist';
  end if;
  v_canonical_key := v_selected.occurrence_key;

  select coalesce(pg_catalog.array_agg(ids.id order by ids.id), '{}'::uuid[])
    into v_target_ids
  from (
    select distinct supplied.user_id as id
    from pg_catalog.unnest(coalesce(p_member_ids, '{}'::uuid[])) supplied(user_id)
  ) ids;
  select coalesce(pg_catalog.array_agg(ids.id order by ids.id), '{}'::uuid[])
    into v_lock_user_ids
  from (
    select v_actor as id
    union
    select v_event.created_by as id
    union
    select supplied.user_id as id
    from pg_catalog.unnest(v_target_ids) supplied(user_id)
  ) ids;
  -- 계정 삭제도 같은 KEY SHARE 잠금을 얻는다. 그룹/일정/하위 잠금보다 먼저 모든
  -- 대상, 요청자 및 작성자를 UUID 순서로 잠근다.
  for v_lock_user_id in
    select u.id
    from auth.users u
    where u.id = any(v_lock_user_ids)
    order by u.id
    for key share
  loop
    v_locked_user_count := v_locked_user_count + 1;
  end loop;
  if v_locked_user_count <> coalesce(pg_catalog.array_length(v_lock_user_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must have accounts';
  end if;

  select g.* into v_group
  from public.groups g
  where g.id = v_event.group_id
  for update;
  if v_group.id is null or v_group.deleted_at is not null then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;
  select e.* into v_event
  from public.events e
  where e.id = p_event_id
  for update;
  if v_event.id is null or v_event.deleted_at is not null
     or p_expected_version is null
     or v_event.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'event was changed, deleted, or is unavailable';
  end if;
  if not exists (
    select 1 from public.event_recurrence_rules r
    where r.event_id = p_event_id
  ) then
    raise exception using errcode = '22023', message = 'event is not recurring';
  end if;
  if v_event.created_by <> v_actor and v_group.owner_id <> v_actor then
    raise exception using errcode = '42501', message = 'only the event creator or group owner can replace members';
  end if;
  select m.* into v_membership
  from public.memberships m
  where m.group_id = v_event.group_id
    and m.user_id = v_actor
  for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using errcode = '42501', message = 'only an active group member can replace event members';
  end if;
  if not (v_event.created_by = any(v_target_ids)) then
    raise exception using errcode = '42501', message = 'event creator must remain an active participant';
  end if;

  perform 1
  from public.memberships m
  where m.group_id = v_event.group_id
    and m.user_id = any(v_target_ids)
  order by m.user_id
  for update;
  select count(*)::integer into v_valid_member_count
  from public.memberships m
  where m.group_id = v_event.group_id
    and m.user_id = any(v_target_ids)
    and m.is_active
    and m.removed_at is null;
  if v_valid_member_count <> coalesce(pg_catalog.array_length(v_target_ids, 1), 0) then
    raise exception using errcode = '42501', message = 'all event members must be active members of the group';
  end if;
  perform 1
  from public.event_members em
  where em.event_id = p_event_id
  order by em.user_id
  for update;
  perform 1
  from public.event_recurrence_rules r
  where r.event_id = p_event_id
  order by r.start_occurrence_index, r.segment_no
  for update;
  select coalesce(pg_catalog.array_agg(em.user_id order by em.user_id), '{}'::uuid[])
    into v_existing_ids
  from public.event_members em
  where em.event_id = p_event_id;

  if v_existing_ids is distinct from v_target_ids then
    v_members_changed := true;
    perform pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true);
    delete from public.event_members em
    where em.event_id = p_event_id
      and not (em.user_id = any(v_target_ids));
    insert into public.event_members (event_id, user_id)
    select p_event_id, supplied.user_id
    from pg_catalog.unnest(v_target_ids) supplied(user_id)
    on conflict (event_id, user_id) do nothing;
    perform pg_catalog.set_config('moduly.event_members_mutation_context', '', true);
    update public.events e
    set version = e.version + 1
    where e.id = p_event_id
      and e.deleted_at is null
      and e.version = p_expected_version;
    if not found then
      raise exception using errcode = '40001', message = 'event was changed, deleted, or unavailable';
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'group_id', v_event.group_id,
    'event_id', p_event_id,
    'occurrence_key', v_canonical_key,
    'series_version', case when v_members_changed then p_expected_version + 1 else p_expected_version end,
    'occurrence_version', 0,
    'scope', 'all',
    'changed', v_members_changed,
    'committed', true
  );
end;
$$;

-- 이전의 테이블 반환 RPC가 소스 수준에서 호환되도록 유지한다. 반복 경로는 이제
-- 순번 0에 대한 이전 `single` 별칭과 함께 응답 반환 구현을 사용하고, 실제 단일
-- 일정 동작은 변경되지 않은 원래 함수 본문에 위임한다.
do $$
begin
  if to_regprocedure('public.replace_event_members_if_version(uuid,integer,uuid[])') is not null
     and to_regprocedure('public._legacy_replace_event_members_if_version(uuid,integer,uuid[])') is null then
    execute 'alter function public.replace_event_members_if_version(uuid,integer,uuid[]) rename to _legacy_replace_event_members_if_version';
  end if;
end;
$$;

create or replace function public.replace_event_members_if_version(
  p_event_id uuid,
  p_expected_version integer,
  p_member_ids uuid[]
)
returns table (
  id uuid,
  group_id uuid,
  created_by uuid,
  title text,
  description text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  is_all_day boolean,
  all_day_start date,
  all_day_end date,
  version integer,
  deleted_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  color_value bigint,
  member_ids uuid[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_input_ids uuid[] := coalesce(p_member_ids, '{}'::uuid[]);
  v_event public.events;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if exists (
    select 1 from pg_catalog.unnest(v_input_ids) supplied(user_id)
    where supplied.user_id is null
  ) then
    raise exception using errcode = '22023', message = 'member_ids cannot contain null';
  end if;
  if exists (
    select 1 from public.event_recurrence_rules r
    where r.event_id = p_event_id
  ) then
    v_result := public.replace_recurring_event_members_if_version(
      p_event_id, p_expected_version, 'single', p_member_ids
    );
    return query
    select e.id, e.group_id, e.created_by, e.title, e.description,
           e.starts_at, e.ends_at, e.timezone, e.is_all_day,
           e.all_day_start, e.all_day_end, e.version, e.deleted_at,
           e.created_at, e.updated_at, e.color_value,
           coalesce((select pg_catalog.array_agg(em.user_id order by em.user_id)
                     from public.event_members em where em.event_id = e.id), '{}'::uuid[])
    from public.events e
    where e.id = p_event_id;
    return;
  end if;
  return query
  select *
  from public._legacy_replace_event_members_if_version(
    p_event_id, p_expected_version, p_member_ids
  );
end;
$$;

-- 공개 함수는 기본적으로 PUBLIC에서 EXECUTE 권한을 받는다. 인증된 RPC 표면만
-- 유지하고 도우미와 테이블은 비공개로 둔다.
revoke execute on function public.recurrence_occurrence_key(bigint) from public, anon, authenticated;
revoke execute on function public._event_occurrence_at_index(uuid, bigint) from public, anon, authenticated;
revoke execute on function public._event_occurrences_for_range(uuid, timestamptz, timestamptz, text) from public, anon, authenticated;
revoke execute on function public._recurrence_receipt(uuid, uuid, text, integer, integer, text, boolean) from public, anon, authenticated;
revoke execute on function public.enforce_recurrence_rule_integrity() from public, anon, authenticated;
revoke execute on function public.enforce_occurrence_override_integrity() from public, anon, authenticated;
revoke execute on function public.touch_recurrence_updated_at() from public, anon, authenticated;
revoke execute on function public._legacy_replace_event_members_if_version(uuid, integer, uuid[])
  from public, anon, authenticated;
revoke execute on function public.replace_recurring_event_members_if_version(uuid, integer, text, uuid[])
  from public, anon, authenticated;
grant execute on function public.replace_recurring_event_members_if_version(uuid, integer, text, uuid[])
  to authenticated;
-- 이전 함수의 이름을 바꾼 뒤 호환성 래퍼를 다시 만들기 때문에 CREATE OR REPLACE가
-- NULL proacl(PUBLIC 실행)을 남길 수 있다. 인증 전용 API 표면으로 명시적으로
-- 재설정한다. 일회용 로컬 실행기에서 service_role은 선택 사항이므로 카탈로그로
-- 보호해 권한을 회수한다.
revoke all on function public.replace_event_members_if_version(uuid, integer, uuid[])
  from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    execute 'revoke all on function public.replace_event_members_if_version(uuid, integer, uuid[]) from service_role';
  end if;
end;
$$;
grant execute on function public.replace_event_members_if_version(uuid, integer, uuid[])
  to authenticated;
revoke execute on function public.create_recurring_event_with_members(uuid, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[], text, integer, smallint[], text, integer, date, smallint) from public, anon, authenticated;
grant execute on function public.create_recurring_event_with_members(uuid, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[], text, integer, smallint[], text, integer, date, smallint) to authenticated;
revoke execute on function public.update_event_occurrence_scope_if_version(uuid, integer, text, text, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[], text, integer, smallint[], text, integer, date, smallint) from public, anon, authenticated;
grant execute on function public.update_event_occurrence_scope_if_version(uuid, integer, text, text, text, text, timestamptz, timestamptz, text, boolean, date, date, bigint, uuid[], text, integer, smallint[], text, integer, date, smallint) to authenticated;
revoke execute on function public.delete_event_occurrence_scope_if_version(uuid, integer, text, text) from public, anon, authenticated;
grant execute on function public.delete_event_occurrence_scope_if_version(uuid, integer, text, text) to authenticated;
revoke execute on function public.event_occurrence_by_key(uuid, text) from public, anon, authenticated;
grant execute on function public.event_occurrence_by_key(uuid, text) to authenticated;
revoke execute on function public.events_for_range_v2(uuid, timestamptz, timestamptz, text, integer, text, uuid) from public, anon, authenticated;
grant execute on function public.events_for_range_v2(uuid, timestamptz, timestamptz, text, integer, text, uuid) to authenticated;

commit;
