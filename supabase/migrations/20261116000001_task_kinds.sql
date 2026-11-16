-- Tasks (issue 123): one row per task and one per list, each with everything sealed in meta_cipher and no
-- storage_key. Titles, notes, checklists, tags, dates, list names and links to other modules are all
-- content, so they stay inside the seal. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'task';
alter type public.content_kind_t add value if not exists 'task_list';
