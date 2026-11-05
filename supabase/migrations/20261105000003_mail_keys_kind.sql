-- The public keys one Mail account has pinned for the people it writes to and hears from sync as their
-- own sealed object, apart from the settings. Who someone mails is content, so the names and keys stay
-- in meta_cipher, and the row's ID is derived on the device from the account. The device only ever adds
-- to it: a server-side delete or an older copy is merged back, never taken as a removal.
-- Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'mail_keys';
