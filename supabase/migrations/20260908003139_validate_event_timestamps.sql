-- 앞선 NOT VALID 제약은 짧은 ACCESS EXCLUSIVE 구간에서 신규 비유한 쓰기를 이미
-- 차단했다. 이 별도 단계는 과거 행을 읽어 배포자에게 명확한 진단을 제공한 뒤
-- 제약을 검증한다. 기존 값의 의미를 추측해 수정하거나 삭제하지 않는다.

begin;

do $$
declare
  v_invalid_count bigint;
  v_sample_ids text;
begin
  select pg_catalog.count(*)
    into v_invalid_count
  from public.events e
  where not pg_catalog.isfinite(e.starts_at)
     or not pg_catalog.isfinite(e.ends_at)
     or not pg_catalog.isfinite(e.created_at)
     or not pg_catalog.isfinite(e.updated_at)
     or (e.deleted_at is not null and not pg_catalog.isfinite(e.deleted_at));

  if v_invalid_count > 0 then
    select pg_catalog.string_agg(sample.id::text, ', ' order by sample.id)
      into v_sample_ids
    from (
      select e.id
      from public.events e
      where not pg_catalog.isfinite(e.starts_at)
         or not pg_catalog.isfinite(e.ends_at)
         or not pg_catalog.isfinite(e.created_at)
         or not pg_catalog.isfinite(e.updated_at)
         or (e.deleted_at is not null and not pg_catalog.isfinite(e.deleted_at))
      order by e.id
      limit 20
    ) sample;

    raise exception using
      errcode = '23514',
      message = 'events contain non-finite timestamps; validation made no data changes',
      detail = pg_catalog.format(
        'invalid event count: %s; sample event ids: %s',
        v_invalid_count,
        coalesce(v_sample_ids, '(none)')
      ),
      hint = 'Inspect with SELECT id, starts_at, ends_at, created_at, updated_at, deleted_at FROM public.events WHERE NOT pg_catalog.isfinite(starts_at) OR NOT pg_catalog.isfinite(ends_at) OR NOT pg_catalog.isfinite(created_at) OR NOT pg_catalog.isfinite(updated_at) OR (deleted_at IS NOT NULL AND NOT pg_catalog.isfinite(deleted_at)); remediate each row explicitly, then rerun this validation migration.';
  end if;
end;
$$;

alter table public.events
  validate constraint events_finite_time_bounds;

commit;
