import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

test('the schema passes the invariant check', async () => {
  const db = await newDatabase()
  assert.deepEqual((await db.query(check)).rows, [])
})

test('the check catches a bad table', async () => {
  const db = await newDatabase()
  await db.exec(`create table public.bad (id uuid primary key, filename text)`)
  const problems = (await db.query(check)).rows.map((r) => r.problem)
  for (const p of ['RLS is off', 'RLS is on but no policy exists', 'missing column: owner_id',
                   'missing column: visibility', 'plaintext content column: filename']) {
    assert.ok(problems.includes(p), p)
  }
})

test('a handle can be claimed before the server name is set, with no Matrix address yet', async () => {
  const db = await newDatabase({ configured: false })
  const u = await newUser(db, 'early_owner')
  const rows = await as(db, u, (q) => q('select handle, mxid from public.profiles where id = $1', [u.id]))
  assert.deepEqual(rows, [{ handle: 'early_owner', mxid: null }])
})

test('setting the server name fills in addresses made before it, and new ones follow', async () => {
  const db = await newDatabase({ configured: false })
  await newUser(db, 'early_user')
  await db.query(`update public.instance_config set matrix_server_name = 'usetotality.com'`)
  await newUser(db, 'later_user')
  const { rows } = await db.query('select handle, mxid from public.profiles order by handle')
  assert.deepEqual(rows, [
    { handle: 'early_user', mxid: '@early_user:usetotality.com' },
    { handle: 'later_user', mxid: '@later_user:usetotality.com' },
  ])
})

test('the server name cannot change once set, because Matrix addresses cannot be renamed', async () => {
  const db = await newDatabase({ configured: false })
  await db.query(`update public.instance_config set matrix_server_name = 'usetotality.com'`)
  await assert.rejects(db.query(`update public.instance_config set matrix_server_name = 'other.example'`), /server name/)
  await assert.rejects(db.query(`update public.instance_config set matrix_server_name = null`), /server name/)
  await db.query(`update public.instance_config set matrix_server_name = 'usetotality.com'`)
})

test('clients cannot set the server name', async () => {
  const db = await newDatabase({ configured: false })
  const u = await newUser(db, 'plain_user')
  await assert.rejects(as(db, u, (q) => q(`update public.instance_config set matrix_server_name = 'evil.example'`)), /permission denied/)
  await assert.rejects(as(db, null, (q) => q(`update public.instance_config set matrix_server_name = 'evil.example'`)), /permission denied/)
})

test('a function added by a later migration is closed to anon by default', async () => {
  const db = await newDatabase()
  await db.exec(`create function public.later_rpc() returns int language sql security definer as 'select 1'`)
  assert.deepEqual((await db.query(`
    select has_function_privilege('anon', 'public.later_rpc()', 'EXECUTE') as anon,
           has_function_privilege('authenticated', 'public.later_rpc()', 'EXECUTE') as authed`)).rows,
    [{ anon: false, authed: false }])
})

test('the check catches a function anon can call', async () => {
  const db = await newDatabase()
  await db.exec(`create function public.open_rpc() returns int language sql as 'select 1';
                 grant execute on function public.open_rpc() to anon`)
  const problems = (await db.query(check)).rows
  assert.deepEqual(problems, [{ table_name: 'open_rpc', problem: 'anon can execute this function' }])
})
