-- 함수 실행 보강이다.
--
-- PostgreSQL은 새 함수에 기본적으로 PUBLIC의 EXECUTE 권한을 부여한다.
-- 초기 마이그레이션은 Flutter 클라이언트에 필요한 도우미와 RPC를
-- authenticated 역할에 허용하지만, 기존 호스팅 프로젝트에는 Dashboard에서
-- 만든 함수 등의 역할별 권한이 남을 수 있다. 허용할 API를 명시하고 트리거
-- 함수는 비공개로 유지한다.

begin;

-- 마이그레이션 역할이 소유한 새 함수는 처음부터 비공개여야 한다. 기존
-- 함수는 아래에서 명시적으로 처리하므로 anon/authenticated 권한이 이미
-- 부여된 프로젝트도 복구할 수 있다.
alter default privileges in schema public
  revoke execute on functions from public;
alter default privileges in schema public
  revoke execute on functions from anon, authenticated;

-- 트리거 전용 함수는 PostgREST RPC 표면에 속하지 않는다. 트리거 실행에는
-- 호출 API 역할의 EXECUTE 권한이 필요하지 않으며, 소유자가 트리거를
-- 만들었으므로 함수는 필요한 경우 SECURITY DEFINER를 포함해 소유자 권한을 유지한다.
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.enforce_version_increment() from public, anon, authenticated;
revoke execute on function public.enforce_initial_version() from public, anon, authenticated;
revoke execute on function public.enforce_group_integrity() from public, anon, authenticated;
revoke execute on function public.enforce_event_integrity() from public, anon, authenticated;
revoke execute on function public.enforce_invite_integrity() from public, anon, authenticated;
revoke execute on function public.enforce_membership_integrity() from public, anon, authenticated;
revoke execute on function public.write_audit_log() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_new_group() from public, anon, authenticated;

-- 호스팅 Supabase 프로젝트에는 이 이벤트 트리거 도우미가 있을 수 있지만
-- 일반 로컬 데이터베이스에는 없을 수 있다. 마이그레이션의 이식성을 유지하고
-- 존재할 때는 직접 RPC 표면을 제거한다.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$$;

-- RLS 정책과 테이블 CHECK 제약은 호출자 권한으로 이 도우미를 실행한다.
-- 로그인 사용자에게는 호출을 허용하되 anon/PUBLIC에는 절대 노출하지 않는다.
revoke execute on function public.is_valid_timezone(text)
  from public, anon, authenticated;
grant execute on function public.is_valid_timezone(text) to authenticated;

revoke execute on function public.is_group_owner(uuid)
  from public, anon, authenticated;
grant execute on function public.is_group_owner(uuid) to authenticated;

revoke execute on function public.is_active_member(uuid)
  from public, anon, authenticated;
grant execute on function public.is_active_member(uuid) to authenticated;

revoke execute on function public.can_view_profile(uuid)
  from public, anon, authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;

-- Flutter 클라이언트가 사용하는 업무 RPC다. authenticated 권한은 유지하되
-- 모든 함수가 내부에서 auth.uid(), 소유권 또는 활성 멤버십을 검사하고,
-- 명시적인 search_path가 있는 SECURITY DEFINER로 남는다.
revoke execute on function public.create_group(text, text)
  from public, anon, authenticated;
grant execute on function public.create_group(text, text) to authenticated;

revoke execute on function public.create_invite_code(uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.create_invite_code(uuid, timestamptz, integer)
  to authenticated;

revoke execute on function public.join_group_with_invite(text)
  from public, anon, authenticated;
grant execute on function public.join_group_with_invite(text) to authenticated;

revoke execute on function public.soft_delete_event_if_version(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.soft_delete_event_if_version(uuid, integer)
  to authenticated;

revoke execute on function public.archive_group_if_version(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.archive_group_if_version(uuid, integer)
  to authenticated;

revoke execute on function public.revoke_invite_code(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.revoke_invite_code(uuid, integer)
  to authenticated;

revoke execute on function public.set_member_active(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.set_member_active(uuid, uuid, boolean)
  to authenticated;

commit;
