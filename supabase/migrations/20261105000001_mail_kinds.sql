-- Mail's marks (one row per message: folder, read, starred, trashed) and its settings (own folders,
-- blocked senders, senders whose images load) sync as sealed objects, the same as bookmarks. Senders
-- and folder names are content, so they stay in meta_cipher, and the row's ID is derived on the device
-- rather than being the mail server's message ID. Messages themselves never come here: they live on the
-- mail server, sealed to the account's mail key. Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'mail_marks';
alter type public.content_kind_t add value if not exists 'mail_settings';
