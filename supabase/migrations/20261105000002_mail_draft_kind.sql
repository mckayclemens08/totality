-- Mail drafts sync as sealed objects, the same as Mail's marks. The words, the recipients, the subject,
-- and the files' names are content, so they stay in meta_cipher; the files themselves are the sealed
-- body in storage, so changing a word doesn't move them all again. The row's ID is derived on the device
-- from the account and the draft, so the sync server can't link a draft to the message it becomes.
-- Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'mail_draft';
