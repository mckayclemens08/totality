-- Social followers and following lists (owner, 2026-11-19; mockup F4k33Y2mGt94dkWjveMPa7).
--
-- 1. A private account's lists are hidden from non-followers. A follow row names two people, so it sits on
--    two lists: the follower's Following and the followee's Followers. It's readable by either person in
--    it, or else only when the reader may see BOTH accounts (`social_can_see`: their own, a public one,
--    or a private one they follow, approved). Blocks still hide everything. This is the table's own rule,
--    so it holds for direct reads, not only for the list call.
-- 2. Profile counts stay visible on a private profile (owner decision 2), so they're counted by a helper
--    that doesn't depend on that rule. They still leave out anyone hidden from you by a block.
-- 3. `social_people` returns each row's photo key, how you relate to them and whether you muted them, pages past 200 with a
--    (followed_at, handle) cursor, and searches the whole list on the server by the start of a username,
--    a name, or a word in the name.
--
-- Every other reader of social_follows was checked: the Following feed, For You's my_follows, friends and
-- follow requests read only the caller's own rows. For You's `near` loses only rows about private accounts
-- the caller can't see, whose posts it can't show anyway. social_follows_approved and the rate trigger
-- are security definer and don't go through this rule.

drop policy social_follows_select on public.social_follows;
create policy social_follows_select on public.social_follows for select to authenticated
  using (not private.social_hidden(owner_id) and not private.social_hidden(followee_id)
         and (owner_id = auth.uid() or followee_id = auth.uid()
              or (approved and private.social_can_see(owner_id) and private.social_can_see(followee_id))));

-- Approved followers and following, as numbers only, leaving out anyone a block hides from the caller.
create function private.social_follow_counts(p_person uuid, out followers bigint, out following bigint)
language sql stable security definer set search_path = '' as $$
  select
    (select count(*) from public.social_follows f
     where f.followee_id = p_person and f.approved and not private.social_hidden(f.owner_id)),
    (select count(*) from public.social_follows f
     where f.owner_id = p_person and f.approved and not private.social_hidden(f.followee_id));
$$;
revoke all on function private.social_follow_counts(uuid) from public, anon;
grant execute on function private.social_follow_counts(uuid) to authenticated;

create or replace function public.social_profile(p_handle text)
returns table (
  id uuid, handle text, display_name text, bio text, avatar_key text,
  posts bigint, followers bigint, following bigint, i_follow boolean, follows_me boolean,
  requested boolean, private_account boolean, muted boolean, can_comment boolean, can_message boolean
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
    private.social_reaches(p.id, coalesce(st.who_can_message, 'anyone'))
  from public.profiles p
  left join public.social_settings st on st.owner_id = p.id
  cross join lateral private.social_follow_counts(p.id) c
  where p.handle = p_handle::extensions.citext and not private.social_hidden(p.id);
$$;

-- Newest first. For the next page, pass the last row's followed_at and handle. The search is a prefix of
-- the username (an @ in front is fine), of the name, or of any word in the name, case ignored.
drop function public.social_people(text, boolean, int);
create function public.social_people(
  p_handle text, p_followers boolean, p_query text default null,
  p_before_at timestamptz default null, p_before_handle text default null, p_limit int default 50
)
returns table (
  id uuid, handle text, display_name text, avatar_key text, followed_at timestamptz,
  i_follow boolean, follows_me boolean, requested boolean, muted boolean
)
language sql stable security invoker set search_path = '' as $$
  with pattern as (
    select replace(replace(replace(lower(nullif(ltrim(btrim(coalesce(p_query, '')), '@'), '')),
                                   '\', '\\'), '%', '\%'), '_', '\_') as p
  )
  select other.id, other.handle::text, other.display_name, other.avatar_key, f.created_at,
    exists (select 1 from public.social_follows x where x.owner_id = auth.uid() and x.followee_id = other.id and x.approved),
    exists (select 1 from public.social_follows x where x.owner_id = other.id and x.followee_id = auth.uid() and x.approved),
    exists (select 1 from public.social_follows x where x.owner_id = auth.uid() and x.followee_id = other.id and not x.approved),
    exists (select 1 from public.social_mutes m where m.owner_id = auth.uid() and m.muted_id = other.id)
  from public.profiles them
  join public.social_follows f
    on f.approved and case when p_followers then f.followee_id = them.id else f.owner_id = them.id end
  join public.profiles other on other.id = case when p_followers then f.owner_id else f.followee_id end
  cross join pattern
  where them.handle = p_handle::extensions.citext
    and (pattern.p is null
         or lower(other.handle::text) like pattern.p || '%'
         or lower(coalesce(other.display_name, '')) like pattern.p || '%'
         or lower(coalesce(other.display_name, '')) like '% ' || pattern.p || '%')
    and (p_before_at is null
         or (f.created_at, other.handle::text) < (p_before_at, coalesce(p_before_handle, '')))
  order by f.created_at desc, other.handle::text desc
  limit least(greatest(p_limit, 1), 200);
$$;
grant execute on function public.social_people(text, boolean, text, timestamptz, text, int) to authenticated;
