-- Profiles exist before a domain does. A Matrix address can't be renamed, so it stays empty until the
-- owner sets the server name, rather than holding a placeholder that would have to change. Setting
-- the name has to fill in every empty row. See proposal §11-L.
alter table public.profiles alter column mxid drop not null;

alter table public.profiles
  add constraint profiles_display_name_length check (char_length(display_name) <= 50),
  add constraint profiles_bio_length check (char_length(bio) <= 160),
  add constraint profiles_avatar_own_folder check (avatar_key is null or avatar_key like id::text || '/%');

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
  if (select email from auth.users where id = auth.uid()) is distinct from lower(p_handle) || '@totality.invalid' then
    raise exception 'a handle must match your username' using errcode = '42501';
  end if;
  select matrix_server_name into v_server from public.instance_config;
  insert into public.profiles (id, handle, display_name, mxid)
  values (auth.uid(), p_handle, p_display_name, '@' || lower(p_handle) || ':' || v_server)
  returning * into v_row;
  return v_row;
end $$;

-- storage -------------------------------------------------------------
-- Profile photos are public by design, so they are the one thing in Storage that isn't ciphertext.
-- Objects live at <owner_id>/<uuid>.jpg. The select policy is only there because Storage needs it to
-- delete. Anyone can fetch a photo through its public URL.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg']);

create policy avatar_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
create policy avatar_select on storage.objects for select to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
create policy avatar_delete on storage.objects for delete to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
