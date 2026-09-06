-- 각 테이블의 복합 NEW/OLD 레코드에서 감사 트리거가 안전하게 동작하게 한다.
--
-- PL/pgSQL 레코드는 모든 테이블의 열을 갖지 않는다. groups 트리거에 연결된
-- CASE 식에서 `new.user_id`를 참조하면 CASE 조건을 선택하기 전에 실패할 수
-- 있다(groups에는 user_id 열이 없다). 먼저 TG_TABLE_NAME으로 분기한 뒤
-- 해당 테이블에 실제로 있는 필드만 읽는다. 원래 스키마 마이그레이션을 이미
-- 실행한 프로젝트에도 적용할 수 있도록 이 마이그레이션을 별도로 둔다.

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

commit;
