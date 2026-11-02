-- Every username becomes a mail address, so some names can't go to just anyone. Mail providers send
-- complaints to abuse@ and postmaster@, a certificate authority trusts whoever answers admin@ and its
-- neighbours, and the rest would pass for Totality itself. The owner decided on 2026-11-02 that these
-- all reach them, at mckayclemens@. Retired names are already refused at sign-up, and this list has to
-- match Username.reserved in the app.
insert into public.retired_handles (handle) values
  ('abuse'), ('admin'), ('administrator'), ('billing'), ('contact'), ('dmarc'), ('email'), ('help'),
  ('hostmaster'), ('info'), ('legal'), ('mail'), ('mailer_daemon'), ('mailerdaemon'), ('mckayclemens'),
  ('no_reply'), ('noreply'), ('official'), ('postmaster'), ('privacy'), ('root'), ('security'),
  ('ssladmin'), ('ssladministrator'), ('staff'), ('support'), ('sysadmin'), ('system'), ('team'),
  ('totality'), ('webmaster')
on conflict do nothing;
