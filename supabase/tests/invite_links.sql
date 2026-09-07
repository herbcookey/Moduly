-- pgTAP fixture for authenticated invite preview/acceptance.
--
-- Every API assertion runs as the real authenticated/anon role with JWT
-- claims.  Setup writes use the session owner and the transaction rolls back,
-- so this fixture is safe to run against a disposable local database.

begin;

create extension if not exists pgtap;
select no_plan();

create temporary table invite_links_fixture (
  owner_id uuid not null,
  member_id uuid not null,
  outsider_id uuid not null,
  inactive_id uuid not null,
  group_id uuid,
  archived_group_id uuid,
  short_invite_id uuid,
  legacy_invite_id uuid,
  expired_invite_id uuid,
  revoked_invite_id uuid,
  exhausted_invite_id uuid,
  archived_invite_id uuid,
  transfer_invite_id uuid
) on commit drop;
grant all on invite_links_fixture to authenticated;

insert into invite_links_fixture (
  owner_id, member_id, outsider_id, inactive_id
) values (
  '00000000-0000-4000-8000-00000000a501',
  '00000000-0000-4000-8000-00000000a502',
  '00000000-0000-4000-8000-00000000a503',
  '00000000-0000-4000-8000-00000000a504'
);

-- Auth rows are fixture setup.  The existing auth trigger creates profiles.
reset role;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_user_meta_data
) values
  (
    (select owner_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-owner@example.test', '',
    now(), now(), now(), '{"display_name":"Invite owner"}'::jsonb
  ),
  (
    (select member_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-member@example.test', '',
    now(), now(), now(), '{"display_name":"Invite member"}'::jsonb
  ),
  (
    (select outsider_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-outsider@example.test', '',
    now(), now(), now(), '{"display_name":"Invite outsider"}'::jsonb
  ),
  (
    (select inactive_id from invite_links_fixture),
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'invite-inactive@example.test', '',
    now(), now(), now(), '{"display_name":"Invite inactive"}'::jsonb
  )
on conflict (id) do nothing;

-- The owner creates a live and an archived group through the authenticated API.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select owner_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from invite_links_fixture),
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

update invite_links_fixture f
set group_id = created.id
from public.create_group('Invite fixture', 'Asia/Seoul', 'Private fixture description') as created;

update invite_links_fixture f
set archived_group_id = created.id
from public.create_group('Archived invite fixture', 'UTC', 'Archived description') as created;

select public.archive_group_if_version(
  (select archived_group_id from invite_links_fixture), 1
);
reset role;

-- Active, historical-inactive, and direct invite rows are setup data.  All
-- invite values below are known only in this transaction; only their digests
-- are inserted into invite_codes.
insert into public.memberships (
  group_id, user_id, role, is_active, removed_at
) values
  (
    (select group_id from invite_links_fixture),
    (select member_id from invite_links_fixture),
    'member', true, null
  ),
  (
    (select group_id from invite_links_fixture),
    (select inactive_id from invite_links_fixture),
    'member', false, now()
  );

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version,
  created_at, updated_at
) values (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345ABCDEFGH', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 3, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('0123456789abcdef0123456789abcdef0123456789abcdef', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 2, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345JKLMNPQR', 'utf8'), 'sha256'), 'hex'),
  now() - interval '1 minute', 1, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('2345STUVWXYZ', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1,
  now() - interval '2 hours', now() - interval '2 hours'
), (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('6789ABCDEFGH', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 1, 1,
  now() - interval '2 hours', now() - interval '2 hours'
)
returning id;

-- Capture the deterministic invite IDs by digest; this avoids persisting the
-- plaintext values in any application table or audit row.
update invite_links_fixture f
set short_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345ABCDEFGH', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set legacy_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('0123456789abcdef0123456789abcdef0123456789abcdef', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set expired_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345JKLMNPQR', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set revoked_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('2345STUVWXYZ', 'utf8'), 'sha256'), 'hex');
update invite_links_fixture f
set exhausted_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('6789ABCDEFGH', 'utf8'), 'sha256'), 'hex');

update public.invite_codes
set revoked_at = now(), version = 2
where id = (select revoked_invite_id from invite_links_fixture);

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version
)
values (
  (select archived_group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('7892JKLMNPQR', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1
)
;

-- Record the archived row with a deterministic digest instead of relying on
-- the generated UUID in this setup-only insert.
update invite_links_fixture f
set archived_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('7892JKLMNPQR', 'utf8'), 'sha256'), 'hex');

insert into public.invite_codes (
  group_id, created_by, token_hash, expires_at, max_uses, uses_count, version
)
values (
  (select group_id from invite_links_fixture),
  (select owner_id from invite_links_fixture),
  encode(extensions.digest(convert_to('7892STUVWXYZ', 'utf8'), 'sha256'), 'hex'),
  now() + interval '1 day', 1, 0, 1
);
update invite_links_fixture f
set transfer_invite_id = i.id
from public.invite_codes i
where i.token_hash = encode(extensions.digest(convert_to('7892STUVWXYZ', 'utf8'), 'sha256'), 'hex');

-- Catalog/ACL/RLS checks are made as the session owner.
select ok(
  exists (
    select 1 from pg_catalog.pg_class
    where oid = 'public.invite_preview_attempts'::regclass
      and relrowsecurity
  ),
  'preview-attempt ledger has RLS enabled'
);
select ok(
  not has_table_privilege('authenticated', 'public.invite_preview_attempts', 'select')
    and not has_table_privilege('authenticated', 'public.invite_preview_attempts', 'insert'),
  'preview-attempt ledger has no direct authenticated table privileges'
);
select ok(
  not has_function_privilege('anon', 'public.preview_invite(text)', 'execute')
    and has_function_privilege('authenticated', 'public.preview_invite(text)', 'execute'),
  'preview RPC is authenticated-only'
);
select ok(
  not has_table_privilege('authenticated', 'public.invite_codes', 'update')
    and not has_column_privilege('authenticated', 'public.invite_codes', 'revoked_at', 'update'),
  'invite table UPDATE is RPC-only'
);
select ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'invite_codes'
      and column_name in ('token', 'plaintext_token')
  ),
  'invite_codes has no plaintext token column'
);

-- Preview by an active ordinary member returns only the approved field set,
-- marks already_member, and never consumes a use.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  public.preview_invite('2345-abcd-efgh') ->> 'valid',
  'true',
  'valid short-code preview succeeds after client-style normalization'
);
select is(
  public.preview_invite('2345-abcd-efgh') ->> 'already_member',
  'true',
  'preview reports active membership only for a valid token'
);
select ok(
  (select array_agg(key order by key)
   from jsonb_object_keys(public.preview_invite('2345ABCDEFGH')) as key)
  = array['already_member','expires_at','group_description','group_id','group_name','group_timezone','valid']::text[],
  'preview valid object contains exactly the sanitized fields'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  0,
  'preview never consumes a use'
);
set local role authenticated;

-- Existing active members can retry a token after each invite lifecycle
-- terminal state.  The exact token/group match and live group are known, so
-- this branch does not disclose anything to inactive members or outsiders.
select is(
  public.preview_invite('2345-JKLM-NPQR') ->> 'already_member',
  'true',
  'active member preview remains idempotent for an expired token'
);
select is(
  public.preview_invite('2345-STUV-WXYZ') ->> 'already_member',
  'true',
  'active member preview remains idempotent for a revoked token'
);
select is(
  public.preview_invite('6789-ABCD-EFGH') ->> 'already_member',
  'true',
  'active member preview remains idempotent for an exhausted token'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-JKLM-NPQR') as j),
  'already_member',
  'active member acceptance remains idempotent after expiry'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-STUV-WXYZ') as j),
  'already_member',
  'active member acceptance remains idempotent after revocation'
);
select is(
  (select j.reason from public.join_group_with_invite('6789-ABCD-EFGH') as j),
  'already_member',
  'active member acceptance remains idempotent after exhaustion'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select exhausted_invite_id from invite_links_fixture)),
  1,
  'terminal active-member retries never consume another use'
);
set local role authenticated;

-- Invalid, expired, revoked, exhausted, archived, malformed, and overlong
-- values all collapse to the same no-group response.
reset role;
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  public.preview_invite('not-a-token'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'missing/malformed preview is uniform'
);
select is(
  public.preview_invite('2345-JKLM-NPQR'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'expired preview is uniform'
);
select is(
  public.preview_invite('2345-STUV-WXYZ'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'revoked preview is uniform'
);
select is(
  public.preview_invite('6789-ABCD-EFGH'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'exhausted preview is uniform'
);
select is(
  public.preview_invite('7892-JKLM-NPQR'),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'archived-group preview is uniform'
);
select is(
  public.preview_invite(repeat('A', 257)),
  '{"reason":"invalid_or_expired","valid":false}'::jsonb,
  'overlong preview is rejected without prefix truncation'
);

-- Every caller also performs a bounded global stale sweep.  Rows belonging to
-- an inactive actor are removed opportunistically through the attempted_at
-- indexes; the actor-specific rolling windows above remain authoritative.
reset role;
insert into public.invite_preview_attempts (actor_id, attempted_at)
values (
  (select inactive_id from invite_links_fixture),
  now() - interval '2 hours'
);
insert into public.invite_join_attempts (
  actor_id, token_hash, attempted_at, succeeded, reason
)
values (
  (select inactive_id from invite_links_fixture),
  encode(extensions.digest(convert_to('stale-row', 'utf8'), 'sha256'), 'hex'),
  now() - interval '2 hours', false, 'invalid_or_expired'
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.preview_invite('not-a-token');
reset role;
select is(
  (select count(*)::integer from public.invite_preview_attempts
   where actor_id = (select inactive_id from invite_links_fixture)
     and attempted_at <= now() - interval '1 hour'),
  0,
  'preview sweep removes stale rows from inactive actors'
);
set local role authenticated;
select public.join_group_with_invite('not-a-token');
reset role;
select is(
  (select count(*)::integer from public.invite_join_attempts
   where actor_id = (select inactive_id from invite_links_fixture)
     and attempted_at <= now() - interval '1 hour'),
  0,
  'join sweep removes stale rows from inactive actors'
);

-- A rate-limited preview has no group data and does not extend its own ledger.
delete from public.invite_preview_attempts
where actor_id = (select member_id from invite_links_fixture);
set local role authenticated;
select public.preview_invite('not-a-token') from generate_series(1, 60);
select is(
  public.preview_invite('2345ABCDEFGH'),
  '{"reason":"rate_limited","valid":false}'::jsonb,
  'preview rate-limit response has no group data'
);
reset role;
select is(
  (select count(*)::integer from public.invite_preview_attempts
   where actor_id = (select member_id from invite_links_fixture)),
  60,
  'blocked preview does not insert another ledger row'
);
delete from public.invite_preview_attempts
where actor_id = (select member_id from invite_links_fixture);

-- Anonymous JWTs are rejected even if a caller supplies an authenticated role
-- and a non-null subject.  Supabase sets is_anonymous on these sessions.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select member_id::text from invite_links_fixture),
    'role', 'authenticated',
    'is_anonymous', true
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select throws_ok(
  'select public.preview_invite(''2345ABCDEFGH'')',
  '28000',
  'authentication is required',
  'anonymous JWT cannot execute preview despite authenticated role'
);
select throws_ok(
  'select public.join_group_with_invite(''2345ABCDEFGH'')',
  '28000',
  'authentication is required',
  'anonymous JWT cannot execute join despite authenticated role'
);
reset role;

-- The anonymous role cannot preview or accept; the database never performs an
-- unauthenticated token lookup.
set request.jwt.claim.sub = '';
set request.jwt.claim.role = 'anon';
set local role anon;
select throws_ok(
  'select public.preview_invite(''2345ABCDEFGH'')',
  '42501',
  null,
  'anon cannot execute preview_invite'
);
select throws_ok(
  'select public.join_group_with_invite(''2345ABCDEFGH'')',
  '42501',
  null,
  'anon cannot execute join_group_with_invite'
);
reset role;

-- A valid outsider joins through a formatted short code.  Repeating the same
-- request is idempotent and does not consume another use.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345-abcd-efgh') as j),
  'joined',
  'outsider accepts a valid formatted short code'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  1,
  'new membership consumes exactly one use'
);
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345ABCDEFGH') as j),
  'already_member',
  'duplicate acceptance is idempotent'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select short_invite_id from invite_links_fixture)),
  1,
  'duplicate acceptance does not consume another use'
);
set local role authenticated;

-- Deactivated membership can rejoin and consumes one additional use.  The
-- legacy 48-hex code accepts uppercase/separator variants as well.
reset role;
update public.memberships
set is_active = false, removed_at = now()
where group_id = (select group_id from invite_links_fixture)
  and user_id = (select outsider_id from invite_links_fixture);
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('01234567-89ABCDEF-01234567-89ABCDEF-01234567-89ABCDEF') as j),
  'joined',
  'legacy 48-hex invite accepts canonical lowercase form'
);
reset role;
select is(
  (select uses_count from public.invite_codes
   where id = (select legacy_invite_id from invite_links_fixture)),
  1,
  'legacy acceptance consumes one use'
);
set local role authenticated;

-- Uniform acceptance failures and max-use terminal behavior.
-- Use the deactivated outsider so terminal invite states remain uniform; the
-- inactive fixture actor has just rejoined through the legacy code above and
-- is therefore an active member for idempotency semantics.
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345-JKLM-NPQR') as j),
  'invalid_or_expired',
  'expired acceptance is uniform'
);
select is(
  (select j.reason from public.join_group_with_invite('2345-STUV-WXYZ') as j),
  'invalid_or_expired',
  'revoked acceptance is uniform'
);
select is(
  (select j.reason from public.join_group_with_invite('6789-ABCD-EFGH') as j),
  'invalid_or_expired',
  'exhausted acceptance is uniform'
);
select is(
  (select j.reason from public.join_group_with_invite(repeat('A', 257)) as j),
  'invalid_or_expired',
  'overlong acceptance is rejected without truncation'
);
reset role;
select is(
  (
    select token_hash
    from public.invite_join_attempts
    where actor_id = (select outsider_id from invite_links_fixture)
    order by id desc
    limit 1
  ),
  encode(
    extensions.digest(
      convert_to('invalid-invite-token-sentinel', 'utf8'),
      'sha256'
    ),
    'hex'
  ),
  'malformed acceptance stores only the fixed sentinel digest'
);
set local role authenticated;

-- Fill the join window with real attempts, then verify blocked calls do not
-- append rate_limited rows (and therefore cannot extend the lockout).
reset role;
delete from public.invite_join_attempts
where actor_id = (select inactive_id from invite_links_fixture);
insert into public.invite_join_attempts (actor_id, token_hash, attempted_at, succeeded, reason)
select
  (select inactive_id from invite_links_fixture),
  encode(extensions.digest(convert_to('rate-' || n::text, 'utf8'), 'sha256'), 'hex'),
  now() - interval '1 minute', false, 'invalid_or_expired'
from generate_series(1, 20) as n;
select set_config(
  'request.jwt.claim.sub',
  (select inactive_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select is(
  (select j.reason from public.join_group_with_invite('2345ABCDEFGH') as j),
  'rate_limited',
  'join rate-limit is typed but does not disclose token/group state'
);
reset role;
select is(
  (select count(*)::integer from public.invite_join_attempts
   where actor_id = (select inactive_id from invite_links_fixture)),
  20,
  'blocked join does not append a rate_limited ledger row'
);

-- Owner transfer changes only the authorization principal.  The new owner
-- can revoke an invite created by the old owner using the same optimistic
-- version contract.
delete from public.invite_join_attempts
where actor_id = (select member_id from invite_links_fixture);
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.transfer_group_ownership(
  (select group_id from invite_links_fixture),
  (select member_id from invite_links_fixture),
  1
);
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
select is(
  (select r.invite_id from public.revoke_invite_code(
    (select transfer_invite_id from invite_links_fixture), 1
  ) as r),
  (select transfer_invite_id from invite_links_fixture),
  'current owner can revoke an invite created before ownership transfer'
);
select throws_ok(
  format(
    'select * from public.revoke_invite_code(%L::uuid, 2)',
    (select transfer_invite_id from invite_links_fixture)
  ),
  '40001',
  'invite was changed, revoked, or is not yours',
  're-revoking a terminal invite is a generic conflict'
);
reset role;
select is(
  (select version from public.invite_codes
   where id = (select transfer_invite_id from invite_links_fixture)),
  2,
  're-revoke does not bump the terminal invite version'
);

-- Direct UPDATE remains denied even to the current owner.  RLS also hides
-- invite rows from an unrelated authenticated outsider.
select set_config(
  'request.jwt.claim.sub',
  (select member_id::text from invite_links_fixture),
  true
);
set request.jwt.claim.role = 'authenticated';
set local role authenticated;
select throws_ok(
  format(
    'update public.invite_codes set revoked_at = now() where id = %L::uuid',
    (select short_invite_id from invite_links_fixture)
  ),
  '42501',
  null,
  'direct invite UPDATE is denied by ACL'
);
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select outsider_id::text from invite_links_fixture),
    'role', 'authenticated'
  )::text,
  true
);
select set_config(
  'request.jwt.claim.sub',
  (select outsider_id::text from invite_links_fixture),
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.invite_codes
   where group_id = (select group_id from invite_links_fixture)),
  0,
  'outsider RLS cannot list invite metadata'
);
reset role;

-- Audit rows contain lifecycle/version metadata only; no token or digest is
-- copied into the public audit table.
select ok(
  not exists (
    select 1
    from public.audit_logs a
    where a.entity_type = 'invite_codes'
      and (a.metadata::text like '%2345ABCDEFGH%'
           or a.metadata::text like '%token_hash%'
           or a.metadata::text like '%2345JKLMNPQR%')
  ),
  'invite audit metadata does not contain plaintext tokens or token hashes'
);
select ok(
  not exists (
    select 1
    from public.invite_join_attempts a
    where a.token_hash = '2345ABCDEFGH'
  ),
  'join ledger stores digests rather than plaintext tokens'
);

select 'invite-links pgTAP checks passed' as result;
rollback;
