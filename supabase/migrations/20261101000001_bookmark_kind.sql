-- Web bookmarks sync as sealed objects, the same as notes and events. A bookmark's address and title
-- are content, so they stay in meta_cipher. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'bookmark';
