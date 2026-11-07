-- An outside mail account (iCloud or Gmail) added beside the Totality address syncs as its own sealed
-- object, one per account, so it appears on the person's other devices (issue 43, decision 2). The
-- provider, the address, the Send switch, and the app password are all in meta_cipher, sealed with the
-- content key on the device. The server never sees any of them, and the row's ID is derived on the device.
-- Older app versions skip kinds they don't know.
alter type public.content_kind_t add value if not exists 'mail_outside';
