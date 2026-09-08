-- 월간 반복의 종료일은 정규화된 순번 0 날짜를 포함해야 한다.
-- 20260908001038에서 순번 0 계산을 바로잡은 뒤에도 생성 RPC는 기준일만
-- 검사했기 때문에, 기준 달의 monthly_day가 이미 지난 규칙을 삽입한 다음
-- 발생 행을 0건 반환할 수 있었다. 기존 행은 변경하지 않고 향후 쓰기만 막는다.

begin;

create or replace function public._monthly_occurrence_zero_date(
  p_anchor_local_date date,
  p_monthly_day smallint
)
returns date
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_month_start date;
  v_candidate date;
  v_last_day integer;
begin
  if p_monthly_day not between 1 and 31 then
    raise exception using errcode = '22023', message = 'monthly_day must be between 1 and 31';
  end if;

  v_month_start := pg_catalog.make_date(
    extract(year from p_anchor_local_date)::integer,
    extract(month from p_anchor_local_date)::integer,
    1
  );
  v_last_day := extract(
    day from v_month_start + interval '1 month - 1 day'
  )::integer;
  v_candidate := v_month_start +
    (least(p_monthly_day::integer, v_last_day) - 1);

  if v_candidate < p_anchor_local_date then
    v_month_start := (v_month_start + interval '1 month')::date;
    v_last_day := extract(
      day from v_month_start + interval '1 month - 1 day'
    )::integer;
    v_candidate := v_month_start +
      (least(p_monthly_day::integer, v_last_day) - 1);
  end if;
  return v_candidate;
end;
$$;

comment on function public._monthly_occurrence_zero_date(date, smallint) is
  '기준 현지 날짜 이상인 첫 유효 월간 날짜다. interval은 순번 0 이후 간격에만 적용된다.';

create or replace function public.enforce_recurrence_until_occurrence_zero()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.frequency = 'monthly'
     and new.end_mode = 'until'
     and new.until_date < public._monthly_occurrence_zero_date(
       new.anchor_local_date,
       new.monthly_day
     ) then
    raise exception using
      errcode = '22023',
      message = 'until_date precedes the first occurrence';
  end if;
  return new;
end;
$$;

drop trigger if exists event_recurrence_until_occurrence_zero
  on public.event_recurrence_rules;
create trigger event_recurrence_until_occurrence_zero
before insert or update on public.event_recurrence_rules
for each row execute function public.enforce_recurrence_until_occurrence_zero();

revoke execute on function public._monthly_occurrence_zero_date(date, smallint)
  from public, anon, authenticated;
revoke execute on function public.enforce_recurrence_until_occurrence_zero()
  from public, anon, authenticated;

commit;
