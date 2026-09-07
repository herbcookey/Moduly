import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static Feature G contract checks.  The pgTAP fixture and local upgrade
/// runner execute the same invariants against PostgreSQL when a disposable
/// database/pgTAP extension is available.
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

  test('migration is additive, ordered, and creator-filter indexed', () {
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
    expect(names.length, 16);
    expect(timestamps.length, names.length);
    expect(timestamps.toSet().length, names.length);
    expect(names, contains('20260907171029_event_search.sql'));
    expect(timestamps.last, '20260907171029');
    expect(
      migration,
      contains(
        'create index if not exists events_group_creator_start_id_live_idx on public.events (group_id, created_by, starts_at, id) where deleted_at is null',
      ),
    );
    expect(migration, isNot(contains('drop table public.events')));
    expect(migration, isNot(contains('truncate public.events')));
  });

  test('RPC signature and security boundary are explicit', () {
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

  test('period, query, and server-limit validation is bounded', () {
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

  test('literal Unicode search and effective recurrence text are explicit', () {
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

  test('cursor and envelope preserve v2 tuple semantics', () {
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

  test('fixture covers privacy, Unicode, filters, recurrence, and keysets', () {
    for (final marker in <String>[
      'Korean title substring is matched case-insensitively',
      'emoji and case-folded Unicode description search works',
      'percent and underscore are literal substring characters',
      'SQL-like input and punctuation are not interpreted as SQL',
      'quotes are literal search characters',
      'NFC query matches the NFC title form',
      'NFD query matches the NFD title form',
      'creator filter returns only an active same-group creator',
      'participant filter is evaluated server-side through event_members',
      'DST local-midnight period is accepted',
      'recurring occurrence override title is searchable',
      'recurring limit-one pages resume same event_id by distinct occurrence_key',
      'one-codepoint query is rejected',
      'query above the Unicode character maximum is rejected',
      'limit above the server maximum is rejected',
      'inactive creator target is rejected',
      'outsider participant target is rejected',
      'cross-group creator target is rejected',
      'outsider cannot search the group',
      'inactive member cannot search the group',
      'archived group is indistinguishable from an unavailable group',
      'missing group is indistinguishable from an unavailable group',
      'anonymous JWT is rejected',
      'missing JWT subject is rejected',
      'non-object cursor is rejected',
      'malformed cursor alphabet is rejected',
      'primary key (event_id, occurrence_key)',
      '1001 bulk events paginate without duplicate rows or omissions',
    ]) {
      expect(
        fixture,
        contains(normalized(marker)),
        reason: 'fixture should assert $marker',
      );
    }
  });

  test(
    'upgrade runner proves fresh, upgrade, reapply, and complete fallback paths',
    () {
      for (final marker in <String>[
        'temporary local PostgreSQL cluster',
        'fresh-schema path',
        'upgrade path',
        'reapplying',
        'legacy event timestamp',
        'pgTAP unavailable',
        'strict assertion stubs for event_search.sql',
        'create function public.no_plan',
        'create function public.ok',
        'create function public.is',
        'create function public.throws_ok',
        'create function public.finish',
        'grant execute on function public.finish() to public',
        'sed',
        '| psql_test',
        'event_search.sql',
        'event_search assertion-stub fixture passed',
        'event_search fresh/upgrade/reapply checks passed',
      ]) {
        expect(
          upgrade,
          contains(normalized(marker)),
          reason: 'runner should prove $marker',
        );
      }
    },
  );
}
