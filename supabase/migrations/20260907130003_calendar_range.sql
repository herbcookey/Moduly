-- 월간 및 일정 목록 보기를 위한 범위 제한 캘린더 조회다.
--
-- 이 마이그레이션은 기존 기능에 추가만 한다. 기능 5의 일정/멤버 행 형태와
-- 기존 events 테이블 권한 및 Realtime publication을 그대로 유지하고, 범위
-- 조회에 제한 없는 그룹 스냅샷이 필요하지 않도록 인증된 RPC 하나를 노출한다.
-- 커서 페이지네이션은 의도적으로 클라이언트에 불투명하다. 이후 발생/검색
-- API는 이 일정 전용 계약을 바꾸지 않고 새 커서 버전을 도입할 수 있다.

begin;

-- 기존 인덱스는 starts_at 조건에 유용하지만, 키셋 페이지네이션에서 동률 순서를
-- 결정하려면 일정 ID가 필요하다. 종일 일정 분기는 날짜 열을 사용하므로 작은
-- 부분 인덱스를 별도로 둔다.
create index if not exists events_group_start_id_live_idx
  on public.events (group_id, starts_at, id)
  where deleted_at is null;

create index if not exists events_group_allday_dates_live_idx
  on public.events (group_id, all_day_start, all_day_end, id)
  where deleted_at is null and is_all_day;

comment on index public.events_group_start_id_live_idx is
  '범위 제한 (starts_at, id) 키셋 페이지를 위한 결정적인 운영 일정 순서다.';
comment on index public.events_group_allday_dates_live_idx is
  '범위 제한 캘린더 조회에서 운영 중인 종일 일정의 날짜 겹침을 지원한다.';

-- 빈 페이지도 명시적인 next_cursor/has_more 계약을 전달할 수 있도록 함수는
-- SETOF 행 대신 JSON 봉투를 반환한다. 각 일정 객체는 member_ids를 포함해
-- 의도적으로 기능 5 RPC 행과 같은 형태를 사용한다.
create or replace function public.events_for_range(
  p_group_id uuid,
  p_range_start timestamptz,
  p_range_end timestamptz,
  p_view_timezone text default null,
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
  v_actor_id uuid := (select auth.uid());
  v_group public.groups;
  v_view_timezone text;
  v_local_start timestamp;
  v_local_end timestamp;
  v_start_date date;
  v_end_date date;
  v_limit integer;
  v_cursor jsonb;
  v_cursor_wire json;
  v_cursor_text text;
  v_cursor_start_text text;
  v_cursor_parts text[];
  v_cursor_year integer;
  v_cursor_month integer;
  v_cursor_day integer;
  v_cursor_hour integer;
  v_cursor_minute integer;
  v_cursor_second integer;
  v_cursor_offset_hour integer;
  v_cursor_offset_minute integer;
  v_cursor_days_in_month integer;
  v_cursor_start timestamptz;
  v_cursor_event_id uuid;
  v_cursor_version text;
  v_rows jsonb := '[]'::jsonb;
  v_next_cursor text;
  v_seen integer := 0;
  v_has_more boolean := false;
  v_last_start timestamptz;
  v_last_id uuid;
  v_event public.events;
begin
  if v_actor_id is null then
    raise exception using
      errcode = '28000',
      message = 'authentication is required';
  end if;

  if p_range_start is null or p_range_end is null
     or not pg_catalog.isfinite(p_range_start)
     or not pg_catalog.isfinite(p_range_end)
     or p_range_end <= p_range_start then
    raise exception using
      errcode = '22023',
      message = 'range must be a positive half-open interval';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception using
      errcode = '22023',
      message = 'limit must be between 1 and 200';
  end if;
  v_limit := p_limit;

  -- 멤버십 상태보다 그룹을 먼저 잠근다. 보관/소유권/멤버십 RPC도 같은 그룹
  -- 우선 순서를 사용하므로 수명 주기 경합 결과가 결정적이다.
  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for share;

  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '42501',
      message = 'group is unavailable';
  end if;

  if not exists (
       select 1
       from public.memberships m
       where m.group_id = p_group_id
         and m.user_id = v_actor_id
         and m.is_active
         and m.removed_at is null
     ) then
    raise exception using
      errcode = '42501',
      -- 호출자가 그룹 존재 여부나 수명 주기를 멤버십과 구분하지 못하도록
      -- 찾을 수 없음/보관됨 분기와 동일하게 유지한다.
      message = 'group is unavailable';
  end if;

  v_view_timezone := coalesce(p_view_timezone, v_group.timezone);
  if v_view_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names t
       where t.name = v_view_timezone
     ) then
    raise exception using
      errcode = '22023',
      message = 'view timezone must be an exact IANA timezone name';
  end if;

  -- 캘린더 호출자는 보기 시간대의 현지 자정에 해당하는 UTC 시각을 보낸다.
  -- 이 형태를 강제하면 종일 일정의 날짜 경계가 명확해지고, 일부 날짜 요청이
  -- 날짜 전용 의미를 조용히 바꾸는 것을 막을 수 있다.
  v_local_start := p_range_start at time zone v_view_timezone;
  v_local_end := p_range_end at time zone v_view_timezone;
  if v_local_start <> pg_catalog.date_trunc('day', v_local_start)
     or v_local_end <> pg_catalog.date_trunc('day', v_local_end) then
    raise exception using
      errcode = '22023',
      message = 'range endpoints must be local midnight in the view timezone';
  end if;
  v_start_date := v_local_start::date;
  v_end_date := v_local_end::date;
  if v_end_date <= v_start_date then
    raise exception using
      errcode = '22023',
      message = 'range must cover at least one calendar day';
  end if;
  if v_end_date - v_start_date > 366 then
    raise exception using
      errcode = '22023',
      message = 'range must not exceed 366 calendar days';
  end if;

  -- 커서 형식 v1은 정확히 {v, starts_at, event_id}를 담은 패딩 없는 URL 안전
  -- Base64 인코딩 JSON 객체다. 알 수 없는 키, 다른 버전, 잘못된 UUID/타임스탬프,
  -- 유한하지 않은 튜플은 공격자가 제어하는 건너뛰기를 만들지 않고 실패 시
  -- 차단하도록 의도적으로 엄격하게 검사한다. 기간에 걸친 일정은 요청 창보다
  -- 먼저 시작할 수 있으므로 range_start보다 앞선 커서가 유효하다. 종일 일정에
  -- 저장된 starts_at은 자체 시간대를 사용하므로 range_end 뒤의 튜플도 유효하다.
  if p_cursor is not null then
    if pg_catalog.length(p_cursor) > 4096
       or pg_catalog.btrim(p_cursor) = ''
       or p_cursor !~ '^[A-Za-z0-9_-]+$' then
      raise exception using
        errcode = '22023',
        message = 'cursor must be an unpadded URL-safe base64 event cursor';
    end if;
    begin
      v_cursor_text := pg_catalog.convert_from(
        pg_catalog.decode(
          pg_catalog.translate(p_cursor, '-_', '+/')
            || pg_catalog.repeat(
                 '=',
                 (4 - (pg_catalog.length(p_cursor) % 4)) % 4
               ),
          'base64'
        ),
        'UTF8'
      );
      -- 원본 JSON 토큰과 JSONB 표현을 모두 유지한다. JSONB는 숫자 표기(예:
      -- 1e0 -> 1)를 정규화하지만 Dart 전송 계약에서는 버전이 JSON 정수 1이어야 한다.
      v_cursor_wire := v_cursor_text::json;
      v_cursor := v_cursor_text::jsonb;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'cursor is malformed';
    end;

    if pg_catalog.jsonb_typeof(v_cursor) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'cursor has an invalid shape';
    end if;
    if v_cursor ->> 'v' is null
       or v_cursor ->> 'starts_at' is null
       or v_cursor ->> 'event_id' is null
       or v_cursor - 'v' - 'starts_at' - 'event_id' <> '{}'::jsonb then
      raise exception using
        errcode = '22023',
        message = 'cursor has an invalid shape';
    end if;

    -- Dart의 EventRangeCursor 디코더에는 문자열 "1"이나 1.0 같은 부동 소수점
    -- 표기가 아닌 JSON 숫자 1, 위의 정확한 키 세 개, 명시적인 Z/오프셋을 포함한
    -- ISO-8601 타임스탬프가 필요하다. 그렇지 않으면 PostgreSQL이 시간대 없는
    -- 타임스탬프를 세션 시간대로 파싱하므로 변환 전에 전송 문자열을 검증한다.
    if pg_catalog.json_typeof(v_cursor_wire -> 'v') <> 'number'
       or pg_catalog.jsonb_typeof(v_cursor -> 'v') <> 'number'
       or (v_cursor_wire -> 'v')::text !~ '^-?[0-9]+$' then
      raise exception using
        errcode = '22023',
        message = 'cursor has an invalid shape';
    end if;
    if pg_catalog.jsonb_typeof(v_cursor -> 'starts_at') <> 'string'
       or pg_catalog.jsonb_typeof(v_cursor -> 'event_id') <> 'string' then
      raise exception using
        errcode = '22023',
        message = 'cursor has an invalid shape';
    end if;

    -- Dart 파서와 정확히 맞춘다. 연/월/일은 네 자리, 초는 필수, 소수점 이하는
    -- 한 자리에서 여섯 자리까지 선택 사항이며, 대문자 Z 또는 부호 있는 HH:MM
    -- 오프셋이 필요하다. PostgreSQL이 불가능한 구성 요소를 정규화하지 못하도록
    -- 아래에서 캡처 값을 검증한 뒤 timestamptz로 변환한다.
    v_cursor_start_text := v_cursor ->> 'starts_at';
    v_cursor_parts := pg_catalog.regexp_match(
      v_cursor_start_text,
      '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?(Z|[+-][0-9]{2}:[0-9]{2})$'
    );
    if v_cursor_parts is null then
      if v_cursor_start_text !~ '(Z|z|[+-][0-9]{2}:[0-9]{2})$' then
        raise exception using
          errcode = '22023',
          message = 'cursor timestamp must include an explicit timezone';
      else
        raise exception using
          errcode = '22023',
          message = 'cursor timestamp is invalid';
      end if;
    end if;

    begin
      v_cursor_year := v_cursor_parts[1]::integer;
      v_cursor_month := v_cursor_parts[2]::integer;
      v_cursor_day := v_cursor_parts[3]::integer;
      v_cursor_hour := v_cursor_parts[4]::integer;
      v_cursor_minute := v_cursor_parts[5]::integer;
      v_cursor_second := v_cursor_parts[6]::integer;
      if v_cursor_parts[8] = 'Z' then
        v_cursor_offset_hour := 0;
        v_cursor_offset_minute := 0;
      else
        v_cursor_offset_hour := pg_catalog.substr(v_cursor_parts[8], 2, 2)::integer;
        v_cursor_offset_minute := pg_catalog.substr(v_cursor_parts[8], 5, 2)::integer;
      end if;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'cursor timestamp is invalid';
    end;

    v_cursor_days_in_month := case v_cursor_month
      when 1 then 31
      when 2 then case
        when v_cursor_year % 400 = 0
          or (v_cursor_year % 4 = 0 and v_cursor_year % 100 <> 0)
          then 29
        else 28
      end
      when 3 then 31
      when 4 then 30
      when 5 then 31
      when 6 then 30
      when 7 then 31
      when 8 then 31
      when 9 then 30
      when 10 then 31
      when 11 then 30
      when 12 then 31
      else 0
    end;
    if v_cursor_month < 1
       or v_cursor_month > 12
       or v_cursor_day < 1
       or v_cursor_day > v_cursor_days_in_month
       or v_cursor_hour < 0
       or v_cursor_hour > 23
       or v_cursor_minute < 0
       or v_cursor_minute > 59
       or v_cursor_second < 0
       or v_cursor_second > 59
       or v_cursor_offset_hour < 0
       or v_cursor_offset_hour > 23
       or v_cursor_offset_minute < 0
       or v_cursor_offset_minute > 59 then
      raise exception using
        errcode = '22023',
        message = 'cursor timestamp is invalid';
    end if;

    v_cursor_version := v_cursor_wire ->> 'v';
    if v_cursor_version <> '1' then
      raise exception using
        errcode = '22023',
        message = 'cursor version is unsupported';
    end if;

    begin
      v_cursor_start := v_cursor_start_text::timestamptz;
      v_cursor_event_id := (v_cursor ->> 'event_id')::uuid;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'cursor tuple is invalid';
    end;
    if not pg_catalog.isfinite(v_cursor_start) then
      raise exception using
        errcode = '22023',
        message = 'cursor tuple is not finite';
    end if;
  end if;

  if p_participant_id is not null
     and not exists (
       select 1
       from public.memberships target
       where target.group_id = p_group_id
         and target.user_id = p_participant_id
         and target.is_active
         and target.removed_at is null
     ) then
    -- 외부 사용자와 비활성 대상을 구분하지 않는다. 둘 다 호출자의 활성 그룹
    -- 범위 밖에 있다.
    raise exception using
      errcode = '42501',
      message = 'participant is not an active member of this group';
  end if;

  for v_event in
    select e.*
    from public.events e
    where e.group_id = p_group_id
      and e.deleted_at is null
      and (
        (
          not e.is_all_day
          and e.starts_at < p_range_end
          and e.ends_at > p_range_start
        )
        or (
          e.is_all_day
          and e.all_day_start < v_end_date
          and e.all_day_end > v_start_date
        )
      )
      and (
        v_cursor_start is null
        or e.starts_at > v_cursor_start
        or (e.starts_at = v_cursor_start and e.id > v_cursor_event_id)
      )
      and (
        p_participant_id is null
        or exists (
          select 1
          from public.event_members em
          join public.memberships target
            on target.group_id = e.group_id
           and target.user_id = em.user_id
          where em.event_id = e.id
            and em.user_id = p_participant_id
            and target.is_active
            and target.removed_at is null
        )
      )
    order by e.starts_at, e.id
    limit (v_limit + 1)
  loop
    if v_seen >= v_limit then
      v_has_more := true;
      exit;
    end if;

    v_rows := v_rows || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', v_event.id,
        'group_id', v_event.group_id,
        'created_by', v_event.created_by,
        'title', v_event.title,
        'description', v_event.description,
        'starts_at', v_event.starts_at,
        'ends_at', v_event.ends_at,
        'timezone', v_event.timezone,
        'is_all_day', v_event.is_all_day,
        'all_day_start', v_event.all_day_start,
        'all_day_end', v_event.all_day_end,
        'version', v_event.version,
        'deleted_at', v_event.deleted_at,
        'created_at', v_event.created_at,
        'updated_at', v_event.updated_at,
        'color_value', v_event.color_value,
        'member_ids', coalesce(
          (
            select pg_catalog.jsonb_agg(
                     pg_catalog.to_jsonb(em.user_id::text)
                     order by em.user_id
                   )
            from public.event_members em
            join public.memberships target
              on target.group_id = v_event.group_id
             and target.user_id = em.user_id
            where em.event_id = v_event.id
              and target.is_active
              and target.removed_at is null
          ),
          '[]'::jsonb
        )
      )
    );
    v_seen := v_seen + 1;
    v_last_start := v_event.starts_at;
    v_last_id := v_event.id;
  end loop;

  if v_has_more then
    v_cursor := pg_catalog.jsonb_build_object(
      'v', 1,
      'starts_at', v_last_start,
      'event_id', v_last_id
    );
    v_next_cursor := pg_catalog.rtrim(
      pg_catalog.translate(
        pg_catalog.replace(
          pg_catalog.encode(
            pg_catalog.convert_to(v_cursor::text, 'UTF8'),
            'base64'
          ),
          E'\n',
          ''
        ),
        '+/',
        '-_'
      ),
      '='
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'events', v_rows,
    'next_cursor', v_next_cursor,
    'has_more', v_has_more
  );
end;
$$;

-- 공개 함수는 기본적으로 PUBLIC에서 EXECUTE 권한을 받는다. 상속된 접근 권한을
-- 명시적으로 제거한 뒤 인증된 Data API 역할에만 노출한다.
revoke execute on function public.events_for_range(
  uuid, timestamptz, timestamptz, text, integer, text, uuid
) from public, anon, authenticated;
grant execute on function public.events_for_range(
  uuid, timestamptz, timestamptz, text, integer, text, uuid
) to authenticated;

commit;
