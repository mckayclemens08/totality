-- Fails review if any row comes back. Proposal §5.1.
with allowlist(name) as (values
  ('instance_config'), ('profiles'), ('identity_keys'), ('devices'), ('push_tokens'),
  ('contacts'), ('invites'), ('content_shares'), ('notifications'), ('reports'),
  ('audit_log'), ('ai_grants'), ('retired_handles')
),
tables as (
  select c.oid, c.relname, c.relrowsecurity
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
)
select relname as table_name, 'RLS is off' as problem from tables where not relrowsecurity
union all
select t.relname, 'RLS is on but no policy exists' from tables t
where not exists (select 1 from pg_policy p where p.polrelid = t.oid)
union all
select t.relname, 'missing column: ' || req.col
from tables t
cross join (values ('owner_id'), ('visibility'), ('created_at'), ('updated_at')) req(col)
where t.relname not in (select name from allowlist)
  and not exists (
    select 1 from pg_attribute a
    where a.attrelid = t.oid and a.attname = req.col and not a.attisdropped
  )
union all
select t.relname, 'plaintext content column: ' || a.attname
from tables t
join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
where t.relname not in (select name from allowlist)
  and a.attname in ('title', 'filename', 'file_name', 'name', 'body', 'content', 'caption', 'text')
union all
select p.proname, 'anon can execute this function'
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
order by 1, 2;
