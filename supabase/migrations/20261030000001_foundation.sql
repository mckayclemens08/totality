-- Totality Phase 0 foundation. Proposal §5, §7, §9; brief §6.
-- Clients get no table access by default. Each table below grants only what it needs.

create schema if not exists extensions;
create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create type public.visibility_t as enum ('private', 'contacts', 'public');
create type public.contact_state_t as enum ('pending_out', 'pending_in', 'accepted', 'blocked');
create type public.content_kind_t as enum
  ('file', 'note', 'doc', 'photo', 'video', 'audio', 'post', 'event', 'transaction', 'ai_memory');
create type public.ai_scope_t as enum ('read', 'propose', 'act');

create function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- instance ------------------------------------------------------------
-- The Matrix server name is an open owner decision. claim_handle refuses to run until it is set.
create table public.instance_config (
  id                 boolean primary key default true check (id),
  matrix_server_name text
);
insert into public.instance_config default values;

-- identity ------------------------------------------------------------
create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  handle           extensions.citext unique not null
                   check (handle::text ~ '^[a-z0-9_]{3,24}$'),
  handle_locked_at timestamptz,
  display_name     text,
  bio              text,
  avatar_key       text,
  mxid             text unique not null,
  did              text unique,
  visibility       public.visibility_t not null default 'public',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table public.identity_keys (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  signing_pub bytea not null check (octet_length(signing_pub) = 32),
  kex_pub     bytea not null check (octet_length(kex_pub) = 32),
  signed_at   timestamptz not null default now(),
  self_sig    bytea not null check (octet_length(self_sig) = 64)
);

create table public.devices (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  platform     text not null check (platform in ('ios', 'macos')),
  device_pub   bytea not null check (octet_length(device_pub) = 32),
  mx_device_id text,
  verified_at  timestamptz,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now()
);

create table public.push_tokens (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  device_id  uuid not null references public.devices(id) on delete cascade,
  apns_token text not null,
  created_at timestamptz not null default now(),
  unique (device_id)
);

-- contacts ------------------------------------------------------------
create table public.contacts (
  id                    uuid primary key default gen_random_uuid(),
  owner_id              uuid not null references auth.users(id) on delete cascade,
  peer_id               uuid references auth.users(id) on delete cascade,
  peer_mxid             text,
  peer_did              text,
  state                 public.contact_state_t not null default 'pending_out',
  can_see_private_posts boolean not null default false,
  key_verified_at       timestamptz,
  -- The exact key that was verified, so a later key change shows as unverified again.
  verified_signing_pub  bytea check (octet_length(verified_signing_pub) = 32),
  created_at            timestamptz not null default now(),
  unique (owner_id, peer_id),
  check ((key_verified_at is null) = (verified_signing_pub is null)),
  check (peer_id is not null or peer_mxid is not null),
  check (peer_id is distinct from owner_id)
);

-- Base64 can contain / and +, which break invite links, so codes are hex.
create table public.invites (
  code        text primary key default encode(extensions.gen_random_bytes(16), 'hex'),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  email       text,
  redeemed_by uuid references auth.users(id) on delete set null,
  redeemed_at timestamptz,
  expires_at  timestamptz not null default now() + interval '14 days',
  created_at  timestamptz not null default now()
);

-- content -------------------------------------------------------------
create table public.content_objects (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  kind         public.content_kind_t not null,
  visibility   public.visibility_t not null default 'private',
  storage_key  text unique,
  byte_size    bigint check (byte_size >= 0),
  content_hash bytea,
  key_ref      text not null check (key_ref ~ '^(crk:|mxroom:|plain:)'),
  meta_cipher  bytea,
  meta_plain   jsonb not null default '{}',
  room_id      text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- Blob reads follow this row, so it can only point at its owner's own folder.
  constraint storage_key_in_owner_folder check (
    storage_key is null or split_part(storage_key, '/', 1) = owner_id::text
  ),
  -- Unencrypted objects can only be public.
  constraint plain_is_public check (key_ref not like 'plain:%' or visibility = 'public'),
  -- Filenames and captions belong in meta_cipher, so only these keys may be plaintext.
  constraint meta_plain_allowlist check (
    jsonb_typeof(meta_plain) = 'object'
    and (meta_plain - array['mime', 'width', 'height', 'duration_ms']) = '{}'::jsonb
  )
);
create index on public.content_objects (owner_id, kind, created_at desc);

-- A grant to one person. wrapped_key is the object's key sealed to the grantee's kex_pub.
create table public.content_shares (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  object_id   uuid not null references public.content_objects(id) on delete cascade,
  grantee_id  uuid not null references auth.users(id) on delete cascade,
  wrapped_key bytea not null,
  created_at  timestamptz not null default now(),
  unique (object_id, grantee_id),
  check (grantee_id <> owner_id)
);

-- shared services -----------------------------------------------------
create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  module       text not null,
  title_cipher bytea,
  content_ref  jsonb,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  subject_id  uuid references auth.users(id) on delete set null,
  object_id   uuid references public.content_objects(id) on delete set null,
  reason      text not null,
  created_at  timestamptz not null default now(),
  check (subject_id is not null or object_id is not null)
);

create table public.audit_log (
  id       bigserial primary key,
  actor_id uuid references auth.users(id) on delete set null,
  action   text not null,
  subject  jsonb not null default '{}',
  at       timestamptz not null default now()
);

create table public.ai_grants (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  module     text not null,
  scope      public.ai_scope_t not null,
  expires_at timestamptz,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (owner_id, module, scope)
);

create trigger touch_profiles before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger touch_content before update on public.content_objects
  for each row execute function public.touch_updated_at();

-- audit ---------------------------------------------------------------
create function public.write_audit(p_action text, p_subject jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor_id, action, subject) values (auth.uid(), p_action, p_subject);
$$;
revoke all on function public.write_audit(text, jsonb) from public, anon, authenticated;

create function public.audit_ai_grant() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.write_audit('ai.grant.' || lower(tg_op),
    jsonb_build_object('grant_id', coalesce(new.id, old.id),
                       'module', coalesce(new.module, old.module),
                       'scope', coalesce(new.scope, old.scope)));
  return coalesce(new, old);
end $$;
create trigger audit_ai_grants after insert or update or delete on public.ai_grants
  for each row execute function public.audit_ai_grant();

-- helpers -------------------------------------------------------------
-- These read other users' contact rows, so they must bypass RLS. A plain subquery in a policy
-- runs as the caller, cannot see the owner's row, and silently denies every contact.
-- They live outside public because PostgREST exposes public as RPC, and is_blocked_by would then
-- tell a blocked user that they are blocked.
create schema private;
grant usage on schema private to authenticated;

create function private.is_visible_contact(p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contacts c
    where c.owner_id = p_owner and c.peer_id = auth.uid()
      and c.state = 'accepted' and c.can_see_private_posts
  );
$$;

create function private.is_blocked_by(p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contacts c
    where c.owner_id = p_owner and c.peer_id = auth.uid() and c.state = 'blocked'
  );
$$;

create function private.has_blocked(p_peer uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contacts c
    where c.owner_id = auth.uid() and c.peer_id = p_peer and c.state = 'blocked'
  );
$$;

-- Shares from someone you blocked are hidden on read. Refusing them on insert would tell the
-- sender they are blocked.
create function private.has_share(p_object uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.content_shares s
    where s.object_id = p_object and s.grantee_id = auth.uid()
      and not private.has_blocked(s.owner_id)
  );
$$;

create function private.owns_object(p_object uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.content_objects o
    where o.id = p_object and o.owner_id = auth.uid()
  );
$$;

-- identity functions --------------------------------------------------
create function public.claim_handle(p_handle text, p_display_name text default null)
returns public.profiles
language plpgsql security definer set search_path = '' as $$
declare
  v_server text;
  v_row public.profiles;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  select matrix_server_name into v_server from public.instance_config;
  if v_server is null then
    raise exception 'matrix_server_name is not configured' using errcode = '55000';
  end if;
  insert into public.profiles (id, handle, display_name, mxid)
  values (auth.uid(), p_handle, p_display_name, '@' || lower(p_handle) || ':' || v_server)
  returning * into v_row;
  return v_row;
end $$;

create function public.redeem_invite(p_code text) returns public.contacts
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_invite public.invites;
  v_email text;
  v_row public.contacts;
begin
  if v_me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  select * into v_invite from public.invites where code = p_code for update;
  if not found or v_invite.redeemed_at is not null or v_invite.expires_at <= now() then
    raise exception 'invite is not valid' using errcode = 'P0002';
  end if;
  if v_invite.owner_id = v_me then
    raise exception 'cannot redeem your own invite' using errcode = '22023';
  end if;
  if v_invite.email is not null then
    select email into v_email from auth.users where id = v_me;
    if lower(v_email) is distinct from lower(v_invite.email) then
      raise exception 'invite is not valid' using errcode = 'P0002';
    end if;
  end if;
  update public.invites set redeemed_by = v_me, redeemed_at = now() where code = p_code;
  insert into public.contacts (owner_id, peer_id, state)
  values (v_invite.owner_id, v_me, 'accepted'), (v_me, v_invite.owner_id, 'accepted')
  on conflict (owner_id, peer_id) do update
    set state = 'accepted'
    where public.contacts.state <> 'blocked';
  perform public.write_audit('invite.redeem', jsonb_build_object('inviter', v_invite.owner_id));
  select * into v_row from public.contacts where owner_id = v_me and peer_id = v_invite.owner_id;
  return v_row;
end $$;

create function public.request_contact(p_peer uuid) returns public.contacts
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_row public.contacts;
begin
  if v_me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.profiles where id = p_peer) then
    raise exception 'no such user' using errcode = 'P0002';
  end if;
  -- A blocked sender gets the same result as a successful request, with nothing delivered.
  if not exists (
    select 1 from public.contacts
    where owner_id = p_peer and peer_id = v_me and state = 'blocked'
  ) then
    insert into public.contacts (owner_id, peer_id, state) values (p_peer, v_me, 'pending_in')
    on conflict (owner_id, peer_id) do nothing;
  end if;
  insert into public.contacts (owner_id, peer_id, state) values (v_me, p_peer, 'pending_out')
  on conflict (owner_id, peer_id) do nothing;
  select * into v_row from public.contacts where owner_id = v_me and peer_id = p_peer;
  return v_row;
end $$;

create function public.accept_contact(p_peer uuid) returns public.contacts
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_row public.contacts;
begin
  update public.contacts set state = 'accepted'
  where owner_id = v_me and peer_id = p_peer and state = 'pending_in'
  returning * into v_row;
  if not found then
    raise exception 'no pending request' using errcode = 'P0002';
  end if;
  update public.contacts set state = 'accepted'
  where owner_id = p_peer and peer_id = v_me and state = 'pending_out';
  return v_row;
end $$;

create function public.block_contact(p_peer uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  insert into public.contacts (owner_id, peer_id, state, can_see_private_posts)
  values (v_me, p_peer, 'blocked', false)
  on conflict (owner_id, peer_id) do update
    set state = 'blocked', can_see_private_posts = false;
  -- The other side loses access too, and is not told why.
  update public.contacts set can_see_private_posts = false
  where owner_id = p_peer and peer_id = v_me;
  delete from public.content_shares
  where (owner_id = v_me and grantee_id = p_peer) or (owner_id = p_peer and grantee_id = v_me);
  perform public.write_audit('contact.block', jsonb_build_object('peer', p_peer));
end $$;

create function public.export_my_data() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'profile',  (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'devices',  (select coalesce(jsonb_agg(d), '[]') from public.devices d where d.owner_id = auth.uid()),
    'contacts', (select coalesce(jsonb_agg(c), '[]') from public.contacts c where c.owner_id = auth.uid()),
    'content',  (select coalesce(jsonb_agg(o), '[]') from public.content_objects o where o.owner_id = auth.uid()),
    'shares',   (select coalesce(jsonb_agg(s), '[]') from public.content_shares s where s.owner_id = auth.uid()),
    'invites',  (select coalesce(jsonb_agg(i), '[]') from public.invites i where i.owner_id = auth.uid()),
    'notifications', (select coalesce(jsonb_agg(n), '[]') from public.notifications n where n.owner_id = auth.uid()),
    'reports',  (select coalesce(jsonb_agg(r), '[]') from public.reports r where r.owner_id = auth.uid()),
    'ai_grants',(select coalesce(jsonb_agg(g), '[]') from public.ai_grants g where g.owner_id = auth.uid()),
    'audit_log',(select coalesce(jsonb_agg(a), '[]') from public.audit_log a where a.actor_id = auth.uid())
  );
$$;

-- row level security --------------------------------------------------
alter table public.instance_config enable row level security;
alter table public.profiles        enable row level security;
alter table public.identity_keys   enable row level security;
alter table public.devices         enable row level security;
alter table public.push_tokens     enable row level security;
alter table public.contacts        enable row level security;
alter table public.invites         enable row level security;
alter table public.content_objects enable row level security;
alter table public.content_shares  enable row level security;
alter table public.notifications   enable row level security;
alter table public.reports         enable row level security;
alter table public.audit_log       enable row level security;
alter table public.ai_grants       enable row level security;

create policy config_select on public.instance_config for select to authenticated using (true);

create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid()
  or (not private.is_blocked_by(id)
      and (visibility = 'public'
           or (visibility = 'contacts' and private.is_visible_contact(id))))
);
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy keys_select on public.identity_keys for select to authenticated using (true);
create policy keys_insert on public.identity_keys for insert to authenticated
  with check (user_id = auth.uid());

create policy devices_select on public.devices for select to authenticated using (owner_id = auth.uid());
create policy devices_insert on public.devices for insert to authenticated with check (owner_id = auth.uid());
create policy devices_update on public.devices for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy devices_delete on public.devices for delete to authenticated using (owner_id = auth.uid());

create policy push_select on public.push_tokens for select to authenticated using (owner_id = auth.uid());
create policy push_insert on public.push_tokens for insert to authenticated with check (owner_id = auth.uid());
create policy push_delete on public.push_tokens for delete to authenticated using (owner_id = auth.uid());

create policy contacts_select on public.contacts for select to authenticated using (owner_id = auth.uid());
create policy contacts_update on public.contacts for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy contacts_delete on public.contacts for delete to authenticated using (owner_id = auth.uid());

create policy invites_select on public.invites for select to authenticated using (owner_id = auth.uid());
create policy invites_insert on public.invites for insert to authenticated with check (owner_id = auth.uid());
create policy invites_delete on public.invites for delete to authenticated using (owner_id = auth.uid());

create policy content_select_own on public.content_objects for select to authenticated
  using (owner_id = auth.uid());
create policy content_select_shared on public.content_objects for select to authenticated
  using (private.has_share(id));
create policy content_select_contacts on public.content_objects for select to authenticated
  using (visibility = 'contacts' and private.is_visible_contact(owner_id));
create policy content_select_public on public.content_objects for select to authenticated
  using (visibility = 'public' and not private.is_blocked_by(owner_id));
create policy content_insert on public.content_objects for insert to authenticated
  with check (owner_id = auth.uid());
create policy content_update on public.content_objects for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy content_delete on public.content_objects for delete to authenticated
  using (owner_id = auth.uid());

create policy shares_select on public.content_shares for select to authenticated
  using (owner_id = auth.uid() or (grantee_id = auth.uid() and not private.has_blocked(owner_id)));
create policy shares_insert on public.content_shares for insert to authenticated
  with check (owner_id = auth.uid() and private.owns_object(object_id));
create policy shares_delete on public.content_shares for delete to authenticated
  using (owner_id = auth.uid());

create policy notifications_select on public.notifications for select to authenticated
  using (owner_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy notifications_delete on public.notifications for delete to authenticated
  using (owner_id = auth.uid());

create policy reports_select on public.reports for select to authenticated using (owner_id = auth.uid());
create policy reports_insert on public.reports for insert to authenticated with check (owner_id = auth.uid());

create policy audit_select on public.audit_log for select to authenticated using (actor_id = auth.uid());

create policy ai_select on public.ai_grants for select to authenticated using (owner_id = auth.uid());
create policy ai_insert on public.ai_grants for insert to authenticated with check (owner_id = auth.uid());
create policy ai_update on public.ai_grants for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy ai_delete on public.ai_grants for delete to authenticated using (owner_id = auth.uid());

-- privileges ----------------------------------------------------------
-- Supabase grants everything to anon and authenticated by default. Column grants only take
-- effect once that is revoked. Columns that decide identity or trust are written only by the
-- functions above: mxid, did, handle, contact state, and invite redemption.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
-- PUBLIC's execute default is global, so this cannot be limited to one schema. Without this line,
-- every later function would be open to anon until someone remembered to revoke it.
alter default privileges revoke execute on functions from public;
revoke all on all functions in schema private from public, anon, authenticated;

grant usage on schema public to authenticated;
grant select on public.instance_config to authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, bio, avatar_key, visibility) on public.profiles to authenticated;
grant select, insert on public.identity_keys to authenticated;
grant select, insert (owner_id, name, platform, device_pub, mx_device_id), delete on public.devices to authenticated;
grant update (name, mx_device_id, last_seen_at, verified_at) on public.devices to authenticated;
grant select, insert (owner_id, device_id, apns_token), delete on public.push_tokens to authenticated;
grant select, delete on public.contacts to authenticated;
grant update (can_see_private_posts, key_verified_at, verified_signing_pub) on public.contacts to authenticated;
grant select, insert (owner_id, email, expires_at), delete on public.invites to authenticated;
grant select, insert, delete on public.content_objects to authenticated;
grant update (visibility, storage_key, byte_size, content_hash, key_ref, meta_cipher, meta_plain, room_id)
  on public.content_objects to authenticated;
grant select, insert, delete on public.content_shares to authenticated;
grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant select, insert on public.reports to authenticated;
grant select on public.audit_log to authenticated;
grant select, insert, delete on public.ai_grants to authenticated;
grant update (expires_at, revoked_at) on public.ai_grants to authenticated;

grant execute on function public.claim_handle(text, text) to authenticated;
grant execute on function public.redeem_invite(text) to authenticated;
grant execute on function public.request_contact(uuid) to authenticated;
grant execute on function public.accept_contact(uuid) to authenticated;
grant execute on function public.block_contact(uuid) to authenticated;
grant execute on function public.export_my_data() to authenticated;
grant execute on function private.is_visible_contact(uuid) to authenticated;
grant execute on function private.is_blocked_by(uuid) to authenticated;
grant execute on function private.has_blocked(uuid) to authenticated;
grant execute on function private.has_share(uuid) to authenticated;
grant execute on function private.owns_object(uuid) to authenticated;

-- storage -------------------------------------------------------------
-- Objects live at <owner_id>/<uuid>. Storage RLS is separate from table RLS, and reads follow
-- content_objects so sharing and revocation apply to the bytes as well as the row.
insert into storage.buckets (id, name, public) values ('content', 'content', false);

create policy content_blob_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'content' and (storage.foldername(name))[1] = auth.uid()::text
);
create policy content_blob_select on storage.objects for select to authenticated using (
  bucket_id = 'content' and exists (
    select 1 from public.content_objects o where o.storage_key = storage.objects.name
  )
);
create policy content_blob_delete on storage.objects for delete to authenticated using (
  bucket_id = 'content' and (storage.foldername(name))[1] = auth.uid()::text
);
