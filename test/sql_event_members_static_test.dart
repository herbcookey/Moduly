import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Contract-level checks for the event participant migration.  The companion
/// pgTAP fixture and local upgrade script exercise the database; these checks
/// keep the migration reviewable when CI does not have a Supabase instance.
void main() {
  late String migration;
  late String upgrade;
  late String fixture;

  setUpAll(() {
    final migrationFile = File(
      'supabase/migrations/20260907130002_event_members.sql',
    );
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: 'The event_members migration must be present',
    );
    migration = migrationFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    final upgradeFile = File('supabase/tests/run_group_management_upgrade.sh');
    expect(
      upgradeFile.existsSync(),
      isTrue,
      reason: 'The local upgrade proof must be present',
    );
    upgrade = upgradeFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    final fixtureFile = File('supabase/tests/event_members.sql');
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'The event_members pgTAP fixture must be present',
    );
    fixture = fixtureFile.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
  });

  test('table, keys, timestamps, and migration backfill are additive', () {
    expect(
      migration,
      contains('create table if not exists public.event_members'),
    );
    expect(
      migration,
      contains(
        'event_id uuid not null references public.events(id) on delete cascade',
      ),
    );
    expect(
      migration,
      contains(
        'user_id uuid not null references auth.users(id) on delete cascade',
      ),
    );
    expect(
      migration,
      contains('created_at timestamptz not null default pg_catalog.now()'),
    );
    expect(migration, contains('primary key (event_id, user_id)'));
    expect(
      migration,
      contains(
        'create index if not exists event_members_user_event_idx on public.event_members (user_id, event_id)',
      ),
    );
    expect(
      migration,
      contains(
        'insert into public.event_members (event_id, user_id, created_at) select e.id, e.created_by, e.created_at from public.events e where not exists ( select 1 from public.event_members existing where existing.event_id = e.id and existing.user_id = e.created_by )',
      ),
    );
    expect(
      migration,
      contains('backfill before adding integrity/transition triggers'),
    );
    expect(migration, contains('installation-complete sentinel'));
    expect(migration, contains('pg_catalog.pg_trigger'));
    expect(migration, contains('v_feature_installed'));
    expect(migration, contains('if not v_feature_installed then'));
    expect(
      migration,
      contains('pg_catalog.pg_get_triggerdef(trigger_row.oid)'),
    );
    expect(upgrade, contains('20260907130002_event_members.sql'));
    expect(upgrade, contains('reapplying'));
    expect(upgrade, contains('after creator deactivation'));
    expect(
      upgrade,
      contains('creator prune/reapply sentinel regression passed'),
    );
  });

  test('RLS and ACLs expose only safe reads and deny child writes', () {
    expect(
      migration,
      contains('alter table public.event_members enable row level security'),
    );
    expect(
      migration,
      contains(
        'create policy event_members_select on public.event_members for select to authenticated using',
      ),
    );
    expect(
      migration,
      contains(
        'create policy event_members_write_deny on public.event_members for all to authenticated using (false) with check (false)',
      ),
    );
    expect(
      migration,
      contains(
        'revoke all on table public.event_members from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains('grant select on table public.event_members to authenticated'),
    );
    expect(migration, contains('e.deleted_at is null'));
    expect(migration, contains('g.deleted_at is null'));
    expect(migration, contains('public.is_active_member(e.group_id)'));
    expect(migration, contains('target.is_active'));
    expect(migration, contains('target.removed_at is null'));
    expect(migration, isNot(contains('event_members for select to public')));
    expect(
      migration,
      isNot(contains('grant insert on table public.event_members')),
    );
    expect(
      migration,
      isNot(contains('grant update on table public.event_members')),
    );
    expect(
      migration,
      isNot(contains('grant delete on table public.event_members')),
    );
  });

  test('the child is not published; parent events are the realtime signal', () {
    expect(
      migration,
      contains(
        'the child table is deliberately not added to supabase_realtime',
      ),
    );
    expect(
      migration,
      isNot(
        contains(
          'alter publication supabase_realtime add table public.event_members',
        ),
      ),
    );
    expect(upgrade, contains('pg_catalog.pg_publication_tables'));
    expect(upgrade, contains('event_members'));
  });

  test('trigger-only functions are hardened and transition bumps are privacy-safe', () {
    for (final functionName in <String>[
      'bump_events_from_event_members_insert()',
      'bump_events_from_event_members_delete()',
      'enforce_event_member_integrity()',
      'seed_event_creator_member()',
    ]) {
      expect(
        migration,
        contains(
          'create or replace function public.$functionName returns trigger language plpgsql security definer set search_path = \'\'',
        ),
      );
      expect(
        migration,
        contains(
          'revoke execute on function public.$functionName from public, anon, authenticated',
        ),
      );
    }
    expect(migration, contains('referencing new table as new_rows'));
    expect(migration, contains('referencing old table as old_rows'));
    expect(migration, contains('order by g.id, e.id'));
    expect(migration, contains('for update of g'));
    expect(migration, contains('version = e.version + 1'));
    expect(migration, contains('updated_at'));
    expect(migration, contains('moduly.event_members_mutation_context'));
    expect(
      migration,
      contains(
        "pg_catalog.current_setting('moduly.event_members_mutation_context', true)",
      ),
    );
    expect(
      migration,
      contains(
        "pg_catalog.set_config('moduly.event_members_mutation_context', 'internal', true)",
      ),
    );
    expect(
      migration,
      contains(
        'create trigger events_seed_creator_member after insert on public.events',
      ),
    );
    expect(
      migration,
      contains(
        'insert into public.event_members (event_id, user_id, created_at)',
      ),
    );
    expect(migration, contains('if p_member_ids is null then'));
    final triggerText = migration.substring(
      0,
      migration.indexOf(
        'create or replace function public.create_event_with_members',
      ),
    );
    expect(triggerText, isNot(contains('member_ids')));
    expect(triggerText, isNot(contains('user_id::text')));
  });

  test(
    'fixture proves legacy trigger, explicit empty/custom lists, and failures',
    () {
      for (final marker in <String>[
        'legacy direct insert keeps the initial event version at one',
        'legacy direct insert seeds one creator assignment without duplicates',
        'create with an explicit empty array leaves no participants',
        'create custom list excludes the creator when requested',
        'rls rejects an outsider direct event insert',
        'existing event checks reject malformed direct insert',
        'unauthorized direct insert leaves no participant row',
        'malformed direct insert leaves no participant row',
        'authenticated cannot call the legacy event seed trigger function directly',
        'deactivation retains the soft-deleted assignment row',
        'deactivation leaves the soft-deleted event version unchanged',
        'leave_group retains soft-deleted assignment history',
        'leave_group leaves archived-group assignment history intact',
      ]) {
        expect(
          fixture,
          contains(marker),
          reason: 'fixture should assert $marker',
        );
      }
    },
  );

  test('RPC signatures and canonical return shape are stable', () {
    expect(
      migration,
      contains(
        'create or replace function public.create_event_with_members( p_group_id uuid, p_title text, p_description text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text, p_is_all_day boolean, p_all_day_start date, p_all_day_end date, p_color_value bigint, p_member_ids uuid[] )',
      ),
    );
    expect(
      migration,
      contains(
        'create or replace function public.update_event_with_members_if_version( p_event_id uuid, p_expected_version integer, p_title text, p_description text, p_starts_at timestamptz, p_ends_at timestamptz, p_timezone text, p_is_all_day boolean, p_all_day_start date, p_all_day_end date, p_color_value bigint, p_member_ids uuid[] )',
      ),
    );
    expect(
      migration,
      contains(
        'create or replace function public.replace_event_members_if_version( p_event_id uuid, p_expected_version integer, p_member_ids uuid[] )',
      ),
    );
    for (final functionName in <String>[
      'create_event_with_members',
      'update_event_with_members_if_version',
      'replace_event_members_if_version',
    ]) {
      final start = migration.indexOf(
        'create or replace function public.$functionName',
      );
      expect(start, greaterThanOrEqualTo(0), reason: functionName);
      final end = migration.indexOf(r'$$;', start);
      expect(end, greaterThan(start), reason: functionName);
      final body = migration.substring(start, end);
      expect(body, contains('returns table'));
      expect(body, contains('member_ids uuid[]'));
      expect(body, contains('security definer'));
      expect(body, contains('set search_path = \'\''));
      expect(body, contains('select auth.uid()'));
      expect(body, contains("coalesce(p_member_ids, '{}'::uuid[])"));
      expect(body, contains('select distinct supplied.user_id'));
      expect(
        body,
        contains('array_agg(supplied.user_id order by supplied.user_id)'),
      );
      expect(body, contains('for update'));
      expect(body, contains('active members'));
    }
    expect(
      migration,
      contains(
        'v_event.created_by <> v_actor_id and v_group.owner_id <> v_actor_id',
      ),
    );
    expect(migration, contains('p_expected_version'));
    expect(migration, contains('on conflict (event_id, user_id) do nothing'));
    expect(migration, contains('member_ids cannot contain null'));
    expect(migration, contains('empty list'));
    for (final signature in <String>[
      'public.create_event_with_members',
      'public.update_event_with_members_if_version',
      'public.replace_event_members_if_version',
    ]) {
      expect(
        migration,
        contains('revoke execute on function $signature('),
        reason: '$signature should be revoked before the authenticated grant',
      );
      expect(
        migration,
        contains('grant execute on function $signature('),
        reason: '$signature should be callable by authenticated only',
      );
    }
  });

  test('membership lifecycle prunes assignments but never restores them', () {
    expect(
      migration,
      contains(
        'create or replace function public.leave_group(p_group_id uuid)',
      ),
    );
    expect(
      migration,
      contains('create or replace function public.set_member_active('),
    );
    expect(migration, contains('if not p_is_active then'));
    expect(migration, contains('delete from public.event_members em'));
    expect(migration, contains('select distinct event_id from removed'));
    expect(
      migration,
      contains('reactivation never restores removed assignments'),
    );
    expect(migration, contains('removed_at = coalesce'));
    expect(migration, contains('e.deleted_at is null'));
    expect(migration, contains('g.deleted_at is null'));

    final leaveStart = migration.indexOf(
      'create or replace function public.leave_group(p_group_id uuid)',
    );
    final activeStart = migration.indexOf(
      'create or replace function public.set_member_active(',
    );
    final lifecycleEnd = migration.indexOf(
      '-- keep direct child writes unavailable',
      activeStart,
    );
    expect(leaveStart, greaterThanOrEqualTo(0));
    expect(activeStart, greaterThan(leaveStart));
    expect(lifecycleEnd, greaterThan(activeStart));
    final leaveBody = migration.substring(leaveStart, activeStart);
    final activeBody = migration.substring(activeStart, lifecycleEnd);
    for (final body in <String>[leaveBody, activeBody]) {
      expect(body, contains('delete from public.event_members em'));
      expect(body, contains('and e.deleted_at is null'));
      expect(
        body,
        contains('where g.id = e.group_id and g.deleted_at is null'),
      );
    }
  });

  test(
    'upgrade evidence covers backfill, cascades, permissions, races, and atomicity',
    () {
      for (final marker in <String>[
        'backfilled',
        'created_at',
        'primary key',
        'foreign key',
        'rls',
        'publication',
        'account',
        'cascade',
        'event_members',
        'replace_event_members_if_version',
        'stale',
        'lock timeout',
        'version',
        'atomic',
        'terminal deactivation retention checks passed',
        'terminal leave/archive retention checks passed',
        'reapplying %s after terminal deactivation',
      ]) {
        expect(
          upgrade,
          contains(marker),
          reason: 'upgrade script should assert $marker',
        );
      }
    },
  );
}
