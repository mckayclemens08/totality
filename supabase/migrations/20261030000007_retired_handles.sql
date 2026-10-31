-- A Matrix account is found by its name, so a name that came free would hand its next owner the old
-- person's Matrix account. Names are retired for good when a profile goes, and sign-up refuses them.
create table public.retired_handles (
  handle     extensions.citext primary key,
  retired_at timestamptz not null default now()
);
alter table public.retired_handles enable row level security;
create policy retired_handles_closed on public.retired_handles for select to authenticated using (false);
revoke all on public.retired_handles from public, anon, authenticated;

create function private.retire_handle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.retired_handles (handle) values (old.handle) on conflict do nothing;
  return old;
end $$;
revoke all on function private.retire_handle() from public, anon, authenticated;

create trigger retire_handle before delete on public.profiles
  for each row execute function private.retire_handle();

-- Definer rights because Supabase's auth role, which runs this, has no access to public tables.
create or replace function private.enforce_username_address() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'a username cannot change' using errcode = '23514';
  end if;
  if new.email is null or new.email !~ '^[a-z0-9_]{3,24}@totality\.invalid$' then
    raise exception 'an account needs a valid username' using errcode = '23514';
  end if;
  if exists (select 1 from public.retired_handles r where r.handle::text = split_part(new.email, '@', 1)) then
    raise exception 'that username is retired' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function private.enforce_username_address() from public, anon, authenticated;
