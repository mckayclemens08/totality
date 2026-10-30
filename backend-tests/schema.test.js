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

test('handles cannot be claimed until the owner sets the server name', async () => {
  const db = await newDatabase({ configured: false })
  const u = await newUser(db, null)
  await assert.rejects(as(db, u, (q) => q(`select public.claim_handle('owner')`)), /matrix_server_name/)
})
