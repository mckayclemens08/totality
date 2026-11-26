-- Tags above For You: only tags that are really in use. A tag needs at least 3 posts from at least
-- 2 different people in the last 30 days, and at most 8 show, most used first, then most recent.
create or replace function public.social_top_tags(p_limit int default 8)
returns table (tag text, posts bigint)
language sql stable security invoker set search_path = '' as $$
  select t, count(*) from public.social_posts s, unnest(s.tags) t
  where s.created_at > now() - interval '30 days'
  group by t
  having count(*) >= 3 and count(distinct s.owner_id) >= 2
  order by count(*) desc, max(s.created_at) desc, t
  limit least(greatest(p_limit, 1), 8);
$$;
