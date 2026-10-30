-- Other people's keys will become URLs once profiles can be viewed, so a key has to be exactly what
-- the app writes, not just anything that starts with the owner's folder.
alter table public.profiles drop constraint profiles_avatar_own_folder;
alter table public.profiles add constraint profiles_avatar_own_folder check (
  avatar_key is null
  or avatar_key ~ ('^' || id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$')
);
