import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 이 검사는 의도적으로 정적 검사로 작성했다. 로컬 Supabase/Docker 데몬을
/// 사용할 수 없어도 CI에서 실행된다. pgTAP 모음은 실제 JWT로 정책을
/// 계속 검사하고, 이 파일은 그 전에 보안 마이그레이션이 빠진 실수를 잡는다.
void main() {
  late String migrations;

  setUpAll(() {
    final directory = Directory('supabase/migrations');
    expect(
      directory.existsSync(),
      isTrue,
      reason: 'Supabase migrations are required',
    );
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.sql'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'At least one SQL migration is required');
    migrations = files
        .map((file) => file.readAsStringSync())
        .join('\n')
        .toLowerCase();
  });

  test('every client-visible table has RLS enabled', () {
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
        reason: 'RLS is missing for public.$table',
      );
    }
    expect(migrations, contains('create policy'));
    expect(migrations, contains('auth.uid()'));
    expect(migrations, isNot(contains('using (true)')));
    expect(migrations, isNot(contains('with check (true)')));
  });

  test('invite flow hashes bearer tokens and is implemented as RPCs', () {
    expect(migrations, contains('token_hash'));
    expect(
      migrations,
      matches(RegExp(r'(digest\s*\(|encode\s*\([^;]*digest)', dotAll: true)),
      reason:
          'Invite tokens must be hashed in the database, never persisted as plaintext',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'create\s+(or\s+replace\s+)?function[^;]+(join|accept)[^;]*invite',
          dotAll: true,
        ),
      ),
      reason: 'Invite acceptance must be a transactional server-side RPC',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'create\s+(or\s+replace\s+)?function[^;]+(create|issue)[^;]*invite',
          dotAll: true,
        ),
      ),
      reason: 'Invite creation must be a server-side RPC',
    );
    expect(migrations, contains('security definer'));
    expect(migrations, contains('set search_path'));
    expect(migrations, contains('expires_at'));
    expect(migrations, contains('uses_count'));
  });

  test('new invite codes use a twelve-character human-friendly alphabet', () {
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

  test('social profiles use provider names without changing authorization', () {
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

  test('event writes enforce optimistic locking in SQL', () {
    expect(migrations, contains('events'));
    expect(
      migrations,
      matches(RegExp(r'function[^;]+(update|edit)[^;]*event', dotAll: true)),
      reason: 'Event updates must go through a server-side versioned function',
    );
    expect(
      migrations,
      matches(
        RegExp(
          r'(update\s+public\.)?events[^;]+version\s*=\s*[^;]+\+\s*1',
          dotAll: true,
        ),
      ),
      reason: 'An accepted event write must increment version atomically',
    );
    expect(
      migrations,
      matches(RegExp(r'where[^;]+version\s*=', dotAll: true)),
      reason: 'The update predicate must include the caller expected version',
    );
    expect(migrations, contains('version > 0'));
    expect(migrations, contains('ends_at > starts_at'));
  });
}
