// Runs the real migration on real Postgres (PGlite) with a stand-in for what Supabase provides.
// The stand-in matches Supabase's role grants so tests are not safer than production. Storage is
// tested at the policy level only, not through the Storage API.
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { PGlite } from '@electric-sql/pglite'
import { citext } from '@electric-sql/pglite/contrib/citext'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'

const root = new URL('..', import.meta.url).pathname

const SUPABASE_STUB = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  create schema auth;
  create schema storage;
  create schema extensions;
  grant usage on schema public, auth, storage, extensions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
  $$;
  create table storage.buckets (
    id text primary key, name text, public boolean default false,
    file_size_limit bigint, allowed_mime_types text[]
  );
  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets(id),
    name text not null,
    owner uuid
  );
  alter table storage.objects enable row level security;
  grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
  create function storage.foldername(name text) returns text[] language sql immutable as $$
    select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
  $$;
`

export const SERVER_NAME = 'totality.test'

export async function newDatabase({ configured = true } = {}) {
  const db = await PGlite.create({ extensions: { citext, pgcrypto } })
  await db.exec(SUPABASE_STUB)
  const dir = process.env.TOTALITY_MIGRATIONS_DIR ?? `${root}supabase/migrations/`
  for (const f of readdirSync(dir).sort()) await db.exec(readFileSync(dir + f, 'utf8'))
  if (configured) await db.query('update public.instance_config set matrix_server_name = $1', [SERVER_NAME])
  return db
}

export async function newUser(db, handle, username = handle ?? `u_${randomUUID().slice(0, 8)}`) {
  const id = randomUUID()
  const email = `${username}@totality.invalid`
  await db.query('insert into auth.users (id, email) values ($1, $2)', [id, email])
  const user = { id, email, handle }
  if (handle) await as(db, user, (q) => q('select public.claim_handle($1)', [handle]))
  return user
}

// Runs fn as a signed-in user, or as anon when user is null, then commits.
export async function as(db, user, fn) {
  return db.transaction(async (tx) => {
    await tx.query(`select set_config('request.jwt.claims', $1, true)`,
      [user ? JSON.stringify({ sub: user.id, role: 'authenticated' }) : ''])
    await tx.exec(`set local role ${user ? 'authenticated' : 'anon'}`)
    const q = async (sql, params) => (await tx.query(sql, params)).rows
    return fn(q)
  })
}

export async function addObject(db, user, fields = {}) {
  const id = randomUUID()
  const o = {
    kind: 'file', visibility: 'private', key_ref: `crk:${id}`,
    storage_key: `${user.id}/${id}`, ...fields,
  }
  await as(db, user, (q) => q(
    `insert into public.content_objects (id, owner_id, kind, visibility, key_ref, storage_key)
     values ($1, $2, $3, $4, $5, $6)`,
    [id, user.id, o.kind, o.visibility, o.key_ref, o.storage_key]))
  if (o.storage_key) {
    await as(db, user, (q) => q(
      `insert into storage.objects (bucket_id, name) values ('content', $1)`, [o.storage_key]))
  }
  return { id, ...o }
}
