-- 계정 삭제 중 FK 정리로 일시적으로 고아가 되는 멤버십 감사 행을 건너뛴다.
--
-- 소유자 계정을 삭제하면 groups.owner_id의 CASCADE가 그룹을 먼저
-- 삭제할 수 있다. 그 뒤 memberships.invited_by의 SET NULL 정리가
-- 멤버십 UPDATE 트리거를 실행하면, 이미 사라진 group_id를 audit_logs에
-- 다시 넣으려 하면서 계정 삭제 전체가 실패한다. 실제 그룹이 존재하는
-- 일반 멤버 활성/비활성 변경은 계속 감사한다.

begin;

create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_group_id uuid;
  v_entity_id uuid;
  v_action text;
  v_version integer;
begin
  if tg_table_name = 'groups' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.id;
      v_version := new.version;
      v_action := case when tg_op = 'INSERT' then 'insert' else 'update' end;
    end if;

  elsif tg_table_name = 'memberships' then
    if tg_op = 'DELETE' then
      v_entity_id := old.user_id;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.user_id;
      v_group_id := new.group_id;
      v_action := case when tg_op = 'INSERT' then 'join' else 'update' end;
    end if;

  elsif tg_table_name = 'invite_codes' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.group_id;
      v_version := new.version;
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif new.revoked_at is not null and old.revoked_at is null then
        v_action := 'revoke';
      else
        v_action := 'update';
      end if;
    end if;

  elsif tg_table_name = 'events' then
    if tg_op = 'DELETE' then
      v_entity_id := old.id;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := new.id;
      v_group_id := new.group_id;
      v_version := new.version;
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif old.deleted_at is null and new.deleted_at is not null then
        v_action := 'soft_delete';
      else
        v_action := 'update';
      end if;
    end if;

  else
    raise exception using
      errcode = '22023',
      message = format('unsupported audit trigger table: %s', tg_table_name);
  end if;

  -- 계정 삭제의 CASCADE 순서에서는 invited_by SET NULL이 실행될 때
  -- membership.group_id가 이미 가리키는 그룹이 없어질 수 있다. 이
  -- 내부 정리 UPDATE만 건너뛰고, 실제 그룹의 일반 UPDATE 감사는 보존한다.
  if v_group_id is not null
     and not exists (
       select 1
       from public.groups g
       where g.id = v_group_id
     ) then
    return null;
  end if;

  -- token_hash, 일정 설명 또는 다른 전달자/PII 필드를 감사 행에 넣지
  -- 않는다. 버전과 수명 주기 작업만으로 충분하다.
  insert into public.audit_logs (group_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_group_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    jsonb_build_object('version', v_version)
  );
  return null;
end;
$$;

-- Keep the trigger helper out of the PostgREST RPC surface on upgraded
-- deployments that may have stale default/public grants.
revoke execute on function public.write_audit_log()
  from public, anon, authenticated;

commit;
