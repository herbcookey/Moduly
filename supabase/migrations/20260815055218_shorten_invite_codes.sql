-- 사람이 읽기 쉬운 초대 코드다. 새로 발급하는 평문만 바꾸므로 기존 48자리
-- 토큰도 계속 유효하며 저장된 해시와 검증 의미는 변하지 않는다.
create or replace function public.create_invite_code(
  p_group_id uuid,
  p_expires_at timestamptz,
  p_max_uses integer default 1
)
returns table (
  invite_id uuid,
  token text,
  expires_at timestamptz,
  max_uses integer
)
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text;
  v_token_hash text;
  v_random bytea;
  v_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_index integer;
  v_attempt integer;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if not public.is_group_owner(p_group_id) then
    raise exception using errcode = '42501', message = 'only the group owner can create invites';
  end if;
  if p_expires_at is null or p_expires_at <= now() then
    raise exception using errcode = '22023', message = 'invite expiration must be in the future';
  end if;
  if p_max_uses is null or p_max_uses not between 1 and 100000 then
    raise exception using errcode = '22023', message = 'max_uses must be between 1 and 100000';
  end if;

  -- Base32 12자는 60비트 엔트로피를 제공한다. 소리 내어 읽고 입력하기
  -- 쉽도록 0, 1, I, O를 제외한다. 반복문은 거의 일어나지 않는 고유 해시
  -- 충돌 때만 다시 시도한다.
  for v_attempt in 1..5 loop
    v_random := extensions.gen_random_bytes(12);
    v_token := '';
    for v_index in 0..11 loop
      v_token := v_token || pg_catalog.substr(
        v_alphabet,
        (pg_catalog.get_byte(v_random, v_index) % 32) + 1,
        1
      );
    end loop;
    v_token_hash := encode(
      extensions.digest(pg_catalog.convert_to(v_token, 'utf8'), 'sha256'),
      'hex'
    );

    insert into public.invite_codes as issued (
      group_id, created_by, token_hash, expires_at, max_uses
    )
    values (p_group_id, v_user_id, v_token_hash, p_expires_at, p_max_uses)
    on conflict (token_hash) do nothing
    returning issued.id, issued.expires_at, issued.max_uses
      into invite_id, expires_at, max_uses;

    if invite_id is not null then
      token := v_token;
      return next;
      return;
    end if;
  end loop;

  raise exception using errcode = '55000', message = 'could not generate a unique invite code';
end;
$$;

revoke execute on function public.create_invite_code(uuid, timestamptz, integer)
  from public, anon;
grant execute on function public.create_invite_code(uuid, timestamptz, integer)
  to authenticated;
