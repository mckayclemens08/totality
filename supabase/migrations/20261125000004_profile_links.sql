-- Links on the public profile: up to 5, https only, shown under the bio. Public like the rest of the
-- profile, so not encrypted. The table keeps its owner (id), visibility, RLS and update policy; this adds
-- one column and lets the owner write it.
--
-- The check is the server's own validation, separate from the app's: a modified client can't store
-- javascript:, data:, http: or a link with a name and password in front of the host.

create function private.valid_profile_links(p_links text[])
returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select p_links is not null
    and coalesce(cardinality(p_links), 0) <= 5
    and not exists (
      select 1 from unnest(p_links) l
      where l is null
        or char_length(l) > 200
        or l !~* '^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?([/?#][^[:space:]<>"\\^`{|}]*)?$'
    );
$$;

grant execute on function private.valid_profile_links(text[]) to authenticated;

alter table public.profiles
  add column links text[] not null default '{}',
  add constraint profiles_links_valid check (private.valid_profile_links(links));

grant update (links) on public.profiles to authenticated;

-- Social's profile now carries the links. The result's shape changes, so the function is replaced and
-- its grant given again.
drop function public.social_profile(text);
create function public.social_profile(p_handle text)
returns table (
  id uuid, handle text, display_name text, bio text, avatar_key text,
  posts bigint, followers bigint, following bigint, i_follow boolean, follows_me boolean,
  requested boolean, private_account boolean, muted boolean, can_comment boolean, can_message boolean,
  links text[]
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
    p.links
  from public.profiles p
  left join public.social_settings st on st.owner_id = p.id
  cross join lateral private.social_follow_counts(p.id) c
  where p.handle = p_handle::extensions.citext and not private.social_hidden(p.id);
$$;
grant execute on function public.social_profile(text) to authenticated;
