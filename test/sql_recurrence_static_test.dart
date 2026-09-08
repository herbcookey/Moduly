import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 기능 2의 정적 계약 검사다. 일회용 데이터베이스와 pgTAP을 사용할 수 있으면
/// `supabase/tests/recurrence.sql`과 로컬 업그레이드 실행기가 PostgreSQL을
/// 대상으로 같은 불변 조건을 실행한다.
void main() {
  late String migration;
  late String monthlyContractMigration;
  late String untilContractMigration;
  late String fixture;
  late String upgrade;

  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907130005_recurrence.sql',
    );
    expect(migrationFile.existsSync(), isTrue);
    migration = normalized(migrationFile.readAsStringSync());
    final monthlyContractMigrationFile = File(
      'supabase/migrations/20260908001038_fix_monthly_occurrence_zero.sql',
    );
    expect(monthlyContractMigrationFile.existsSync(), isTrue);
    monthlyContractMigration = normalized(
      monthlyContractMigrationFile.readAsStringSync(),
    );
    final untilContractMigrationFile = File(
      'supabase/migrations/20260908003015_reject_recurrence_ending_before_first_occurrence.sql',
    );
    expect(untilContractMigrationFile.existsSync(), isTrue);
    untilContractMigration = normalized(
      untilContractMigrationFile.readAsStringSync(),
    );
    final fixtureFile = File('supabase/tests/recurrence.sql');
    expect(fixtureFile.existsSync(), isTrue);
    fixture = normalized(fixtureFile.readAsStringSync());
    final upgradeFile = File('supabase/tests/run_recurrence_upgrade.sh');
    expect(upgradeFile.existsSync(), isTrue);
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('마이그레이션 순서와 추가형 하위 스키마가 명확하다', () {
    final names =
        Directory('supabase/migrations')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.sql'))
            .map((file) => file.uri.pathSegments.last)
            .toList()
          ..sort();
    final timestamps = names
        .map((name) => RegExp(r'^(\d+)_[^/]+\.sql$').firstMatch(name))
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!)
        .toList();
    expect(timestamps.length, names.length);
    expect(timestamps.toSet().length, names.length);
    expect(names, contains('20260907130005_recurrence.sql'));
    expect(names, contains('20260908001038_fix_monthly_occurrence_zero.sql'));
    expect(
      names,
      contains(
        '20260908003015_reject_recurrence_ending_before_first_occurrence.sql',
      ),
    );
    expect(
      names.indexOf('20260908001038_fix_monthly_occurrence_zero.sql'),
      lessThan(
        names.indexOf(
          '20260908003015_reject_recurrence_ending_before_first_occurrence.sql',
        ),
      ),
    );
    expect(
      migration,
      contains('create table if not exists public.event_recurrence_rules'),
    );
    expect(
      migration,
      contains('create table if not exists public.event_occurrence_overrides'),
    );
    expect(
      migration,
      contains('references public.events(id) on delete cascade'),
    );
    expect(migration, contains('primary key (event_id, occurrence_index)'));
    expect(migration, contains('unique (event_id, occurrence_key)'));
    expect(
      migration,
      contains(
        'create index if not exists event_recurrence_rules_event_start_idx',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists event_occurrence_overrides_event_key_idx',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists event_occurrence_overrides_effective_start_idx',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists event_occurrence_overrides_effective_end_idx',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists event_occurrence_overrides_effective_all_day_start_idx',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists event_occurrence_overrides_effective_all_day_end_idx',
      ),
    );
    expect(
      migration,
      contains('create trigger event_occurrence_override_integrity'),
    );
    expect(migration, isNot(contains('drop table public.events')));
    expect(migration, isNot(contains('truncate public.events')));
  });

  test('월간 순번 0 계약은 전진 마이그레이션으로 교체된다', () {
    expect(
      monthlyContractMigration,
      contains('create or replace function public._event_occurrence_at_index('),
    );
    expect(
      monthlyContractMigration,
      contains(
        'when v_month_anchor_candidate < v_rule.anchor_local_date then 1',
      ),
    );
    expect(
      monthlyContractMigration,
      contains('v_month_offset := v_offset * v_rule.interval_value + case'),
    );
    expect(
      monthlyContractMigration,
      contains(
        "comment on function public._event_occurrence_at_index(uuid, bigint)",
      ),
    );
    expect(
      monthlyContractMigration,
      isNot(contains('update public.event_recurrence_rules')),
    );
    expect(
      monthlyContractMigration,
      isNot(contains('delete from public.event_recurrence_rules')),
    );
    expect(
      monthlyContractMigration,
      isNot(contains('truncate public.event_recurrence_rules')),
    );
  });

  test('월간 종료일은 순번 0을 포함하며 기존 데이터를 변경하지 않는다', () {
    expect(
      untilContractMigration,
      contains(
        'create or replace function public._monthly_occurrence_zero_date(',
      ),
    );
    expect(
      untilContractMigration,
      contains('if v_candidate < p_anchor_local_date then'),
    );
    expect(untilContractMigration, contains('interval은 순번 0 이후 간격에만 적용된다'));
    expect(
      untilContractMigration,
      contains(
        'create or replace function public.enforce_recurrence_until_occurrence_zero()',
      ),
    );
    expect(
      untilContractMigration,
      contains('before insert or update on public.event_recurrence_rules'),
    );
    expect(
      untilContractMigration,
      contains('until_date precedes the first occurrence'),
    );
    expect(
      untilContractMigration,
      contains(
        'revoke execute on function public._monthly_occurrence_zero_date(date, smallint)',
      ),
    );
    expect(
      untilContractMigration,
      isNot(contains('update public.event_recurrence_rules set')),
    );
    expect(
      untilContractMigration,
      isNot(contains('delete from public.event_recurrence_rules')),
    );
    expect(
      untilContractMigration,
      isNot(contains('truncate public.event_recurrence_rules')),
    );
    expect(
      upgrade,
      contains('create rpc committed a monthly series but returned zero rows'),
    );
    expect(
      upgrade,
      contains('rejected monthly series left partial event data'),
    );
  });

  test('규칙 의미와 안정적인 순번 키에 제약 조건이 적용된다', () {
    expect(migration, contains("frequency in ('daily', 'weekly', 'monthly')"));
    expect(
      migration,
      contains(
        'interval_value integer not null check (interval_value between 1 and 999)',
      ),
    );
    expect(migration, contains("end_mode in ('never', 'count', 'until')"));
    expect(migration, contains('monthly_day between 1 and 31'));
    expect(migration, contains('anchor_local_time time without time zone'));
    expect(migration, contains('duration_seconds bigint'));
    expect(migration, contains('duration_days integer'));
    expect(
      migration,
      contains("return 'o' || pg_catalog.lpad(p_index::text, 20, '0')"),
    );
    expect(migration, contains("occurrence_key text not null"));
    expect(migration, contains("'single'::text"));
    expect(migration, contains('at time zone v_rule.timezone'));
    expect(migration, contains('p_index > 2147483647::bigint'));
    expect(migration, contains("when sqlstate '22008' then"));
    expect(migration, contains("when sqlstate '22003' then"));
    expect(migration, contains('날짜, 월, 타임스탬프 및 시간대'));
    expect(migration, contains('weekdays cannot contain null'));
    expect(migration, contains('weekdays must be sorted and distinct'));
    expect(migration, contains('at time zone v_effective_timezone'));
    expect(
      migration,
      contains(
        "v_effective_frequency <> 'monthly' and p_monthly_day is not null",
      ),
    );
    expect(migration, contains('범위 조회를 무한 반복으로 바꾸는 것을 막는다'));
  });

  test('RLS, ACL, 정의자 검색 경로, 작성자/버전 잠금이 명확하다', () {
    for (final table in <String>[
      'event_recurrence_rules',
      'event_occurrence_overrides',
    ]) {
      expect(
        migration,
        contains('alter table public.$table enable row level security'),
      );
      expect(
        migration,
        contains(
          'revoke all on table public.$table from public, anon, authenticated',
        ),
      );
      expect(migration, contains('create policy ${table}_write_deny'));
    }
    expect(migration, contains("set search_path = ''"));
    expect(migration, contains('for key share'));
    expect(migration, contains("auth.jwt() ->> 'is_anonymous'"));
    expect(
      migration,
      contains('revoke execute on function public.events_for_range_v2('),
    );
    expect(
      migration,
      contains('grant execute on function public.events_for_range_v2('),
    );
    expect(
      migration,
      contains(
        'revoke execute on function public.create_recurring_event_with_members(',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.create_recurring_event_with_members(',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.update_event_occurrence_scope_if_version(',
      ),
    );
    expect(migration, contains('v_event.created_by <> v_actor'));
    expect(migration, contains('v_event.version <> p_expected_version'));
    expect(
      migration,
      contains('from public.groups g where g.id = v_event.group_id for update'),
    );
    expect(
      migration,
      contains(
        'where m.group_id = v_event.group_id and m.user_id = v_actor for update',
      ),
    );
    expect(
      migration,
      contains('order by r.start_occurrence_index, r.segment_no for update'),
    );
    expect(migration, contains('version = e.version + 1'));
    expect(migration, contains('all event members must have accounts'));
    expect(
      migration,
      contains(
        'create or replace function public.replace_recurring_event_members_if_version(',
      ),
    );
    expect(migration, contains('p_occurrence_key text'));
    expect(migration, contains('p_member_ids uuid[]'));
    expect(
      migration,
      contains('rename to _legacy_replace_event_members_if_version'),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.replace_recurring_event_members_if_version(',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on function public.replace_event_members_if_version(',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on function public.replace_event_members_if_version(uuid, integer, uuid[]) from service_role',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.replace_event_members_if_version(',
      ),
    );
    expect(
      migration,
      contains('event creator must remain an active participant'),
    );
  });

  test('v2 읽기 봉투/커서와 범위 영수증 계약이 명확하다', () {
    expect(
      migration,
      contains('create or replace function public.events_for_range_v2('),
    );
    expect(migration, contains('p_member_ids uuid[]'));
    expect(migration, contains('p_frequency text'));
    expect(migration, contains('returns jsonb'));
    expect(migration, contains("v_cursor->>'occurrence_key'"));
    expect(migration, contains("o[0-9]{20}"));
    expect(
      migration,
      contains('order by o.starts_at, o.event_id, o.occurrence_key'),
    );
    expect(migration, contains('limit (v_limit + 1)'));
    expect(migration, contains('v_end_date - v_start_date > 366'));
    expect(migration, contains("'scheduled_starts_at'"));
    expect(migration, contains("'occurrence_version'"));
    expect(migration, contains("'recurrence_rule'"));
    expect(migration, contains("'series_version', p_series_version"));
    expect(migration, contains("'changed', p_changed"));
    expect(migration, contains("'committed', true"));
    expect(migration, contains('어느 하위 테이블도 supabase_realtime에 추가하지 않는다'));
    expect(migration, contains("p_scope not in ('this', 'future', 'all')"));
    expect(
      migration,
      contains("p_scope <> 'all' and p_member_ids is not null"),
    );
    expect(migration, contains("p_scope = 'all' and p_member_ids is null"));
    expect(migration, contains('creator must remain an active participant'));
    expect(migration, contains('converting to a singleton'));
    expect(
      migration,
      contains(
        'delete from public.event_occurrence_overrides where event_id = p_event_id and occurrence_index >= v_index',
      ),
    );
    expect(fixture, contains('월간 31일은 2월 말일로 조정된다'));
    expect(fixture, contains('월간 순번 0은 기준 시각 이후의 첫 유효한 날짜다'));
    expect(fixture, contains('간격이 0이면 거부된다'));
    expect(fixture, contains('간격이 1000이면 거부된다'));
    expect(fixture, contains('future 범위 업데이트는 반복 일정을 분할한다'));
    expect(fixture, contains('전체 범위 교체는 희소 예외와 참여자를 원자적으로 재설정한다'));
    expect(fixture, contains('동일한 this 범위 재실행은 아무 작업도 하지 않는다'));
    expect(fixture, contains('취소 재실행은 멱등적으로 아무 작업도 하지 않는다'));
    expect(fixture, contains('전용 응답 rpc'));
    expect(fixture, contains('반복 일정 구성원 교체는 생성자 누락을 거부한다'));
    expect(
      fixture,
      contains('반복 일정 구성원 전용 rpc는 authenticated 역할을 통해서만 실행할 수 있다'),
    );
    expect(fixture, contains('호환성 래퍼의 public acl 권한이 회수되어 있다'));
    expect(upgrade, contains('제한 발생 1097개를 기대했지만'));
    expect(upgrade, contains('dst 누락 시각을 앞으로 해석하지 않았습니다'));
    expect(upgrade, contains('23시간 utc 경과 투영'));
    expect(upgrade, contains('25시간 utc 경과 투영'));
    expect(upgrade, contains('상속된 향후 횟수'));
    expect(upgrade, contains('범위 안으로 이동한 재정의'));
    expect(upgrade, contains('익명 생성 호출이 예기치 않게 성공했습니다'));
    expect(upgrade, contains('null 갱신 범위가 예기치 않게 성공했습니다'));
    expect(upgrade, contains('단일 일정에서 반복 일정으로 변환'));
    expect(upgrade, contains('반복 일정에서 단일 일정으로 변환'));
    expect(upgrade, contains('replace_recurring_event_members_if_version'));
    expect(upgrade, contains('작성자를 제외한 반복 멤버 교체'));
    expect(upgrade, contains('이전 반복 교체가 예기치 않게 작성자를 제거'));
    expect(upgrade, contains('단일 일정 호환성 빈 교체'));
    expect(upgrade, contains('lock dedicated members'));
    expect(upgrade, contains('service_role이 호환성 래퍼를 실행할 수 있습니다'));
    expect(fixture, contains('오래된 상위 버전은 거부된다'));
    expect(upgrade, contains('재적용 중'));
    expect(upgrade, contains('월간 순번 0이 기준 시각 이후의 첫 유효한 날짜'));
    expect(upgrade, contains('pgtap을 사용할 수 없어'));
    expect(upgrade, contains('explain (costs off)'));
    expect(migration, contains('표식을 안정적인 순번 0 구체화'));
    expect(migration, contains('전에 소비한 순번만큼'));
  });
}
