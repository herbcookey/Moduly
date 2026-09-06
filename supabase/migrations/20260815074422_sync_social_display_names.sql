-- 소셜 인증 프로필에는 제공자가 전달한 표시 이름을 사용한다. 이 값은
-- 권한 부여 입력으로 사용하지 않으며, 멤버십과 auth.uid()만 접근 결정을
-- 내리는 근거로 남는다.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_display_name text;
begin
  v_display_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'preferred_username'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'nickname'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    '멤버'
  );

  insert into public.profiles (id, display_name, timezone)
  values (
    new.id,
    left(v_display_name, 120),
    coalesce(nullif(new.raw_user_meta_data ->> 'timezone', ''), 'UTC')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- 사용자가 수정한 이름은 보존한다. 기존 트리거가 자동 생성한 값(빈 값,
-- member 자리표시자 또는 이메일의 로컬 부분)만 교체한다.
update public.profiles as profile
set display_name = left(provider_name.value, 120),
    updated_at = now()
from auth.users as auth_user
cross join lateral (
  select coalesce(
    nullif(btrim(auth_user.raw_user_meta_data ->> 'display_name'), ''),
    nullif(btrim(auth_user.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(auth_user.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(auth_user.raw_user_meta_data ->> 'preferred_username'), ''),
    nullif(btrim(auth_user.raw_user_meta_data ->> 'nickname'), '')
  ) as value
) as provider_name
where profile.id = auth_user.id
  and provider_name.value is not null
  and (
    btrim(profile.display_name) = ''
    or profile.display_name = '멤버'
    or profile.display_name = split_part(coalesce(auth_user.email, ''), '@', 1)
  );

revoke execute on function public.handle_new_user()
  from public, anon, authenticated;
