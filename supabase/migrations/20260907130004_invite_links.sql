-- Authenticated invite-link preview and acceptance hardening.
--
-- This migration is additive.  Existing invite_codes rows keep their SHA-256
-- digests (including legacy 48-character hexadecimal codes); plaintext bearer
-- values are never backfilled or written.  Preview is deliberately an
-- authenticated operation so a logged-out deep link is routed through the
-- application's login flow before any group metadata can be requested.

begin;

-- Preview throttling is intentionally smaller than the join ledger.  It has
-- no token, digest, group, or result columns: actor/timestamp are the only
-- request metadata retained.  The composite key also avoids adding a
-- surrogate identifier that could become an accidental correlation handle.
create table if not exists public.invite_preview_attempts (
  actor_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, attempted_at)
);

comment on table public.invite_preview_attempts is
  'Private preview rate-limit ledger. It stores only actor_id and attempted_at; no token or digest is retained.';
comment on column public.invite_preview_attempts.actor_id is
  'Authenticated caller responsible for the preview request.';
comment on column public.invite_preview_attempts.attempted_at is
  'Wall-clock time of a real preview attempt, used for the rolling one-hour limit.';

create index if not exists invite_preview_attempts_actor_time_idx
  on public.invite_preview_attempts (actor_id, attempted_at desc);
create index if not exists invite_preview_attempts_time_idx
  on public.invite_preview_attempts (attempted_at);

-- The legacy join ledger already has an actor/time index for rolling-window
-- checks.  Keep a second timestamp-only index so bounded global stale sweeps
-- do not scan every actor's history.
create index if not exists invite_join_attempts_time_idx
  on public.invite_join_attempts (attempted_at);

alter table public.invite_preview_attempts enable row level security;

-- Keep the table private even if a future migration accidentally restores a
-- table grant.  The SECURITY DEFINER preview RPC is owned by the migration
-- role and can still maintain the ledger.
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_policy p
    where p.polname = 'invite_preview_attempts_deny'
      and p.polrelid = 'public.invite_preview_attempts'::regclass
  ) then
    execute 'create policy invite_preview_attempts_deny on public.invite_preview_attempts for all to authenticated using (false) with check (false)';
  end if;
end;
$$;

revoke all on table public.invite_preview_attempts from public, anon, authenticated;

-- Match lib/core/invite_code_utils.dart on the server.  Separators are display
-- only; short codes are canonical uppercase in the human alphabet and legacy
-- 48-character hexadecimal values are canonical lowercase.  NULL means the
-- input is empty, overlong, or malformed; callers return one safe terminal
-- result rather than exposing which validation branch failed.
create or replace function public._canonicalize_invite_token(p_token text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_raw text;
  v_compact text;
  v_short_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
begin
  -- Reject before normalization as well as after it.  This avoids silently
  -- accepting an attacker-controlled prefix when a very large value arrives.
  if p_token is null
     or pg_catalog.octet_length(p_token) > 256 then
    return null;
  end if;

  v_raw := pg_catalog.btrim(p_token);
  if pg_catalog.char_length(v_raw) = 0
     or pg_catalog.char_length(v_raw) > 256
     or pg_catalog.octet_length(v_raw) > 256 then
    return null;
  end if;

  v_compact := pg_catalog.regexp_replace(v_raw, '[[:space:]-]+', '', 'g');
  if pg_catalog.char_length(v_compact) = 0
     or pg_catalog.char_length(v_compact) > 256 then
    return null;
  end if;

  if v_compact ~ '^[0-9a-fA-F]{48}$' then
    return pg_catalog.lower(v_compact);
  end if;

  if pg_catalog.char_length(v_compact) = 12
     and pg_catalog.upper(v_compact) ~ ('^[' || v_short_alphabet || ']{12}$') then
    return pg_catalog.upper(v_compact);
  end if;

  return null;
end;
$$;

comment on function public._canonicalize_invite_token(text) is
  'Private server-side invite canonicalizer; returns NULL for malformed/overlong input.';

-- Preview exposes only the minimum confirmation fields.  It has no anon
-- execution grant and records no token/hash.  Every non-live state uses the
-- same no-group response, so a caller cannot probe hidden group existence.
create or replace function public.preview_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_token text;
  v_token_hash text;
  v_attempt_count integer;
  v_invite_group_id uuid;
  v_group_name text;
  v_group_description text;
  v_group_timezone text;
  v_expires_at timestamptz;
  v_revoked_at timestamptz;
  v_uses_count integer;
  v_max_uses integer;
  v_already_member boolean;
  v_invalid_token_sentinel constant text := 'invalid-invite-token-sentinel';
begin
  if v_user_id is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using
      errcode = '28000',
      message = 'authentication is required';
  end if;

  -- Serialize and prune this actor's rolling window before counting.  A
  -- request that is already at the limit does not insert another row, so
  -- repeated blocked probes cannot extend their own lockout.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  delete from public.invite_preview_attempts
  where actor_id = v_user_id
    and attempted_at <= pg_catalog.now() - interval '1 hour';

  -- Bounded opportunistic cleanup keeps rows from inactive actors from
  -- growing without bound.  SKIP LOCKED makes concurrent preview callers
  -- deterministic and limits each invocation to a small ctid batch.
  with stale as (
    select p.ctid
    from public.invite_preview_attempts p
    where p.attempted_at <= pg_catalog.now() - interval '1 hour'
    order by p.attempted_at, p.ctid
    for update skip locked
    limit 100
  )
  delete from public.invite_preview_attempts p
  using stale
  where p.ctid = stale.ctid;

  select count(*)::integer
    into v_attempt_count
  from public.invite_preview_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

  if v_attempt_count >= 60 then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'rate_limited'
    );
  end if;

  insert into public.invite_preview_attempts (actor_id, attempted_at)
  values (v_user_id, pg_catalog.clock_timestamp());

  v_token := public._canonicalize_invite_token(p_token);
  v_token_hash := encode(
    extensions.digest(
      pg_catalog.convert_to(coalesce(v_token, v_invalid_token_sentinel), 'utf8'),
      'sha256'
    ),
    'hex'
  );

  -- The fixed sentinel above keeps malformed input bounded and prevents an
  -- arbitrary attacker string from being retained or digested.  A malformed
  -- value cannot match a real invite digest, so return the uniform terminal
  -- result before looking up any group.
  if v_token is null then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  select i.group_id, g.name, g.description, g.timezone, i.expires_at,
         i.revoked_at, i.uses_count, i.max_uses,
         exists (
           select 1
           from public.memberships m
           where m.group_id = g.id
             and m.user_id = v_user_id
             and m.is_active
             and m.removed_at is null
         )
    into v_invite_group_id, v_group_name, v_group_description,
         v_group_timezone, v_expires_at, v_revoked_at, v_uses_count,
         v_max_uses, v_already_member
  from public.invite_codes i
  join public.groups g on g.id = i.group_id
  where i.token_hash = v_token_hash
    and g.deleted_at is null
  limit 1;

  if not found then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  -- A caller who is already an active member may safely retry a previously
  -- valid token after it expires, is revoked, or reaches max_uses.  The
  -- membership bit is only exposed after an exact token/group match; outsiders
  -- still receive the same no-group terminal response below.
  if not v_already_member
     and (
       v_revoked_at is not null
       or v_expires_at <= pg_catalog.now()
       or v_uses_count >= v_max_uses
     ) then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'reason', 'invalid_or_expired'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'valid', true,
    'group_id', v_invite_group_id,
    'group_name', v_group_name,
    'group_description', v_group_description,
    'group_timezone', v_group_timezone,
    'expires_at', v_expires_at,
    'already_member', v_already_member
  );
end;
$$;

-- Replace acceptance without changing the existing PostgREST signature or
-- row shape.  Canonicalization happens before hashing, and overlong input is
-- rejected instead of being silently truncated.  The old 48-character digest
-- rows therefore remain valid while newly issued 12-character codes accept
-- the same separator/case variants as the client.
create or replace function public.join_group_with_invite(p_token text)
returns table (
  group_id uuid,
  membership_id uuid,
  joined boolean,
  reason text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_token text;
  v_token_hash text;
  v_attempt_id bigint;
  v_attempt_count integer;
  v_invite_id uuid;
  v_invite_group_id uuid;
  v_expires_at timestamptz;
  v_max_uses integer;
  v_uses_count integer;
  v_revoked_at timestamptz;
  v_group public.groups;
  v_group_owner uuid;
  v_membership_id uuid;
  v_membership_active boolean;
  v_invalid_token_sentinel constant text := 'invalid-invite-token-sentinel';
begin
  if v_user_id is null
     or coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') = 'true' then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- The actor lock covers pruning, counting and the real-attempt ledger row.
  -- Blocked requests return without inserting a row, preventing an attacker
  -- from extending the rolling window indefinitely.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );
  delete from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at <= pg_catalog.now() - interval '1 hour';

  select count(*)::integer
    into v_attempt_count
  from public.invite_join_attempts
  where actor_id = v_user_id
    and attempted_at > pg_catalog.now() - interval '1 hour';

  -- Bound each invocation's global cleanup work.  SKIP LOCKED allows callers
  -- for different actors to prune stale rows without forming a lock cycle.
  with stale as (
    select a.ctid
    from public.invite_join_attempts a
    where a.attempted_at <= pg_catalog.now() - interval '1 hour'
    order by a.attempted_at, a.ctid
    for update skip locked
    limit 100
  )
  delete from public.invite_join_attempts a
  using stale
  where a.ctid = stale.ctid;

  if v_attempt_count >= 20 then
    return query select null::uuid, null::uuid, false, 'rate_limited'::text;
    return;
  end if;

  v_token := public._canonicalize_invite_token(p_token);
  v_token_hash := encode(
    extensions.digest(
      pg_catalog.convert_to(coalesce(v_token, v_invalid_token_sentinel), 'utf8'),
      'sha256'
    ),
    'hex'
  );

  -- Store a digest for every real attempt, including malformed input.  This
  -- preserves the existing private ledger contract without retaining the
  -- bearer value itself.
  insert into public.invite_join_attempts (actor_id, token_hash, succeeded, reason)
  values (v_user_id, v_token_hash, false, 'invalid_or_expired')
  returning id into v_attempt_id;

  if v_token is null then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  -- Read the parent id without a lock only to establish the group lock target.
  -- The locked group is rechecked before the invite and membership writes.
  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.token_hash = v_token_hash;
  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  -- Group-first lock order is shared with create/revoke/archive/transfer and
  -- prevents lifecycle writes from racing invite use consumption.
  select i.id, i.group_id, i.expires_at, i.max_uses, i.uses_count, i.revoked_at
    into v_invite_id, v_invite_group_id, v_expires_at, v_max_uses, v_uses_count, v_revoked_at
  from public.invite_codes i
  where i.token_hash = v_token_hash
  for update;

  if not found then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_invite_group_id <> v_group.id then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_group.deleted_at is not null then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  v_group_owner := v_group.owner_id;
  select m.user_id, m.is_active
    into v_membership_id, v_membership_active
  from public.memberships m
  where m.group_id = v_invite_group_id
    and m.user_id = v_user_id
  for update;

  -- An active member can safely retry a token after its lifecycle reaches a
  -- terminal state.  The exact token/group match and live-group check above
  -- prevent this branch from revealing membership to outsiders.
  if found and v_membership_active then
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if v_revoked_at is not null then
    update public.invite_join_attempts
      set reason = 'revoked'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_expires_at <= pg_catalog.now() then
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_uses_count >= v_max_uses then
    update public.invite_join_attempts
      set reason = 'max_uses'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;
  if v_group.deleted_at is not null then
    update public.invite_join_attempts
      set reason = 'group_unavailable'
      where id = v_attempt_id;
    return query select null::uuid, null::uuid, false, 'invalid_or_expired'::text;
    return;
  end if;

  if v_group_owner = v_user_id then
    insert into public.memberships (group_id, user_id, role, is_active, removed_at)
    values (v_invite_group_id, v_user_id, 'owner', true, null)
    on conflict (group_id, user_id) do update
      set role = 'owner', is_active = true, removed_at = null,
          updated_at = pg_catalog.now()
    returning user_id into v_membership_id;
    update public.invite_join_attempts
      set succeeded = true, reason = 'already_member'
      where id = v_attempt_id;
    return query select v_invite_group_id, v_membership_id, true, 'already_member'::text;
    return;
  end if;

  if found then
    update public.memberships as m
      set role = 'member', is_active = true, removed_at = null,
          joined_at = pg_catalog.now()
      where m.group_id = v_invite_group_id
        and m.user_id = v_user_id
      returning m.user_id into v_membership_id;
  else
    insert into public.memberships (group_id, user_id, role, is_active, invited_by)
    values (v_invite_group_id, v_user_id, 'member', true, v_group_owner)
    returning user_id into v_membership_id;
  end if;

  update public.invite_codes
    set uses_count = uses_count + 1,
        version = version + 1
  where id = v_invite_id;
  update public.invite_join_attempts
    set succeeded = true, reason = 'joined'
    where id = v_attempt_id;

  return query select v_invite_group_id, v_membership_id, true, 'joined'::text;
end;
$$;

-- Revoke by the current active group owner rather than the historical creator.
-- This keeps owner-transfer semantics correct while retaining the same
-- optimistic version and generic conflict response.
create or replace function public.revoke_invite_code(
  p_invite_id uuid,
  p_expected_version integer
)
returns table (
  invite_id uuid,
  group_id uuid,
  expires_at timestamptz,
  max_uses integer,
  uses_count integer,
  revoked_at timestamptz,
  version integer,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_actor_row auth.users;
  v_invite_group_id uuid;
  v_group public.groups;
  v_invite public.invite_codes;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;

  -- Account deletion locks auth.users before its cascading group rows.  Take
  -- the compatible key-share lock first so a concurrent revoke waits on the
  -- actor row rather than forming a cross-order deadlock with deletion.
  select u.*
    into v_actor_row
  from auth.users u
  where u.id = v_user_id
  for key share;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  select i.group_id
    into v_invite_group_id
  from public.invite_codes i
  where i.id = p_invite_id;

  select g.*
    into v_group
  from public.groups g
  where g.id = v_invite_group_id
  for update;
  if not found
     or v_group.owner_id <> v_user_id
     or v_group.deleted_at is not null then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  select i.*
    into v_invite
  from public.invite_codes i
  where i.id = p_invite_id
  for update;
  if not found
     or v_invite.group_id <> v_group.id
     or p_expected_version is null
     or v_invite.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  -- Revocation is terminal.  A retry with the current terminal version is a
  -- generic conflict and must not bump the version or emit another audit row.
  if v_invite.revoked_at is not null then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  update public.invite_codes i
  set revoked_at = pg_catalog.now(),
      version = i.version + 1
  where i.id = p_invite_id
    and i.version = p_expected_version
  returning i.* into v_invite;
  if not found then
    raise exception using
      errcode = '40001',
      message = 'invite was changed, revoked, or is not yours';
  end if;

  return query
  select v_invite.id, v_invite.group_id, v_invite.expires_at,
         v_invite.max_uses, v_invite.uses_count, v_invite.revoked_at,
         v_invite.version, v_invite.created_at, v_invite.updated_at;
end;
$$;

-- PostgreSQL defaults new functions to PUBLIC EXECUTE.  Keep the helper
-- private, expose preview only to authenticated callers, and explicitly reset
-- the unchanged existing invite RPC ACLs on upgraded deployments.
revoke execute on function public._canonicalize_invite_token(text)
  from public, anon, authenticated;
revoke execute on function public.preview_invite(text)
  from public, anon, authenticated;
grant execute on function public.preview_invite(text) to authenticated;

revoke execute on function public.create_invite_code(uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.create_invite_code(uuid, timestamptz, integer)
  to authenticated;
revoke execute on function public.join_group_with_invite(text)
  from public, anon, authenticated;
grant execute on function public.join_group_with_invite(text) to authenticated;
revoke execute on function public.revoke_invite_code(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.revoke_invite_code(uuid, integer) to authenticated;

-- The owner-authorized RPCs are the only invite mutation path.  The existing
-- 202608110002 column grant must be removed for both fresh and upgraded DBs.
revoke update on table public.invite_codes from public, anon, authenticated;
revoke update (expires_at, max_uses, revoked_at, version)
  on public.invite_codes from public, anon, authenticated;

commit;
