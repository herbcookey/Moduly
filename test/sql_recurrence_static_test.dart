import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static Feature 2 contract checks.  `supabase/tests/recurrence.sql` and the
/// local upgrade runner execute the same invariants against PostgreSQL when a
/// disposable database/pgTAP is available.
void main() {
  late String migration;
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
    final fixtureFile = File('supabase/tests/recurrence.sql');
    expect(fixtureFile.existsSync(), isTrue);
    fixture = normalized(fixtureFile.readAsStringSync());
    final upgradeFile = File('supabase/tests/run_recurrence_upgrade.sh');
    expect(upgradeFile.existsSync(), isTrue);
    upgrade = normalized(upgradeFile.readAsStringSync());
  });

  test('migration ordering and additive child schema are explicit', () {
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
    expect(names.length, 14);
    expect(timestamps.length, names.length);
    expect(timestamps.toSet().length, names.length);
    expect(names, contains('20260907130005_recurrence.sql'));
    expect(timestamps.last, '20260907130005');
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

  test('rule semantics and stable ordinal keys are constrained', () {
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
    expect(
      migration,
      contains('date, month, timestamp, and timezone arithmetic'),
    );
    expect(migration, contains('weekdays cannot contain null'));
    expect(migration, contains('weekdays must be sorted and distinct'));
    expect(migration, contains('at time zone v_effective_timezone'));
    expect(
      migration,
      contains(
        "v_effective_frequency <> 'monthly' and p_monthly_day is not null",
      ),
    );
    expect(migration, contains('range read into an open loop'));
  });

  test('RLS, ACL, definer search path, and author/version locks are visible', () {
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

  test('v2 read envelope/cursor and scope receipt contracts are explicit', () {
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
    expect(migration, contains('neither child is added to supabase_realtime'));
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
    expect(fixture, contains('monthly day 31 clamps'));
    expect(fixture, contains('interval zero is rejected'));
    expect(fixture, contains('interval 1000 is rejected'));
    expect(fixture, contains('future-scope update splits'));
    expect(
      fixture,
      contains('all-scope replacement atomically resets sparse exceptions'),
    );
    expect(fixture, contains('identical this-scope replay is a no-op'));
    expect(
      fixture,
      contains('replaying a cancellation is an idempotent no-op'),
    );
    expect(fixture, contains('dedicated receipt rpc'));
    expect(
      fixture,
      contains('recurring member replacement rejects creator omission'),
    );
    expect(fixture, contains('dedicated recurring member rpc is executable'));
    expect(fixture, contains('compatibility wrapper public acl is revoked'));
    expect(upgrade, contains('expected 1097 bounded occurrences'));
    expect(upgrade, contains('dst gap was not resolved forward'));
    expect(upgrade, contains('23-hour utc elapsed projection'));
    expect(upgrade, contains('25-hour utc elapsed projection'));
    expect(upgrade, contains('inherited future count'));
    expect(upgrade, contains('moved-in override'));
    expect(upgrade, contains('anonymous create call unexpectedly succeeded'));
    expect(upgrade, contains('null update scope unexpectedly succeeded'));
    expect(upgrade, contains('singleton-to-recurrence conversion'));
    expect(upgrade, contains('recurrence-to-singleton conversion'));
    expect(upgrade, contains('replace_recurring_event_members_if_version'));
    expect(upgrade, contains('creator-excluded recurring member replacement'));
    expect(upgrade, contains('legacy recurring replacement removed creator'));
    expect(upgrade, contains('singleton compatibility empty replacement'));
    expect(upgrade, contains('lock dedicated members'));
    expect(
      upgrade,
      contains('compatibility wrapper is executable by service_role'),
    );
    expect(fixture, contains('stale parent version is rejected'));
    expect(upgrade, contains('reapplying'));
    expect(upgrade, contains('pgtap is unavailable'));
    expect(upgrade, contains('explain (costs off)'));
    expect(
      migration,
      contains('normalize that sentinel to the stable ordinal-zero'),
    );
    expect(migration, contains('consumed before v_index'));
  });
}
