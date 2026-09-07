-- Bounded calendar reads for monthly and agenda views.
--
-- This migration is additive.  It keeps the Feature 5 event/member row shape,
-- leaves the legacy events table grants and realtime publication intact, and
-- exposes one authenticated RPC so range reads never need an unbounded group
-- snapshot.  Cursor pagination is deliberately opaque to clients; a later
-- occurrence/search API can introduce a new cursor version without changing
-- this event-only contract.

begin;

-- The existing index is useful for a starts_at predicate, but the event id is
-- required to make ties deterministic for keyset pagination.  The all-day
-- branch uses date columns and gets its own small partial index.
create index if not exists events_group_start_id_live_idx
  on public.events (group_id, starts_at, id)
  where deleted_at is null;

create index if not exists events_group_allday_dates_live_idx
  on public.events (group_id, all_day_start, all_day_end, id)
  where deleted_at is null and is_all_day;

comment on index public.events_group_start_id_live_idx is
  'Deterministic live-event order for bounded (starts_at, id) keyset pages.';
comment on index public.events_group_allday_dates_live_idx is
  'Live all-day date overlap support for bounded calendar range reads.';

-- The function returns a JSON envelope rather than a SETOF row so an empty
-- page can still carry an explicit next_cursor/has_more contract.  Every event
-- object intentionally mirrors the Feature 5 RPC row, including member_ids.
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

  -- Lock the group before membership state.  Archive/ownership/membership
  -- RPCs use the same group-first order, making lifecycle races deterministic.
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
      -- Keep this identical to the not-found/archived branch so callers
      -- cannot distinguish group existence or lifecycle from membership.
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

  -- Calendar callers send UTC instants corresponding to local midnight in the
  -- view timezone.  Requiring that shape keeps all-day date boundaries
  -- unambiguous and prevents a partial-day request from silently changing the
  -- date-only semantics.
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

  -- Cursor format v1 is an unpadded URL-safe base64-encoded JSON object with
  -- exactly {v, starts_at, event_id}.  It is intentionally strict: unknown
  -- keys, another version, invalid UUID/timestamp, or a non-finite tuple
  -- fails closed instead of producing an attacker-controlled skip.  A cursor
  -- below range_start is valid because a spanning event may begin before the
  -- requested window; a tuple after range_end is also valid because an
  -- all-day event's stored starts_at uses its own timezone.
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
      -- Keep the original JSON token as well as its JSONB view.  JSONB
      -- canonicalizes numeric spellings (for example 1e0 -> 1), while the
      -- Dart wire contract requires the version to be the JSON integer 1.
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

    -- Dart's EventRangeCursor decoder requires the JSON number 1 (not the
    -- string "1" or a floating-point spelling such as 1.0), the exact three
    -- keys above, and an ISO-8601 timestamp carrying an explicit Z/offset.
    -- Validate the wire text before casting: PostgreSQL would otherwise parse
    -- a timezone-less timestamp in the session timezone.
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

    -- Match the Dart parser exactly: four-digit year/month/day, mandatory
    -- seconds, optional one-to-six fractional digits, and an uppercase Z or
    -- signed HH:MM offset.  The captures are validated below before the
    -- timestamptz cast so PostgreSQL cannot normalize impossible components.
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
    -- Do not distinguish an outsider from an inactive target.  Both are
    -- outside the caller's active-group scope.
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

-- Public functions receive EXECUTE from PUBLIC by default.  Remove inherited
-- access explicitly, then expose only the authenticated Data API role.
revoke execute on function public.events_for_range(
  uuid, timestamptz, timestamptz, text, integer, text, uuid
) from public, anon, authenticated;
grant execute on function public.events_for_range(
  uuid, timestamptz, timestamptz, text, integer, text, uuid
) to authenticated;

commit;
