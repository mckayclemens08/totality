-- Encrypted sync. A row is one item: its sealed details in meta_cipher, and its sealed body in Storage
-- at <owner>/<id>/<hash>.body, a new path for each version, so nothing is ever overwritten in place.

-- A deleted item keeps a row with no content, so other devices learn it's gone and don't re-upload it.
alter table public.content_objects add column deleted_at timestamptz;

grant update (deleted_at) on public.content_objects to authenticated;

-- Storage needs read access to delete, and an old version has no row pointing at it any more.
create policy content_blob_select_own on storage.objects for select to authenticated using (
  bucket_id = 'content' and (storage.foldername(name))[1] = auth.uid()::text
);

-- The free plan's upload ceiling, stated here so a bigger file fails clearly.
update storage.buckets set file_size_limit = 52428800 where id = 'content';
