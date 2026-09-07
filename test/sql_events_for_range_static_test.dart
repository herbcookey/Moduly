import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static contract checks for the bounded calendar range migration.  The
/// pgTAP fixture and local upgrade script execute the same contract against
/// PostgreSQL; these checks keep security and pagination invariants visible in
/// environments without a Supabase/Docker daemon.
void main() {
  late String migration;
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
      reason: 'the CLI-created calendar range migration must be present',
    );
    migration = normalized(migrationFile.readAsStringSync());

    final fixtureFile = File('supabase/tests/events_for_range.sql');
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'the bounded-range pgTAP fixture must be present',
    );
    fixture = normalized(fixtureFile.readAsStringSync());

    final upgradeFile = File('supabase/tests/run_events_for_range_upgrade.sh');
    expect(
      upgradeFile.existsSync(),
      isTrue,
      reason: 'the local range upgrade proof must be present',
    );
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('migration is additive, strictly ordered, and indexed for keysets', () {
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
      reason: 'every migration filename must carry a numeric timestamp prefix',
    );
    expect(timestamps.toSet().length, timestamps.length);
    expect(migrations, contains('20260907130003_calendar_range.sql'));
    expect(
      timestamps.last,
      '20260907130003',
      reason: 'the Feature 1 migration must be the current final migration',
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

  test('RPC signature and security boundary are explicit', () {
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

  test('range and overlap validation uses local calendar semantics', () {
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

  test('cursor contract is opaque, URL-safe, versioned, and fail-closed', () {
    expect(migration, contains('exactly {v, starts_at, event_id}'));
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
      reason:
          'all-day starts_at can be outside the viewer UTC range; tuple-only cursors remain valid',
    );
    expect(migration, contains('limit (v_limit + 1)'));
    expect(migration, contains('order by e.starts_at, e.id'));
    expect(
      migration,
      contains('e.starts_at = v_cursor_start and e.id > v_cursor_event_id'),
    );
  });

  test('event/member visibility and realtime privacy are preserved', () {
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

  test('fixture covers authorization, boundaries, cursors, and pagination', () {
    for (final marker in <String>[
      'owner sees the overlap and all-day rows',
      'active ordinary members can read',
      'outsider cannot read group event ranges',
      'inactive member cannot read group event ranges',
      'archived groups fail closed',
      'missing groups fail closed',
      'range is half-open at both timed boundaries',
      'all-day event ending at range_start is excluded',
      'participant filter returns only rows assigned',
      'inactive participant targets are rejected',
      'cross-group participant targets are rejected',
      'DST local-midnight validation accepts',
      'ranges over 366 local calendar days are rejected',
      'zero limit is rejected',
      'limit above the bounded maximum is rejected',
      'malformed cursors are rejected',
      'non-object cursor payload is rejected',
      'cursor version is unsupported',
      'string cursor version is rejected',
      'floating-point cursor version is rejected',
      'timezone-less cursor timestamp is rejected',
      'unknown cursor keys are rejected',
      'cursor timestamps require seconds',
      'cursor fractions longer than six digits are rejected',
      'impossible cursor calendar dates are rejected',
      'invalid cursor clock components are rejected',
      'invalid cursor offsets are rejected',
      'valid cursor fractions from one through six digits are accepted',
      'valid six-digit cursor fractions with an explicit offset are accepted',
      'non-finite cursor tuples are rejected',
      'finite tuple after range_end is accepted',
      '1001 events paginate without duplicate rows or omissions',
      'every bulk event appears in exactly one keyset page',
      'final one-row page is preserved',
      'complete event shape and member_ids',
      'when realtime is configured, the parent events table remains the invalidation signal',
    ]) {
      expect(
        fixture,
        contains(normalized(marker)),
        reason: 'fixture should assert $marker',
      );
    }
  });

  test(
    'upgrade script proves historical backfill and reapply preservation',
    () {
      for (final marker in <String>[
        'temporary local PostgreSQL cluster',
        r'rm -rf -- "$work_dir"',
        'before event_members',
        'historical creator backfill',
        'inactive/deleted creator backfill timestamp',
        'applying %s',
        'reapplying %s',
        'range RPC returned deleted or missing rows',
        'range migration reapply changed backfilled row count',
        'event_members must not be added to supabase_realtime',
        'events_for_range upgrade/reapply/backfill checks passed',
      ]) {
        expect(
          upgrade,
          contains(normalized(marker)),
          reason: 'upgrade should prove $marker',
        );
      }
    },
  );
}
