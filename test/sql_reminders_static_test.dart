import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static Feature 3 contract checks. The disposable PostgreSQL runner covers
/// execution semantics; these checks keep the migration/Edge boundary visible
/// even when Docker or a provider SDK is unavailable in CI.
void main() {
  late String migration;
  late String fixture;
  late String runner;
  late String edge;
  late String edgeTest;
  late String config;

  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  setUpAll(() {
    migration = normalized(
      File(
        'supabase/migrations/20260907130006_reminders.sql',
      ).readAsStringSync(),
    );
    fixture = normalized(
      File('supabase/tests/reminders.sql').readAsStringSync(),
    );
    runner = normalized(
      File('supabase/tests/run_reminders_upgrade.sh').readAsStringSync(),
    );
    edge = normalized(
      File('supabase/functions/send-reminders/index.ts').readAsStringSync(),
    );
    edgeTest = normalized(
      File(
        'supabase/functions/send-reminders/index.test.ts',
      ).readAsStringSync(),
    );
    config = normalized(File('supabase/config.toml').readAsStringSync());
  });

  test('migration is the CLI-created immediate successor and additive', () {
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
    expect(timestamps.toSet().length, names.length);
    expect(timestamps.last, '20260907171029');
    expect(
      migration,
      contains('create table if not exists public.notification_preferences'),
    );
    expect(
      migration,
      contains('create table if not exists public.event_reminder_settings'),
    );
    expect(migration, contains('unique (user_id, event_id, channel)'));
    expect(migration, contains('occurrence_key text not null'));
    expect(migration, contains('event_reminder_settings_event_member_fk'));
    expect(
      migration,
      contains(
        'foreign key (event_id, user_id) references public.event_members(event_id, user_id) on delete cascade',
      ),
    );
  });

  test('client settings and candidate RPC wire contract is explicit', () {
    for (final signature in <String>[
      'public.get_notification_preferences()',
      'public.set_notification_preferences( p_local_enabled boolean, p_push_enabled boolean, p_expected_version integer )',
      'public.get_event_reminder(p_event_id uuid)',
      'public.set_event_reminder( p_event_id uuid, p_channel text, p_enabled boolean, p_lead_seconds integer, p_all_day_days_before smallint, p_expected_event_version integer, p_expected_setting_version integer )',
      'public.reminder_candidates_for_user( p_fire_at_start timestamptz, p_fire_at_end timestamptz, p_limit integer default 100, p_cursor text default null )',
      'public.register_push_device( p_provider text, p_platform text, p_environment text, p_token text, p_installation_id text default null )',
      'public.revoke_push_device(p_device_id uuid)',
    ]) {
      expect(migration, contains('create or replace function $signature'));
    }
    expect(
      migration,
      contains('fire_at range must be finite and at most 60 days'),
    );
    expect(migration, contains('lead_seconds between 0 and 604800'));
    expect(migration, contains("interval '604800 seconds'"));
    expect(migration, contains('limit must be between 1 and 200'));
    expect(migration, contains("'all_day_local_time', '09:00:00'"));
    expect(migration, contains("'channel', 'local'"));
    expect(migration, contains("'capability', 'client_local_scheduler'"));
    expect(migration, contains("occurrence_key > p_after_occurrence_key"));
    expect(migration, contains('next_cursor'));
    expect(migration, contains('all_day_days_before'));
    expect(migration, contains("'single'"));
  });

  test('RLS, ACL, private bearer storage, and lifecycle hooks are present', () {
    for (final table in <String>[
      'notification_preferences',
      'event_reminder_settings',
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
    }
    for (final table in <String>[
      'push_device_tokens',
      'push_provider_capability',
      'event_reminder_jobs',
      'event_reminder_reconcile_queue',
    ]) {
      expect(
        migration,
        contains('alter table private.$table enable row level security'),
      );
      expect(
        migration,
        contains(
          'revoke all on table private.$table from public, anon, authenticated',
        ),
      );
    }
    expect(
      migration,
      contains("create index if not exists event_reminder_jobs_due_idx"),
    );
    expect(
      migration,
      contains("create index if not exists event_reminder_reconcile_due_idx"),
    );
    expect(migration, contains('references auth.users(id) on delete cascade'));
    expect(migration, contains('reminders_events_after_change'));
    expect(migration, contains('reminders_memberships_after_change'));
    expect(migration, contains('cancel_group_user_event_reminder_jobs'));
    expect(migration, contains('event_deleted'));
    expect(
      migration,
      contains(
        'delete from public.event_reminder_settings where event_id = new.id',
      ),
    );
    expect(migration, contains('membership_removed'));
    expect(migration, contains('setting_disabled'));
  });

  test('queue leases, idempotency, retry and worker boundary are explicit', () {
    expect(migration, contains('for update of j skip locked'));
    expect(migration, contains('for update skip locked'));
    expect(
      migration,
      contains(
        "status in ('pending', 'processing', 'retry', 'sent', 'cancelled', 'dead_letter')",
      ),
    );
    expect(migration, contains('event_reminder_jobs_active_revision_idx'));
    expect(migration, contains('retry_exhausted'));
    expect(migration, contains("q.status = 'processing'"));
    expect(migration, contains("j.status = 'processing'"));
    expect(migration, contains("'cancelled_jobs', v_cancelled"));
    expect(migration, contains("v_actor, 'device_revoked'"));
    expect(migration, contains('dirty boolean not null default false'));
    expect(migration, contains('if v_queue.dirty'));
    expect(migration, contains("set status = 'pending', attempts = 0"));
    expect(migration, contains('worker_claim_event_reminder_jobs'));
    expect(migration, contains('worker_load_event_reminder_payload'));
    expect(migration, contains('worker_complete_event_reminder_job'));
    expect(migration, contains('pg_roles where rolname = \'service_role\''));
    expect(migration, contains('never represented in sql'));
    expect(fixture, contains('dead_letter'));
    expect(fixture, contains('last active device'));
    expect(fixture, contains('eighth-attempt worker crash'));
    expect(fixture, contains('dirty bit'));
    expect(fixture, contains('reconcile race fixture'));
    expect(fixture, contains('timed lead beyond seven days'));
    expect(fixture, contains('participant lifecycle is terminal'));
    expect(fixture, contains('group leave follows the same path'));
    expect(fixture, contains('soft-deleting an event is terminal'));
    expect(runner, contains("printf 'reapplying %s\\n'"));
    expect(runner, contains('20260907130006_reminders.sql'));
  });

  test('Edge worker fails closed before claim and never logs payloads', () {
    expect(config, contains('[functions.send-reminders]'));
    expect(config, contains('verify_jwt = false'));
    expect(edge, contains('reminder_worker_secret'));
    expect(edge, contains('crypto.subtle.digest("sha-256"'));
    expect(edge, contains('if (!await internalsecret(request))'));
    expect(edge, contains('return json({ error: "unauthorized" }, 401)'));
    expect(edge, contains('providersecretconfigured'));
    expect(edge, contains('worker_push_capability'));
    expect(edge, contains('capability: "push_unconfigured"'));
    final capabilityIndex = edge.indexOf('worker_push_capability');
    final claimIndex = edge.indexOf('worker_claim_reconcile_requests');
    expect(capabilityIndex, greaterThanOrEqualTo(0));
    expect(claimIndex, greaterThan(capabilityIndex));
    expect(edge, isNot(contains('console.log')));
    expect(edge, isNot(contains('console.error')));
    expect(edge, isNot(contains('console.warn')));
    expect(edge, contains('provider_adapter_unavailable'));
    expect(edge, contains('export async function handlerequest'));
    expect(edgeTest, contains('missing and mismatched worker secrets'));
    expect(edgeTest, contains('leaves every lease untouched'));
    expect(edgeTest, contains('private-device-token'));
    expect(edgeTest, contains('assertfalse(serialized.includes(forbidden))'));
    expect(edgeTest, contains('params.p_limit, 100'));
  });
}
