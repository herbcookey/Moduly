#!/usr/bin/env bash

# 기능 3의 신규 설치/업그레이드/재적용 검증이다. 이 실행기는 일회용 로컬
# PostgreSQL 클러스터를 사용하며 Supabase 프로젝트나 제공자에 접속하지 않는다.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/splanner-reminders-upgrade.XXXXXX")
data_dir="$work_dir/data"
socket_dir="$work_dir/s"
port="${SPLANNER_TEST_PORT:-$((59800 + RANDOM % 150))}"
mkdir -p "$socket_dir"
initdb -D "$data_dir" -A trust --no-locale >/dev/null
pg_ctl -D "$data_dir" -o "-p $port -k $socket_dir" -w start >/dev/null
cleanup() {
  pg_ctl -D "$data_dir" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
psql_test() { psql -X -v ON_ERROR_STOP=1 -h "$socket_dir" -p "$port" postgres "$@"; }

psql_test <<'SQL'
create schema auth;
create role anon;
create role authenticated;
create role service_role;
create table auth.users (
  id uuid primary key,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
SQL

reminders_migration="$repo_dir/supabase/migrations/20260907130006_reminders.sql"
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ "$migration" == "$reminders_migration" ]] && break
  printf '%s 적용 중\n' "$(basename "$migration")"
  psql_test -f "$migration" >/dev/null
done

# 기능 3 전에 이전 행을 설치한다. 미리 알림 행을 만들어 내서는 안 되며 일정/그룹
# 내용은 바이트 단위로 변경 없이 유지해야 한다.
psql_test <<'SQL'
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at)
values
 ('00000000-0000-4000-8000-00000000f101', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rem-owner@example.test', '', now(), now(), now()),
 ('00000000-0000-4000-8000-00000000f102', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rem-member@example.test', '', now(), now(), now()),
 ('00000000-0000-4000-8000-00000000f103', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rem-inactive@example.test', '', now(), now(), now()),
 ('00000000-0000-4000-8000-00000000f104', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rem-outsider@example.test', '', now(), now(), now());
insert into public.groups (id, owner_id, name, description, timezone, version, created_at, updated_at)
values ('00000000-0000-4000-8000-00000000f201', '00000000-0000-4000-8000-00000000f101', 'Reminder fixture group', 'legacy group data', 'UTC', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
insert into public.memberships (group_id, user_id, role, is_active, joined_at, removed_at)
values
 ('00000000-0000-4000-8000-00000000f201', '00000000-0000-4000-8000-00000000f102', 'member', true, '2026-01-01T00:00:00Z', null),
 ('00000000-0000-4000-8000-00000000f201', '00000000-0000-4000-8000-00000000f103', 'member', true, '2026-01-01T00:00:00Z', null);
insert into public.events (id, group_id, created_by, title, description, starts_at, ends_at,
                           timezone, is_all_day, version, created_at, updated_at)
values ('00000000-0000-4000-8000-00000000f301', '00000000-0000-4000-8000-00000000f201',
        '00000000-0000-4000-8000-00000000f101', 'Legacy reminder event', 'legacy event data',
        '2026-03-10T14:00:00Z', '2026-03-10T15:00:00Z', 'UTC', false, 1,
        '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z');
insert into public.event_members (event_id, user_id)
values ('00000000-0000-4000-8000-00000000f301', '00000000-0000-4000-8000-00000000f102'),
       ('00000000-0000-4000-8000-00000000f301', '00000000-0000-4000-8000-00000000f103');
SQL

printf '%s 적용 중\n' "$(basename "$reminders_migration")"
psql_test -f "$reminders_migration" >/dev/null

# 마이그레이션 뒤 참여자를 비활성화하여 미리 알림 훅이 실제 비활성 멤버십을 대상으로
# 취소/정리 및 후보 ACL을 검사하게 한다.
psql_test <<'SQL'
update public.memberships
set is_active = false, removed_at = '2026-02-01T00:00:00Z'
where group_id = '00000000-0000-4000-8000-00000000f201'
  and user_id = '00000000-0000-4000-8000-00000000f103';
insert into public.events (id, group_id, created_by, title, description, starts_at, ends_at,
                           timezone, is_all_day, all_day_start, all_day_end, version,
                           created_at, updated_at)
values
 ('00000000-0000-4000-8000-00000000f302', '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f101', 'Timed reminder event', 'timed payload',
  '2026-03-10T16:00:00Z', '2026-03-10T17:00:00Z', 'UTC', false, null, null, 1,
  '2026-01-03T00:00:00Z', '2026-01-03T00:00:00Z'),
 ('00000000-0000-4000-8000-00000000f303', '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f101', 'All-day reminder event', 'all-day payload',
  '2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z', 'America/New_York', true,
  '2026-03-08', '2026-03-09', 1, '2026-01-04T00:00:00Z', '2026-01-04T00:00:00Z'),
 ('00000000-0000-4000-8000-00000000f304', '00000000-0000-4000-8000-00000000f201',
  '00000000-0000-4000-8000-00000000f101', 'Recurring reminder event', 'recurring payload',
  '2026-03-10T15:00:00Z', '2026-03-10T16:00:00Z', 'UTC', false, null, null, 1,
  '2026-01-05T00:00:00Z', '2026-01-05T00:00:00Z');
insert into public.event_recurrence_rules (
  event_id, segment_no, start_occurrence_index, end_occurrence_index,
  frequency, interval_value, weekdays, monthly_day, end_mode, occurrence_count,
  until_date, anchor_local_date, anchor_local_time, timezone, is_all_day,
  duration_seconds, duration_days, title, description, color_value, version,
  created_at, updated_at
) values (
  '00000000-0000-4000-8000-00000000f304', 0, 0, null, 'daily', 1, '{}'::smallint[],
  null, 'count', 2, null, '2026-03-10', '15:00:00', 'UTC', false,
  3600, null, 'Recurring reminder event', 'recurring payload', 1, 1,
  '2026-01-05T00:00:00Z', '2026-01-05T00:00:00Z');
SQL

printf '%s 재적용 중\n' "$(basename "$reminders_migration")"
psql_test -f "$reminders_migration" >/dev/null
printf '미리 알림 픽스처 실행 중\n'
psql_test -f "$repo_dir/supabase/tests/reminders.sql" >/dev/null
printf '미리 알림 신규 설치/재적용/인접 기능 검사를 통과했습니다\n'
