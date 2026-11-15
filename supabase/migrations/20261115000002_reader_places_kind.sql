-- Where the person stopped in each Reader file, as one row per person with everything sealed in meta_cipher
-- and no storage_key (issue 117). Which items were read, and where in them, are inside the seal. A device
-- sends it at most every few minutes, or as the app goes to the background, so the row's changes don't time
-- any one item's opening. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'reader_places';
