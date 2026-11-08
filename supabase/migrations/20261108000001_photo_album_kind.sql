-- A photo album is one row of its own kind, holding only its sealed name in meta_cipher, and no
-- storage_key (issue 54, step 3). Which photos are in an album, a photo's caption, whether it's a
-- favourite, and whether it's in Recently Deleted are all in that photo's sealed details, so the server
-- sees none of them. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'photo_album';
