-- Social safety (issue 149 §6 and step 7): mute, report, who can comment, private accounts, hiding like
-- counts, saves, and the "Who can message me" setting (§4).

-- settings ------------------------------------------------------------
-- One row per person. Everyone signed in can read it, because it decides what they may do on that person's
-- posts and whether their posts need an approved follow. It holds choices, never content.
create type public.social_reach_t as enum ('anyone', 'followers', 'friends', 'no_one');

create table public.social_settings (
  owner_id         uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  visibility       public.visibility_t not null default 'public' check (visibility = 'public'),
  who_can_comment  public.social_reach_t not null default 'anyone',
  who_can_message  public.social_reach_t not null default 'anyone' check (who_can_message <> 'no_one'),
  private_account  boolean not null default false,
  hide_like_counts boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger touch_social_settings before update on public.social_settings
  for each row execute function public.touch_updated_at();

alter table public.social_settings enable row level security;
create policy social_settings_select on public.social_settings for select to authenticated using (true);
create policy social_settings_insert on public.social_settings for insert to authenticated with check (owner_id = auth.uid());
create policy social_settings_update on public.social_settings for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select on public.social_settings to authenticated;
grant insert (who_can_comment, who_can_message, private_account, hide_like_counts) on public.social_settings to authenticated;
grant update (who_can_comment, who_can_message, private_account, hide_like_counts) on public.social_settings to authenticated;

-- follow requests -----------------------------------------------------
-- Following a private account is a request until they approve it. Approved follows behave as before.
alter table public.social_follows add column approved boolean not null default true;

create function private.social_is_private(p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select private_account from public.social_settings where owner_id = p_owner), false);
$$;

create function private.social_follows_approved(p_follower uuid, p_followee uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.social_follows
                 where owner_id = p_follower and followee_id = p_followee and approved);
$$;

-- Whether the caller may see someone's posts: their own, a public account's, or a private one they follow.
create function private.social_can_see(p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_owner = auth.uid()
      or (not private.social_hidden(p_owner)
          and (not private.social_is_private(p_owner) or private.social_follows_approved(auth.uid(), p_owner)));
$$;

-- Whether someone's reach setting lets the caller in. Friends follow each other, both approved.
create function private.social_reaches(p_owner uuid, p_reach public.social_reach_t) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_owner = auth.uid() or case p_reach
    when 'anyone' then true
    when 'followers' then private.social_follows_approved(auth.uid(), p_owner)
    when 'friends' then private.social_follows_approved(auth.uid(), p_owner) and private.social_follows_approved(p_owner, auth.uid())
    else false
  end;
$$;

create function private.social_may_comment(p_post uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.social_reaches(s.owner_id,
           coalesce((select who_can_comment from public.social_settings where owner_id = s.owner_id), 'anyone'))
  from public.social_posts s where s.id = p_post;
$$;

revoke all on function private.social_is_private(uuid), private.social_follows_approved(uuid, uuid),
  private.social_can_see(uuid), private.social_reaches(uuid, public.social_reach_t),
  private.social_may_comment(uuid) from public, anon;
grant execute on function private.social_is_private(uuid), private.social_follows_approved(uuid, uuid),
  private.social_can_see(uuid), private.social_reaches(uuid, public.social_reach_t),
  private.social_may_comment(uuid) to authenticated;

-- A private account's posts reach only approved followers.
drop policy social_posts_select on public.social_posts;
create policy social_posts_select on public.social_posts for select to authenticated
  using (private.social_can_see(owner_id));

-- Who can comment is the post author's choice. The author can always comment on their own post.
drop policy social_comments_insert on public.social_comments;
create policy social_comments_insert on public.social_comments for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.social_posts p where p.id = post_id)
              and private.social_may_comment(post_id));

-- A pending request is seen only by the two people in it.
drop policy social_follows_select on public.social_follows;
create policy social_follows_select on public.social_follows for select to authenticated
  using (not private.social_hidden(owner_id) and not private.social_hidden(followee_id)
         and (approved or owner_id = auth.uid() or followee_id = auth.uid()));
-- The person followed can remove a follower, or turn down a request.
drop policy social_follows_delete on public.social_follows;
create policy social_follows_delete on public.social_follows for delete to authenticated
  using (owner_id = auth.uid() or followee_id = auth.uid());

create or replace function public.social_follow(p_handle text) returns void
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
  insert into public.social_follows (owner_id, followee_id, approved)
  values (v_me, v_them, not private.social_is_private(v_them))
  on conflict (owner_id, followee_id) do nothing;
end $$;

create function public.social_approve_follower(p_handle text) returns void
language sql security definer set search_path = '' as $$
  update public.social_follows f set approved = true
  from public.profiles p
  where p.handle = p_handle::extensions.citext and f.owner_id = p.id and f.followee_id = auth.uid();
$$;

create function public.social_remove_follower(p_handle text) returns void
language sql security invoker set search_path = '' as $$
  delete from public.social_follows f using public.profiles p
  where p.handle = p_handle::extensions.citext and f.owner_id = p.id and f.followee_id = auth.uid();
$$;

create function public.social_follow_requests()
returns table (handle text, display_name text, requested_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select p.handle::text, p.display_name, f.created_at
  from public.social_follows f join public.profiles p on p.id = f.owner_id
  where f.followee_id = auth.uid() and not f.approved
  order by f.created_at desc;
$$;

-- Turning a private account public lets everyone waiting in.
create function private.social_open_requests() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.private_account and not new.private_account then
    update public.social_follows set approved = true where followee_id = new.owner_id and not approved;
  end if;
  return new;
end $$;
revoke all on function private.social_open_requests() from public, anon, authenticated;
create trigger social_open_requests after update on public.social_settings
  for each row execute function private.social_open_requests();

-- mutes ---------------------------------------------------------------
-- Muting hides someone's posts from your feeds without telling them. Only you can see your mutes.
create table public.social_mutes (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  muted_id   uuid not null references auth.users(id) on delete cascade,
  visibility public.visibility_t not null default 'private' check (visibility = 'private'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, muted_id),
  check (owner_id <> muted_id)
);
alter table public.social_mutes enable row level security;
create policy social_mutes_select on public.social_mutes for select to authenticated using (owner_id = auth.uid());
create policy social_mutes_insert on public.social_mutes for insert to authenticated with check (owner_id = auth.uid());
create policy social_mutes_delete on public.social_mutes for delete to authenticated using (owner_id = auth.uid());
grant select, delete on public.social_mutes to authenticated;
grant insert (muted_id) on public.social_mutes to authenticated;

-- saves ---------------------------------------------------------------
-- Saved public posts. Only you can see what you saved; the author isn't told.
create table public.social_saves (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  post_id    uuid not null references public.social_posts(id) on delete cascade,
  visibility public.visibility_t not null default 'private' check (visibility = 'private'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, post_id)
);
alter table public.social_saves enable row level security;
create policy social_saves_select on public.social_saves for select to authenticated using (owner_id = auth.uid());
create policy social_saves_insert on public.social_saves for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.social_posts p where p.id = post_id));
create policy social_saves_delete on public.social_saves for delete to authenticated using (owner_id = auth.uid());
grant select, delete on public.social_saves to authenticated;
grant insert (post_id) on public.social_saves to authenticated;

-- reports -------------------------------------------------------------
-- Reports go to the owner as moderator for now (owner, 2026-11-17). A report can name a post or comment.
alter table public.reports
  add column social_post_id uuid references public.social_posts(id) on delete set null,
  add column social_comment_id uuid references public.social_comments(id) on delete set null,
  drop constraint reports_check,
  add constraint reports_names_something check (
    subject_id is not null or object_id is not null or social_post_id is not null or social_comment_id is not null),
  add constraint reports_reason_length check (char_length(reason) between 1 and 500);

create function public.social_report(p_handle text, p_post uuid, p_comment uuid, p_reason text) returns void
language sql security invoker set search_path = '' as $$
  insert into public.reports (owner_id, subject_id, social_post_id, social_comment_id, reason)
  select auth.uid(), p.id, p_post, p_comment, btrim(p_reason)
  from public.profiles p where p.handle = p_handle::extensions.citext;
$$;

-- feeds, now with mutes, hidden like counts and saves -----------------
-- A post's row gains whether you saved it, and its likes are null when its author hides them from others.
alter type public.social_post_row add attribute saved boolean;

create or replace function private.social_rows(p_posts uuid[]) returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select s.id, s.owner_id, p.handle::text, p.display_name, p.avatar_key,
    s.title, s.body, s.tags, s.created_at, s.edited_at,
    case when s.owner_id <> auth.uid()
              and coalesce((select hide_like_counts from public.social_settings x where x.owner_id = s.owner_id), false)
         then null
         else (select count(*) from public.social_likes l where l.post_id = s.id) end,
    (select count(*) from public.social_comments c where c.post_id = s.id),
    exists (select 1 from public.social_likes l where l.post_id = s.id and l.owner_id = auth.uid()),
    ''::text,
    exists (select 1 from public.social_saves v where v.post_id = s.id and v.owner_id = auth.uid())
  from public.social_posts s
  join public.profiles p on p.id = s.owner_id
  where s.id = any (p_posts);
$$;

create or replace function public.social_following_feed(p_before timestamptz default null, p_limit int default 30)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select r.* from private.social_rows(array(
    select s.id from public.social_posts s
    where (s.owner_id = auth.uid()
           or s.owner_id in (select f.followee_id from public.social_follows f where f.owner_id = auth.uid() and f.approved))
      and s.owner_id not in (select m.muted_id from public.social_mutes m where m.owner_id = auth.uid())
      and (p_before is null or s.created_at < p_before)
    order by s.created_at desc
    limit least(greatest(p_limit, 1), 100)
  )) r
  order by r.created_at desc;
$$;

-- For You keeps its ranking from the first migration; it now skips muted people and carries saves.
create or replace function public.social_for_you(p_limit int default 30, p_tag text default null)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  with me as (select auth.uid() as id),
  my_follows as (select f.followee_id as id from public.social_follows f, me where f.owner_id = me.id and f.approved),
  near as (
    select f.followee_id as id, min(p.handle::text) as via
    from public.social_follows f join public.profiles p on p.id = f.owner_id
    where f.owner_id in (select id from my_follows) and f.approved
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
      and not exists (select 1 from public.social_mutes m where m.owner_id = me.id and m.muted_id = s.owner_id)
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
         row.created_at, row.edited_at, row.likes, row.comments, row.liked, picked.why, row.saved
  from picked, lateral private.social_rows(array[picked.id]) row
  order by picked.score desc, picked.created_at desc, picked.id;
$$;

create function public.social_saved(p_limit int default 60)
returns setof public.social_post_row
language sql stable security invoker set search_path = '' as $$
  select r.* from private.social_rows(array(
    select v.post_id from public.social_saves v where v.owner_id = auth.uid()
    order by v.created_at desc limit least(greatest(p_limit, 1), 200)
  )) r
  order by r.created_at desc;
$$;

-- Friends and followers count approved follows only.
create or replace function public.social_friends()
returns table (handle text)
language sql stable security invoker set search_path = '' as $$
  select p.handle::text
  from public.social_follows mine
  join public.social_follows theirs on theirs.owner_id = mine.followee_id and theirs.followee_id = mine.owner_id
  join public.profiles p on p.id = mine.followee_id
  where mine.owner_id = auth.uid() and mine.approved and theirs.approved
  order by 1;
$$;

-- The profile gains the person's ID (for blocking), their settings that matter to you, and your request.
drop function public.social_profile(text);
create function public.social_profile(p_handle text)
returns table (
  id uuid, handle text, display_name text, bio text, avatar_key text,
  posts bigint, followers bigint, following bigint, i_follow boolean, follows_me boolean,
  requested boolean, private_account boolean, muted boolean, can_comment boolean, can_message boolean
)
language sql stable security invoker set search_path = '' as $$
  select p.id, p.handle::text, p.display_name, p.bio, p.avatar_key,
    (select count(*) from public.social_posts s where s.owner_id = p.id),
    (select count(*) from public.social_follows f where f.followee_id = p.id and f.approved),
    (select count(*) from public.social_follows f where f.owner_id = p.id and f.approved),
    exists (select 1 from public.social_follows f where f.owner_id = auth.uid() and f.followee_id = p.id and f.approved),
    exists (select 1 from public.social_follows f where f.owner_id = p.id and f.followee_id = auth.uid() and f.approved),
    exists (select 1 from public.social_follows f where f.owner_id = auth.uid() and f.followee_id = p.id and not f.approved),
    coalesce(st.private_account, false),
    exists (select 1 from public.social_mutes m where m.owner_id = auth.uid() and m.muted_id = p.id),
    private.social_reaches(p.id, coalesce(st.who_can_comment, 'anyone')),
    private.social_reaches(p.id, coalesce(st.who_can_message, 'anyone'))
  from public.profiles p
  left join public.social_settings st on st.owner_id = p.id
  where p.handle = p_handle::extensions.citext and not private.social_hidden(p.id);
$$;

create or replace function public.social_people(p_handle text, p_followers boolean, p_limit int default 100)
returns table (handle text, display_name text, followed_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select other.handle::text, other.display_name, f.created_at
  from public.profiles them
  join public.social_follows f on f.approved and ((p_followers and f.followee_id = them.id) or (not p_followers and f.owner_id = them.id))
  join public.profiles other on other.id = case when p_followers then f.owner_id else f.followee_id end
  where them.handle = p_handle::extensions.citext
  order by f.created_at desc
  limit least(greatest(p_limit, 1), 200);
$$;

-- Your own settings, with the defaults when you've never changed them.
create function public.social_my_settings()
returns table (who_can_comment public.social_reach_t, who_can_message public.social_reach_t,
               private_account boolean, hide_like_counts boolean)
language sql stable security invoker set search_path = '' as $$
  select coalesce(s.who_can_comment, 'anyone'), coalesce(s.who_can_message, 'anyone'),
         coalesce(s.private_account, false), coalesce(s.hide_like_counts, false)
  from (select 1) one left join public.social_settings s on s.owner_id = auth.uid();
$$;

create function public.social_set_settings(
  p_who_can_comment public.social_reach_t, p_who_can_message public.social_reach_t,
  p_private_account boolean, p_hide_like_counts boolean
) returns void
language sql security invoker set search_path = '' as $$
  insert into public.social_settings (who_can_comment, who_can_message, private_account, hide_like_counts)
  values (p_who_can_comment, p_who_can_message, p_private_account, p_hide_like_counts)
  on conflict (owner_id) do update set
    who_can_comment = excluded.who_can_comment, who_can_message = excluded.who_can_message,
    private_account = excluded.private_account, hide_like_counts = excluded.hide_like_counts;
$$;

grant execute on function public.social_set_settings(public.social_reach_t, public.social_reach_t, boolean, boolean) to authenticated;
grant execute on function public.social_approve_follower(text) to authenticated;
grant execute on function public.social_remove_follower(text) to authenticated;
grant execute on function public.social_follow_requests() to authenticated;
grant execute on function public.social_report(text, uuid, uuid, text) to authenticated;
grant execute on function public.social_saved(int) to authenticated;
grant execute on function public.social_profile(text) to authenticated;
grant execute on function public.social_my_settings() to authenticated;

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
    'social_saves',    (select coalesce(jsonb_agg(x), '[]') from public.social_saves x where x.owner_id = auth.uid())
  );
$$;
