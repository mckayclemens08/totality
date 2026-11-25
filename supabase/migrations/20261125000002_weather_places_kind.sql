-- The places saved in Weather, as one row per person with everything sealed in meta_cipher and no
-- storage_key (issue 203). Place names and coordinates are inside the seal. The last forecast stays on each
-- device and never syncs. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'weather_places';
