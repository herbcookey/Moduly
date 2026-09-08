import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 인증된 초대 링크 마이그레이션의 정적 계약 검사다. Supabase 스택을 사용할 수
/// 있으면 함께 제공되는 pgTAP 픽스처와 로컬 실행기가 PostgreSQL을 대상으로
/// 같은 검증을 수행한다.
void main() {
  late String migration;
  late String fixture;
  late String upgrade;

  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907130004_invite_links.sql',
    );
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: '추가형 초대 링크 마이그레이션이 있어야 한다',
    );
    migration = normalized(migrationFile.readAsStringSync());

    final fixtureFile = File('supabase/tests/invite_links.sql');
    expect(fixtureFile.existsSync(), isTrue, reason: '초대 링크 pgTAP 픽스처가 있어야 한다');
    fixture = normalized(fixtureFile.readAsStringSync());

    final upgradeFile = File('supabase/tests/run_invite_links_upgrade.sh');
    expect(
      upgradeFile.existsSync(),
      isTrue,
      reason: '로컬 초대 링크 업그레이드 증거가 있어야 한다',
    );
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('마이그레이션이 추가형이며 기존 기록 바로 뒤에 온다', () {
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
    expect(timestamps.length, migrations.length);
    expect(timestamps.toSet().length, timestamps.length);
    expect(migrations, contains('20260907130004_invite_links.sql'));
    expect(
      BigInt.parse(timestamps.last),
      greaterThanOrEqualTo(BigInt.parse('20260907171029')),
      reason: '초대 링크 이후의 forward-only 수정 마이그레이션을 허용해야 한다',
    );
    expect(migration, isNot(contains('drop table public.')));
    expect(migration, isNot(contains('truncate public.')));
    expect(upgrade, contains('재적용 중'));
    expect(upgrade, contains('20260907130004_invite_links.sql'));
  });

  test('미리보기 원장이 사용자/시간만 담고 비공개이며 속도가 제한된다', () {
    expect(
      migration,
      contains(
        'create table if not exists public.invite_preview_attempts ( actor_id uuid not null references auth.users(id) on delete cascade, attempted_at timestamptz not null default pg_catalog.clock_timestamp(), primary key (actor_id, attempted_at) )',
      ),
    );
    expect(migration, contains('invite_preview_attempts_actor_time_idx'));
    expect(migration, contains('invite_preview_attempts_time_idx'));
    expect(migration, contains('invite_join_attempts_time_idx'));
    expect(
      migration,
      contains(
        'alter table public.invite_preview_attempts enable row level security',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on table public.invite_preview_attempts from public, anon, authenticated',
      ),
    );
    expect(migration, contains('invite_preview_attempts_deny'));
    expect(
      migration,
      isNot(contains('invite_preview_attempts ( actor_id, token')),
    );
    expect(migration, contains("v_attempt_count >= 60"));
    expect(migration, contains('delete from public.invite_preview_attempts'));
    expect(
      migration,
      contains(
        "return pg_catalog.jsonb_build_object( 'valid', false, 'reason', 'rate_limited' )",
      ),
    );
  });

  test('서버 정규화와 다이제스트 전용 저장이 명확하다', () {
    expect(
      migration,
      contains(
        'create or replace function public._canonicalize_invite_token(p_token text)',
      ),
    );
    expect(
      migration,
      contains("regexp_replace(v_raw, '[[:space:]-]+', '', 'g')"),
    );
    expect(migration, contains('octet_length(p_token) > 256'));
    expect(migration, contains('octet_length(v_raw) > 256'));
    expect(migration, contains('invalid-invite-token-sentinel'));
    expect(migration, contains(r"v_compact ~ '^[0-9a-fa-f]{48}$'"));
    expect(migration, contains('v_short_alphabet constant text'));
    expect(migration, contains('char_length(v_raw) > 256'));
    expect(migration, contains('return null'));
    expect(migration, contains('extensions.digest('));
    expect(
      migration,
      contains(
        "pg_catalog.convert_to(coalesce(v_token, v_invalid_token_sentinel), 'utf8')",
      ),
    );
    expect(migration, isNot(contains('plaintext_token')));
    expect(migration, contains('토큰이나 다이제스트는 보존하지 않는다'));
  });

  test('미리보기 JSON, 인증 경계, 비소모 의미가 명확하다', () {
    expect(
      migration,
      contains(
        'create or replace function public.preview_invite(p_token text)',
      ),
    );
    expect(migration, contains('returns jsonb'));
    expect(migration, contains('security definer'));
    expect(migration, contains("set search_path = ''"));
    expect(migration, contains("errcode = '28000'"));
    for (final key in <String>[
      "'valid', true",
      "'group_id', v_invite_group_id",
      "'group_name', v_group_name",
      "'group_description', v_group_description",
      "'group_timezone', v_group_timezone",
      "'expires_at', v_expires_at",
      "'already_member'",
      "'invalid_or_expired'",
    ]) {
      expect(migration, contains(key), reason: '미리보기 필드/사유: $key');
    }
    expect(migration, contains('v_revoked_at is not null'));
    expect(migration, contains('v_expires_at <= pg_catalog.now()'));
    expect(migration, contains('v_uses_count >= v_max_uses'));
    expect(migration, contains('g.deleted_at is null'));
    expect(migration, contains("auth.jwt() ->> 'is_anonymous'"));
    expect(migration, contains('for update skip locked'));
    expect(
      migration,
      contains(
        'revoke execute on function public.preview_invite(text) from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.preview_invite(text) to authenticated',
      ),
    );
    expect(
      migration,
      isNot(
        contains(
          'grant execute on function public.preview_invite(text) to anon',
        ),
      ),
    );
  });

  test('참여가 트랜잭션 잠금, 멱등성, 안전한 오류를 보존한다', () {
    expect(
      migration,
      contains(
        'create or replace function public.join_group_with_invite(p_token text)',
      ),
    );
    expect(migration, contains('pg_catalog.pg_advisory_xact_lock'));
    expect(migration, contains("v_attempt_count >= 20"));
    expect(migration, contains('delete from public.invite_join_attempts'));
    expect(
      migration,
      contains(
        'return query select null::uuid, null::uuid, false, \'rate_limited\'::text',
      ),
    );
    expect(
      migration,
      contains('v_token := public._canonicalize_invite_token(p_token)'),
    );
    expect(migration, contains('v_invalid_token_sentinel constant text'));
    expect(migration, contains('coalesce(v_token, v_invalid_token_sentinel)'));
    expect(migration, contains('where g.id = v_invite_group_id for update'));
    expect(migration, contains('where i.token_hash = v_token_hash for update'));
    expect(migration, contains('where m.group_id = v_invite_group_id'));
    expect(migration, contains("reason = 'already_member'"));
    expect(migration, contains("reason = 'joined'"));
    expect(migration, contains('uses_count = uses_count + 1'));
    expect(migration, contains("'invalid_or_expired'::text"));
    expect(migration, isNot(contains('v_token := pg_catalog.left(v_token')));
    expect(migration, contains("auth.jwt() ->> 'is_anonymous'"));
    expect(migration, contains('for update skip locked'));
  });

  test('취소는 현재 소유자 전용이며 초대 테이블 쓰기는 RPC 전용이다', () {
    final revokeStart = migration.indexOf(
      'create or replace function public.revoke_invite_code',
    );
    expect(revokeStart, greaterThanOrEqualTo(0));
    final revokeEnd = migration.indexOf(r'$$;', revokeStart);
    expect(revokeEnd, greaterThan(revokeStart));
    final revokeBody = migration.substring(revokeStart, revokeEnd);
    expect(revokeBody, contains('v_group.owner_id <> v_user_id'));
    expect(
      revokeBody,
      contains('from auth.users u where u.id = v_user_id for key share'),
    );
    expect(revokeBody, isNot(contains('v_invite.created_by <> v_user_id')));
    expect(revokeBody, isNot(contains('i.created_by = v_user_id')));
    expect(revokeBody, contains('where i.id = p_invite_id for update'));
    expect(revokeBody, contains("errcode = '40001'"));
    expect(revokeBody, contains('v_invite.revoked_at is not null'));
    expect(
      migration,
      contains(
        'revoke update on table public.invite_codes from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains('revoke update (expires_at, max_uses, revoked_at, version)'),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.revoke_invite_code(uuid, integer) to authenticated',
      ),
    );
  });

  test('pgTAP 픽스처가 주체, 수명 주기, 개인정보 보호 사례를 검사한다', () {
    for (final marker in <String>[
      'create extension if not exists pgtap',
      "set local role authenticated",
      '유효한 미리보기 객체에는 정제된 필드만 정확히 포함된다',
      '미리보기 요청 제한 응답에는 그룹 데이터가 없다',
      '활성 구성원의 만료 토큰 미리보기는 멱등성을 유지한다',
      '활성 구성원의 수락은 취소 후에도 멱등성을 유지한다',
      '미리보기 정리 작업은 비활성 행위자의 오래된 행을 제거한다',
      '외부 사용자는 유효한 형식의 짧은 코드를 수락할 수 있다',
      '레거시 48자리 16진수 초대는 정규 소문자 형식을 허용한다',
      '중복 수락은 멱등성을 유지한다',
      '너무 긴 수락 토큰은 절삭 없이 거부된다',
      '잘못된 수락 토큰은 고정 센티널 다이제스트만 저장한다',
      '차단된 가입은 rate_limited 원장 행을 추가하지 않는다',
      '현재 소유자는 소유권 이전 전에 생성된 초대를 취소할 수 있다',
      '최종 상태의 초대를 다시 취소하면 일반 충돌이 발생한다',
      'acl은 초대 직접 update를 거부한다',
      '초대 감사 메타데이터에는 평문 토큰이나 토큰 해시가 포함되지 않는다',
    ]) {
      expect(fixture, contains(marker), reason: marker);
    }
    expect(upgrade, contains('재적용 시 이전 초대 필드를 보존하지 않았습니다'));
    expect(upgrade, contains('invite-links 업그레이드/재적용 검사를 통과'));
    expect(upgrade, contains('pgtap 확장을 사용할 수 없어'));
  });
}
