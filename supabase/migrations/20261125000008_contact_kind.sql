-- One card in Contacts, as one row per card with everything sealed in meta_cipher and no storage_key
-- (issue 205). Names, numbers, addresses, notes, labels, the photo and any @username link are all inside the
-- seal. No new table: the existing content_objects rules (owner_id, visibility, RLS, mutation policy) apply.
-- The older `contacts` table (the account graph) is a different thing and is left alone. Older app versions
-- skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'contact';
