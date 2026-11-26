-- Social reposts. A repost shows someone else's PUBLIC post to your followers, "reposted by you" above it.
--
-- Only public posts can be reposted: social_posts is itself pinned to visibility = 'public', and a repost row
-- points at one of those, so a Friends or Close-friends post (which lives only in an encrypted Matrix room)
-- can't be reposted and never leaves its audience. A private account's posts can't be reposted either, since
-- that would hand them to people the account never let in. Quote reposts (your own text on top) are not in
-- this version, so the table holds no text at all.
--
-- A repost is public, like a like or a follow. Undo is a delete of your own row.

create table public.social_reposts (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  post_id    uuid not null references public.social_posts(id) on delete cascade,
  visibility public.visibility_t not null default 'public' check (visibility = 'public'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, post_id)
);
create index social_reposts_post on public.social_reposts (post_id);
create index social_reposts_owner on public.social_reposts (owner_id, created_at desc);

-- Whether the caller may repost this post: it is someone else's, public (the table only holds those), the
-- caller can read it, and its author isn't a private account.
create function private.social_may_repost(p_post uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.social_posts s
    where s.id = p_post
      and s.owner_id <> auth.uid()
      and private.social_can_see(s.owner_id)
      and not private.social_is_private(s.owner_id)
  );
$$;
revoke all on function private.social_may_repost(uuid) from public, anon;
grant execute on function private.social_may_repost(uuid) to authenticated;

-- 300 reposts an hour per account, so one account can't flood everyone's Following.
create function private.social_repost_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.social_reposts
      where owner_id = new.owner_id and created_at > now() - interval '1 hour') >= 300 then
    raise exception 'too many reposts in an hour' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function private.social_repost_rate() from public, anon, authenticated;
create trigger social_reposts_rate before insert on public.social_reposts
  for each row execute function private.social_repost_rate();
create trigger touch_social_reposts before update on public.social_reposts
  for each row execute function public.touch_updated_at();

alter table public.social_reposts enable row level security;

-- You see a repost when you could see the reposter's posts and the post itself.
create policy social_reposts_select on public.social_reposts for select to authenticated
  using (private.social_can_see(owner_id)
         and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_reposts_insert on public.social_reposts for insert to authenticated
  with check (owner_id = auth.uid() and private.social_may_repost(post_id));
create policy social_reposts_update on public.social_reposts for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy social_reposts_delete on public.social_reposts for delete to authenticated
  using (owner_id = auth.uid());

-- owner_id defaults to the caller and isn't granted, so nobody can repost as someone else.
grant select, delete on public.social_reposts to authenticated;
grant insert (post_id) on public.social_reposts to authenticated;

-- How many times posts were reposted, and whether the caller did. Runs as the caller, so the policy above
-- decides which reposts are counted.
create function public.social_repost_stats(p_posts uuid[])
returns table (post_id uuid, reposts bigint, reposted boolean)
language sql stable security invoker set search_path = '' as $$
  select s.id,
    (select count(*) from public.social_reposts r where r.post_id = s.id),
    exists (select 1 from public.social_reposts r where r.post_id = s.id and r.owner_id = auth.uid())
  from public.social_posts s
  where s.id = any (p_posts);
$$;

-- Reposts in Following: yours and those of people you follow (approved, not muted), newest repost first.
-- The post comes back as the feed rows do, inside `post`.
create function public.social_reposts_feed(p_before timestamptz default null, p_limit int default 30)
returns table (reposter_handle text, reposter_name text, reposted_at timestamptz, post jsonb)
language sql stable security invoker set search_path = '' as $$
  select pr.handle::text, pr.display_name, picked.created_at, to_jsonb(row)
  from (
    select r.owner_id, r.post_id, r.created_at from public.social_reposts r
    where (r.owner_id = auth.uid()
           or r.owner_id in (select f.followee_id from public.social_follows f where f.owner_id = auth.uid() and f.approved))
      and r.owner_id not in (select m.muted_id from public.social_mutes m where m.owner_id = auth.uid())
      and (p_before is null or r.created_at < p_before)
    order by r.created_at desc
    limit least(greatest(p_limit, 1), 100)
  ) picked
  join public.profiles pr on pr.id = picked.owner_id,
  lateral private.social_rows(array[picked.post_id]) row
  order by picked.created_at desc;
$$;

-- One person's reposts, newest first, for their profile.
create function public.social_reposts_by(p_handle text, p_before timestamptz default null, p_limit int default 30)
returns table (reposter_handle text, reposter_name text, reposted_at timestamptz, post jsonb)
language sql stable security invoker set search_path = '' as $$
  select pr.handle::text, pr.display_name, picked.created_at, to_jsonb(row)
  from (
    select r.owner_id, r.post_id, r.created_at from public.social_reposts r
    join public.profiles x on x.id = r.owner_id
    where x.handle = p_handle::extensions.citext
      and (p_before is null or r.created_at < p_before)
    order by r.created_at desc
    limit least(greatest(p_limit, 1), 100)
  ) picked
  join public.profiles pr on pr.id = picked.owner_id,
  lateral private.social_rows(array[picked.post_id]) row
  order by picked.created_at desc;
$$;

revoke all on function public.social_repost_stats(uuid[]), public.social_reposts_feed(timestamptz, int),
  public.social_reposts_by(text, timestamptz, int) from public, anon;
grant execute on function public.social_repost_stats(uuid[]), public.social_reposts_feed(timestamptz, int),
  public.social_reposts_by(text, timestamptz, int) to authenticated;
