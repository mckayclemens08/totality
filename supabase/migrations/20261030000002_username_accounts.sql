-- Accounts are a username and a password, with no email. Supabase Auth needs an address, so each
-- account has name@totality.invalid. That domain is reserved and can never receive mail.

-- The app builds the address, and this holds anyone calling the auth API directly to the same rule.
-- Without it, unconfirmed real addresses could be registered, and an invite addressed to one could
-- be redeemed by a stranger. The address is also fixed: email changes apply at once when
-- confirmation is off, which would free a name for someone else to take.
create function private.enforce_username_address() returns trigger
language plpgsql set search_path = '' as $$
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
  return new;
end $$;
revoke all on function private.enforce_username_address() from public, anon, authenticated;

create trigger enforce_username_address before insert or update of email on auth.users
  for each row execute function private.enforce_username_address();

-- The username is the handle, so nobody can claim a handle that signs in as someone else.
create or replace function public.claim_handle(p_handle text, p_display_name text default null)
returns public.profiles
language plpgsql security definer set search_path = '' as $$
declare
  v_server text;
  v_row public.profiles;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  select matrix_server_name into v_server from public.instance_config;
  if v_server is null then
    raise exception 'matrix_server_name is not configured' using errcode = '55000';
  end if;
  if (select email from auth.users where id = auth.uid()) is distinct from lower(p_handle) || '@totality.invalid' then
    raise exception 'a handle must match your username' using errcode = '42501';
  end if;
  insert into public.profiles (id, handle, display_name, mxid)
  values (auth.uid(), p_handle, p_display_name, '@' || lower(p_handle) || ':' || v_server)
  returning * into v_row;
  return v_row;
end $$;
