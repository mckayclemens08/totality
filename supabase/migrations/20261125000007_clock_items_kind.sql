-- The Clock's world cities, timer presets and stopwatch, as one row per person with everything sealed in
-- meta_cipher and no storage_key (issue 204). Alarms aren't synced: each rings on the device that set it.
-- The row is a content_objects row like home_layout, so owner_id, visibility, RLS and the mutation
-- policies already cover it. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'clock_items';
