-- The server name becomes part of every Matrix address, and those can't be renamed. So setting it
-- fills in the profiles made before it existed, and changing it afterwards is refused.
create function private.apply_matrix_server_name() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.matrix_server_name is not null and new.matrix_server_name is distinct from old.matrix_server_name then
    raise exception 'the Matrix server name cannot change' using errcode = '23514';
  end if;
  if old.matrix_server_name is null and new.matrix_server_name is not null then
    update public.profiles
    set mxid = '@' || lower(handle::text) || ':' || new.matrix_server_name
    where mxid is null;
  end if;
  return new;
end $$;
revoke all on function private.apply_matrix_server_name() from public, anon, authenticated;

create trigger apply_matrix_server_name before update of matrix_server_name on public.instance_config
  for each row execute function private.apply_matrix_server_name();
