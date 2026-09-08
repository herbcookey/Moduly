-- 그룹 관리 RPC와 불변 조건이다.
--
-- 이 마이그레이션은 의도적으로 그룹 소유권 변경을 RPC 뒤에 둔다. API 역할에는
-- 소유권, 역할 또는 그룹 표시 열에 대한 직접 UPDATE 권한이 없다. SECURITY
-- DEFINER 함수는 빈 search_path를 사용하고 모든 애플리케이션 객체를 정규화한다.

begin;

-- 인덱스 이름은 스키마 계약의 일부다. pg_catalog에서 정확히 단일 열 고유 부분
-- 인덱스 정의임을 확인한 경우에만 같은 이름의 기존 객체를 허용한다. 같은 이름의
-- 잘못된 인덱스가 있으면 데이터 복구 전에 중단한다.
do $$
declare
  v_index_oid oid;
  v_indrelid oid;
  v_indisunique boolean;
  v_indisvalid boolean;
  v_indnkeyatts integer;
  v_indnatts integer;
  v_index_key_attnum integer;
  v_group_attnum integer;
  v_index_has_expr boolean;
  v_predicate text;
  v_index_def text;
  v_expected_predicate text := '((role = ''owner''::public.group_member_role) AND is_active)';
  v_expected_index_def text := 'CREATE UNIQUE INDEX memberships_one_active_owner_idx ON public.memberships USING btree (group_id) WHERE ((role = ''owner''::public.group_member_role) AND is_active)';
begin
  perform pg_catalog.set_config('search_path', '', true);

  select c.oid,
         i.indrelid,
         i.indisunique,
         i.indisvalid,
         i.indnkeyatts,
         i.indnatts,
         i.indkey[0],
         i.indexprs is not null,
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         pg_catalog.pg_get_indexdef(c.oid)
    into v_index_oid,
         v_indrelid,
         v_indisunique,
         v_indisvalid,
         v_indnkeyatts,
         v_indnatts,
         v_index_key_attnum,
         v_index_has_expr,
         v_predicate,
         v_index_def
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  left join pg_catalog.pg_index i on i.indexrelid = c.oid
  where n.nspname = 'public'
    and c.relname = 'memberships_one_active_owner_idx';

  if found then
    select a.attnum
      into v_group_attnum
    from pg_catalog.pg_attribute a
    where a.attrelid = 'public.memberships'::regclass
      and a.attname = 'group_id';

    if v_index_oid is null
       or v_indrelid <> 'public.memberships'::regclass
       or v_indisunique is distinct from true
       or v_indisvalid is distinct from true
       or v_indnkeyatts <> 1
       or v_indnatts <> 1
       or v_index_key_attnum <> v_group_attnum
       or v_index_has_expr
       or v_index_def is null
       or pg_catalog.regexp_replace(
            pg_catalog.lower(coalesce(v_predicate, '')),
            '[[:space:]]+', '', 'g'
          ) <> pg_catalog.regexp_replace(
            pg_catalog.lower(v_expected_predicate),
            '[[:space:]]+', '', 'g'
          )
       or pg_catalog.regexp_replace(
            pg_catalog.lower(coalesce(v_index_def, '')),
            '[[:space:]]+', '', 'g'
          ) <> pg_catalog.regexp_replace(
            pg_catalog.lower(v_expected_index_def),
            '[[:space:]]+', '', 'g'
          ) then
      raise exception using
        errcode = '55000',
        message = 'memberships_one_active_owner_idx exists but is not the expected unique partial index on memberships(group_id)';
    end if;
  end if;
end;
$$;

-- 고유 인덱스를 만들기 전에 결과가 결정적인 소유자-멤버십 불일치만 복구한다.
-- 각 그룹에서 추가 활성 소유자 행을 먼저 일반 멤버로 내린 다음 groups.owner_id
-- 행을 삽입/재활성화/소유자로 승격한다. 이 순서는 기존 멤버십 트리거와 함께
-- 안전하며 유효한 인덱스가 이미 있어도 동작한다. 임의의 소유자를 선택하지 않으며
-- groups.owner_id만 최종 기준으로 삼는다.
do $$
declare
  v_group_id uuid;
  v_owner_id uuid;
  v_owner_role public.group_member_role;
  v_owner_active boolean;
  v_owner_removed_at timestamptz;
begin
  perform pg_catalog.set_config('search_path', '', true);

  for v_group_id, v_owner_id in
    select g.id, g.owner_id
    from public.groups g
    order by g.id
  loop
    update public.memberships m
    set role = 'member',
        updated_at = pg_catalog.now()
    where m.group_id = v_group_id
      and m.user_id <> v_owner_id
      and m.role = 'owner'
      and m.is_active;

    select m.role, m.is_active, m.removed_at
      into v_owner_role, v_owner_active, v_owner_removed_at
    from public.memberships m
    where m.group_id = v_group_id
      and m.user_id = v_owner_id;

    if not found then
      insert into public.memberships (
        group_id, user_id, role, is_active, removed_at
      ) values (
        v_group_id, v_owner_id, 'owner', true, null
      );
    elsif v_owner_role is distinct from 'owner'::public.group_member_role
       or v_owner_active is distinct from true
       or v_owner_removed_at is not null then
      update public.memberships m
      set role = 'owner',
          is_active = true,
          removed_at = null,
          updated_at = pg_catalog.now()
      where m.group_id = v_group_id
        and m.user_id = v_owner_id;
    end if;
  end loop;
end;
$$;

-- 잘못되었거나 모호한 이전 행이 남아 있으면 알기 쉬운 오류로 중단한다. 그룹에는
-- 활성 소유자 행이 정확히 하나 있어야 하며 그 행은 groups.owner_id여야 한다.
do $$
declare
  v_bad_group uuid;
begin
  select g.id
    into v_bad_group
  from public.groups g
  where not exists (
          select 1
          from public.memberships m
          where m.group_id = g.id
            and m.user_id = g.owner_id
            and m.role = 'owner'
            and m.is_active
            and m.removed_at is null
        )
     or 1 <> (
          select count(*)
          from public.memberships m
          where m.group_id = g.id
            and m.role = 'owner'
            and m.is_active
            and m.removed_at is null
        )
  order by g.id
  limit 1;
  if found then
    raise exception using
      errcode = '55000',
      message = pg_catalog.format('group %s has an ambiguous active owner membership after deterministic backfill', v_bad_group);
  end if;
end;
$$;

-- 한 그룹에 활성 소유자가 둘 있어서는 안 된다. 보호된 CREATE 뒤에 pg_catalog
-- 정의를 검사하여 IF NOT EXISTS가 이전 배포에서 생긴 잘못된 객체를 숨기지 못하게 한다.
create unique index if not exists memberships_one_active_owner_idx
  on public.memberships (group_id)
  where role = 'owner' and is_active;

do $$
declare
  v_index_oid oid;
  v_indrelid oid;
  v_indisunique boolean;
  v_indisvalid boolean;
  v_indnkeyatts integer;
  v_indnatts integer;
  v_index_key_attnum integer;
  v_group_attnum integer;
  v_index_has_expr boolean;
  v_predicate text;
  v_index_def text;
  v_expected_predicate text := '((role = ''owner''::public.group_member_role) AND is_active)';
  v_expected_index_def text := 'CREATE UNIQUE INDEX memberships_one_active_owner_idx ON public.memberships USING btree (group_id) WHERE ((role = ''owner''::public.group_member_role) AND is_active)';
begin
  perform pg_catalog.set_config('search_path', '', true);
  select c.oid,
         i.indrelid,
         i.indisunique,
         i.indisvalid,
         i.indnkeyatts,
         i.indnatts,
         i.indkey[0],
         i.indexprs is not null,
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         pg_catalog.pg_get_indexdef(c.oid)
    into v_index_oid,
         v_indrelid,
         v_indisunique,
         v_indisvalid,
         v_indnkeyatts,
         v_indnatts,
         v_index_key_attnum,
         v_index_has_expr,
         v_predicate,
         v_index_def
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_index i on i.indexrelid = c.oid
  where n.nspname = 'public'
    and c.relname = 'memberships_one_active_owner_idx';

  select a.attnum
    into v_group_attnum
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.memberships'::regclass
    and a.attname = 'group_id';

  if v_index_oid is null
     or v_indrelid <> 'public.memberships'::regclass
     or v_indisunique is distinct from true
     or v_indisvalid is distinct from true
     or v_indnkeyatts <> 1
     or v_indnatts <> 1
     or v_index_key_attnum <> v_group_attnum
     or v_index_has_expr
     or v_index_def is null
     or pg_catalog.regexp_replace(
          pg_catalog.lower(coalesce(v_predicate, '')),
          '[[:space:]]+', '', 'g'
        ) <> pg_catalog.regexp_replace(
          pg_catalog.lower(v_expected_predicate),
          '[[:space:]]+', '', 'g'
        )
     or pg_catalog.regexp_replace(
          pg_catalog.lower(coalesce(v_index_def, '')),
          '[[:space:]]+', '', 'g'
        ) <> pg_catalog.regexp_replace(
          pg_catalog.lower(v_expected_index_def),
          '[[:space:]]+', '', 'g'
        ) then
    raise exception using
      errcode = '55000',
      message = 'memberships_one_active_owner_idx is not the expected unique partial index on memberships(group_id)';
  end if;
end;
$$;

comment on index public.memberships_one_active_owner_idx is
  '각 그룹에는 활성 소유자 멤버십이 최대 하나만 존재할 수 있다.';

-- 일반 Postgres 테스트에서 Realtime은 선택 사항이다. Supabase publication이
-- 있으면 그룹 수명 주기와 멤버십 무효화를 위해 groups와 memberships를 멱등적으로
-- 포함하되 Realtime 스키마 자체는 절대 변경하지 않는다.
do $$
begin
  if exists (
       select 1
       from pg_catalog.pg_publication
       where pubname = 'supabase_realtime'
     )
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'groups'
     ) then
    execute 'alter publication supabase_realtime add table public.groups';
  end if;
end;
$$;

do $$
begin
  if exists (
       select 1
       from pg_catalog.pg_publication
       where pubname = 'supabase_realtime'
     )
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'memberships'
     ) then
    execute 'alter publication supabase_realtime add table public.memberships';
  end if;
end;
$$;

-- 직접 events INSERT/UPDATE 문은 여전히 클라이언트 쓰기 계약의 일부이므로 RLS
-- 멤버십 검사를 보관 작업과 직렬화해야 한다. 기존 events_integrity 트리거를
-- 재사용해 상위 그룹을 먼저 잠그고 일정 필드를 검증하기 전에 종료 상태 행을
-- 거부한다. 인증/그룹 연쇄 삭제를 포함한 DELETE는 이 트리거를 실행하지 않으므로
-- 기존 동작을 유지한다.
create or replace function public.enforce_event_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group public.groups;
begin
  select g.*
    into v_group
  from public.groups g
  where g.id = new.group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'group was archived or is unavailable';
  end if;

  if tg_op = 'UPDATE' then
    if new.group_id <> old.group_id or new.created_by <> old.created_by then
      raise exception 'event group_id and created_by are immutable';
    end if;
    if old.deleted_at is not null and new.deleted_at is null then
      raise exception 'a deleted event cannot be restored';
    end if;
  end if;

  if new.is_all_day then
    -- UTC 시각을 일정의 IANA 시간대로 다시 변환한다. 두 경계는 로컬
    -- 자정이어야 하며 반열린 날짜 범위와 일치해야 한다.
    if (new.starts_at at time zone new.timezone) <> (new.all_day_start::timestamp)
       or (new.ends_at at time zone new.timezone) <> (new.all_day_end::timestamp) then
      raise exception 'all-day UTC boundaries must be local midnight for the supplied IANA date range';
    end if;
  end if;
  return new;
end;
$$;

-- 소유권 이전만 groups.owner_id 또는 멤버십 역할을 바꿀 수 있다. 표시는
-- 트랜잭션 로컬이며 두 불변 테이블 트리거가 모두 확인한다. 정확한 그룹, 이전
-- 소유자, 새 소유자 UUID를 담으며 잘못되었거나 오래되었거나 불완전한 표시는
-- 절대 허용하지 않는다.
create or replace function public.enforce_group_integrity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_marker jsonb;
  v_marker_valid boolean := false;
begin
  if tg_op = 'UPDATE' then
    if new.owner_id <> old.owner_id then
      begin
        v_marker := nullif(pg_catalog.current_setting('moduly.transfer_marker', true), '')::jsonb;
      exception when others then
        v_marker := null;
      end;

      v_marker_valid := v_marker is not null
        and pg_catalog.jsonb_typeof(v_marker) = 'object'
        and v_marker ->> 'group_id' = old.id::text
        and v_marker ->> 'old_owner_id' = old.owner_id::text
        and v_marker ->> 'new_owner_id' = new.owner_id::text
        and v_marker ->> 'group_id' is not null
        and v_marker ->> 'old_owner_id' is not null
        and v_marker ->> 'new_owner_id' is not null
        and v_marker -> 'group_id' is not null
        and v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb;

      if not v_marker_valid then
        raise exception using
          errcode = '42501',
          message = 'group owner_id is immutable outside transfer_group_ownership';
      end if;
    end if;

    if old.deleted_at is not null and new.deleted_at is null then
      raise exception using
        errcode = '22023',
        message = 'a deleted group cannot be restored';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_membership_integrity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_owner_id uuid;
  v_marker jsonb;
  v_marker_valid boolean := false;
  v_transfer_role_change boolean := false;
begin
  -- 계정/그룹 연쇄 삭제에서는 이미 사라졌을 수 있는 상위 행을 조회하지 않고도
  -- 멤버십을 제거할 수 있어야 한다. 행 단위 CHECK 제약은 계속 삽입/갱신을
  -- 보호하며, 여기서 DELETE에 강제할 불변 조건은 없다.
  if tg_op = 'DELETE' then
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if new.group_id <> old.group_id or new.user_id <> old.user_id then
      raise exception using
        errcode = '42501',
        message = 'membership group_id and user_id are immutable';
    end if;
  end if;

  select g.owner_id
    into v_owner_id
  from public.groups g
  where g.id = new.group_id;
  if v_owner_id is null then
    raise exception using
      errcode = '23503',
      message = 'membership group does not exist';
  end if;

  begin
    v_marker := nullif(pg_catalog.current_setting('moduly.transfer_marker', true), '')::jsonb;
  exception when others then
    v_marker := null;
  end;
  v_marker_valid := v_marker is not null
    and pg_catalog.jsonb_typeof(v_marker) = 'object'
    and v_marker ->> 'group_id' = new.group_id::text
    and v_marker ->> 'old_owner_id' is not null
    and v_marker ->> 'new_owner_id' is not null
    and v_marker ->> 'old_owner_id' = v_owner_id::text
    and v_marker ->> 'new_owner_id' <> v_owner_id::text
    and v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb;

  -- 유효한 이전에서는 그룹 owner_id가 바뀌기 전에 이전 소유자 행을 일반 멤버로
  -- 내리고, groups.owner_id가 아직 이전 소유자를 가리킬 때 대상을 소유자로
  -- 올린다. 트랜잭션 표시가 허용하는 역할 전환은 이 두 가지뿐이다.
  if tg_op = 'UPDATE' then
    v_transfer_role_change := v_marker_valid and (
      (
        old.user_id::text = v_marker ->> 'old_owner_id'
        and old.role = 'owner'
        and new.user_id = old.user_id
        and new.role = 'member'
        and new.is_active
        and new.removed_at is null
      )
      or
      (
        old.user_id::text = v_marker ->> 'new_owner_id'
        and old.role = 'member'
        and new.user_id = old.user_id
        and new.role = 'owner'
        and new.is_active
        and new.removed_at is null
      )
    );
  end if;

  if new.user_id = v_owner_id then
    if (new.role <> 'owner' or not new.is_active or new.removed_at is not null)
       and not v_transfer_role_change then
      raise exception using
        errcode = '23514',
        message = 'the group owner must retain an active owner membership';
    end if;
  elsif new.role = 'owner' and not v_transfer_role_change then
    raise exception using
      errcode = '23514',
      message = 'only groups.owner_id may have the owner role';
  end if;

  if (new.is_active and new.removed_at is not null)
     or (not new.is_active and new.removed_at is null) then
    raise exception using
      errcode = '23514',
      message = 'is_active and removed_at must agree';
  end if;
  return new;
end;
$$;

-- DELETE 경로를 명시적이고 안전하게 유지한다. 계정/그룹 연쇄 삭제는 상위 행이
-- 사라진 뒤 트리거를 호출할 수 있으며, 위 함수의 조기 반환은 의도적으로 해당
-- 경로를 무동작으로 만든다.
drop trigger if exists memberships_integrity on public.memberships;
create trigger memberships_integrity
before insert or update or delete on public.memberships
for each row execute function public.enforce_membership_integrity();

-- 필드 및 고아 행에 안전한 감사 트리거를 유지하면서 일정과 그룹의 deleted_at이
-- NULL에서 NULL이 아닌 값으로 바뀌는 경우를 모두 soft_delete로 표시한다. 보관된
-- 하위 행은 계속 저장하지만, 수명 주기는 일반 update가 아닌 이 최소 감사 작업으로 나타낸다.
create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
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
      if tg_op = 'INSERT' then
        v_action := 'insert';
      elsif old.deleted_at is null and new.deleted_at is not null then
        v_action := 'soft_delete';
      else
        v_action := 'update';
      end if;
    end if;

  elsif tg_table_name = 'memberships' then
    if tg_op = 'DELETE' then
      -- 멤버십 행은 audit_logs에서 의도적으로 사용자를 식별하지 않는다.
      -- UUID를 노출하지 않아도 그룹/작업/타임스탬프는 여전히 유용하다.
      v_entity_id := null;
      v_group_id := old.group_id;
      v_action := 'soft_delete';
    else
      v_entity_id := null;
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
      message = pg_catalog.format('unsupported audit trigger table: %s', tg_table_name);
  end if;

  -- 계정 삭제 연쇄 작업은 소유 그룹 행이 이미 사라진 뒤 invited_by를 SET NULL할
  -- 수 있다. 해당 고아 내부 갱신만 건너뛰며, 존재하는 그룹의 일반 쓰기는 계속 감사한다.
  if v_group_id is not null
     and not exists (
       select 1
       from public.groups g
       where g.id = v_group_id
     ) then
    return null;
  end if;

  insert into public.audit_logs (
    group_id, actor_id, action, entity_type, entity_id, metadata
  ) values (
    v_group_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    pg_catalog.jsonb_build_object('version', v_version)
  );
  return null;
end;
$$;

-- 소유자 전용 낙관적 잠금 그룹 세부 정보 갱신이다. 검증 전에 행을 잠가 동시
-- 보관 또는 이전이 비결정적 결과를 만들지 못하게 한다. 입력 오류에는 22023을,
-- 오래되었거나 삭제되었거나 없거나 권한 없는 행에는 안전한 직렬화/충돌 코드
-- 40001을 사용한다.
create or replace function public.update_group_if_version(
  p_group_id uuid,
  p_expected_version integer,
  p_name text,
  p_description text,
  p_timezone text
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_name text := pg_catalog.btrim(coalesce(p_name, ''));
  v_description text := pg_catalog.btrim(coalesce(p_description, ''));
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if pg_catalog.char_length(v_name) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'group name must be 1-160 characters';
  end if;
  if pg_catalog.char_length(v_description) > 10000 then
    raise exception using errcode = '22023', message = 'group description must be at most 10000 characters';
  end if;
  if p_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names t
       where t.name = p_timezone
     ) then
    raise exception using errcode = '22023', message = 'timezone must be an exact IANA timezone name';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  update public.groups g
  set name = v_name,
      description = v_description,
      timezone = p_timezone,
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;
  return v_group;
end;
$$;

-- 활성 일반 멤버는 자신의 멤버십만 탈퇴할 수 있다. 그룹 잠금은 보관/탈퇴 경합
-- 결과를 결정적으로 만들며, 멤버십 행을 바꾸기 전에 소유자와 보관된 그룹을 거부한다.
create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '42501',
      message = 'only an active ordinary member can leave this group';
  end if;

  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_user_id
  for update;

  if not found
     or not v_membership.is_active
     or v_membership.role <> 'member' then
    raise exception using
      errcode = '42501',
      message = 'only an active ordinary member can leave this group';
  end if;

  update public.memberships m
  set is_active = false,
      removed_at = coalesce(m.removed_at, pg_catalog.now())
  where m.group_id = p_group_id
    and m.user_id = v_user_id
    and m.role = 'member'
    and m.is_active
    and exists (
      select 1
      from public.groups g
      where g.id = m.group_id
        and g.deleted_at is null
    );

  if not found then
    raise exception using
      errcode = '40001',
      message = 'membership was changed or the group is unavailable';
  end if;
  return;
end;
$$;

-- 소유권을 원자적으로 이전한다. 그룹 행을 먼저 잠근 뒤 두 멤버십 행을 잠근다.
-- 모든 소유권 및 멤버십 검사를 통과한 뒤에만 트랜잭션 로컬 표시를 채우며, 영향을
-- 받는 모든 행에서 불변 트리거가 이를 검증한다.
create or replace function public.transfer_group_ownership(
  p_group_id uuid,
  p_new_owner_id uuid,
  p_expected_version integer
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_old_membership public.memberships;
  v_new_membership public.memberships;
  v_active_owner_count integer;
  v_final_owner_id uuid;
  v_marker text;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if p_new_owner_id is null or p_new_owner_id = v_user_id then
    raise exception using errcode = '22023', message = 'new owner must be another user';
  end if;

  -- 모든 멤버십 행보다 그룹을 먼저 잠근다. 보관/갱신도 같은 잠금 순서를 사용해
  -- 이전과 종료 작업 사이의 교착 상태를 막는다.
  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  -- 정렬된 쿼리가 그룹 잠금 뒤에 두 멤버십 잠금을 얻는다. 아래에서 결과 행을
  -- 복사하여 필요한 각 역할/상태를 검사한다.
  select m.*
    into v_old_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = v_user_id
  for update;
  if not found
     or v_old_membership.role <> 'owner'
     or not v_old_membership.is_active
     or v_old_membership.removed_at is not null then
    raise exception using
      errcode = '40001',
      message = 'current owner membership is unavailable';
  end if;

  select m.*
    into v_new_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = p_new_owner_id
  for update;
  if not found
     or v_new_membership.role <> 'member'
     or not v_new_membership.is_active
     or v_new_membership.removed_at is not null then
    raise exception using
      errcode = '42501',
      message = 'new owner must be an active member of this group';
  end if;

  v_marker := pg_catalog.json_build_object(
    'group_id', p_group_id::text,
    'old_owner_id', v_user_id::text,
    'new_owner_id', p_new_owner_id::text
  )::text;
  perform pg_catalog.set_config('moduly.transfer_marker', v_marker, true);

  -- groups.owner_id를 바꾸기 전에 이전 소유자를 내리고 새 소유자를 올린다. 따라서
  -- 이 쓰기 도중에도 부분 고유 인덱스가 활성 소유자 둘을 볼 수 없다.
  update public.memberships m
  set role = 'member',
      updated_at = pg_catalog.now()
  where m.group_id = p_group_id
    and m.user_id = v_user_id
    and m.role = 'owner'
    and m.is_active;
  if not found then
    raise exception using errcode = '40001', message = 'current owner membership changed';
  end if;

  update public.memberships m
  set role = 'owner',
      updated_at = pg_catalog.now()
  where m.group_id = p_group_id
    and m.user_id = p_new_owner_id
    and m.role = 'member'
    and m.is_active
    and m.removed_at is null;
  if not found then
    raise exception using errcode = '40001', message = 'new owner membership changed';
  end if;

  update public.groups g
  set owner_id = p_new_owner_id,
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;
  if not found then
    raise exception using errcode = '40001', message = 'group was changed during ownership transfer';
  end if;

  -- 반환 전에 같은 트랜잭션에서 최종 불변 조건을 검사한다. 고유 인덱스는 중복
  -- 소유자를 잡고, 이 검사는 누락된 소유자 행이나 트리거/스키마 불일치도 잡는다.
  select count(*)::integer
    into v_active_owner_count
  from public.memberships m
  where m.group_id = p_group_id
    and m.role = 'owner'
    and m.is_active
    and m.removed_at is null;
  select m.user_id
    into v_final_owner_id
  from public.memberships m
  where m.group_id = p_group_id
    and m.role = 'owner'
    and m.is_active
    and m.removed_at is null
  limit 1;
  if v_active_owner_count <> 1
     or v_final_owner_id <> p_new_owner_id
     or v_group.owner_id <> p_new_owner_id then
    raise exception using
      errcode = '40001',
      message = 'ownership transfer invariant failed';
  end if;

  perform pg_catalog.set_config('moduly.transfer_marker', '', true);
  return v_group;
end;
$$;

-- 종료 그룹 잠금을 얻으면서 archive_group_if_version의 공개 시그니처를 보존한다.
-- 기존 groups 감사 트리거가 deleted_at의 NULL에서 NULL 아닌 값으로의 전환을
-- soft_delete 작업으로 기록한다. 하위 행은 그대로 두고 기존 그룹/멤버/일정 RLS
-- 도우미가 숨긴다.
create or replace function public.archive_group_if_version(
  p_group_id uuid,
  p_expected_version integer
)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;

  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null
     or p_expected_version is null
     or v_group.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;

  update public.groups g
  set deleted_at = pg_catalog.now(),
      version = g.version + 1
  where g.id = p_group_id
    and g.owner_id = v_user_id
    and g.deleted_at is null
    and g.version = p_expected_version
  returning g.* into v_group;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'group was changed, archived, or is not yours';
  end if;
  return v_group;
end;
$$;

-- 기존 그룹 범위 RPC도 소유권/수명 주기 상태를 확인하기 전에 그룹 잠금을 얻는다.
-- 따라서 이전, 보관, 관리, 초대 및 일정 쓰기가 그룹 우선의 한 잠금 순서를 공유하므로
-- 동시 이전/보관이 도우미 검사를 통과한 뒤 오래된 데이터를 쓰지 못한다.
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
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
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

  -- 소유자/삭제 상태를 확인하기 전에 대상 그룹을 잠근다. 이 마이그레이션의 다른
  -- 모든 그룹 범위 쓰기도 같은 그룹 우선 순서를 사용한다.
  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null then
    raise exception using
      errcode = '42501',
      message = 'only the group owner can create invites';
  end if;

  if p_expires_at is null or p_expires_at <= pg_catalog.now() then
    raise exception using errcode = '22023', message = 'invite expiration must be in the future';
  end if;
  if p_max_uses is null or p_max_uses not between 1 and 100000 then
    raise exception using errcode = '22023', message = 'max_uses must be between 1 and 100000';
  end if;

  -- 20260815055218_shorten_invite_codes.sql에서 도입한 사람이 읽기 쉬운 12자 코드와
  -- SHA-256 해시 의미를 보존한다.
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

create or replace function public.join_group_with_invite(p_token text)
returns table (
  group_id uuid,
  membership_id uuid,
  joined boolean,
  reason text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := pg_catalog.btrim(coalesce(p_token, ''));
  v_token_hash text;
  v_attempt_id bigint;
  v_attempt_count integer;
  v_invite_id uuid;
  v_invite_group_id uuid;
  v_expires_at timestamptz;
  v_max_uses integer;
  v_uses_count integer;
  v_revoked_at timestamptz;
  v_group public.groups;
  v_group_owner uuid;
  v_membership_id uuid;
  v_membership_active boolean;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if pg_catalog.char_length(v_token) > 256 then
    v_token := pg_catalog.left(v_token, 256);
  end if;
  v_token_hash := encode(
    extensions.digest(pg_catalog.convert_to(v_token, 'utf8'), 'sha256'),
    'hex'
  );

  -- 호출자의 시도를 이전과 정확히 같은 방식으로 직렬화한다. 아래 그룹 잠금은
  -- 그룹 소유 멤버십/초대 쓰기보다 먼저 얻는다.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  select count(*)::integer into v_attempt_count
  from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

  if v_attempt_count >= 20 then
    insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
    values (v_user_id, v_token_hash, false, 'rate_limited')
    returning id into v_attempt_id;
    return query select null::uuid, null::uuid, false, 'rate_limited'::text;
    return;
  end if;

  insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
  values (v_user_id, v_token_hash, false, 'invalid_or_expired')
  returning id into v_attempt_id;

  -- 잠금 대상을 정하기 위해서만 잠금 없이 그룹 ID를 읽는다. 초대 행과 멤버십을
  -- 바꾸기 전에 잠긴 그룹 행을 다시 확인하므로 동시 보관/이전이 오래된 쓰기를
  -- 남기지 못한다.
  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.token_hash = v_token_hash;
  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  -- 취소/생성 및 다른 모든 그룹 범위 RPC의 그룹 우선 잠금 순서와 맞도록 상위
  -- 그룹 뒤에 초대를 잠근다.
  select i.id, i.group_id, i.expires_at, i.max_uses, i.uses_count, i.revoked_at
    into v_invite_id, v_invite_group_id, v_expires_at, v_max_uses, v_uses_count, v_revoked_at
  from public.invite_codes i
  where i.token_hash = v_token_hash
  for update;

  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_invite_group_id <> v_group.id then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_revoked_at is not null then
    update public.invite_join_attempts
      set reason = 'revoked'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_expires_at <= pg_catalog.now() then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_uses_count >= v_max_uses then
    update public.invite_join_attempts
      set reason = 'max_uses'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  if v_group.deleted_at is not null then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  v_group_owner := v_group.owner_id;

  select m.user_id, m.is_active
    into v_membership_id, v_membership_active
  from public.memberships m
  where m.group_id = v_invite_group_id
    and m.user_id = v_user_id
  for update;

  if found and v_membership_active then
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  -- 멤버십을 복구/재가입하고 초대를 사용하는 동안 그룹 잠금을 유지하므로
  -- 보관/이전이 이 사이에 끼어들 수 없다.
  if v_group_owner = v_user_id then
    insert into public.memberships (group_id, user_id, role, is_active, removed_at)
    values (v_invite_group_id, v_user_id, 'owner', true, null)
    on conflict (group_id, user_id) do update
      set role = 'owner', is_active = true, removed_at = null, updated_at = pg_catalog.now()
    returning user_id into v_membership_id;
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if found then
    update public.memberships
      set role = 'member', is_active = true, removed_at = null, joined_at = pg_catalog.now()
      where group_id = v_invite_group_id and user_id = v_user_id
      returning user_id into v_membership_id;
  else
    insert into public.memberships (group_id, user_id, role, is_active, invited_by)
    values (v_invite_group_id, v_user_id, 'member', true, v_group_owner)
    returning user_id into v_membership_id;
  end if;

  update public.invite_codes
    set uses_count = uses_count + 1,
        version = version + 1
    where id = v_invite_id;
  update public.invite_join_attempts
    set succeeded = true, reason = 'joined'
    where id = v_attempt_id;

  return query select v_invite_group_id, v_membership_id, true, 'joined'::text;
end;
$$;

create or replace function public.soft_delete_event_if_version(
  p_event_id uuid,
  p_expected_version integer
)
returns public.events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_event_group_id uuid;
  v_group public.groups;
  v_membership public.memberships;
  v_event public.events;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select e.group_id
    into v_event_group_id
  from public.events e
  where e.id = p_event_id;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_event_group_id
  for update;
  if not found or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  -- 그룹 우선, 멤버십 차례의 잠금은 관리/가입과 맞으며 비활성화가 아래 활성
  -- 멤버 검사와 경합하는 것을 막는다.
  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = v_event_group_id
    and m.user_id = v_user_id
  for update;
  if not found or not v_membership.is_active or v_membership.removed_at is not null then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  select e.*
    into v_event
  from public.events e
  where e.id = p_event_id
  for update;
  if not found
     or v_event.group_id <> v_event_group_id
     or v_event.created_by <> v_user_id
     or v_event.deleted_at is not null
     or p_expected_version is null
     or v_event.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;

  update public.events e
  set deleted_at = pg_catalog.now(),
      version = e.version + 1
  where e.id = p_event_id
    and e.created_by = v_user_id
    and e.deleted_at is null
    and e.version = p_expected_version
  returning e.* into v_event;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'event was changed, deleted, or is not yours';
  end if;
  return v_event;
end;
$$;

create or replace function public.revoke_invite_code(
  p_invite_id uuid,
  p_expected_version integer
)
returns table (
  invite_id uuid,
  group_id uuid,
  expires_at timestamptz,
  max_uses integer,
  uses_count integer,
  revoked_at timestamptz,
  version integer,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invite_group_id uuid;
  v_group public.groups;
  v_invite public.invite_codes;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- 잠금 없이 상위를 찾은 뒤 그룹을 먼저 잠그고 그 잠금 아래에서 초대를 다시
  -- 읽는다. 이제 검사와 쓰기 사이에 초대 소유권/그룹 수명 주기가 바뀔 수 없다.
  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.id = p_invite_id;
  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  select i.*
    into v_invite
  from public.invite_codes i
  where i.id = p_invite_id
  for update;
  if not found
     or v_invite.group_id <> v_group.id
     or v_invite.created_by <> v_user_id
     or p_expected_version is null
     or v_invite.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  update public.invite_codes i
  set revoked_at = coalesce(i.revoked_at, pg_catalog.now()),
      version = i.version + 1
  where i.id = p_invite_id
    and i.created_by = v_user_id
    and i.version = p_expected_version
  returning i.* into v_invite;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;
  return query
  select v_invite.id, v_invite.group_id, v_invite.expires_at,
         v_invite.max_uses, v_invite.uses_count, v_invite.revoked_at,
         v_invite.version, v_invite.created_at, v_invite.updated_at;
end;
$$;

create or replace function public.set_member_active(
  p_group_id uuid,
  p_user_id uuid,
  p_is_active boolean
)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_group public.groups;
  v_membership public.memberships;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = p_group_id
  for update;
  if not found
     or v_group.owner_id <> v_actor_id
     or v_group.deleted_at is not null
     or p_user_id = v_actor_id then
    raise exception using
      errcode = '42501',
      message = 'only the owner can change another member';
  end if;

  select m.*
    into v_membership
  from public.memberships m
  where m.group_id = p_group_id
    and m.user_id = p_user_id
  for update;
  if not found or v_membership.role <> 'member' then
    raise exception using errcode = '22023', message = 'member does not exist';
  end if;

  update public.memberships m
  set is_active = p_is_active,
      removed_at = case when p_is_active then null else coalesce(m.removed_at, pg_catalog.now()) end
  where m.group_id = p_group_id
    and m.user_id = p_user_id
    and m.role = 'member'
  returning m.* into v_membership;
  if not found then
    raise exception using errcode = '22023', message = 'member does not exist';
  end if;
  return v_membership;
end;
$$;

-- 현재 사용자가 소유한 그룹 이름/ID/상태와 삭제 개수만 반환한다. 이는 계정 삭제
-- 표시용 사전 검사이며 감사/로깅 API가 아니다.
create or replace function public.account_deletion_preflight()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owned_groups jsonb;
  v_active_owned_groups jsonb;
  v_archived_owned_groups jsonb;
  v_events bigint;
  v_invites bigint;
  v_memberships bigint;
  v_groups bigint;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', case when g.deleted_at is null then 'active' else 'archived' end,
        'member_count', (
          select count(*)::integer
          from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer
          from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_owned_groups
  from public.groups g
  where g.owner_id = v_user_id;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', 'active',
        'member_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_active_owned_groups
  from public.groups g
  where g.owner_id = v_user_id and g.deleted_at is null;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'timezone', g.timezone,
        'version', g.version,
        'deleted_at', g.deleted_at,
        'status', 'archived',
        'member_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id and m.is_active and m.removed_at is null
        ),
        'membership_count', (
          select count(*)::integer from public.memberships m
          where m.group_id = g.id
        )
      ) order by g.created_at, g.id
    ),
    '[]'::jsonb
  )
    into v_archived_owned_groups
  from public.groups g
  where g.owner_id = v_user_id and g.deleted_at is not null;

  -- 소유 그룹과 작성한 행은 모두 auth.users 연쇄 작업에서 사라진다. 두 조건을
  -- 모두 만족해도 각 행을 한 번만 세도록 OR 조건자를 사용한다.
  select count(*) into v_groups
  from public.groups g
  where g.owner_id = v_user_id;
  select count(*) into v_events
  from public.events e
  where e.created_by = v_user_id
     or exists (select 1 from public.groups g where g.id = e.group_id and g.owner_id = v_user_id);
  select count(*) into v_invites
  from public.invite_codes i
  where i.created_by = v_user_id
     or exists (select 1 from public.groups g where g.id = i.group_id and g.owner_id = v_user_id);
  select count(*) into v_memberships
  from public.memberships m
  where m.user_id = v_user_id
     or exists (select 1 from public.groups g where g.id = m.group_id and g.owner_id = v_user_id);

  return pg_catalog.jsonb_build_object(
    'owned_groups', v_owned_groups,
    'active_owned_groups', v_active_owned_groups,
    'archived_owned_groups', v_archived_owned_groups,
    'groups', v_groups,
    'events', v_events,
    'invites', v_invites,
    'memberships', v_memberships
  );
end;
$$;

-- 이전 배포는 membership.user_id를 audit_logs.entity_id에 기록했다. 식별 가능한
-- 해당 필드만 제거하고 그룹/작업/버전 메타데이터는 유지한다.
update public.audit_logs
set entity_id = null
where entity_type = 'memberships'
  and entity_id is not null;

-- 인증 삭제는 auth.users와 groups 양쪽으로 퍼진다. 감사 FK를 지연하면 PostgreSQL이
-- 상위 연쇄 삭제 뒤 actor_id 및 group_id SET NULL 작업을 함께 적용할 수 있다.
-- 감사 행 자체를 보존하면서 일시적인 교차 연쇄 위반을 피한다.
alter table public.audit_logs
  alter constraint audit_logs_group_id_fkey deferrable initially deferred;
alter table public.audit_logs
  alter constraint audit_logs_actor_id_fkey deferrable initially deferred;

-- 직접 세부 정보 갱신은 RPC 전용으로 유지한다. 모든 API 역할에서 오래된 테이블 및
-- 열 단위 권한을 회수하며, SECURITY DEFINER RPC는 소유자 승인 쓰기 경로를 유지한다.
-- groups INSERT는 기존 create_group 트리거/RPC 계약과 계속 호환된다.
revoke update on table public.groups from public, anon, authenticated;
revoke update (owner_id, name, description, timezone, version, deleted_at,
               created_at, updated_at) on public.groups
  from public, anon, authenticated;
-- 업그레이드된 ACL 카탈로그에 승인된 세부 정보 열 목록을 명시적으로 유지한다.
revoke update (name, description, timezone, version) on public.groups
  from public, anon, authenticated;

-- 멤버십 상태 변경은 소유자 관리 RPC를 통해서만 노출한다. 남은 열 권한을 제거해
-- 오래된 직접 UPDATE 경로를 닫는다. set_member_active는 멤버십 검사 전에 상위
-- 그룹을 잠그고, 계정/그룹 연쇄 작업은 제한 없는 소유자 측 실행을 유지한다.
revoke update on table public.memberships from public, anon, authenticated;
revoke update (group_id, user_id, role, joined_at, removed_at, invited_by,
               created_at, updated_at, is_active) on public.memberships
  from public, anon, authenticated;

-- 새 SECURITY DEFINER 함수는 PUBLIC의 기본 EXECUTE 권한을 상속해서는 안 된다.
revoke execute on function public.write_audit_log()
  from public, anon, authenticated;

revoke execute on function public.update_group_if_version(uuid, integer, text, text, text)
  from public, anon, authenticated;
grant execute on function public.update_group_if_version(uuid, integer, text, text, text)
  to authenticated;

revoke execute on function public.leave_group(uuid)
  from public, anon, authenticated;
grant execute on function public.leave_group(uuid) to authenticated;

revoke execute on function public.transfer_group_ownership(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.transfer_group_ownership(uuid, uuid, integer)
  to authenticated;

revoke execute on function public.archive_group_if_version(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.archive_group_if_version(uuid, integer)
  to authenticated;

revoke execute on function public.account_deletion_preflight()
  from public, anon, authenticated;
grant execute on function public.account_deletion_preflight() to authenticated;

commit;
