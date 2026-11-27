-- Broadcast channels: you may only invite people who follow you (owner, 2026-11-26). The Matrix guard
-- recognises a channel by its power levels and asks the message-gate function with channel: true, which then
-- asks this as well as message_gate, so a modified app can't invite just anyone. The message_gate rule
-- ("who can message me") still applies on top. No table is added or changed.

-- For each Matrix username p_sender wants to invite to a channel, whether that person follows p_sender
-- (an approved follow) and neither side has blocked the other. An unknown name is never allowed. Only the
-- message-gate edge function can call this, with the service role.
create function public.channel_gate(p_sender text, p_recipients text[])
returns table (handle text, allowed boolean)
language sql stable security definer set search_path = '' as $$
  select r.h, coalesce(s.id is not null and t.id is not null
                       and not private.message_hidden(s.id, t.id)
                       and private.social_follows_approved(t.id, s.id), false)
  from unnest(p_recipients) r(h)
  left join public.profiles s on s.handle = lower(p_sender)::extensions.citext
  left join public.profiles t on t.handle = lower(r.h)::extensions.citext;
$$;
revoke all on function public.channel_gate(text, text[]) from public, anon, authenticated;
grant execute on function public.channel_gate(text, text[]) to service_role;
