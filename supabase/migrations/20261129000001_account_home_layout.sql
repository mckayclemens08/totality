-- Sign-in-linked Home grid layout per device kind (owner-approved exception, 2026-11-27).
-- Holds only module IDs, tile sizes, and removed/added timestamps — never user content — under strict owner-only RLS.
create table public.account_home_layouts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  visibility visibility_t not null default 'private' check (visibility = 'private'),
  device_kind text not null check (device_kind in ('iphone', 'mac')),
  layout_json jsonb not null check (pg_column_size(layout_json) <= 8192),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, device_kind)
);

alter table public.account_home_layouts enable row level security;
revoke all on public.account_home_layouts from public, anon;
grant select, insert, update, delete on public.account_home_layouts to authenticated;

create policy home_layout_select on public.account_home_layouts
  for select to authenticated using (owner_id = auth.uid());

create policy home_layout_insert on public.account_home_layouts
  for insert to authenticated with check (owner_id = auth.uid());

create policy home_layout_update on public.account_home_layouts
  for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy home_layout_delete on public.account_home_layouts
  for delete to authenticated using (owner_id = auth.uid());

create function public.save_home_layout(p_device_kind text, p_layout jsonb, p_updated_at timestamptz)
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_stamp timestamptz := coalesce(p_updated_at, now());
  v_result timestamptz;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  insert into public.account_home_layouts (owner_id, visibility, device_kind, layout_json, created_at, updated_at)
  values (v_uid, 'private', p_device_kind, p_layout, v_stamp, v_stamp)
  on conflict (owner_id, device_kind) do update
    set layout_json = case when excluded.updated_at > account_home_layouts.updated_at then excluded.layout_json else account_home_layouts.layout_json end,
        updated_at = greatest(account_home_layouts.updated_at, excluded.updated_at)
  returning updated_at into v_result;
  return v_result;
end;
$$;

revoke all on function public.save_home_layout(text, jsonb, timestamptz) from public, anon;
grant execute on function public.save_home_layout(text, jsonb, timestamptz) to authenticated;
