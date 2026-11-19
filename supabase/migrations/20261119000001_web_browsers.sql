-- Browsers you've paired with the website, so the iPhone can list them under Devices and remove one
-- (owner, 2026-11-19: "Whole sign-in"). A row is one browser's sign-in: its Supabase session, a plain
-- label like "Safari on Mac", when it was last active, and its Matrix device if Messages is on there.
-- No content and no keys. Removing a browser ends that session, so its refresh token stops working, and
-- leaves a marker the browser reads within five minutes to wipe itself and sign out.
--
-- Rows change only through the functions below, which act for the signed-in person alone: a browser
-- for its own session, the iPhone for any of the person's browsers.
create table public.web_browsers (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  visibility     public.visibility_t not null default 'private' check (visibility = 'private'),
  session_id     uuid not null,
  device_label   text not null check (char_length(device_label) between 1 and 80),
  matrix_device  text check (matrix_device ~ '^[A-Za-z0-9_.-]{1,64}$'),
  last_seen_at   timestamptz not null default now(),
  removed_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (owner_id, session_id)
);
create trigger touch_web_browsers before update on public.web_browsers
  for each row execute function public.touch_updated_at();

alter table public.web_browsers enable row level security;
create policy web_browsers_select on public.web_browsers for select to authenticated
  using (owner_id = auth.uid());
-- Nobody writes rows directly; the functions below run as the table's owner. This policy is the table's
-- mutation rule in writing: it allows nothing.
create policy web_browsers_no_direct_writes on public.web_browsers for all to authenticated
  using (false) with check (false);
revoke all on public.web_browsers from public, anon, authenticated;
grant select on public.web_browsers to authenticated;

-- The session this request was made with, from the signed token. Null if the token has none.
create function public.current_session_id() returns uuid language sql stable set search_path = public as $$
  select nullif(auth.jwt() ->> 'session_id', '')::uuid
$$;

-- Called by the website after it's paired, and each time it opens or checks in (every five minutes).
-- Returns 'ok', or 'removed' if this browser was removed from the iPhone, in which case the browser wipes
-- itself and signs out. Its first call adds the row, so browsers paired before this existed show up too.
create function public.browser_check_in(p_label text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  sess uuid := public.current_session_id();
  b public.web_browsers;
begin
  if me is null or sess is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select * into b from public.web_browsers where owner_id = me and session_id = sess;
  if found and b.removed_at is not null then return 'removed'; end if;
  if found then
    update public.web_browsers set last_seen_at = now() where id = b.id and last_seen_at < now() - interval '1 minute';
    return 'ok';
  end if;
  if p_label is null or char_length(p_label) not between 1 and 80 then raise exception 'bad label' using errcode = '22023'; end if;
  -- Markers and rows for sessions that have ended are cleared as new ones come, and the list stays short.
  delete from public.web_browsers w where w.owner_id = me
    and (w.removed_at < now() - interval '30 days'
         or (w.removed_at is null and not exists (select 1 from auth.sessions s where s.id = w.session_id)));
  if (select count(*) from public.web_browsers where owner_id = me and removed_at is null) >= 20 then
    raise exception 'too many browsers' using errcode = 'P0001';
  end if;
  insert into public.web_browsers (owner_id, session_id, device_label) values (me, sess, p_label);
  return 'ok';
end $$;

-- The website records its Matrix device once Messages signs in there (null when Messages signs out).
create function public.browser_set_matrix_device(p_device text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.current_session_id() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  update public.web_browsers set matrix_device = p_device
    where owner_id = auth.uid() and session_id = public.current_session_id() and removed_at is null;
end $$;

-- A browser signing itself out takes its row with it.
create function public.browser_forget() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.web_browsers where owner_id = auth.uid() and session_id = public.current_session_id();
end $$;

-- The iPhone's list: browsers still signed in, newest activity first.
create function public.my_browsers() returns table (id uuid, device_label text, last_seen_at timestamptz, matrix_device text)
language sql stable security definer set search_path = public as $$
  select b.id, b.device_label, b.last_seen_at, b.matrix_device from public.web_browsers b
  where b.owner_id = auth.uid() and b.removed_at is null
    and exists (select 1 from auth.sessions s where s.id = b.session_id and s.user_id = auth.uid())
  order by b.last_seen_at desc
$$;

-- Remove from the iPhone: ends that browser's sign-in and marks it removed. Returns its Matrix device, which
-- the iPhone then deletes on the Matrix server. Only the person's own browsers, and never the session making
-- this call, so you can't remove the device you're using by mistake.
create function public.remove_browser(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b public.web_browsers;
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select * into b from public.web_browsers where id = p_id and owner_id = me and removed_at is null;
  if not found then return null; end if;
  if b.session_id = public.current_session_id() then raise exception 'this is the session in use' using errcode = '22023'; end if;
  update public.web_browsers set removed_at = now() where id = b.id;
  -- Its refresh tokens go with the session, so it can't get another access token.
  delete from auth.sessions where id = b.session_id and user_id = me;
  return b.matrix_device;
end $$;

revoke execute on function public.current_session_id() from public, anon, authenticated;
revoke execute on function public.browser_check_in(text) from public, anon;
revoke execute on function public.browser_set_matrix_device(text) from public, anon;
revoke execute on function public.browser_forget() from public, anon;
revoke execute on function public.my_browsers() from public, anon;
revoke execute on function public.remove_browser(uuid) from public, anon;
grant execute on function public.browser_check_in(text), public.browser_set_matrix_device(text), public.browser_forget(),
  public.my_browsers(), public.remove_browser(uuid) to authenticated;
