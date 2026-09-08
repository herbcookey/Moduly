-- 기능 G: 범위를 제한한 그룹 단위 일정 검색이다.
--
-- 기존 캘린더 클라이언트가 events_for_range_v2 시그니처와 커서 의미를 유지하도록
-- 검색을 별도 조회 계약으로 둔다. 결과는 반복 도우미를 통해 확장하므로 구간 및
-- 개별 발생 재정의 텍스트를 캘린더 호출자에게 표시되는 그대로 검색한다.

begin;

-- 작성자 조건자는 일반적인 비반복 경로에서 선택도를 높인다. 유효 행의 최종
-- 기준은 계속 범위/발생 도우미다.
create index if not exists events_group_creator_start_id_live_idx
  on public.events (group_id, created_by, starts_at, id)
  where deleted_at is null;

create or replace function public.search_events_v1(
  p_group_id uuid,
  p_range_start timestamptz,
  p_range_end timestamptz,
  p_view_timezone text default null,
  p_query text default null,
  p_creator_id uuid default null,
  p_participant_id uuid default null,
  p_limit integer default 50,
  p_cursor text default null
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
  v_query text;
  v_query_lower text;
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
  -- 의도적으로 인증과 그룹 권한 검사를 모든 결과 생성 및 발생 확장보다 먼저
  -- 수행한다. 존재 여부를 알아내는 수단이 되지 않도록 누락되었거나 보관되었거나
  -- 접근할 수 없는 그룹은 같은 오류를 사용한다.
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
    from public.groups g
   where g.id = p_group_id
   for share;
  if not found or v_group.deleted_at is not null or not public.is_active_member(p_group_id) then
    raise exception using errcode = '42501', message = 'group is unavailable';
  end if;

  if p_range_start is null or p_range_end is null
     or not pg_catalog.isfinite(p_range_start)
     or not pg_catalog.isfinite(p_range_end)
     or p_range_end <= p_range_start then
    raise exception using errcode = '22023', message = 'range must be a positive half-open interval';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using errcode = '22023', message = 'limit must be between 1 and 100';
  end if;
  v_limit := p_limit;

  v_query := pg_catalog.btrim(coalesce(p_query, ''));
  if v_query <> '' and (
       pg_catalog.char_length(v_query) not between 2 and 100
       or pg_catalog.octet_length(v_query) > 400
     ) then
    raise exception using errcode = '22023', message = 'query must contain 2 to 100 characters and at most 400 bytes';
  end if;
  v_query_lower := pg_catalog.lower(v_query);

  v_view_timezone := coalesce(p_view_timezone, v_group.timezone);
  if not exists (
    select 1
      from pg_catalog.pg_timezone_names t
     where t.name = v_view_timezone
  ) then
    raise exception using errcode = '22023', message = 'view timezone must be an exact IANA timezone name';
  end if;
  v_start_date := (p_range_start at time zone v_view_timezone)::date;
  v_end_date := (p_range_end at time zone v_view_timezone)::date;
  if (p_range_start at time zone v_view_timezone)
       <> pg_catalog.date_trunc('day', p_range_start at time zone v_view_timezone)
     or (p_range_end at time zone v_view_timezone)
       <> pg_catalog.date_trunc('day', p_range_end at time zone v_view_timezone)
     or v_end_date <= v_start_date
     or v_end_date - v_start_date > 366 then
    raise exception using errcode = '22023', message = 'range must be local-midnight and at most 366 days';
  end if;

  if p_creator_id is not null and not exists (
    select 1
      from public.memberships m
     where m.group_id = p_group_id
       and m.user_id = p_creator_id
       and m.is_active
       and m.removed_at is null
  ) then
    raise exception using errcode = '42501', message = 'creator is not an active member of this group';
  end if;
  if p_participant_id is not null and not exists (
    select 1
      from public.memberships m
     where m.group_id = p_group_id
       and m.user_id = p_participant_id
       and m.is_active
       and m.removed_at is null
  ) then
    raise exception using errcode = '42501', message = 'participant is not an active member of this group';
  end if;

  -- 커서는 캘린더 RPC가 사용하는 엄격한 v2 JSON 튜플
  -- {v,starts_at,event_id,occurrence_key}와 정확히 같다. 클라이언트에는
  -- 의도적으로 불투명하며 알 수 없는 JSON 필드는 거부한다.
  if p_cursor is not null then
    if pg_catalog.length(p_cursor) > 4096
       or pg_catalog.btrim(p_cursor) = ''
       or p_cursor !~ '^[A-Za-z0-9_-]+$' then
      raise exception using errcode = '22023', message = 'cursor is malformed';
    end if;
    begin
      v_cursor_text := pg_catalog.convert_from(
        pg_catalog.decode(
          pg_catalog.translate(p_cursor, '-_', '+/')
            || pg_catalog.repeat('=', (4 - (pg_catalog.length(p_cursor) % 4)) % 4),
          'base64'
        ),
        'UTF8'
      );
      v_cursor_wire := v_cursor_text::json;
      v_cursor := v_cursor_text::jsonb;
    exception when others then
      raise exception using errcode = '22023', message = 'cursor is malformed';
    end;
    if pg_catalog.jsonb_typeof(v_cursor) <> 'object'
       or v_cursor - 'v' - 'starts_at' - 'event_id' - 'occurrence_key' <> '{}'::jsonb
       or v_cursor->>'v' is null
       or v_cursor->>'starts_at' is null
       or v_cursor->>'event_id' is null
       or v_cursor->>'occurrence_key' is null then
      raise exception using errcode = '22023', message = 'cursor has an invalid shape';
    end if;
    if pg_catalog.json_typeof(v_cursor_wire -> 'v') <> 'number'
       or (v_cursor_wire -> 'v')::text !~ '^[0-9]+$'
       or (v_cursor->>'v') <> '2'
       or pg_catalog.json_typeof(v_cursor_wire -> 'starts_at') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'event_id') <> 'string'
       or pg_catalog.json_typeof(v_cursor_wire -> 'occurrence_key') <> 'string'
       or (v_cursor->>'starts_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then
      raise exception using errcode = '22023', message = 'cursor has an invalid version or timestamp';
    end if;
    if (v_cursor->>'occurrence_key') !~ '^(single|o[0-9]{20})$' then
      raise exception using errcode = '22023', message = 'cursor occurrence key is invalid';
    end if;
    begin
      v_cursor_start := (v_cursor->>'starts_at')::timestamptz;
      v_cursor_event := (v_cursor->>'event_id')::uuid;
    exception when others then
      raise exception using errcode = '22023', message = 'cursor tuple is invalid';
    end;
    if not pg_catalog.isfinite(v_cursor_start) then
      raise exception using errcode = '22023', message = 'cursor tuple is not finite';
    end if;
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
      cross join lateral public._event_occurrences_for_range(
        e.id, p_range_start, p_range_end, v_view_timezone
      ) o
     where e.group_id = p_group_id
       and e.deleted_at is null
       and (p_creator_id is null or e.created_by = p_creator_id)
       and (
         v_query_lower = ''
         or position(v_query_lower in pg_catalog.lower(o.title)) > 0
         or position(v_query_lower in pg_catalog.lower(o.description)) > 0
       )
       and (p_participant_id is null or exists (
         select 1
           from public.event_members em
           join public.memberships m
             on m.group_id = e.group_id
            and m.user_id = em.user_id
            and m.is_active
            and m.removed_at is null
          where em.event_id = e.id
            and em.user_id = p_participant_id
       ))
       and (
         v_cursor_start is null
         or o.starts_at > v_cursor_start
         or (o.starts_at = v_cursor_start and o.event_id > v_cursor_event)
         or (o.starts_at = v_cursor_start and o.event_id = v_cursor_event and o.occurrence_key > v_cursor_key)
       )
     order by o.starts_at, o.event_id, o.occurrence_key
     limit (v_limit + 1)
  loop
    if v_seen >= v_limit then
      v_has_more := true;
      exit;
    end if;
    v_rows := v_rows || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', v_row.id,
      'event_id', v_row.event_id,
      'series_id', v_row.series_id,
      'group_id', v_row.group_id,
      'created_by', v_row.created_by,
      'title', v_row.title,
      'description', v_row.description,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at,
      'timezone', v_row.timezone,
      'is_all_day', v_row.is_all_day,
      'all_day_start', v_row.all_day_start,
      'all_day_end', v_row.all_day_end,
      'version', v_row.version,
      'deleted_at', v_row.deleted_at,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'color_value', v_row.color_value,
      'member_ids', to_jsonb(v_row.member_ids),
      'occurrence_key', v_row.occurrence_key,
      'occurrence_index', v_row.occurrence_index,
      'occurrence_version', v_row.occurrence_version,
      'is_occurrence', v_row.is_occurrence,
      'scheduled_starts_at', v_row.scheduled_starts_at,
      'scheduled_ends_at', v_row.scheduled_ends_at,
      'recurrence_rule', v_row.recurrence_rule
    ));
    v_seen := v_seen + 1;
    v_last := v_row;
  end loop;

  if v_has_more then
    v_cursor := pg_catalog.jsonb_build_object(
      'v', 2,
      'starts_at', v_last.starts_at,
      'event_id', v_last.event_id,
      'occurrence_key', v_last.occurrence_key
    );
    v_cursor_text := pg_catalog.rtrim(
      pg_catalog.translate(
        pg_catalog.replace(
          pg_catalog.encode(pg_catalog.convert_to(v_cursor::text, 'UTF8'), 'base64'),
          E'\n', ''
        ),
        '+/', '-_'
      ),
      '='
    );
  else
    v_cursor_text := null;
  end if;

  return pg_catalog.jsonb_build_object(
    'events', v_rows,
    'next_cursor', v_cursor_text,
    'has_more', v_has_more
  );
end;
$$;

comment on function public.search_events_v1(uuid, timestamptz, timestamptz, text, text, uuid, uuid, integer, text)
  is '작성자/참여자 필터와 v2 키셋 커서를 사용하는 범위 제한 그룹 단위 리터럴 유니코드 일정 검색이다.';

revoke execute on function public.search_events_v1(uuid, timestamptz, timestamptz, text, text, uuid, uuid, integer, text)
  from public, anon, authenticated;
grant execute on function public.search_events_v1(uuid, timestamptz, timestamptz, text, text, uuid, uuid, integer, text)
  to authenticated;

commit;
