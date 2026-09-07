import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static contract checks for the authenticated invite-link migration.  The
/// companion pgTAP fixture and local runner execute the same assertions against
/// PostgreSQL when a Supabase stack is available.
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
      reason: 'the additive invite-links migration must be present',
    );
    migration = normalized(migrationFile.readAsStringSync());

    final fixtureFile = File('supabase/tests/invite_links.sql');
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'the invite-links pgTAP fixture must be present',
    );
    fixture = normalized(fixtureFile.readAsStringSync());

    final upgradeFile = File('supabase/tests/run_invite_links_upgrade.sh');
    expect(
      upgradeFile.existsSync(),
      isTrue,
      reason: 'the local invite-links upgrade proof must be present',
    );
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('migration is additive and strictly after the existing history', () {
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
    expect(timestamps.last, '20260907130005');
    expect(migration, isNot(contains('drop table public.')));
    expect(migration, isNot(contains('truncate public.')));
    expect(upgrade, contains('reapplying'));
    expect(upgrade, contains('20260907130004_invite_links.sql'));
  });

  test('preview ledger is actor/time-only, private, and rate limited', () {
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

  test('server canonicalization and digest-only storage are explicit', () {
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
    expect(migration, contains('no token or digest is retained'));
  });

  test('preview JSON, auth boundary, and no-consume semantics are explicit', () {
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
      expect(migration, contains(key), reason: 'preview field/reason: $key');
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

  test('join preserves transactional locks, idempotency, and safe errors', () {
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

  test('revoke is current-owner-only and invite table writes are RPC-only', () {
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

  test('pgTAP fixture covers principal, lifecycle, and privacy cases', () {
    for (final marker in <String>[
      'create extension if not exists pgtap',
      "set local role authenticated",
      'preview valid object contains exactly the sanitized fields',
      'preview rate-limit response has no group data',
      'active member preview remains idempotent for an expired token',
      'active member acceptance remains idempotent after revocation',
      'preview sweep removes stale rows from inactive actors',
      'outsider accepts a valid formatted short code',
      'legacy 48-hex invite accepts canonical lowercase form',
      'duplicate acceptance is idempotent',
      'overlong acceptance is rejected without truncation',
      'malformed acceptance stores only the fixed sentinel digest',
      'blocked join does not append a rate_limited ledger row',
      'current owner can revoke an invite created before ownership transfer',
      're-revoking a terminal invite is a generic conflict',
      'direct invite update is denied by acl',
      'invite audit metadata does not contain plaintext tokens or token hashes',
    ]) {
      expect(fixture, contains(marker), reason: marker);
    }
    expect(
      upgrade,
      contains('legacy invite fields were not preserved on reapply'),
    );
    expect(upgrade, contains('invite-links upgrade/reapply checks passed'));
    expect(upgrade, contains('pgtap extension unavailable'));
  });
}
