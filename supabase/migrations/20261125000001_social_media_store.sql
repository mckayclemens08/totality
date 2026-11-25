-- Social's photos and voice clips move to Totality's own server (`server/social-media/`), off Supabase
-- Storage's shared free 1 GB. A post's media entry may now say where its file is: no `store` means the old
-- `social-media` bucket (posts made before the move, which keep working), and `"store": "totality"` means
-- the Oracle server. Nothing else is allowed, so a row can't point a reader anywhere else.
--
-- The bucket stays readable for older posts, and its owners can still remove their files from it. New
-- uploads stop going there once everyone runs the version that writes to Totality's server; closing it to
-- new files is a separate step (see the PR), so an older build on someone's phone isn't broken first.
-- No new table.
create or replace function private.social_media_valid(p_media jsonb, p_owner uuid) returns boolean
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
        and (e.item->'store' is null or e.item->'store' = '"totality"'::jsonb)
        and (e.item->'width' is null or jsonb_typeof(e.item->'width') = 'number')
        and (e.item->'height' is null or jsonb_typeof(e.item->'height') = 'number')
        and (e.item->'duration' is null or jsonb_typeof(e.item->'duration') = 'number')
      )
    )
    and (select count(*) from jsonb_array_elements(p_media) e(item) where e.item->>'kind' = 'audio')
        in (0, case when jsonb_array_length(p_media) = 1 then 1 else 0 end);
$$;
