-- 이미 배포된 반복 일정 스키마를 바꾸거나 기존 행을 수정하지 않고,
-- 월간 반복의 순번 계약만 앞으로 교체한다. monthly_day를 기준 달에
-- 적용한 후 생긴 날짜가 기준일보다 앞이면 다음 달의 첫 유효한 날짜를
-- 순번 0으로 사용한다. 이로써 이미 저장된 기준점과 안정적인 순번 키를
-- 그대로 보존한다.

begin;

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
  v_month_anchor_candidate date;
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

  if p_occurrence_index is not null and p_occurrence_index > 2147483647::bigint then
    return;
  end if;

  if p_occurrence_index = -1
     and not exists (
       select 1
       from public.event_recurrence_rules r
       where r.event_id = p_event_id
     ) then
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
      and (r.end_occurrence_index is null
           or p_occurrence_index < r.end_occurrence_index)
    order by r.start_occurrence_index, r.segment_no
  loop
    v_offset := p_occurrence_index - v_rule.start_occurrence_index;
    if v_rule.end_mode = 'count' and v_offset >= v_rule.occurrence_count then
      continue;
    end if;

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
        -- 순번 0 후보가 기준 달에서 이미 지나갔는지 먼저 판정한다.
        -- 지나갔다면 다음 달을 순번 0의 기준으로 삼고 그 뒤부터
        -- interval을 적용한다.
        v_month_start := pg_catalog.date_trunc(
          'month',
          v_rule.anchor_local_date
        )::date;
        v_month_last := (pg_catalog.date_trunc('month', v_month_start)
          + interval '1 month - 1 day')::date;
        v_month_anchor_candidate := v_month_start
          + least(
              v_rule.monthly_day,
              extract(day from v_month_last)::integer
            ) - 1;
        v_month_offset := v_offset * v_rule.interval_value
          + case
              when v_month_anchor_candidate < v_rule.anchor_local_date then 1
              else 0
            end;
        if v_month_offset > 2147483647::bigint
           or v_month_offset < -2147483648::bigint then
          continue;
        end if;
        v_month_start := (pg_catalog.date_trunc(
          'month',
          v_rule.anchor_local_date
        ) + (v_month_offset::integer * interval '1 month'))::date;
        v_month_last := (pg_catalog.date_trunc('month', v_month_start)
          + interval '1 month - 1 day')::date;
        v_occurrence_date := v_month_start
          + least(
              v_rule.monthly_day,
              extract(day from v_month_last)::integer
            ) - 1;
      end if;

      if v_rule.end_mode = 'until' and v_occurrence_date > v_rule.until_date then
        continue;
      end if;

      if v_rule.is_all_day then
        v_local_start := v_occurrence_date::timestamp;
        v_local_end := (v_occurrence_date + v_rule.duration_days)::timestamp;
      else
        v_local_start := v_occurrence_date::timestamp + v_rule.anchor_local_time;
        v_local_end := v_local_start
          + (v_rule.duration_seconds * interval '1 second');
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

    select coalesce(
      pg_catalog.array_agg(em.user_id order by em.user_id),
      '{}'::uuid[]
    ) into v_member_ids
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
             case when v_rule.is_all_day
               then v_occurrence_date + v_rule.duration_days end),
           v_event.version, v_event.deleted_at, v_event.created_at,
           v_event.updated_at, coalesce(v_override.color_value, v_rule.color_value),
           v_member_ids, v_occurrence_key, p_occurrence_index,
           coalesce(v_override.version, 0), true, v_scheduled_start,
           v_scheduled_end,
           pg_catalog.jsonb_build_object(
             'frequency', v_rule.frequency,
             'interval', v_rule.interval_value,
             'weekdays', pg_catalog.to_jsonb(v_rule.weekdays),
             'end', v_rule.end_mode,
             'count', v_rule.occurrence_count,
             'until_date', v_rule.until_date,
             'monthly_day', v_rule.monthly_day
           );
    return;
  end loop;
end;
$$;

comment on function public._event_occurrence_at_index(uuid, bigint) is
  '월간 순번 0을 기준 시각 이후의 첫 유효한 날짜로 정규화하는 반복 발생 구체화기다.';

commit;
