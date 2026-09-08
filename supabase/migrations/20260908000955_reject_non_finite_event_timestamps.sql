-- PostgreSQL의 timestamptz는 특수값 +/-infinity를 허용하지만 Flutter의 엄격한
-- 일정 전송 형식은 유한한 ISO-8601 시각만 허용한다. 기존 CHECK인 ends_at >
-- starts_at만으로는 (-infinity, infinity)와 (finite, infinity)를 막지 못하며,
-- 수명 주기 열의 특수값도 캘린더 행 전체의 엄격한 파싱을 실패시킨다.
--
-- 이 첫 단계는 NOT VALID 제약만 빠르게 설치하고 즉시 커밋한다. 테이블 전체 점검과
-- 검증은 다음 forward-only 마이그레이션에서 수행하므로 ACCESS EXCLUSIVE 잠금을
-- 긴 스캔 동안 유지하지 않는다. 기존 행은 그대로 두되 신규/갱신 쓰기는 즉시
-- 다섯 timestamptz 열의 유한성 계약을 따라야 한다.

begin;

alter table public.events
  add constraint events_finite_time_bounds
  check (
    pg_catalog.isfinite(starts_at)
    and pg_catalog.isfinite(ends_at)
    and pg_catalog.isfinite(created_at)
    and pg_catalog.isfinite(updated_at)
    and (deleted_at is null or pg_catalog.isfinite(deleted_at))
  ) not valid;

comment on constraint events_finite_time_bounds on public.events is
  '캘린더 전송 형식이 파싱할 수 있도록 일정의 모든 timestamptz 열에서 +/-infinity를 거부한다.';

commit;
