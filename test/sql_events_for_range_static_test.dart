import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 범위가 제한된 달력 범위 마이그레이션의 정적 계약 검사다. pgTAP 픽스처와 로컬
/// 업그레이드 스크립트는 PostgreSQL을 대상으로 같은 계약을 실행한다. 이 검사는
/// Supabase/Docker 데몬이 없는 환경에서도 보안과 페이지네이션 불변 조건을
/// 명확히 보여 준다.
void main() {
  late String migration;
  late String finiteTimestampsMigration;
  late String finiteTimestampsMigrationName;
  late String validateTimestampsMigration;
  late String validateTimestampsMigrationName;
  late String fixture;
  late String upgrade;

  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907130003_calendar_range.sql',
    );
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: 'CLI로 만든 달력 범위 마이그레이션이 있어야 한다',
    );
    migration = normalized(migrationFile.readAsStringSync());

    final finiteTimestampMigrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('_reject_non_finite_event_timestamps.sql'),
        )
        .toList(growable: false);
    expect(
      finiteTimestampMigrations,
      hasLength(1),
      reason: 'CLI로 만든 비유한 일정 타임스탬프 차단 마이그레이션이 하나 있어야 한다',
    );
    finiteTimestampsMigrationName =
        finiteTimestampMigrations.single.uri.pathSegments.last;
    finiteTimestampsMigration = normalized(
      finiteTimestampMigrations.single.readAsStringSync(),
    );

    final validateTimestampMigrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('_validate_event_timestamps.sql'))
        .toList(growable: false);
    expect(
      validateTimestampMigrations,
      hasLength(1),
      reason: 'CLI로 만든 일정 타임스탬프 검증 마이그레이션이 하나 있어야 한다',
    );
    validateTimestampsMigrationName =
        validateTimestampMigrations.single.uri.pathSegments.last;
    validateTimestampsMigration = normalized(
      validateTimestampMigrations.single.readAsStringSync(),
    );

    final fixtureFile = File('supabase/tests/events_for_range.sql');
    expect(fixtureFile.existsSync(), isTrue, reason: '범위 제한 pgTAP 픽스처가 있어야 한다');
    fixture = normalized(fixtureFile.readAsStringSync());

    final upgradeFile = File('supabase/tests/run_events_for_range_upgrade.sh');
    expect(upgradeFile.existsSync(), isTrue, reason: '로컬 범위 업그레이드 증거가 있어야 한다');
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('마이그레이션이 추가형이고 엄격히 정렬되며 키셋용으로 색인된다', () {
    final migrations =
        Directory('supabase/migrations')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.sql'))
            .map((file) => file.uri.pathSegments.last)
            .toList()
          ..sort();
    final timestamps = migrations
        .map((name) => RegExp(r'^(\d+)_[^/]+\.sql$').firstMatch(name))
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!)
        .toList();
    expect(timestamps, isNotEmpty);
    expect(
      timestamps.length,
      migrations.length,
      reason: '모든 마이그레이션 파일명에 숫자 타임스탬프 접두사가 있어야 한다',
    );
    expect(timestamps.toSet().length, timestamps.length);
    expect(migrations, contains('20260907130003_calendar_range.sql'));
    final finiteTimestampPrefix = RegExp(
      r'^(\d+)_',
    ).firstMatch(finiteTimestampsMigrationName)!.group(1)!;
    final validateTimestampPrefix = RegExp(
      r'^(\d+)_',
    ).firstMatch(validateTimestampsMigrationName)!.group(1)!;
    expect(
      BigInt.parse(finiteTimestampPrefix),
      greaterThan(BigInt.parse('20260907171029')),
      reason: '이미 배포되었을 수 있는 일정 검색 뒤의 forward-only 마이그레이션이어야 한다',
    );
    expect(
      BigInt.parse(validateTimestampPrefix),
      greaterThan(BigInt.parse(finiteTimestampPrefix)),
      reason: '장기 검증은 짧은 NOT VALID 보호막이 커밋된 뒤 실행되어야 한다',
    );
    expect(
      migration,
      contains(
        'create index if not exists events_group_start_id_live_idx on public.events (group_id, starts_at, id) where deleted_at is null',
      ),
    );
    expect(
      migration,
      contains(
        'create index if not exists events_group_allday_dates_live_idx on public.events (group_id, all_day_start, all_day_end, id) where deleted_at is null and is_all_day',
      ),
    );
    expect(migration, contains('create index if not exists'));
    expect(migration, isNot(contains('drop table public.events')));
    expect(migration, isNot(contains('truncate public.events')));
  });

  test('짧은 보호막 뒤 별도 검증으로 모든 일정 타임스탬프를 안전하게 제한한다', () {
    const constraint = 'events_finite_time_bounds';
    final addConstraint =
        'add constraint $constraint check ( pg_catalog.isfinite(starts_at) and pg_catalog.isfinite(ends_at) and pg_catalog.isfinite(created_at) and pg_catalog.isfinite(updated_at) and (deleted_at is null or pg_catalog.isfinite(deleted_at)) ) not valid';
    final detectExisting =
        'where not pg_catalog.isfinite(e.starts_at) or not pg_catalog.isfinite(e.ends_at) or not pg_catalog.isfinite(e.created_at) or not pg_catalog.isfinite(e.updated_at) or (e.deleted_at is not null and not pg_catalog.isfinite(e.deleted_at))';
    final validateConstraint = 'validate constraint $constraint';

    expect(finiteTimestampsMigration, contains(addConstraint));
    expect(finiteTimestampsMigration, isNot(contains(detectExisting)));
    expect(finiteTimestampsMigration, isNot(contains(validateConstraint)));
    expect(finiteTimestampsMigration, contains('commit;'));
    expect(validateTimestampsMigration, contains(detectExisting));
    expect(
      validateTimestampsMigration,
      contains(
        'events contain non-finite timestamps; validation made no data changes',
      ),
    );
    expect(
      validateTimestampsMigration,
      contains(
        'inspect with select id, starts_at, ends_at, created_at, updated_at, deleted_at from public.events',
      ),
    );
    expect(validateTimestampsMigration, contains(validateConstraint));
    expect(
      validateTimestampsMigration.indexOf(detectExisting),
      lessThan(validateTimestampsMigration.indexOf(validateConstraint)),
    );
    expect(finiteTimestampsMigration, isNot(contains('update public.events')));
    expect(
      validateTimestampsMigration,
      isNot(contains('update public.events')),
    );
    expect(
      '$finiteTimestampsMigration $validateTimestampsMigration',
      isNot(contains('delete from public.events')),
    );
    expect(
      '$finiteTimestampsMigration $validateTimestampsMigration',
      isNot(contains('truncate public.events')),
    );
  });

  test('RPC 시그니처와 보안 경계가 명확하다', () {
    expect(
      migration,
      contains(
        'create or replace function public.events_for_range( p_group_id uuid, p_range_start timestamptz, p_range_end timestamptz, p_view_timezone text default null, p_limit integer default 100, p_cursor text default null, p_participant_id uuid default null ) returns jsonb',
      ),
    );
    expect(migration, contains('language plpgsql security definer'));
    expect(migration, contains("set search_path = ''"));
    expect(migration, contains('v_actor_id uuid := (select auth.uid())'));
    expect(migration, contains('from public.groups g'));
    expect(migration, contains('from public.memberships m'));
    expect(migration, contains('v_group.deleted_at is not null'));
    expect(migration, contains('message = \'group is unavailable\''));
    expect(
      migration,
      contains('revoke execute on function public.events_for_range('),
    );
    expect(migration, contains('from public, anon, authenticated'));
    expect(
      migration,
      contains('grant execute on function public.events_for_range('),
    );
    expect(migration, contains('to authenticated'));
  });

  test('범위 및 겹침 검증이 현지 달력 의미를 사용한다', () {
    expect(migration, contains('pg_catalog.isfinite(p_range_start)'));
    expect(migration, contains('pg_catalog.isfinite(p_range_end)'));
    expect(migration, contains('p_range_end <= p_range_start'));
    expect(migration, contains('v_end_date <= v_start_date'));
    expect(migration, contains('v_end_date - v_start_date > 366'));
    expect(migration, contains('p_range_start at time zone v_view_timezone'));
    expect(migration, contains('p_range_end at time zone v_view_timezone'));
    expect(
      migration,
      contains('range endpoints must be local midnight in the view timezone'),
    );
    expect(
      migration,
      contains(
        'not e.is_all_day and e.starts_at < p_range_end and e.ends_at > p_range_start',
      ),
    );
    expect(
      migration,
      contains(
        'e.is_all_day and e.all_day_start < v_end_date and e.all_day_end > v_start_date',
      ),
    );
    expect(migration, contains('where t.name = v_view_timezone'));
    expect(migration, contains('coalesce(p_view_timezone, v_group.timezone)'));
    expect(migration, contains('from pg_catalog.pg_timezone_names t'));
  });

  test('커서 계약이 불투명하고 URL에 안전하며 버전이 있고 안전하게 실패한다', () {
    expect(migration, contains('정확히 {v, starts_at, event_id}'));
    expect(migration, contains(r"p_cursor !~ '^[a-za-z0-9_-]+$'"));
    expect(migration, contains("pg_catalog.translate(p_cursor, '-_', '+/')"));
    expect(migration, contains("pg_catalog.repeat( '=',"));
    expect(migration, contains("'v', 1"));
    expect(migration, contains("v_cursor ->> 'v'"));
    expect(
      migration,
      contains("pg_catalog.jsonb_typeof(v_cursor -> 'v') <> 'number'"),
    );
    expect(migration, contains("pg_catalog.json_typeof(v_cursor_wire -> 'v')"));
    expect(
      migration,
      contains(r"(v_cursor_wire -> 'v')::text !~ '^-?[0-9]+$'"),
    );
    expect(migration, contains("v_cursor - 'v' - 'starts_at' - 'event_id'"));
    expect(migration, contains('v_cursor_version <> \'1\''));
    expect(
      migration,
      contains('cursor timestamp must include an explicit timezone'),
    );
    expect(migration, contains('cursor timestamp is invalid'));
    expect(migration, contains('v_cursor_parts := pg_catalog.regexp_match('));
    expect(migration, contains('v_cursor_parts[6]::integer'));
    expect(migration, contains('v_cursor_parts[8] = \'z\''));
    expect(migration, contains('v_cursor_days_in_month'));
    expect(migration, contains('v_cursor_hour > 23'));
    expect(migration, contains('v_cursor_offset_hour > 23'));
    expect(migration, contains('v_cursor_offset_minute > 59'));
    expect(migration, contains(r'{1,6}'));
    expect(migration, contains(r'(z|[+-][0-9]{2}:[0-9]{2})$'));
    expect(migration, contains("pg_catalog.isfinite(v_cursor_start)"));
    expect(migration, contains('pg_catalog.length(p_cursor) > 4096'));
    expect(migration, contains("'+/', '-_'"));
    expect(migration, contains("pg_catalog.rtrim("));
    expect(
      migration,
      isNot(contains('cursor is outside the requested range')),
      reason: '종일 starts_at은 조회자 UTC 범위 밖일 수 있으며 튜플 전용 커서는 유효하다',
    );
    expect(migration, contains('limit (v_limit + 1)'));
    expect(migration, contains('order by e.starts_at, e.id'));
    expect(
      migration,
      contains('e.starts_at = v_cursor_start and e.id > v_cursor_event_id'),
    );
  });

  test('일정/멤버 표시 범위와 Realtime 개인정보 보호가 유지된다', () {
    expect(migration, contains('e.deleted_at is null'));
    expect(migration, contains('target.is_active'));
    expect(migration, contains('target.removed_at is null'));
    expect(migration, contains('p_participant_id is not null'));
    expect(
      migration,
      contains('exists ( select 1 from public.event_members em'),
    );
    expect(migration, contains("'member_ids'"));
    expect(migration, contains("'events', v_rows"));
    expect(migration, contains("'next_cursor', v_next_cursor"));
    expect(migration, contains("'has_more', v_has_more"));
    expect(
      migration,
      isNot(
        contains(
          'alter publication supabase_realtime add table public.event_members',
        ),
      ),
    );
    expect(migration, isNot(contains('create publication supabase_realtime')));
    expect(migration, contains('from public.event_members em'));
    expect(migration, contains('join public.memberships target'));
  });

  test('픽스처가 권한, 경계, 커서, 페이지네이션을 검사한다', () {
    for (final marker in <String>[
      '소유자는 정확한 반개방 일 범위에서 겹치는 일정과 종일 일정 행을 볼 수 있다',
      '활성 일반 구성원은 고정된 시간대와 함께 활성 그룹을 조회할 수 있다',
      '외부 사용자는 그룹 이벤트 범위를 조회할 수 없다',
      '비활성 구성원은 그룹 이벤트 범위를 조회할 수 없다',
      '보관된 그룹은 과거 행을 반환하지 않고 접근을 차단한다',
      '존재하지 않는 그룹도 같은 권한 결과로 접근을 차단한다',
      '범위는 시간 경계에서 반개방 구간으로 동작한다',
      'range_start에 끝나는 종일 일정은 제외된다',
      '참여자 필터는 활성 대상에게 할당된 행만 반환한다',
      '비활성 참여자 대상은 목록을 노출하지 않고 거부된다',
      '다른 그룹의 참여자 대상은 상태를 노출하지 않고 거부된다',
      'dst 현지 자정 검증은 23시간짜리 utc 날짜를 허용한다',
      '현지 달력 기준 366일을 넘는 범위는 거부된다',
      '0인 제한값은 거부된다',
      '정해진 최대값을 넘는 제한값은 거부된다',
      '잘못된 커서는 행을 조회하기 전에 거부된다',
      '객체가 아닌 커서 페이로드는 거부된다',
      'cursor version is unsupported',
      '문자열 형식의 커서 버전은 거부된다',
      '부동소수점 형식의 커서 버전은 거부된다',
      '시간대가 없는 커서 타임스탬프는 거부된다',
      '알 수 없는 커서 키는 거부된다',
      '커서 타임스탬프에는 초가 필요하다',
      '소수 부분이 여섯 자리를 넘는 커서는 거부된다',
      '존재할 수 없는 달력 날짜를 담은 커서는 거부된다',
      '잘못된 시각 요소를 담은 커서는 거부된다',
      '잘못된 오프셋을 담은 커서는 거부된다',
      '한 자리부터 여섯 자리까지의 유효한 커서 소수 부분은 허용된다',
      '명시적 오프셋이 있는 유효한 여섯 자리 커서 소수 부분은 허용된다',
      '유한하지 않은 커서 튜플은 타임스탬프 변환 전에 거부된다',
      'range_end 뒤의 유한한 튜플은 빈 연속 페이지로 허용된다',
      '이벤트 1001개가 중복 행이나 누락 없이 페이지로 나뉜다',
      '모든 대량 이벤트가 정확히 하나의 키셋 페이지에 나타난다',
      '마지막 한 행짜리 페이지가 유지된다',
      '완전한 이벤트 구조와 member_ids가 포함된다',
      'starts_at이 -infinity인 일정은 테이블 경계에서 거부된다',
      'ends_at이 infinity인 일정은 테이블 경계에서 거부된다',
      'created_at이 -infinity인 일정은 테이블 경계에서 거부된다',
      'updated_at이 infinity인 일정은 테이블 경계에서 거부된다',
      'deleted_at이 infinity인 일정은 테이블 경계에서 거부된다',
      '일정 타임스탬프 유한성 검사는 검증된 상태다',
      '실시간 기능이 구성되면 상위 events 테이블이 계속 무효화 신호 역할을 한다',
    ]) {
      expect(
        fixture,
        contains(normalized(marker)),
        reason: '픽스처가 $marker 항목을 검증해야 한다',
      );
    }
  });

  test('업그레이드 스크립트가 과거 데이터 채우기와 재적용 보존을 입증한다', () {
    for (final marker in <String>[
      '임시 로컬',
      r'rm -rf -- "$work_dir"',
      'event_members 이전',
      '과거 작성자 데이터 채우기',
      '비활성/삭제 작성자 데이터 채우기의 타임스탬프',
      '%s 적용 중',
      '%s 재적용 중',
      '범위 RPC가 삭제된 행을 반환했거나 필요한 행을 누락',
      '범위 마이그레이션 재적용으로 채운 행 개수가 변경',
      '기존 비유한 일정 행을 탐지하지 못했습니다',
      '비유한 일정 행은 실패한 마이그레이션에서 변경되면 안 됩니다',
      'not valid 유한성 보호막이 커밋되지 않았습니다',
      'created_at 비유한 신규 일정이 허용되었습니다',
      'updated_at 비유한 갱신이 허용되었습니다',
      'deleted_at 비유한 갱신이 허용되었습니다',
      '배포자 명시 조치 후 유한성 검증 마이그레이션을 적용',
      '신규 비유한 일정 경계가 허용되었습니다',
      'event_members를 supabase_realtime에 추가해서는 안',
      'events_for_range 업그레이드/재적용/데이터 채우기 검사를 통과',
    ]) {
      expect(
        upgrade,
        contains(normalized(marker)),
        reason: '업그레이드가 $marker 항목을 입증해야 한다',
      );
    }
  });
}
