-- Moduly 계정 삭제 정책이다.
--
-- 인증된 사용자가 자신의 JWT로 delete-account Edge Function을 호출한다.
-- 함수가 JWT를 검증한 뒤 서버 전용 Auth 관리자 API로 auth.users(id)를
-- 삭제한다. 이 연쇄 삭제로 Auth 삭제와 앱 정리가 하나의 데이터베이스
-- 트랜잭션이 된다.
--
-- 정책:
--   * 사용자가 소유한 일정방, 일정, 멤버십, 초대 코드는 영구 삭제한다. 소유
--     일정방의 공유 데이터도 의도적으로 삭제하며 앱 확인 화면에 다시 표시한다.
--   * 다른 일정방에서 사용자가 작성한 멤버십과 일정도 영구 삭제한다.
--   * 관련 행이 삭제된 감사 행은 actor_id/group_id를 NULL로 남겨, 삭제된
--     계정을 식별하지 않고 보안 이력을 보존한다.
--   * 클라이언트에는 서비스/비밀 키를 전달하지 않는다. Auth 관리자 삭제 API를
--     호출할 수 있는 구성 요소는 Edge Function뿐이다.

begin;

-- 원래 스키마는 소유/작성 행 참조에 RESTRICT를 사용했다. 실수로 삭제되는
-- 것을 막지만 인증된 사용자의 의도적인 계정 삭제도 완료하지 못하게 한다.
-- 해당 참조만 명시적인 cascade로 바꾸며, 일정방 소유 하위 행은 이미
-- cascade 처리된다.
alter table public.groups
  drop constraint if exists groups_owner_id_fkey;
alter table public.groups
  add constraint groups_owner_id_fkey
  foreign key (owner_id)
  references auth.users(id)
  on delete cascade;

alter table public.invite_codes
  drop constraint if exists invite_codes_created_by_fkey;
alter table public.invite_codes
  add constraint invite_codes_created_by_fkey
  foreign key (created_by)
  references auth.users(id)
  on delete cascade;

alter table public.events
  drop constraint if exists events_created_by_fkey;
alter table public.events
  add constraint events_created_by_fkey
  foreign key (created_by)
  references auth.users(id)
  on delete cascade;

comment on constraint groups_owner_id_fkey on public.groups is
  '계정 삭제 정책: auth.users를 삭제하면 소유한 그룹과 연쇄 하위 행을 영구 삭제한다.';
comment on constraint invite_codes_created_by_fkey on public.invite_codes is
  '계정 삭제 정책: 작성자를 삭제하면 초대 코드를 영구 제거한다.';
comment on constraint events_created_by_fkey on public.events is
  '계정 삭제 정책: 작성자를 삭제하면 일정을 영구 제거한다.';

commit;
