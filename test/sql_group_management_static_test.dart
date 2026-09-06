import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;
  late String edgeFunction;
  late String preflightValidator;
  late String upgradeScript;
  late String realtimeMigration;
  late String schemaMigration;

  setUpAll(() {
    final file = File(
      'supabase/migrations/20260907130001_group_management.sql',
    );
    expect(
      file.existsSync(),
      isTrue,
      reason: 'The monotonic group-management migration is required',
    );
    migration = file.readAsStringSync().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    edgeFunction = File(
      'supabase/functions/delete-account/index.ts',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    preflightValidator = File(
      'supabase/functions/delete-account/preflight_validator.mjs',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    upgradeScript = File(
      'supabase/tests/run_group_management_upgrade.sh',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    realtimeMigration = File(
      'supabase/migrations/202608110002_rls_rpc.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    schemaMigration = File(
      'supabase/migrations/202608110001_schema.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  });

  test('update RPC is an owner-only, locked optimistic update', () {
    expect(
      migration,
      contains(
        'create or replace function public.update_group_if_version( p_group_id uuid, p_expected_version integer, p_name text, p_description text, p_timezone text )',
      ),
    );
    expect(migration, contains('returns public.groups'));
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = \'\''));
    expect(migration, contains('v_user_id uuid := auth.uid()'));
    expect(migration, contains('pg_catalog.btrim(coalesce(p_name, \'\'))'));
    expect(migration, contains('char_length(v_name) not between 1 and 160'));
    expect(migration, contains('char_length(v_description) > 10000'));
    expect(migration, contains('pg_catalog.pg_timezone_names'));
    expect(
      migration,
      contains('from public.groups g where g.id = p_group_id for update'),
    );
    expect(
      migration,
      contains(
        'g.deleted_at is null and g.version = p_expected_version returning g.* into v_group',
      ),
    );
    expect(migration, contains("errcode = '40001'"));
    expect(migration, contains('version = g.version + 1'));
  });

  test('leave RPC is self-only and preserves membership history', () {
    expect(
      migration,
      contains(
        'create or replace function public.leave_group(p_group_id uuid)',
      ),
    );
    expect(migration, contains('returns void'));
    expect(migration, contains('only an active ordinary member can leave'));
    expect(migration, contains('for update'));
    expect(migration, contains('m.user_id = v_user_id'));
    expect(migration, contains('set is_active = false'));
    expect(migration, contains('removed_at = coalesce(m.removed_at'));
    expect(migration, contains("v_membership.role <> 'member'"));
  });

  test('transfer uses a validated transaction marker and final invariant', () {
    expect(
      migration,
      contains(
        'create or replace function public.transfer_group_ownership( p_group_id uuid, p_new_owner_id uuid, p_expected_version integer )',
      ),
    );
    expect(
      migration,
      contains('pg_catalog.set_config(\'moduly.transfer_marker\''),
    );
    expect(
      migration,
      contains("current_setting('moduly.transfer_marker', true)"),
    );
    expect(migration, contains("'group_id'"));
    expect(migration, contains("'old_owner_id'"));
    expect(migration, contains("'new_owner_id'"));
    expect(
      migration,
      contains(
        'select g.* into v_group from public.groups g where g.id = p_group_id for update',
      ),
    );
    expect(
      migration,
      contains(
        'from public.memberships m where m.group_id = p_group_id and m.user_id = v_user_id for update',
      ),
    );
    expect(migration, contains("set role = 'member'"));
    expect(migration, contains("set role = 'owner'"));
    expect(migration, contains('owner_id = p_new_owner_id'));
    expect(migration, contains('v_active_owner_count <> 1'));
    expect(
      migration,
      contains(
        'create unique index if not exists memberships_one_active_owner_idx',
      ),
    );
    expect(migration, contains("where role = 'owner' and is_active"));
    expect(
      migration,
      contains(
        'revoke update (name, description, timezone, version) on public.groups from public, anon, authenticated',
      ),
    );
    expect(migration, contains('if tg_op = \'delete\' then return old;'));
  });

  test(
    'legacy owner rows and same-name indexes are repaired or rejected safely',
    () {
      expect(migration, contains('pg_catalog.pg_index'));
      expect(migration, contains('pg_catalog.pg_get_expr'));
      expect(migration, contains('pg_catalog.pg_get_indexdef'));
      expect(migration, contains('v_expected_index_def'));
      expect(
        migration,
        contains(
          'memberships_one_active_owner_idx exists but is not the expected',
        ),
      );
      expect(migration, contains('deterministic backfill'));
      expect(migration, contains('m.user_id <> v_owner_id'));
      expect(migration, contains("set role = 'member'"));
      expect(migration, contains("insert into public.memberships"));
      expect(migration, contains('ambiguous active owner membership'));
      expect(
        migration,
        contains(
          'create unique index if not exists memberships_one_active_owner_idx',
        ),
      );
    },
  );

  test('transfer marker and membership delete paths are fail-closed', () {
    expect(
      migration,
      contains(
        "v_marker - 'group_id' - 'old_owner_id' - 'new_owner_id' = '{}'::jsonb",
      ),
    );
    expect(
      migration,
      contains("v_marker ->> 'old_owner_id' = v_owner_id::text"),
    );
    expect(migration, contains("if tg_op = 'delete' then return old;"));
    expect(
      migration,
      contains('before insert or update or delete on public.memberships'),
    );
  });

  test(
    'group-scoped mutating RPCs lock the group before stale checks/writes',
    () {
      final functionNames = <String>[
        'create_invite_code',
        'join_group_with_invite',
        'soft_delete_event_if_version',
        'revoke_invite_code',
        'set_member_active',
      ];
      for (final functionName in functionNames) {
        final start = migration.indexOf(
          'create or replace function public.$functionName',
        );
        expect(start, greaterThanOrEqualTo(0), reason: functionName);
        final bodyStart = migration.indexOf(r'as $$', start);
        final bodyEnd = migration.indexOf(r'$$;', bodyStart);
        expect(bodyStart, greaterThanOrEqualTo(start), reason: functionName);
        expect(bodyEnd, greaterThan(bodyStart), reason: functionName);
        final body = migration.substring(bodyStart, bodyEnd);
        final groupLock = body.indexOf('for update');
        expect(groupLock, greaterThanOrEqualTo(0), reason: functionName);
        expect(
          body,
          isNot(contains('for share')),
          reason: '$functionName must not use a stale shared group lock',
        );
        expect(
          body.indexOf('from public.groups g where g.id ='),
          greaterThanOrEqualTo(0),
          reason: '$functionName must lock its parent group',
        );
        for (final write in <String>[
          'update public.invite_codes',
          'insert into public.invite_codes',
          'update public.memberships',
          'insert into public.memberships',
          'update public.events',
        ]) {
          final writeIndex = body.indexOf(write);
          if (writeIndex >= 0) {
            expect(
              groupLock,
              lessThan(writeIndex),
              reason: '$functionName writes $write before locking its group',
            );
          }
        }
        final lifecycleCheck = body.indexOf('v_group.deleted_at is not null');
        expect(
          lifecycleCheck,
          greaterThan(groupLock),
          reason: '$functionName checks lifecycle after the group lock',
        );
      }
    },
  );

  test('direct event writes serialize with terminal group transitions', () {
    final eventGuard = migration.indexOf(
      'create or replace function public.enforce_event_integrity()',
    );
    expect(eventGuard, greaterThanOrEqualTo(0));
    final bodyStart = migration.indexOf(r'as $$', eventGuard);
    final bodyEnd = migration.indexOf(r'$$;', bodyStart);
    expect(bodyEnd, greaterThan(bodyStart));
    final declaration = migration.substring(eventGuard, bodyStart);
    final body = migration.substring(bodyStart, bodyEnd);
    expect(declaration, contains('security definer'));
    expect(
      body,
      contains('from public.groups g where g.id = new.group_id for update'),
    );
    expect(body, contains('v_group.deleted_at is not null'));
    expect(body, contains("errcode = '40001'"));
    expect(
      schemaMigration,
      contains(
        'create trigger events_integrity before insert or update on public.events',
      ),
    );
    expect(
      schemaMigration,
      isNot(contains('create trigger events_integrity before delete')),
    );
  });

  test('pgTAP fixture runs real authenticated owner/member/outsider flows', () {
    final fixture = File(
      'supabase/tests/group_management.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    expect(fixture, contains('create extension if not exists pgtap'));
    expect(fixture, contains('set local role authenticated'));
    expect(fixture, contains("'role', 'authenticated'"));
    for (final id in <String>['owner_id', 'member_id', 'outsider_id']) {
      expect(fixture, contains("'sub', (select $id::text"));
    }
    expect(fixture, contains('has_column_privilege'));
    expect(fixture, contains('direct groups update is denied by acl'));
    expect(fixture, contains('direct membership role update is denied by acl'));
    expect(
      fixture,
      contains(
        'authenticated callers cannot update membership status directly',
      ),
    );
    expect(fixture, contains('malformed transfer marker is rejected'));
    expect(fixture, contains('preflight group count is exact'));
    expect(fixture, contains('preflight event cascade count is exact'));
    expect(fixture, contains('preflight invite cascade count is exact'));
    expect(fixture, contains('preflight membership cascade count is exact'));
    expect(
      fixture,
      contains('preflight summary does not expose user uuids or pii'),
    );
    expect(fixture, contains('invited_by is nulled in a surviving group'));
    expect(
      fixture,
      contains('deleting another owner cascades its group and memberships'),
    );
    expect(fixture, contains('owner cannot transfer with a stale version'));
    expect(fixture, contains('owner cannot archive with a stale version'));
    expect(
      fixture,
      contains('active members cannot perform stale group updates'),
    );
    expect(
      fixture,
      contains('active members cannot perform stale ownership transfers'),
    );
    expect(fixture, contains('active members cannot perform stale archives'));
    expect(fixture, contains('outsiders cannot perform stale group updates'));
    expect(
      fixture,
      contains('outsiders cannot perform stale ownership transfers'),
    );
    expect(fixture, contains('outsiders cannot perform stale archives'));
    expect(fixture, contains("'40001'"));
  });

  test('API ACLs and audit payloads remain minimal', () {
    expect(
      migration,
      contains(
        'revoke update on table public.groups from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'revoke update on table public.memberships from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'revoke update (group_id, user_id, role, joined_at, removed_at, invited_by, created_at, updated_at, is_active) on public.memberships from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      isNot(
        contains('grant update (is_active, removed_at) on public.memberships'),
      ),
    );
    expect(migration, contains('v_entity_id := null'));
    expect(
      migration,
      contains("where entity_type = 'memberships' and entity_id is not null"),
    );
    expect(migration, contains("jsonb_build_object('version', v_version)"));
    expect(
      migration,
      contains("alter publication supabase_realtime add table public.groups"),
    );
    expect(migration, contains("tablename = 'groups'"));
    expect(
      migration,
      contains(
        "alter publication supabase_realtime add table public.memberships",
      ),
    );
    expect(migration, contains("tablename = 'memberships'"));
    expect(realtimeMigration, contains("tablename = 'events'"));
    expect(
      realtimeMigration,
      contains(
        "execute 'alter publication supabase_realtime add table public.events'",
      ),
    );
    expect(migration, isNot(contains('create schema realtime')));
  });

  test('archive is terminal and preflight is authenticated-only JSON', () {
    expect(
      migration,
      contains(
        'create or replace function public.archive_group_if_version( p_group_id uuid, p_expected_version integer )',
      ),
    );
    expect(migration, contains('set deleted_at = pg_catalog.now()'));
    expect(migration, contains('old'));
    expect(migration, contains('child rows remain intact'));
    expect(
      migration,
      contains(
        'create or replace function public.account_deletion_preflight()',
      ),
    );
    expect(migration, contains('returns jsonb'));
    expect(migration, contains("'owned_groups'"));
    expect(migration, contains("'active_owned_groups'"));
    expect(migration, contains("'archived_owned_groups'"));
    expect(migration, contains("'member_count'"));
    expect(migration, contains("'events', v_events"));
    expect(migration, contains("'invites', v_invites"));
    expect(migration, contains("'memberships', v_memberships"));
    expect(
      migration,
      contains(
        'revoke execute on function public.account_deletion_preflight() from public, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.account_deletion_preflight() to authenticated',
      ),
    );
  });

  test('delete-account obtains the caller summary before admin deletion', () {
    final preflight = edgeFunction.indexOf(
      "authclient.rpc( 'account_deletion_preflight', )",
    );
    final adminDelete = edgeFunction.indexOf('auth.admin.deleteuser');
    expect(preflight, greaterThanOrEqualTo(0));
    expect(adminDelete, greaterThan(preflight));
    expect(edgeFunction, contains('preflight_failed'));
    expect(edgeFunction, contains('isvaliddeletionsummary(summary)'));
    expect(edgeFunction, contains("from './preflight_validator.mjs'"));
    expect(edgeFunction, contains('json({ deleted: true, summary })'));
    expect(edgeFunction, contains("catch (_) {"));
    expect(edgeFunction, contains("json({ error: 'internal_error' }, 500)"));
    expect(edgeFunction, isNot(contains('console.log')));
    expect(edgeFunction, isNot(contains('console.error')));
  });

  test('Edge preflight validator mirrors the client fail-closed contract', () {
    expect(preflightValidator, contains('isvaliddeletionsummary'));
    expect(preflightValidator, contains('owned_groups'));
    expect(preflightValidator, contains('active_owned_groups'));
    expect(preflightValidator, contains('archived_owned_groups'));
    expect(preflightValidator, contains('isrequirednonnegativeinteger'));
    expect(preflightValidator, contains('member_count'));
    expect(preflightValidator, contains('membership_count'));
    expect(preflightValidator, contains('new set(owned.map'));
    expect(preflightValidator, contains('canonicalgroup'));
    expect(preflightValidator, contains('ownedcanonical.get(group.id)'));
    expect(preflightValidator, contains('activeids.size + archivedids.size'));
    expect(preflightValidator, contains("status === 'active'"));
    expect(preflightValidator, contains('date.parse'));
    expect(preflightValidator, isNot(contains('console.log')));
    expect(preflightValidator, isNot(contains('console.error')));
  });

  test(
    'upgrade evidence applies migrations 1..10 and verifies preservation',
    () {
      expect(upgradeScript, contains('initdb'));
      expect(upgradeScript, contains('applies migrations 1..9'));
      expect(upgradeScript, contains('20260907130001_group_management.sql'));
      expect(upgradeScript, contains('reapplying'));
      expect(
        upgradeScript,
        contains('existing group fields were not preserved'),
      );
      expect(
        upgradeScript,
        contains('existing membership fields were not preserved'),
      );
      expect(
        upgradeScript,
        contains('existing invite fields were not preserved'),
      );
      expect(
        upgradeScript,
        contains('existing event fields were not preserved'),
      );
      expect(
        upgradeScript,
        contains('existing audit fields were not preserved'),
      );
      expect(upgradeScript, contains('owner membership was not backfilled'));
      expect(
        upgradeScript,
        contains('active-owner unique partial index is missing'),
      );
      expect(upgradeScript, contains('lock_timeout'));
      expect(
        upgradeScript,
        contains('two-session transfer/archive group-lock race checks passed'),
      );
      expect(upgradeScript, contains('error: +40001'));
      expect(upgradeScript, contains('repeatable read'));
      expect(upgradeScript, contains('event race'));
      expect(upgradeScript, contains('event child was modified after archive'));
      expect(
        upgradeScript,
        contains('membership/archive rpc-only race checks passed'),
      );
      expect(
        upgradeScript,
        contains('membership row was modified after archive'),
      );
      expect(
        upgradeScript,
        contains('direct membership update unexpectedly succeeded'),
      );
      expect(upgradeScript, isNot(contains('supabase_url')));
      expect(upgradeScript, isNot(contains('service_role')));
    },
  );
}
