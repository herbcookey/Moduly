-- Flutter 모델에 이미 포함된 그룹 및 일정 표시 필드를 영속화한다. 열을 NOT NULL로
-- 만들기 전에 기존 행을 채우므로 데이터를 삭제하지 않고 마이그레이션을 적용할 수 있다.

begin;

alter table public.groups
  add column if not exists description text;

update public.groups
set description = ''
where description is null;

alter table public.groups
  alter column description set default '',
  alter column description set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'groups_description_length_check'
      and conrelid = 'public.groups'::regclass
  ) then
    alter table public.groups
      add constraint groups_description_length_check
      check (char_length(description) <= 10000);
  end if;
end;
$$;

comment on column public.groups.description is
  '선택적 그룹 설명이며 10,000자로 제한한다.';

alter table public.events
  add column if not exists color_value bigint;

update public.events
set color_value = 4282874742
where color_value is null;

alter table public.events
  alter column color_value set default 4282874742,
  alter column color_value set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'events_color_value_range_check'
      and conrelid = 'public.events'::regclass
  ) then
    alter table public.events
      add constraint events_color_value_range_check
      check (color_value between 0 and 4294967295);
  end if;
end;
$$;

comment on column public.events.color_value is
  '0..4294967295의 닫힌 범위를 사용하는 부호 없는 32비트 ARGB 색상 값이다.';

-- 오버로드된 RPC를 남기지 않고 이전의 인자 두 개짜리 시그니처를 제거한다.
-- timezone을 두 번째 매개변수로 유지하고 선택적 description을 세 번째에 추가해
-- 위치 기반 호출자와의 호환성을 보존한다.
drop function if exists public.create_group(text, text);
drop function if exists public.create_group(text, text, text);

create function public.create_group(
  p_name text,
  p_timezone text default 'UTC',
  p_description text default ''
)
returns public.groups
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_description text := btrim(coalesce(p_description, ''));
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'group name must be 1-160 characters';
  end if;
  if char_length(v_description) > 10000 then
    raise exception using errcode = '22023', message = 'group description must be at most 10000 characters';
  end if;
  if not public.is_valid_timezone(coalesce(p_timezone, 'UTC')) then
    raise exception using errcode = '22023', message = 'timezone must be an IANA timezone name';
  end if;

  insert into public.groups (owner_id, name, timezone, description)
  values (v_user_id, btrim(p_name), coalesce(p_timezone, 'UTC'), v_description)
  returning * into v_group;
  return v_group;
end;
$$;

-- PostgreSQL은 새 함수의 EXECUTE 권한을 기본적으로 PUBLIC에 부여한다. 이 RPC는
-- 인증된 호출자에게만 공개한다. 함수는 SECURITY DEFINER에서 자체 auth.uid 및
-- 입력 검증을 수행한다.
revoke execute on function public.create_group(text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_group(text, text, text) to authenticated;

-- 초기 마이그레이션이 열 단위 권한을 사용하므로 새 열에는 명시적인 권한이
-- 필요하다. 호출자가 읽거나 변경할 수 있는 행은 계속 RLS 정책이 제어한다.
grant insert (description) on public.groups to authenticated;
grant update (description) on public.groups to authenticated;
grant insert (color_value) on public.events to authenticated;
grant update (color_value) on public.events to authenticated;

commit;
