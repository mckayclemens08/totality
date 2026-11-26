-- Social activity for notifications (issue 232, issue 149 step 6). When an empty push wakes a phone, Social
-- asks here what's new for the signed-in person: new followers, follow requests, likes and comments on
-- their posts, reposts of their posts, and replies to their comments. Everything it returns is already readable to them through
-- the tables' own policies; this only gathers it in one call. It adds no table and keeps nothing.
-- People they blocked, who blocked them, or whom they muted are left out, and so is their own activity.
create function public.social_activity(p_since timestamptz, p_limit int default 50)
returns table (
  kind         text,
  id           uuid,
  handle       text,
  display_name text,
  post_id      uuid,
  post_snippet text,
  comment_id   uuid,
  snippet      text,
  at           timestamptz
)
language sql stable security invoker set search_path = '' as $$
  with me as (select auth.uid() as id),
  muted as (select m.muted_id from public.social_mutes m where m.owner_id = (select id from me)),
  events as (
    select case when f.approved then 'follower' else 'request' end as kind, f.id, f.owner_id as actor,
           null::uuid as post_id, null::uuid as comment_id, null::text as snippet, f.created_at as at
    from public.social_follows f
    where f.followee_id = (select id from me) and f.created_at > p_since
    union all
    select 'like', l.id, l.owner_id, l.post_id, null, null, l.created_at
    from public.social_likes l join public.social_posts p on p.id = l.post_id
    where p.owner_id = (select id from me) and l.created_at > p_since
    union all
    select 'repost', r.id, r.owner_id, r.post_id, null, null, r.created_at
    from public.social_reposts r join public.social_posts p on p.id = r.post_id
    where p.owner_id = (select id from me) and r.created_at > p_since
    union all
    select case when p.owner_id = (select id from me) then 'comment' else 'reply' end, c.id, c.owner_id,
           c.post_id, c.id, left(c.body, 140), c.created_at
    from public.social_comments c
    join public.social_posts p on p.id = c.post_id
    left join public.social_comments parent on parent.id = c.parent_id
    where c.created_at > p_since
      and (p.owner_id = (select id from me) or parent.owner_id = (select id from me))
  )
  select e.kind, e.id, pr.handle::text, pr.display_name, e.post_id,
         left(coalesce(sp.title, sp.body), 80), e.comment_id, e.snippet, e.at
  from events e
  join public.profiles pr on pr.id = e.actor
  left join public.social_posts sp on sp.id = e.post_id
  where (select id from me) is not null
    and e.actor <> (select id from me)
    and not private.social_hidden(e.actor)
    and e.actor not in (select muted_id from muted)
  order by e.at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;
revoke all on function public.social_activity(timestamptz, int) from public, anon;
grant execute on function public.social_activity(timestamptz, int) to authenticated;
