-- Social step 4 (issue 149): video posts and stories.
--
-- Video: a post may now carry one video with one photo, its poster frame, taken on the phone. Videos are
-- capped at three minutes (owner, 2026-11-17) and made small on the phone before upload; the file lives on
-- Totality's own server like every other post's media.
--
-- Stories: a photo, a video or text that vanishes after 24 hours (owner, 2026-11-17). Only PUBLIC stories
-- live here, pinned to visibility = 'public' like public posts, which is what lets them hold readable text.
-- Friends and Close-friends stories travel in the author's end-to-end encrypted Matrix room, as their posts
-- do, and never come here. Expired rows are deleted: on every new story, and every fifteen minutes by
-- pg_cron where the database has it. Until then, an expired row is never readable.
--
-- Who viewed a story is listed for its author only (owner, 2026-11-17). Views of any story, public or
-- encrypted, are kept in social_story_views, which only the viewer and the author can read, and they're
-- deleted with the story's day. For an encrypted story the row says that someone opened one of the
-- author's stories, and when; never what was in it.

-- video in posts ---------------------------------------------------------
create or replace function private.social_media_valid(p_media jsonb, p_owner uuid) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_media) = 'array'
    and jsonb_array_length(p_media) <= 4
    and not exists (
      select 1 from jsonb_array_elements(p_media) e(item)
      where not (
        jsonb_typeof(e.item) = 'object'
        and e.item->>'kind' in ('photo', 'audio', 'video')
        and coalesce(e.item->>'path', '') ~ ('^' || p_owner::text || '/[0-9a-f-]{36}$')
        and jsonb_typeof(e.item->'size') = 'number'
        and not (e.item ? 'key')
        and (e.item->'store' is null or e.item->'store' = '"totality"'::jsonb)
        and (e.item->'width' is null or jsonb_typeof(e.item->'width') = 'number')
        and (e.item->'height' is null or jsonb_typeof(e.item->'height') = 'number')
        and (e.item->'duration' is null or jsonb_typeof(e.item->'duration') = 'number')
        -- A video is on Totality's server and says how long it is: three minutes at most.
        and (e.item->>'kind' <> 'video' or (coalesce(e.item->'store' = '"totality"'::jsonb, false)
             and case when jsonb_typeof(e.item->'duration') = 'number' then (e.item->>'duration')::numeric <= 181 else false end))
      )
    )
    -- One audio clip on its own, or one video with at most its poster photo, or up to four photos.
    and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'audio')
        in (0, case when jsonb_array_length(p_media) = 1 then 1 else 0 end)
    and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'video')
        in (0, case when jsonb_array_length(p_media) <= 2 then 1 else 0 end);
$$;

-- stories ----------------------------------------------------------------
-- A story's media: a photo story holds one photo; a video story one video and its poster photo; a text
-- story nothing. Each on Totality's server's story shelf, whose files go after a day, in the author's own
-- folder, never with a key.
create function private.social_story_media_valid(p_kind text, p_media jsonb, p_owner uuid) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_media) = 'array'
    and not exists (
      select 1 from jsonb_array_elements(p_media) e(item)
      where not (
        jsonb_typeof(e.item) = 'object'
        and e.item->>'kind' in ('photo', 'video')
        and coalesce(e.item->>'path', '') ~ ('^' || p_owner::text || '/[0-9a-f-]{36}$')
        and jsonb_typeof(e.item->'size') = 'number'
        and not (e.item ? 'key')
        and coalesce(e.item->'store' = '"stories"'::jsonb, false)
        and (e.item->'width' is null or jsonb_typeof(e.item->'width') = 'number')
        and (e.item->'height' is null or jsonb_typeof(e.item->'height') = 'number')
        and (e.item->>'kind' <> 'video'
             or case when jsonb_typeof(e.item->'duration') = 'number' then (e.item->>'duration')::numeric <= 181 else false end)
      )
    )
    and case p_kind
      when 'text' then jsonb_array_length(p_media) = 0
      when 'photo' then jsonb_array_length(p_media) = 1 and p_media->0->>'kind' = 'photo'
      when 'video' then jsonb_array_length(p_media) = 2
        and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'video') = 1
        and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'photo') = 1
      else false
    end;
$$;
revoke all on function private.social_story_media_valid(text, jsonb, uuid) from public, anon;
grant execute on function private.social_story_media_valid(text, jsonb, uuid) to authenticated;

create table public.social_stories (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  visibility  public.visibility_t not null default 'public' check (visibility = 'public'),
  kind        text not null check (kind in ('photo', 'video', 'text')),
  -- A text story's words, or a photo or video story's caption.
  body        text not null default '' check (char_length(body) <= 300),
  -- A text story's colour, one of the app's named swatches.
  background  text check (background is null or background in ('accent', 'blush', 'sage', 'lilac', 'slate')),
  media       jsonb not null default '[]',
  expires_at  timestamptz not null default now() + interval '24 hours',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (private.social_story_media_valid(kind, media, owner_id)),
  check (kind <> 'text' or char_length(btrim(body)) > 0)
);
create index social_stories_owner on public.social_stories (owner_id, created_at);
create index social_stories_expiry on public.social_stories (expires_at);

create table public.social_story_views (
  id          uuid primary key default gen_random_uuid(),
  -- The person who opened the story.
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  author_id   uuid not null references auth.users(id) on delete cascade,
  -- A public story's row, or an encrypted story's ID from inside its room post.
  story_id    uuid not null,
  visibility  public.visibility_t not null default 'private' check (visibility = 'private'),
  expires_at  timestamptz not null default now() + interval '25 hours',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (owner_id, story_id),
  check (owner_id <> author_id)
);
create index social_story_views_author on public.social_story_views (author_id, story_id);
create index social_story_views_expiry on public.social_story_views (expires_at);

-- The server sets a story's times, so nobody can make one last longer than a day.
create function private.social_story_times() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.created_at := now();
  new.updated_at := now();
  new.expires_at := now() + case when tg_table_name = 'social_stories' then interval '24 hours' else interval '25 hours' end;
  return new;
end $$;
revoke all on function private.social_story_times() from public, anon, authenticated;
create trigger social_story_times before insert on public.social_stories
  for each row execute function private.social_story_times();
create trigger social_story_view_times before insert on public.social_story_views
  for each row execute function private.social_story_times();

-- Fifty stories a day, and three thousand story views a day, for one account.
create function private.social_story_rate_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  if tg_table_name = 'social_stories' then
    select count(*) into v_count from public.social_stories
      where owner_id = new.owner_id and created_at > now() - interval '1 day';
    if v_count >= 50 then raise exception 'too many stories in a day' using errcode = 'P0001'; end if;
  else
    select count(*) into v_count from public.social_story_views
      where owner_id = new.owner_id and created_at > now() - interval '1 day';
    if v_count >= 3000 then raise exception 'too many story views in a day' using errcode = 'P0001'; end if;
  end if;
  return new;
end $$;
revoke all on function private.social_story_rate_limit() from public, anon, authenticated;
create trigger social_stories_rate before insert on public.social_stories
  for each row execute function private.social_story_rate_limit();
create trigger social_story_views_rate before insert on public.social_story_views
  for each row execute function private.social_story_rate_limit();

-- Deletes every story and view whose day is up.
create function private.social_expire_stories() returns void
language sql security definer set search_path = '' as $$
  delete from public.social_stories where expires_at <= now();
  delete from public.social_story_views where expires_at <= now();
$$;
revoke all on function private.social_expire_stories() from public, anon, authenticated;

create function private.social_expire_stories_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.social_expire_stories();
  return null;
end $$;
revoke all on function private.social_expire_stories_trigger() from public, anon, authenticated;
create trigger social_stories_expire after insert on public.social_stories
  for each statement execute function private.social_expire_stories_trigger();

-- Every fifteen minutes too, where pg_cron is there (Supabase has it on the free plan). Without it, the
-- trigger above and the expiry checks below still keep an expired story from ever being read.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('social-expire-stories', '*/15 * * * *', 'select private.social_expire_stories()');
  end if;
exception when others then
  raise notice 'pg_cron is not set up, so expired stories go when the next one is posted';
end $$;

-- row level security -----------------------------------------------------
alter table public.social_stories enable row level security;
alter table public.social_story_views enable row level security;

-- Like a post: yours, a public account's, or a private one you're an approved follower of. Never once
-- its day is up.
create policy social_stories_select on public.social_stories for select to authenticated
  using (expires_at > now() and private.social_can_see(owner_id));
create policy social_stories_insert on public.social_stories for insert to authenticated
  with check (owner_id = auth.uid());
create policy social_stories_delete on public.social_stories for delete to authenticated
  using (owner_id = auth.uid());
grant select, delete on public.social_stories to authenticated;
grant insert (kind, body, background, media) on public.social_stories to authenticated;

-- Only the viewer and the story's author can read a view. Someone blocked either way can't add one, and a
-- view of a public story has to name that story's real author.
create policy social_story_views_select on public.social_story_views for select to authenticated
  using ((owner_id = auth.uid() or author_id = auth.uid()) and expires_at > now());
create policy social_story_views_insert on public.social_story_views for insert to authenticated
  with check (owner_id = auth.uid() and not private.social_hidden(author_id)
              and not exists (select 1 from public.social_stories s where s.id = story_id and s.owner_id <> author_id));
create policy social_story_views_delete on public.social_story_views for delete to authenticated
  using (owner_id = auth.uid());
grant select, delete on public.social_story_views to authenticated;
grant insert (author_id, story_id) on public.social_story_views to authenticated;

-- reading ----------------------------------------------------------------
create type public.social_story_row as (
  id uuid, owner_id uuid, handle text, display_name text, avatar_key text,
  kind text, body text, background text, media jsonb, created_at timestamptz, expires_at timestamptz, viewed boolean
);

-- Your stories and those of people you follow (approved), skipping anyone you muted, oldest first within
-- each person, as the viewer plays them.
create function public.social_stories() returns setof public.social_story_row
language sql stable security invoker set search_path = '' as $$
  select s.id, s.owner_id, p.handle::text, p.display_name, p.avatar_key, s.kind, s.body, s.background, s.media,
         s.created_at, s.expires_at,
         exists (select 1 from public.social_story_views v where v.story_id = s.id and v.owner_id = auth.uid())
  from public.social_stories s join public.profiles p on p.id = s.owner_id
  where s.expires_at > now()
    and (s.owner_id = auth.uid()
         or s.owner_id in (select f.followee_id from public.social_follows f where f.owner_id = auth.uid() and f.approved))
    and s.owner_id not in (select m.muted_id from public.social_mutes m where m.owner_id = auth.uid())
  order by s.owner_id, s.created_at
  limit 500;
$$;

-- Who opened one of your stories, newest first. Anyone else asking gets nothing back.
create function public.social_story_viewers(p_story uuid) returns table (handle text, display_name text, avatar_key text, viewed_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select p.handle::text, p.display_name, p.avatar_key, v.created_at
  from public.social_story_views v join public.profiles p on p.id = v.owner_id
  where v.story_id = p_story and v.author_id = auth.uid() and v.expires_at > now()
    and not private.social_hidden(v.owner_id)
  order by v.created_at desc
  limit 1000;
$$;

-- Marks a story as seen, by its author's handle. Seeing it twice is harmless, and seeing your own is nothing.
create function public.social_view_story(p_story uuid, p_author text) returns void
language sql security invoker set search_path = '' as $$
  insert into public.social_story_views (author_id, story_id)
  -- Someone blocked either way is skipped quietly, so this never tells anyone about a block.
  select p.id, p_story from public.profiles p
  where p.handle = p_author and p.id <> auth.uid() and not private.social_hidden(p.id)
  on conflict (owner_id, story_id) do nothing;
$$;

grant execute on function public.social_stories() to authenticated;
grant execute on function public.social_story_viewers(uuid) to authenticated;
grant execute on function public.social_view_story(uuid, text) to authenticated;

-- Export includes the new tables.
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
    'social_seen',     (select coalesce(jsonb_agg(x), '[]') from public.social_seen x where x.owner_id = auth.uid()),
    'social_settings', (select to_jsonb(x) from public.social_settings x where x.owner_id = auth.uid()),
    'social_mutes',    (select coalesce(jsonb_agg(x), '[]') from public.social_mutes x where x.owner_id = auth.uid()),
    'social_saves',    (select coalesce(jsonb_agg(x), '[]') from public.social_saves x where x.owner_id = auth.uid()),
    'message_requests_received', (select coalesce(jsonb_agg(x), '[]') from public.message_requests x where x.recipient_id = auth.uid()),
    'social_stories',  (select coalesce(jsonb_agg(x), '[]') from public.social_stories x where x.owner_id = auth.uid()),
    'social_story_views', (select coalesce(jsonb_agg(x), '[]') from public.social_story_views x where x.owner_id = auth.uid())
  );
$$;
