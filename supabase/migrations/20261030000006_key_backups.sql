-- The second copy of a person's key backup. The Matrix server holds the first, so that Oracle closing
-- the account can't cost anyone their backup. It's locked by a recovery key the server never sees, and
-- there's one per person: the first device to set up wins, and the rest join it.
create table public.key_backups (
  owner_id   uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  visibility public.visibility_t not null default 'private' check (visibility = 'private'),
  key_id     text not null check (key_id ~ '^[0-9a-f]{32}$'),
  backup     jsonb not null check (jsonb_typeof(backup) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch_key_backups before update on public.key_backups
  for each row execute function public.touch_updated_at();

alter table public.key_backups enable row level security;
create policy key_backups_select on public.key_backups for select to authenticated using (owner_id = auth.uid());
create policy key_backups_insert on public.key_backups for insert to authenticated with check (owner_id = auth.uid());

-- No update or delete for clients. A stolen session must not be able to replace or erase the backup.
grant select, insert (owner_id, key_id, backup) on public.key_backups to authenticated;
