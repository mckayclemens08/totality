-- Messages' "Who can message me" (issue 149 §4 and step 8). The setting itself is
-- social_settings.who_can_message (Anyone, Followers or Friends). This adds message requests, for people
-- the setting doesn't let in, and the check Totality's Matrix guard asks before any invite reaches the
-- Matrix server (server/matrix-guard, through the message-gate edge function).
--
-- A request holds who asked whom, and nothing else: no message, no preview. The first message is only
-- written once the chat exists, inside the end-to-end encrypted room.

create type public.message_request_state_t as enum ('pending', 'accepted', 'declined');

-- owner_id asked to message recipient_id. Only the recipient can read it, so the sender never learns a
-- request was declined: to them it stays waiting.
create table public.message_requests (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  visibility   public.visibility_t not null default 'private' check (visibility = 'private'),
  state        public.message_request_state_t not null default 'pending',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (owner_id, recipient_id),
  check (owner_id <> recipient_id)
);
create index message_requests_recipient on public.message_requests (recipient_id, state);
create trigger touch_message_requests before update on public.message_requests
  for each row execute function public.touch_updated_at();

-- Requests are made and answered through the functions below only. The recipient may read and clear their
-- own; nobody can write a row directly.
alter table public.message_requests enable row level security;
create policy message_requests_select on public.message_requests for select to authenticated
  using (recipient_id = auth.uid());
create policy message_requests_delete on public.message_requests for delete to authenticated
  using (recipient_id = auth.uid());
grant select, delete on public.message_requests to authenticated;

-- the rule --------------------------------------------------------------
-- Neither side of a block can find the other here, as in Social.
create function private.message_hidden(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.contacts c where c.state = 'blocked'
                 and ((c.owner_id = p_a and c.peer_id = p_b) or (c.owner_id = p_b and c.peer_id = p_a)));
$$;
revoke all on function private.message_hidden(uuid, uuid) from public, anon, authenticated;

-- Whether p_sender may start a chat with p_recipient. Neither side of a block reaches the other. A
-- request the recipient accepted lets either of them invite the other, and so does a request the
-- recipient is still waiting on from the sender (they asked for it). Otherwise the recipient's setting
-- decides: Followers means the sender follows them, approved; Friends means both follow each other.
create function private.message_reaches(p_sender uuid, p_recipient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_sender <> p_recipient
     and not private.message_hidden(p_sender, p_recipient)
     and (
       exists (select 1 from public.message_requests r where r.state = 'accepted'
               and ((r.owner_id = p_sender and r.recipient_id = p_recipient)
                 or (r.owner_id = p_recipient and r.recipient_id = p_sender)))
       or exists (select 1 from public.message_requests r where r.state = 'pending'
                  and r.owner_id = p_recipient and r.recipient_id = p_sender)
       or case coalesce((select s.who_can_message from public.social_settings s where s.owner_id = p_recipient), 'anyone')
            when 'anyone' then true
            when 'followers' then private.social_follows_approved(p_sender, p_recipient)
            when 'friends' then private.social_follows_approved(p_sender, p_recipient)
                            and private.social_follows_approved(p_recipient, p_sender)
            else false
          end
     );
$$;
revoke all on function private.message_reaches(uuid, uuid) from public, anon, authenticated;

create function private.handle_id(p_handle text) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.profiles where handle = lower(p_handle)::extensions.citext;
$$;
revoke all on function private.handle_id(text) from public, anon, authenticated;

-- what the app calls ------------------------------------------------------
-- 'allowed' (start the chat), 'ask' (send a request first), 'asked' (a request is waiting), or
-- 'unknown'. A declined request reads as 'asked', so a decline is never announced. Someone on either side
-- of a block is 'unknown', the same answer Social gives.
create function public.message_reach(p_handle text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_other uuid := private.handle_id(p_handle);
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if v_other is null or v_other = auth.uid() or private.message_hidden(auth.uid(), v_other) then
    return 'unknown';
  end if;
  if private.message_reaches(auth.uid(), v_other) then return 'allowed'; end if;
  if exists (select 1 from public.message_requests where owner_id = auth.uid() and recipient_id = v_other) then
    return 'asked';
  end if;
  return 'ask';
end $$;

-- Asks to message someone. At most 30 new requests a day. Across a block there's no such user.
create function public.message_request_send(p_handle text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_other uuid := private.handle_id(p_handle);
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if v_other is null or v_other = auth.uid() or private.message_hidden(auth.uid(), v_other) then
    raise exception 'no such user' using errcode = 'P0001';
  end if;
  if private.message_reaches(auth.uid(), v_other) then return; end if;
  if (select count(*) from public.message_requests
      where owner_id = auth.uid() and created_at > now() - interval '1 day') >= 30 then
    raise exception 'too many message requests' using errcode = 'P0001';
  end if;
  insert into public.message_requests (owner_id, recipient_id) values (auth.uid(), v_other)
  on conflict (owner_id, recipient_id) do nothing;
end $$;

-- Requests waiting for you, oldest last. Someone you've blocked never shows.
create function public.message_requests_incoming()
returns table (handle text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.handle::text, r.created_at
  from public.message_requests r join public.profiles p on p.id = r.owner_id
  where r.recipient_id = auth.uid() and r.state = 'pending'
    and not private.message_hidden(auth.uid(), r.owner_id)
  order by r.created_at desc;
$$;

-- Accepts or declines a waiting request. Accepting lets the two of you start a chat.
create function public.message_request_answer(p_handle text, p_accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_other uuid := private.handle_id(p_handle);
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.message_requests
     set state = case when p_accept then 'accepted' else 'declined' end::public.message_request_state_t
   where owner_id = v_other and recipient_id = auth.uid() and state = 'pending';
  if not found then raise exception 'no such request' using errcode = 'P0001'; end if;
end $$;

-- People who accepted your requests, so their invite to the chat you asked for is joined straight away.
create function public.message_requests_accepted()
returns table (handle text)
language sql stable security definer set search_path = '' as $$
  select p.handle::text
  from public.message_requests r join public.profiles p on p.id = r.recipient_id
  where r.owner_id = auth.uid() and r.state = 'accepted' and not private.message_hidden(auth.uid(), r.recipient_id);
$$;

-- Your own setting, and changing only it.
create function public.message_my_reach() returns public.social_reach_t
language sql stable security invoker set search_path = '' as $$
  select coalesce((select who_can_message from public.social_settings where owner_id = auth.uid()), 'anyone');
$$;

create function public.message_set_reach(p_reach public.social_reach_t) returns void
language sql security invoker set search_path = '' as $$
  insert into public.social_settings (who_can_message) values (p_reach)
  on conflict (owner_id) do update set who_can_message = excluded.who_can_message;
$$;

revoke all on function public.message_reach(text), public.message_request_send(text),
  public.message_requests_incoming(), public.message_request_answer(text, boolean),
  public.message_requests_accepted(), public.message_my_reach(),
  public.message_set_reach(public.social_reach_t) from public, anon;
grant execute on function public.message_reach(text), public.message_request_send(text),
  public.message_requests_incoming(), public.message_request_answer(text, boolean),
  public.message_requests_accepted(), public.message_my_reach(),
  public.message_set_reach(public.social_reach_t) to authenticated;

-- what the Matrix guard asks -----------------------------------------------
-- For each Matrix username p_sender wants to invite, whether they may. Only the message-gate edge function
-- can call this, with the service role it gets from Supabase's own secret store. An unknown name is never
-- allowed.
create function public.message_gate(p_sender text, p_recipients text[])
returns table (handle text, allowed boolean)
language sql stable security definer set search_path = '' as $$
  select r.h, coalesce(s.id is not null and t.id is not null and private.message_reaches(s.id, t.id), false)
  from unnest(p_recipients) r(h)
  left join public.profiles s on s.handle = lower(p_sender)::extensions.citext
  left join public.profiles t on t.handle = lower(r.h)::extensions.citext;
$$;
revoke all on function public.message_gate(text, text[]) from public, anon, authenticated;
grant execute on function public.message_gate(text, text[]) to service_role;

-- Export includes the requests you were sent. The ones you sent belong to their recipients, who decide on them.
create or replace function public.export_my_data() returns jsonb
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
    'audit_log',(select coalesce(jsonb_agg(a), '[]') from public.audit_log a where a.actor_id = auth.uid()),
    'social_posts',    (select coalesce(jsonb_agg(x), '[]') from public.social_posts x where x.owner_id = auth.uid()),
    'social_follows',  (select coalesce(jsonb_agg(x), '[]') from public.social_follows x where x.owner_id = auth.uid()),
    'social_likes',    (select coalesce(jsonb_agg(x), '[]') from public.social_likes x where x.owner_id = auth.uid()),
    'social_comments', (select coalesce(jsonb_agg(x), '[]') from public.social_comments x where x.owner_id = auth.uid()),
    'social_seen',     (select coalesce(jsonb_agg(x), '[]') from public.social_seen x where x.owner_id = auth.uid()),
    'social_settings', (select to_jsonb(x) from public.social_settings x where x.owner_id = auth.uid()),
    'social_mutes',    (select coalesce(jsonb_agg(x), '[]') from public.social_mutes x where x.owner_id = auth.uid()),
    'social_saves',    (select coalesce(jsonb_agg(x), '[]') from public.social_saves x where x.owner_id = auth.uid()),
    'message_requests_received', (select coalesce(jsonb_agg(x), '[]') from public.message_requests x where x.recipient_id = auth.uid())
  );
$$;
