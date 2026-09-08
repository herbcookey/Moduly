import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 기능 G의 정적 계약 검사다. 일회용 데이터베이스와 pgTAP 확장을 사용할 수
/// 있으면 pgTAP 픽스처와 로컬 업그레이드 실행기가 PostgreSQL을 대상으로
/// 같은 불변 조건을 실행한다.
void main() {
  late String migration;
  late String fixture;
  late String upgrade;

  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907171029_event_search.sql',
    );
    expect(migrationFile.existsSync(), isTrue);
    migration = normalized(migrationFile.readAsStringSync());

    final fixtureFile = File('supabase/tests/event_search.sql');
    expect(fixtureFile.existsSync(), isTrue);
    fixture = normalized(fixtureFile.readAsStringSync());

    final upgradeFile = File('supabase/tests/run_event_search_upgrade.sh');
    expect(upgradeFile.existsSync(), isTrue);
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('마이그레이션이 추가형이고 순서가 있으며 생성자 필터로 색인된다', () {
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
    expect(names.length, greaterThanOrEqualTo(16));
    expect(timestamps.length, names.length);
    expect(timestamps.toSet().length, names.length);
    expect(names, contains('20260907171029_event_search.sql'));
    expect(
      BigInt.parse(timestamps.last),
      greaterThanOrEqualTo(BigInt.parse('20260907171029')),
      reason: '검색 이후의 forward-only 수정 마이그레이션을 허용해야 한다',
    );
    expect(
      migration,
      contains(
        'create index if not exists events_group_creator_start_id_live_idx on public.events (group_id, created_by, starts_at, id) where deleted_at is null',
      ),
    );
    expect(migration, isNot(contains('drop table public.events')));
    expect(migration, isNot(contains('truncate public.events')));
  });

  test('RPC 시그니처와 보안 경계가 명확하다', () {
    expect(
      migration,
      contains(
        'create or replace function public.search_events_v1( p_group_id uuid, p_range_start timestamptz, p_range_end timestamptz, p_view_timezone text default null, p_query text default null, p_creator_id uuid default null, p_participant_id uuid default null, p_limit integer default 50, p_cursor text default null ) returns jsonb',
      ),
    );
    expect(migration, contains('language plpgsql security definer'));
    expect(migration, contains("set search_path = ''"));
    expect(migration, contains('v_actor uuid := (select auth.uid())'));
    expect(migration, contains("auth.jwt() ->> 'is_anonymous'"));
    expect(migration, contains('from public.groups g'));
    expect(migration, contains('for share'));
    expect(migration, contains('public.is_active_member(p_group_id)'));
    expect(migration, contains('message = \'group is unavailable\''));
    expect(
      migration,
      contains('revoke execute on function public.search_events_v1('),
    );
    expect(migration, contains('from public, anon, authenticated'));
    expect(
      migration,
      contains('grant execute on function public.search_events_v1('),
    );
    expect(migration, contains('to authenticated'));
  });

  test('기간, 검색어, 서버 한도 검증 범위가 제한된다', () {
    expect(migration, contains('pg_catalog.isfinite(p_range_start)'));
    expect(migration, contains('pg_catalog.isfinite(p_range_end)'));
    expect(migration, contains('p_range_end <= p_range_start'));
    expect(migration, contains('coalesce(p_view_timezone, v_group.timezone)'));
    expect(migration, contains('from pg_catalog.pg_timezone_names t'));
    expect(migration, contains('v_end_date - v_start_date > 366'));
    expect(
      migration,
      contains('v_query := pg_catalog.btrim(coalesce(p_query, \'\'))'),
    );
    expect(
      migration,
      contains('pg_catalog.char_length(v_query) not between 2 and 100'),
    );
    expect(migration, contains('pg_catalog.octet_length(v_query) > 400'));
    expect(
      migration,
      contains('p_limit is null or p_limit < 1 or p_limit > 100'),
    );
    expect(migration, contains('limit (v_limit + 1)'));
    expect(migration, isNot(contains('count(')));
    expect(migration, isNot(contains(' like ')));
  });

  test('리터럴 Unicode 검색과 유효 반복 텍스트가 명확하다', () {
    expect(migration, contains('v_query_lower := pg_catalog.lower(v_query)'));
    expect(
      migration,
      contains('position(v_query_lower in pg_catalog.lower(o.title)) > 0'),
    );
    expect(
      migration,
      contains(
        'position(v_query_lower in pg_catalog.lower(o.description)) > 0',
      ),
    );
    expect(
      migration,
      contains(
        'cross join lateral public._event_occurrences_for_range( e.id, p_range_start, p_range_end, v_view_timezone ) o',
      ),
    );
    expect(migration, contains('e.created_by = p_creator_id'));
    expect(migration, contains('from public.event_members em'));
    expect(migration, contains('m.is_active'));
    expect(migration, contains('m.removed_at is null'));
  });

  test('커서와 봉투가 v2 튜플 의미를 보존한다', () {
    expect(
      migration,
      contains(
        'v_cursor - \'v\' - \'starts_at\' - \'event_id\' - \'occurrence_key\'',
      ),
    );
    expect(migration, contains("(v_cursor->>'v') <> '2'"));
    expect(migration, contains("'^(single|o[0-9]{20})\$'"));
    expect(migration, contains("pg_catalog.translate(p_cursor, '-_', '+/')"));
    expect(migration, contains("pg_catalog.json_typeof(v_cursor_wire -> 'v')"));
    expect(migration, contains("pg_catalog.isfinite(v_cursor_start)"));
    expect(
      migration,
      contains('order by o.starts_at, o.event_id, o.occurrence_key'),
    );
    expect(
      migration,
      contains('o.starts_at = v_cursor_start and o.event_id = v_cursor_event'),
    );
    expect(migration, contains("'events', v_rows"));
    expect(migration, contains("'next_cursor', v_cursor_text"));
    expect(migration, contains("'has_more', v_has_more"));
  });

  test('픽스처가 개인정보 보호, Unicode, 필터, 반복, 키셋을 검사한다', () {
    for (final marker in <String>[
      '한국어 제목의 부분 문자열이 대소문자 구분 없이 일치한다',
      '이모지 및 대소문자를 정규화한 유니코드 설명 검색이 동작한다',
      '퍼센트 기호와 밑줄은 부분 문자열의 리터럴 문자로 처리된다',
      'sql 형태의 입력과 문장 부호는 sql로 해석되지 않는다',
      '따옴표는 검색용 리터럴 문자로 처리된다',
      'nfc 검색어는 nfc 형식의 제목과 일치한다',
      'nfd 검색어는 nfd 형식의 제목과 일치한다',
      '생성자 필터는 같은 그룹의 활성 생성자만 반환한다',
      '참여자 필터는 서버에서 event_members를 통해 평가된다',
      'dst가 적용되는 현지 자정 기간도 허용된다',
      '반복 발생 항목의 재정의 제목을 검색할 수 있다',
      '반복 일정의 한 행짜리 페이지는 서로 다른 occurrence_key로 같은 event_id를 이어 간다',
      '코드 포인트 하나인 검색어는 거부된다',
      '유니코드 문자 최대 길이를 넘는 검색어는 거부된다',
      '서버 최대값을 넘는 제한값은 거부된다',
      '비활성 생성자 대상은 거부된다',
      '외부 사용자 참여자 대상은 거부된다',
      '다른 그룹의 생성자 대상은 거부된다',
      '외부 사용자는 그룹을 검색할 수 없다',
      '비활성 구성원은 그룹을 검색할 수 없다',
      '보관된 그룹은 사용할 수 없는 그룹과 구분되지 않는다',
      '존재하지 않는 그룹은 사용할 수 없는 그룹과 구분되지 않는다',
      '익명 jwt는 거부된다',
      'jwt subject가 없으면 거부된다',
      '객체가 아닌 커서는 거부된다',
      '잘못된 문자 집합을 사용한 커서는 거부된다',
      'primary key (event_id, occurrence_key)',
      '대량 이벤트 1001개가 중복이나 누락 없이 페이지로 나뉜다',
    ]) {
      expect(
        fixture,
        contains(normalized(marker)),
        reason: '픽스처가 $marker 항목을 검증해야 한다',
      );
    }
  });

  test('업그레이드 실행기가 신규, 업그레이드, 재적용, 완전 대체 경로를 입증한다', () {
    for (final marker in <String>[
      '임시 로컬',
      '신규 스키마 경로',
      '업그레이드 경로',
      '재적용 중',
      '이전 일정 타임스탬프',
      'pgTAP을 사용할 수 없어',
      'event_search.sql에 엄격한 검증 스텁',
      'create function public.no_plan',
      'create function public.ok',
      'create function public.is',
      'create function public.throws_ok',
      'create function public.finish',
      'grant execute on function public.finish() to public',
      'sed',
      '| psql_test',
      'event_search.sql',
      'event_search 검증 스텁 픽스처를 통과',
      'event_search 신규 설치/업그레이드/재적용 검사를 통과',
    ]) {
      expect(
        upgrade,
        contains(normalized(marker)),
        reason: '실행기가 $marker 항목을 입증해야 한다',
      );
    }
  });
}
