-- Music catalog, unified playlists, and OpenSubsonic server metadata as one owner-only row with
-- everything sealed in meta_cipher and no storage_key. Uploaded audio blobs travel under audio/music_audio.
alter type public.content_kind_t add value if not exists 'music_catalog';
