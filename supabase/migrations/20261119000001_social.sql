-- Social, native (issue 149; owner, 2026-11-17: "Native now, maybe later"). Proposal §3.3.
--
-- Only PUBLIC social content lives here: public posts, their likes and comments, and who follows whom.
-- Every one of these tables is pinned to visibility = 'public' by a check constraint, which is what lets it
-- hold readable text (the schema check allows plaintext only where a table can never hold anything else).
-- Friends and Close-friends posts, and their likes and replies, never come here: they travel in end-to-end
-- encrypted Matrix rooms.
--
-- Blocks reuse contacts.state = 'blocked'. Someone you blocked, or who blocked you, sees none of your
-- posts, likes, comments or follows, and you see none of theirs.

-- helpers -------------------------------------------------------------
-- Neither side of a block sees the other. Kept in private, like the other block helpers, so PostgREST
-- can't be asked whether someone blocked you.
create function private.social_hidden(p_other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_other <> auth.uid() and (private.is_blocked_by(p_other) or private.has_blocked(p_other));
$$;
revoke all on function private.social_hidden(uuid) from public, anon;
grant execute on function private.social_hidden(uuid) to authenticated;

-- A tag is lower-case letters, digits and underscores, as typed after a # (issue 149: tags, no categories).
create function private.social_tags_valid(p_tags text[]) returns boolean
language sql immutable set search_path = '' as $$
  select cardinality(p_tags) <= 10
     and array_position(p_tags, null) is null
     and coalesce(bool_and(t ~ '^[a-z0-9_]{1,30}$'), true)
     and cardinality(p_tags) = (select count(distinct t) from unnest(p_tags) t)
  from unnest(p_tags) t;
$$;
revoke all on function private.social_tags_valid(text[]) from public, anon;
grant execute on function private.social_tags_valid(text[]) to authenticated;

-- follows -------------------------------------------------------------
-- owner_id follows followee_id. Follower lists are public, as on the profile screen.
create table public.social_follows (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  followee_id uuid not null references auth.users(id) on delete cascade,
  visibility  public.visibility_t not null default 'public' check (visibility = 'public'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (owner_id, followee_id),
  check (owner_id <> followee_id)
);
create index social_follows_followee on public.social_follows (followee_id);

-- posts ---------------------------------------------------------------
create table public.social_posts (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  visibility  public.visibility_t not null default 'public' check (visibility = 'public'),
  title       text check (title is null or char_length(title) between 1 and 120),
  body        text not null default '' check (char_length(body) <= 5000),
  tags        text[] not null default '{}' check (private.social_tags_valid(tags)),
  edited_at   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (char_length(btrim(coalesce(title, '') || body)) > 0)
);
create index social_posts_owner on public.social_posts (owner_id, created_at desc);
create index social_posts_recent on public.social_posts (created_at desc);
create index social_posts_tags on public.social_posts using gin (tags);

-- likes ---------------------------------------------------------------
create table public.social_likes (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  post_id     uuid not null references public.social_posts(id) on delete cascade,
  visibility  public.visibility_t not null default 'public' check (visibility = 'public'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (owner_id, post_id)
);
create index social_likes_post on public.social_likes (post_id);

-- comments ------------------------------------------------------------
-- A reply to a comment sits under it, one level deep, as in the mockup.
create table public.social_comments (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  post_id     uuid not null references public.social_posts(id) on delete cascade,
  parent_id   uuid references public.social_comments(id) on delete cascade,
  visibility  public.visibility_t not null default 'public' check (visibility = 'public'),
  body        text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index social_comments_post on public.social_comments (post_id, created_at);

-- A reply must be to a comment on the same post, and to a top-level one.
create function private.social_comment_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_parent public.social_comments;
begin
  if new.parent_id is not null then
    select * into v_parent from public.social_comments where id = new.parent_id;
    if not found or v_parent.post_id <> new.post_id or v_parent.parent_id is not null then
      raise exception 'that reply is not to a comment on this post' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.social_comment_guard() from public, anon, authenticated;
create trigger social_comment_guard before insert on public.social_comments
  for each row execute function private.social_comment_guard();

-- seen ----------------------------------------------------------------
-- What For You has already shown this person, so it never shows a post twice, and what they said
-- "Not interested" to. Only they can read it. It names public posts, so it holds no private content,
-- but it is a reading history, so it is private.
create table public.social_seen (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  post_id        uuid not null references public.social_posts(id) on delete cascade,
  visibility     public.visibility_t not null default 'private' check (visibility = 'private'),
  not_interested boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (owner_id, post_id)
);

-- Edits are marked, so a post edited after people liked it says so.
create function private.social_post_edited() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if new.title is distinct from old.title or new.body is distinct from old.body or new.tags is distinct from old.tags then
    new.edited_at := now();
  end if;
  return new;
end $$;
revoke all on function private.social_post_edited() from public, anon, authenticated;
create trigger social_post_edited before update on public.social_posts
  for each row execute function private.social_post_edited();
create trigger touch_social_seen before update on public.social_seen
  for each row execute function public.touch_updated_at();

-- Keeps one account from flooding the server: 60 posts and 600 comments an hour, 2,000 follows a day.
create function private.social_rate_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  if tg_table_name = 'social_posts' then
    select count(*) into v_count from public.social_posts
      where owner_id = new.owner_id and created_at > now() - interval '1 hour';
    if v_count >= 60 then raise exception 'too many posts in an hour' using errcode = 'P0001'; end if;
  elsif tg_table_name = 'social_comments' then
    select count(*) into v_count from public.social_comments
      where owner_id = new.owner_id and created_at > now() - interval '1 hour';
    if v_count >= 600 then raise exception 'too many comments in an hour' using errcode = 'P0001'; end if;
  elsif tg_table_name = 'social_follows' then
    select count(*) into v_count from public.social_follows
      where owner_id = new.owner_id and created_at > now() - interval '1 day';
    if v_count >= 2000 then raise exception 'too many follows in a day' using errcode = 'P0001'; end if;
  end if;
  return new;
end $$;
revoke all on function private.social_rate_limit() from public, anon, authenticated;
create trigger social_posts_rate before insert on public.social_posts
  for each row execute function private.social_rate_limit();
create trigger social_comments_rate before insert on public.social_comments
  for each row execute function private.social_rate_limit();
create trigger social_follows_rate before insert on public.social_follows
  for each row execute function private.social_rate_limit();

-- row level security --------------------------------------------------
alter table public.social_follows  enable row level security;
alter table public.social_posts    enable row level security;
alter table public.social_likes    enable row level security;
alter table public.social_comments enable row level security;
alter table public.social_seen     enable row level security;

create policy social_follows_select on public.social_follows for select to authenticated
  using (not private.social_hidden(owner_id) and not private.social_hidden(followee_id));
-- Following goes through social_follow, which hides a block; the table takes no direct inserts.
create policy social_follows_delete on public.social_follows for delete to authenticated
  using (owner_id = auth.uid());

create policy social_posts_select on public.social_posts for select to authenticated
  using (not private.social_hidden(owner_id));
create policy social_posts_insert on public.social_posts for insert to authenticated
  with check (owner_id = auth.uid());
create policy social_posts_update on public.social_posts for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy social_posts_delete on public.social_posts for delete to authenticated
  using (owner_id = auth.uid());

-- The subqueries on social_posts run as the caller, so a post you can't see can't be liked or read through.
create policy social_likes_select on public.social_likes for select to authenticated
  using (not private.social_hidden(owner_id)
         and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_likes_insert on public.social_likes for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_likes_delete on public.social_likes for delete to authenticated
  using (owner_id = auth.uid());

create policy social_comments_select on public.social_comments for select to authenticated
  using (not private.social_hidden(owner_id)
         and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_comments_insert on public.social_comments for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.social_posts p where p.id = post_id));
-- Your own comment, or any comment on your own post.
create policy social_comments_delete on public.social_comments for delete to authenticated
  using (owner_id = auth.uid()
         or exists (select 1 from public.social_posts p where p.id = post_id and p.owner_id = auth.uid()));

create policy social_seen_select on public.social_seen for select to authenticated using (owner_id = auth.uid());
create policy social_seen_insert on public.social_seen for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_seen_update on public.social_seen for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy social_seen_delete on public.social_seen for delete to authenticated using (owner_id = auth.uid());

-- privileges ----------------------------------------------------------
-- owner_id defaults to the caller and isn't granted, so nobody can post, like or comment as someone else.
grant select, delete on public.social_follows to authenticated;
grant select, delete on public.social_posts to authenticated;
grant insert (title, body, tags) on public.social_posts to authenticated;
grant update (title, body, tags) on public.social_posts to authenticated;
grant select, delete on public.social_likes to authenticated;
grant insert (post_id) on public.social_likes to authenticated;
grant select, delete on public.social_comments to authenticated;
grant insert (post_id, parent_id, body) on public.social_comments to authenticated;
grant select, delete on public.social_seen to authenticated;
grant insert (post_id, not_interested) on public.social_seen to authenticated;
grant update (not_interested) on public.social_seen to authenticated;

-- functions -----------------------------------------------------------
-- Everything below except social_follow runs as the caller, so the policies above decide what it sees.

-- Follows someone by handle. Following someone who blocked you looks the same as following anyone, and
-- nothing is stored, so a block is never revealed.
create function public.social_follow(p_handle text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_them uuid;
begin
  if v_me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select id into v_them from public.profiles where handle = p_handle::extensions.citext;
  if v_them is null then raise exception 'no such user' using errcode = 'P0002'; end if;
  if v_them = v_me then raise exception 'you can''t follow yourself' using errcode = '22023'; end if;
  if exists (select 1 from public.contacts where owner_id = v_them and peer_id = v_me and state = 'blocked')
     or exists (select 1 from public.contacts where owner_id = v_me and peer_id = v_them and state = 'blocked') then
    return;
  end if;
  insert into public.social_follows (owner_id, followee_id) values (v_me, v_them)
  on conflict (owner_id, followee_id) do nothing;
end $$;

create function public.social_unfollow(p_handle text) returns void
language sql security invoker set search_path = '' as $$
  delete from public.social_follows f
  using public.profiles p
  where p.handle = p_handle::extensions.citext and f.followee_id = p.id and f.owner_id = auth.uid();
$$;

-- One person's profile as Social shows it: the public profile plus counts and how you're connected.
create function public.social_profile(p_handle text)
returns table (
  id uuid, handle text, display_name text, bio text, avatar_key text,
  posts bigint, followers bigint, following bigint, i_follow boolean, follows_me boolean
)
language sql stable security invoker set search_path = '' as $$
  select p.id, p.handle::text, p.display_name, p.bio, p.avatar_key,
    (select count(*) from public.social_posts s where s.owner_id = p.id),
    (select count(*) from public.social_follows f where f.followee_id = p.id),
    (select count(*) from public.social_follows f where f.owner_id = p.id),
    exists (select 1 from public.social_follows f where f.owner_id = auth.uid() and f.followee_id = p.id),
    exists (select 1 from public.social_follows f where f.owner_id = p.id and f.followee_id = auth.uid())
  from public.profiles p
  where p.handle = p_handle::extensions.citext and not private.social_hidden(p.id);
$$;

-- The handles of people you follow who follow you back: your Friends, who may read your Friends posts.
-- The device keeps your Friends room's members to this list.
create function public.social_friends()
returns table (handle text)
language sql stable security invoker set search_path = '' as $$
  select p.handle::text
  from public.social_follows mine
  join public.social_follows theirs on theirs.owner_id = mine.followee_id and theirs.followee_id = mine.owner_id
  join public.profiles p on p.id = mine.followee_id
  where mine.owner_id = auth.uid()
  order by 1;
$$;

-- Who follows a person, or whom they follow, newest first.
create function public.social_people(p_handle text, p_followers boolean, p_limit int default 100)
returns table (handle text, display_name text, followed_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select other.handle::text, other.display_name, f.created_at
  from public.profiles them
  join public.social_follows f on (p_followers and f.followee_id = them.id) or (not p_followers and f.owner_id = them.id)
  join public.profiles other on other.id = case when p_followers then f.owner_id else f.followee_id end
  where them.handle = p_handle::extensions.citext
  order by f.created_at desc
  limit least(greatest(p_limit, 1), 200);
$$;

-- A post as every feed returns it. The reason is For You's "Why am I seeing this?" line, and empty elsewhere.
create type public.social_post_row as (
  id uuid, author_id uuid, handle text, display_name text, avatar_key text,
  title text, body text, tags text[], created_at timestamptz, edited_at timestamptz,
  likes bigint, comments bigint, liked boolean, reason text
);

create function private.social_rows(p_posts uuid[]) returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select s.id, s.owner_id, p.handle::text, p.display_name, p.avatar_key,
    s.title, s.body, s.tags, s.created_at, s.edited_at,
    (select count(*) from public.social_likes l where l.post_id = s.id),
    (select count(*) from public.social_comments c where c.post_id = s.id),
    exists (select 1 from public.social_likes l where l.post_id = s.id and l.owner_id = auth.uid()),
    ''::text
  from public.social_posts s
  join public.profiles p on p.id = s.owner_id
  where s.id = any (p_posts);
$$;
revoke all on function private.social_rows(uuid[]) from public, anon;
grant execute on function private.social_rows(uuid[]) to authenticated;

-- Following: your public posts and those of everyone you follow, newest first. Friends and Close-friends
-- posts come from Matrix and are merged in on the device.
create function public.social_following_feed(p_before timestamptz default null, p_limit int default 30)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select r.* from private.social_rows(array(
    select s.id from public.social_posts s
    where (s.owner_id = auth.uid()
           or s.owner_id in (select f.followee_id from public.social_follows f where f.owner_id = auth.uid()))
      and (p_before is null or s.created_at < p_before)
    order by s.created_at desc
    limit least(greatest(p_limit, 1), 100)
  )) r
  order by r.created_at desc;
$$;

-- One person's public posts, newest first.
create function public.social_posts_by(p_handle text, p_before timestamptz default null, p_limit int default 30)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select r.* from private.social_rows(array(
    select s.id from public.social_posts s join public.profiles p on p.id = s.owner_id
    where p.handle = p_handle::extensions.citext and (p_before is null or s.created_at < p_before)
    order by s.created_at desc
    limit least(greatest(p_limit, 1), 100)
  )) r
  order by r.created_at desc;
$$;

create function public.social_post(p_id uuid)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select * from private.social_rows(array[p_id]);
$$;

-- A post's comments, oldest first, with replies after the comment they answer.
create function public.social_comments_of(p_post uuid)
returns table (id uuid, parent_id uuid, author_id uuid, handle text, display_name text, body text, created_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select c.id, c.parent_id, c.owner_id, p.handle::text, p.display_name, c.body, c.created_at
  from public.social_comments c
  join public.profiles p on p.id = c.owner_id
  left join public.social_comments parent on parent.id = c.parent_id
  where c.post_id = p_post
  order by coalesce(parent.created_at, c.created_at), c.parent_id nulls first, c.created_at
  limit 500;
$$;

-- For You (issue 149 §5): Totality's own ranking, reading public posts only, and only what you do inside
-- Social. It's simple and explainable on purpose:
--   newer posts first; likes and comments count up; posts from people your follows follow count up;
--   tags you've liked count up, and tags of posts you said Not interested to count down;
--   never your own posts, and never a post you've already been shown.
-- The reason says which signal put the post there.
create function public.social_for_you(p_limit int default 30, p_tag text default null)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  with me as (select auth.uid() as id),
  my_follows as (select f.followee_id as id from public.social_follows f, me where f.owner_id = me.id),
  near as (
    select f.followee_id as id, min(p.handle::text) as via
    from public.social_follows f join public.profiles p on p.id = f.owner_id
    where f.owner_id in (select id from my_follows)
    group by f.followee_id
  ),
  liked_tags as (
    select t as tag, count(*) as n
    from (select s.tags from public.social_likes l join public.social_posts s on s.id = l.post_id, me
          where l.owner_id = me.id order by l.created_at desc limit 200) recent, unnest(recent.tags) t
    group by t
  ),
  disliked_tags as (
    select distinct t as tag
    from public.social_seen n join public.social_posts s on s.id = n.post_id, me, unnest(s.tags) t
    where n.owner_id = me.id and n.not_interested
  ),
  candidates as (
    select s.id, s.owner_id, s.tags, s.created_at,
      (select count(*) from public.social_likes l where l.post_id = s.id) as likes,
      (select count(*) from public.social_comments c where c.post_id = s.id) as comments
    from public.social_posts s, me
    where s.owner_id <> me.id
      and s.created_at > now() - interval '30 days'
      and (p_tag is null or p_tag = any (s.tags))
      and not exists (select 1 from public.social_seen n where n.owner_id = me.id and n.post_id = s.id)
  ),
  scored as (
    select c.*,
      (select lt.tag from liked_tags lt where lt.tag = any (c.tags) order by lt.n desc, lt.tag limit 1) as top_tag,
      (select coalesce(sum(lt.n), 0) from liked_tags lt where lt.tag = any (c.tags)) as affinity,
      exists (select 1 from disliked_tags d where d.tag = any (c.tags)) as disliked,
      n.via,
      ln(1 + c.likes + 2 * c.comments) as engagement,
      extract(epoch from now() - c.created_at) / 3600.0 as age_hours
    from candidates c left join near n on n.id = c.owner_id
  ),
  ranked as (
    select s.*,
      (1 + s.engagement)
        * (case when s.via is not null then 1.5 else 1 end)
        * (1 + 0.3 * ln(1 + s.affinity))
        * (case when s.disliked then 0.2 else 1 end)
        / power(s.age_hours + 2, 1.3) as score
    from scored s
  ),
  picked as (
    select r.*,
      case
        when r.top_tag is not null then 'You liked posts tagged #' || r.top_tag || '.'
        when r.via is not null then 'People you follow follow them, like @' || r.via || '.'
        when r.likes + r.comments >= 10 then 'Lots of people liked this.'
        else 'New on Totality.'
      end as why
    from ranked r
    order by r.score desc, r.created_at desc, r.id
    limit least(greatest(p_limit, 1), 60)
  )
  select row.id, row.author_id, row.handle, row.display_name, row.avatar_key, row.title, row.body, row.tags,
         row.created_at, row.edited_at, row.likes, row.comments, row.liked, picked.why
  from picked, lateral private.social_rows(array[picked.id]) row
  order by picked.score desc, picked.created_at desc, picked.id;
$$;

-- Marks posts as shown, so For You won't show them again. Not interested also turns their tags down.
create function public.social_mark_seen(p_posts uuid[], p_not_interested boolean default false) returns void
language sql security invoker set search_path = '' as $$
  insert into public.social_seen (post_id, not_interested)
  select s.id, p_not_interested from public.social_posts s where s.id = any (p_posts[1:200])
  on conflict (owner_id, post_id) do update
    set not_interested = public.social_seen.not_interested or excluded.not_interested;
$$;

-- Tags in use lately, most used first, for the chips above For You.
create function public.social_top_tags(p_limit int default 12)
returns table (tag text, posts bigint)
language sql stable security invoker set search_path = '' as $$
  select t, count(*) from public.social_posts s, unnest(s.tags) t
  where s.created_at > now() - interval '30 days'
  group by t order by count(*) desc, t
  limit least(greatest(p_limit, 1), 30);
$$;

-- Search: people by handle or name, and public posts by tag or words.
create function public.social_search_people(p_query text, p_limit int default 20)
returns table (handle text, display_name text)
language sql stable security invoker set search_path = '' as $$
  select p.handle::text, p.display_name from public.profiles p
  where char_length(btrim(p_query)) > 0 and not private.social_hidden(p.id)
    and (p.handle::text ilike '%' || replace(replace(btrim(lower(p_query)), '%', ''), '_', '\_') || '%'
         or p.display_name ilike '%' || replace(replace(btrim(p_query), '%', ''), '_', '\_') || '%')
  order by (p.handle::text = lower(btrim(p_query))) desc, p.handle
  limit least(greatest(p_limit, 1), 50);
$$;

grant execute on function public.social_follow(text) to authenticated;
grant execute on function public.social_unfollow(text) to authenticated;
grant execute on function public.social_profile(text) to authenticated;
grant execute on function public.social_friends() to authenticated;
grant execute on function public.social_people(text, boolean, int) to authenticated;
grant execute on function public.social_following_feed(timestamptz, int) to authenticated;
grant execute on function public.social_posts_by(text, timestamptz, int) to authenticated;
grant execute on function public.social_post(uuid) to authenticated;
grant execute on function public.social_comments_of(uuid) to authenticated;
grant execute on function public.social_for_you(int, text) to authenticated;
grant execute on function public.social_mark_seen(uuid[], boolean) to authenticated;
grant execute on function public.social_top_tags(int) to authenticated;
grant execute on function public.social_search_people(text, int) to authenticated;

-- Export includes Social. Redefined here with every earlier key kept.
create or replace function public.export_my_data() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'profile',  (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'devices',  (select coalesce(jsonb_agg(d), '[]') from public.devices d where d.owner_id = auth.uid()),
    'contacts', (select coalesce(jsonb_agg(c), '[]') from public.contacts c where c.owner_id = auth.uid()),
    'content',  (select coalesce(jsonb_agg(o), '[]') from public.content_objects o where o.owner_id = auth.uid()),
    'shares',   (select coalesce(jsonb_agg(s), '[]') from public.content_shares s where s.owner_id = auth.uid()),
    'invites',  (select coalesce(jsonb_agg(i), '[]') from public.invites i where i.owner_id = auth.uid()),
    'notifications', (select coalesce(jsonb_agg(n), '[]') from public.notifications n where n.owner_id = auth.uid()),
    'reports',  (select coalesce(jsonb_agg(r), '[]') from public.reports r where r.owner_id = auth.uid()),
    'ai_grants',(select coalesce(jsonb_agg(g), '[]') from public.ai_grants g where g.owner_id = auth.uid()),
    'audit_log',(select coalesce(jsonb_agg(a), '[]') from public.audit_log a where a.actor_id = auth.uid()),
    'social_posts',    (select coalesce(jsonb_agg(x), '[]') from public.social_posts x where x.owner_id = auth.uid()),
    'social_follows',  (select coalesce(jsonb_agg(x), '[]') from public.social_follows x where x.owner_id = auth.uid()),
    'social_likes',    (select coalesce(jsonb_agg(x), '[]') from public.social_likes x where x.owner_id = auth.uid()),
    'social_comments', (select coalesce(jsonb_agg(x), '[]') from public.social_comments x where x.owner_id = auth.uid()),
    'social_seen',     (select coalesce(jsonb_agg(x), '[]') from public.social_seen x where x.owner_id = auth.uid())
  );
$$;
