-- 선택적인 로컬 데모 시드다.
--
-- Supabase는 `supabase db reset` 중 마이그레이션 뒤에 이 파일을 실행한다.
-- 새 로컬 스택에는 보통 인증 사용자가 없으므로 누군가 가입할 때까지
-- 의도적으로 아무 작업도 하지 않는다. 가짜 auth.users 행이나 비밀번호를
-- 만들지 않는다. 로컬 사용자를 만든 뒤 시드를 다시 실행한다.

do $$
declare
  v_user_id uuid;
  v_existing_owner uuid;
  v_group_id constant uuid := '00000000-0000-4000-8000-000000001001';
  v_event_id constant uuid := '00000000-0000-4000-8000-000000001002';
begin
  select id into v_user_id
  from auth.users
  order by created_at
  limit 1;

  if v_user_id is null then
    raise notice 'Moduly seed skipped: create a local auth user, then run `supabase db seed` again.';
    return;
  end if;

  select owner_id into v_existing_owner
  from public.groups
  where id = v_group_id;
  if v_existing_owner is not null and v_existing_owner <> v_user_id then
    raise notice 'Moduly seed skipped: demo group already belongs to another local user.';
    return;
  end if;

  insert into public.profiles (id, display_name, timezone)
  values (v_user_id, 'Local planner', 'Asia/Seoul')
  on conflict (id) do update
    set display_name = excluded.display_name,
        timezone = excluded.timezone;

  insert into public.groups (id, owner_id, name, timezone)
  values (v_group_id, v_user_id, 'Moduly demo', 'Asia/Seoul')
  on conflict (id) do nothing;

  -- 일정방 트리거가 소유자 멤버십을 만든다. 이 upsert는 관계없는 사용자에게
  -- 접근 권한을 주지 않고 부분적으로 시드된 데이터베이스를 복구한다.
  insert into public.memberships (group_id, user_id, role, is_active, removed_at)
  values (v_group_id, v_user_id, 'owner', true, null)
  on conflict (group_id, user_id) do update
    set role = 'owner', is_active = true, removed_at = null;

  insert into public.events (
    id, group_id, created_by, title, description,
    starts_at, ends_at, timezone, is_all_day,
    all_day_start, all_day_end
  ) values (
    v_event_id,
    v_group_id,
    v_user_id,
    'Welcome to Moduly',
    'Edit or remove this local demo event to verify optimistic locking.',
    '2025-12-31 15:00:00+00',
    '2026-01-02 15:00:00+00',
    'Asia/Seoul',
    true,
    '2026-01-01',
    '2026-01-03'
  )
  on conflict (id) do nothing;
end;
$$;
