-- Backgrounds are visible to signed-in Totality members, subject to blocks.
alter table public.profiles add column background_key text,
  add constraint profiles_background_own_key check (
    background_key is null or background_key ~ ('^' || id::text || '/[0-9a-f-]{36}[.]jpg$')
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-backgrounds', 'profile-backgrounds', false, 2097152, array['image/jpeg']);

create policy background_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'profile-backgrounds'
  and name ~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}[.]jpg$')
);

create policy background_read on storage.objects for select to authenticated using (
  bucket_id = 'profile-backgrounds'
  and storage.allow_only_operation('object.get_authenticated')
  and exists (
    select 1 from public.profiles p
    where p.background_key = storage.objects.name and not private.social_hidden(p.id)
  )
);

create policy background_delete_lookup on storage.objects for select to authenticated using (
  bucket_id = 'profile-backgrounds'
  and storage.allow_any_operation(array['object.delete', 'object.delete_many'])
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy background_delete on storage.objects for delete to authenticated using (
  bucket_id = 'profile-backgrounds' and (storage.foldername(name))[1] = auth.uid()::text
  and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.background_key = storage.objects.name)
);

-- Compare-and-swap so competing devices cannot clear or replace an unseen edit.
create function public.set_profile_background(p_previous text, p_next text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or (p_next is not null and not exists (
    select 1 from storage.objects o where o.bucket_id = 'profile-backgrounds'
      and o.name = p_next and o.owner_id = auth.uid()::text
  )) then
    return false;
  end if;
  update public.profiles set background_key = p_next
    where id = auth.uid() and background_key is not distinct from p_previous;
  return found;
end;
$$;
revoke all on function public.set_profile_background(text, text) from public, anon;
grant execute on function public.set_profile_background(text, text) to authenticated;

-- A moderator can clear the reported version using the service role. The image
-- immediately stops satisfying the download policy once its reference is gone.
create function public.clear_reported_profile_background(p_owner uuid, p_key text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set background_key = null where id = p_owner and background_key = p_key;
  return found;
end;
$$;
revoke all on function public.clear_reported_profile_background(uuid, text) from public, anon, authenticated;
grant execute on function public.clear_reported_profile_background(uuid, text) to service_role;

drop function public.social_profile(text);
create function public.social_profile(p_handle text)
returns table (
  id uuid, handle text, display_name text, bio text, avatar_key text,
  posts bigint, followers bigint, following bigint, i_follow boolean, follows_me boolean,
  requested boolean, private_account boolean, muted boolean, can_comment boolean, can_message boolean,
  links text[], background_key text
)
language sql stable security invoker set search_path = '' as $$
  select p.id, p.handle::text, p.display_name, p.bio, p.avatar_key,
    (select count(*) from public.social_posts s where s.owner_id = p.id),
    c.followers,
    c.following,
    exists (select 1 from public.social_follows f where f.owner_id = auth.uid() and f.followee_id = p.id and f.approved),
    exists (select 1 from public.social_follows f where f.owner_id = p.id and f.followee_id = auth.uid() and f.approved),
    exists (select 1 from public.social_follows f where f.owner_id = auth.uid() and f.followee_id = p.id and not f.approved),
    coalesce(st.private_account, false),
    exists (select 1 from public.social_mutes m where m.owner_id = auth.uid() and m.muted_id = p.id),
    private.social_reaches(p.id, coalesce(st.who_can_comment, 'anyone')),
    private.social_reaches(p.id, coalesce(st.who_can_message, 'anyone')),
    p.links, p.background_key
  from public.profiles p
  left join public.social_settings st on st.owner_id = p.id
  cross join lateral private.social_follow_counts(p.id) c
  where p.handle = p_handle::extensions.citext and not private.social_hidden(p.id);
$$;
grant execute on function public.social_profile(text) to authenticated;
