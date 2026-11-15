-- The Reader's linked Google Drive folders and the Drive files opened from them, as one row per person
-- with everything sealed in meta_cipher and no storage_key (issue 102). Folder names, file titles and the
-- Google account's address are all inside the seal. Listings, downloaded files and Google sign-ins never
-- reach the server: each device connects to Google itself. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'reader_drive';
