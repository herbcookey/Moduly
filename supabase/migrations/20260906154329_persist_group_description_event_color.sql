-- Persist the group and event presentation fields that are already part of the
-- Flutter models. Existing rows are backfilled before the columns become
-- NOT NULL, so this migration can be applied without dropping data.

begin;

alter table public.groups
  add column if not exists description text;

update public.groups
set description = ''
where description is null;

alter table public.groups
  alter column description set default '',
  alter column description set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'groups_description_length_check'
      and conrelid = 'public.groups'::regclass
  ) then
    alter table public.groups
      add constraint groups_description_length_check
      check (char_length(description) <= 10000);
  end if;
end;
$$;

comment on column public.groups.description is
  'Optional group description, limited to 10000 characters.';

alter table public.events
  add column if not exists color_value bigint;

update public.events
set color_value = 4282874742
where color_value is null;

alter table public.events
  alter column color_value set default 4282874742,
  alter column color_value set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'events_color_value_range_check'
      and conrelid = 'public.events'::regclass
  ) then
    alter table public.events
      add constraint events_color_value_range_check
      check (color_value between 0 and 4294967295);
  end if;
end;
$$;

comment on column public.events.color_value is
  'Unsigned 32-bit ARGB color value in the inclusive range 0..4294967295.';

-- The old two-argument signature is removed instead of leaving an overloaded
-- RPC. Keeping the timezone as the second parameter preserves positional
-- callers while the optional description is added as the third parameter.
drop function if exists public.create_group(text, text);
drop function if exists public.create_group(text, text, text);

create function public.create_group(
  p_name text,
  p_timezone text default 'UTC',
  p_description text default ''
)
returns public.groups
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups;
  v_description text := btrim(coalesce(p_description, ''));
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication is required';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'group name must be 1-160 characters';
  end if;
  if char_length(v_description) > 10000 then
    raise exception using errcode = '22023', message = 'group description must be at most 10000 characters';
  end if;
  if not public.is_valid_timezone(coalesce(p_timezone, 'UTC')) then
    raise exception using errcode = '22023', message = 'timezone must be an IANA timezone name';
  end if;

  insert into public.groups (owner_id, name, timezone, description)
  values (v_user_id, btrim(p_name), coalesce(p_timezone, 'UTC'), v_description)
  returning * into v_group;
  return v_group;
end;
$$;

-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default. Keep this
-- RPC private to authenticated callers; the function performs its own auth.uid
-- and input validation under SECURITY DEFINER.
revoke execute on function public.create_group(text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_group(text, text, text) to authenticated;

-- New columns need explicit privileges because the initial migration uses
-- column-level grants. RLS policies continue to control which rows callers can
-- read or mutate.
grant insert (description) on public.groups to authenticated;
grant update (description) on public.groups to authenticated;
grant insert (color_value) on public.events to authenticated;
grant update (color_value) on public.events to authenticated;

commit;
