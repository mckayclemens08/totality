-- A one-time mailbox for adding a browser to an account (issue 150). The browser makes a slot and shows its
-- ID in a QR code; the iPhone puts the content key in it, sealed to the browser's public key. The server
-- only ever holds ciphertext and public keys, and a slot lives for two minutes.
create table public.pairing_slots (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  visibility    public.visibility_t not null default 'private' check (visibility = 'private'),
  browser_pub   text not null check (browser_pub ~ '^[0-9a-f]{64}$'),
  device_label  text not null check (char_length(device_label) between 1 and 80),
  phone_pub     text check (phone_pub ~ '^[0-9a-f]{64}$'),
  sealed        text check (char_length(sealed) between 1 and 512),
  expires_at    timestamptz not null default now() + interval '2 minutes',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((phone_pub is null) = (sealed is null))
);
create index pairing_slots_owner on public.pairing_slots (owner_id, expires_at);
create trigger touch_pairing_slots before update on public.pairing_slots
  for each row execute function public.touch_updated_at();

-- Clears old slots and caps live ones, so a stolen session can't fill the table.
create function public.pairing_slots_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.pairing_slots where owner_id = new.owner_id and expires_at < now() - interval '1 hour';
  if (select count(*) from public.pairing_slots where owner_id = new.owner_id and expires_at > now()) >= 5 then
    raise exception 'too many open pairing codes' using errcode = 'P0001';
  end if;
  new.expires_at := now() + interval '2 minutes';
  return new;
end $$;
revoke execute on function public.pairing_slots_guard() from public, anon, authenticated;
create trigger pairing_slots_guard before insert on public.pairing_slots
  for each row execute function public.pairing_slots_guard();

alter table public.pairing_slots enable row level security;
create policy pairing_slots_select on public.pairing_slots for select to authenticated
  using (owner_id = auth.uid() and expires_at > now());
create policy pairing_slots_insert on public.pairing_slots for insert to authenticated
  with check (owner_id = auth.uid() and phone_pub is null and sealed is null);
-- One use: the iPhone can fill a slot once, before it expires, and never change it after.
create policy pairing_slots_update on public.pairing_slots for update to authenticated
  using (owner_id = auth.uid() and expires_at > now() and sealed is null)
  with check (owner_id = auth.uid());
create policy pairing_slots_delete on public.pairing_slots for delete to authenticated
  using (owner_id = auth.uid());

grant select, delete on public.pairing_slots to authenticated;
grant insert (browser_pub, device_label) on public.pairing_slots to authenticated;
grant update (phone_pub, sealed) on public.pairing_slots to authenticated;
