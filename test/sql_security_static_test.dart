import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 이 검사는 의도적으로 정적 검사로 작성했다. 로컬 Supabase/Docker 데몬을
/// 사용할 수 없어도 CI에서 실행된다. pgTAP 모음은 실제 JWT로 정책을
/// 계속 검사하고, 이 파일은 그 전에 보안 마이그레이션이 빠진 실수를 잡는다.
void main() {
  late String migrations;

  setUpAll(() {
    final directory = Directory('supabase/migrations');
    expect(directory.existsSync(), isTrue, reason: 'Supabase 마이그레이션이 필요하다');
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.sql'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'SQL 마이그레이션이 하나 이상 필요하다');
    migrations = files
        .map((file) => file.readAsStringSync())
        .join('\n')
        .toLowerCase();
  });

  test('클라이언트에 보이는 모든 테이블에 RLS가 활성화된다', () {
    for (final table in <String>[
      'profiles',
      'groups',
      'memberships',
      'invite_codes',
      'events',
      'audit_logs',
      'invite_join_attempts',
      'event_members',
      'event_recurrence_rules',
      'event_occurrence_overrides',
      'notification_preferences',
      'event_reminder_settings',
    ]) {
      expect(
        migrations,
        contains('alter table public.$table enable row level security'),
        reason: 'public.$table에 RLS가 없다',
      );
    }
    expect(migrations, contains('create policy'));
    expect(migrations, contains('auth.uid()'));
    expect(migrations, isNot(contains('using (true)')));
    expect(migrations, isNot(contains('with check (true)')));
  });

  test('초대 흐름이 전달자 토큰을 해시하고 RPC로 구현된다', () {
    expect(migrations, contains('token_hash'));
    expect(
      migrations,
      matches(RegExp(r'(digest\s*\(|encode\s*\([^;]*digest)', dotAll: true)),
      reason: '초대 토큰은 데이터베이스에서 해시해야 하며 평문으로 저장하면 안 된다',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'create\s+(or\s+replace\s+)?function[^;]+(join|accept)[^;]*invite',
          dotAll: true,
        ),
      ),
      reason: '초대 수락은 트랜잭션 서버 측 RPC여야 한다',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'create\s+(or\s+replace\s+)?function[^;]+(create|issue)[^;]*invite',
          dotAll: true,
        ),
      ),
      reason: '초대 생성은 서버 측 RPC여야 한다',
    );
    expect(migrations, contains('security definer'));
    expect(migrations, contains('set search_path'));
    expect(migrations, contains('expires_at'));
    expect(migrations, contains('uses_count'));
  });

  test('새 초대 코드가 읽기 쉬운 12자 문자 집합을 사용한다', () {
    expect(
      migrations,
      contains(
        "v_alphabet constant text := '23456789abcdefghjklmnpqrstuvwxyz'",
      ),
    );
    expect(migrations, contains('for v_index in 0..11 loop'));
    expect(
      migrations,
      contains("digest(pg_catalog.convert_to(v_token, 'utf8'), 'sha256')"),
    );
  });

  test('소셜 프로필이 권한을 바꾸지 않고 공급자 이름을 사용한다', () {
    expect(migrations, contains("raw_user_meta_data ->> 'full_name'"));
    expect(migrations, contains("raw_user_meta_data ->> 'name'"));
    expect(migrations, contains('from auth.users as auth_user'));
    expect(
      migrations,
      contains(
        'revoke execute on function public.handle_new_user()\n  from public, anon, authenticated',
      ),
    );
  });

  test('일정 쓰기가 SQL에서 낙관적 잠금을 적용한다', () {
    expect(migrations, contains('events'));
    expect(
      migrations,
      matches(RegExp(r'function[^;]+(update|edit)[^;]*event', dotAll: true)),
      reason: '일정 갱신은 서버 측 버전 함수로 처리해야 한다',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'(update\s+public\.)?events[^;]+version\s*=\s*[^;]+\+\s*1',
          dotAll: true,
        ),
      ),
      reason: '허용된 일정 쓰기는 버전을 원자적으로 증가시켜야 한다',
    );
    expect(
      migrations,
      matches(RegExp(r'where[^;]+version\s*=', dotAll: true)),
      reason: '갱신 조건에 호출자가 예상한 버전이 포함되어야 한다',
    );
    expect(migrations, contains('version > 0'));
    expect(migrations, contains('ends_at > starts_at'));
  });
}
