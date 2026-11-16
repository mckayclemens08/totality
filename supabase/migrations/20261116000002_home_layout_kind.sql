-- Which modules the person removed from Home, as one row per person with everything sealed in meta_cipher
-- and no storage_key (issue 129). Which modules, and when, are inside the seal. Tile sizes and places stay
-- on each device. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'home_layout';
