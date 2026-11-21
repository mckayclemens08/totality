-- Photo and audio posts (issue 149 §2, steps 3 and 4 without video).
--
-- Media live in one Storage bucket, `social-media`, under `<account id>/<random id>`:
--   * Public posts: the file is stored readable, so For You can show it to anyone.
--   * Friends and Close-friends posts: the file is sealed on the device first (AES-256-GCM, a fresh key
--     per file). The key goes only into the post's end-to-end encrypted Matrix event, never here, so this
--     bucket holds ciphertext it can't open. The bucket learns each file's size and when it arrived.
-- The bucket is public to read; only you can add to or remove from your own folder, and nothing can be
-- overwritten. No new table: `social_posts` gains a `media` column, so the invariants check is unchanged.
--
-- Cost rule: Supabase's free plan has 1 GB of Storage. Each file is capped at 4 MB by the bucket, photos
-- are made smaller on the device (1600 px, at most 1.5 MB) and audio stops at two minutes. Each account may
-- hold at most 150 MB in the bucket. When it's full, uploads are refused with "media storage full".

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('social-media', 'social-media', true, 4194304, array['image/jpeg', 'audio/mp4', 'application/octet-stream'])
on conflict (id) do nothing;

-- Bytes one account holds in the bucket. A file whose size isn't recorded yet counts as the largest allowed.
create function private.social_media_used(p_owner uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(coalesce((o.metadata->>'size')::bigint, 4194304)), 0)::bigint
  from storage.objects o
  where o.bucket_id = 'social-media' and (storage.foldername(o.name))[1] = p_owner::text;
$$;
revoke all on function private.social_media_used(uuid) from public, anon;
grant execute on function private.social_media_used(uuid) to authenticated;

create function private.social_media_room(p_owner uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.social_media_used(p_owner) >= 150 * 1024 * 1024 then
    raise exception 'media storage full';
  end if;
  return true;
end;
$$;
revoke all on function private.social_media_room(uuid) from public, anon;
grant execute on function private.social_media_room(uuid) to authenticated;

create policy social_media_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'social-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and array_length(storage.foldername(name), 1) = 1
  and private.social_media_room((select auth.uid()))
);

-- Storage's remove reads the rows it deletes, so you can list your own folder (anyone can fetch a file by its path).
create policy social_media_select on storage.objects for select to authenticated
using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy social_media_delete on storage.objects for delete to authenticated
using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- What a public post's `media` may hold: up to four photos, or one audio clip alone, each in the author's
-- own folder, with no key (a public file is stored readable, so a key here would be a lie).
create function private.social_media_valid(p_media jsonb, p_owner uuid) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_media) = 'array'
    and jsonb_array_length(p_media) <= 4
    and not exists (
      select 1 from jsonb_array_elements(p_media) e(item)
      where not (
        jsonb_typeof(e.item) = 'object'
        and e.item->>'kind' in ('photo', 'audio')
        and coalesce(e.item->>'path', '') ~ ('^' || p_owner::text || '/[0-9a-f-]{36}$')
        and jsonb_typeof(e.item->'size') = 'number'
        and not (e.item ? 'key')
        and (e.item->'width' is null or jsonb_typeof(e.item->'width') = 'number')
        and (e.item->'height' is null or jsonb_typeof(e.item->'height') = 'number')
        and (e.item->'duration' is null or jsonb_typeof(e.item->'duration') = 'number')
      )
    )
    and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'audio')
        in (0, case when jsonb_array_length(p_media) = 1 then 1 else 0 end);
$$;

alter table public.social_posts add column media jsonb not null default '[]'::jsonb;
alter table public.social_posts add constraint social_posts_media_valid check (private.social_media_valid(media, owner_id));
-- A photo or a clip is a post on its own; the text may be empty when there's media.
alter table public.social_posts drop constraint social_posts_check;
alter table public.social_posts add constraint social_posts_has_content
  check (char_length(btrim(coalesce(title, '') || body)) > 0 or jsonb_array_length(media) > 0);

-- Every feed's row gains the post's media.
alter type public.social_post_row add attribute media jsonb;

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
    exists (select 1 from public.social_saves v where v.post_id = s.id and v.owner_id = auth.uid()),
    s.media
  from public.social_posts s
  join public.profiles p on p.id = s.owner_id
  where s.id = any (p_posts);
$$;

-- For You builds its rows by hand to add its reason, so it carries the media too. Unchanged otherwise.
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
         row.created_at, row.edited_at, row.likes, row.comments, row.liked, picked.why, row.saved, row.media
  from picked, lateral private.social_rows(array[picked.id]) row
  order by picked.score desc, picked.created_at desc, picked.id;
$$;
