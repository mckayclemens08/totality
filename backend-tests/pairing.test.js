import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
const hex = (c) => c.repeat(64)
before(async () => { db = await newDatabase() })
const pair = async () => { n += 1; return [await newUser(db, `pair_a${n}`), await newUser(db, `pair_b${n}`)] }
const open = (u) => as(db, u, async (q) =>
  (await q(`insert into public.pairing_slots (browser_pub, device_label) values ($1, 'Safari on a Mac') returning id`, [hex('a')]))[0].id)
const fill = (u, id) => as(db, u, (q) => q(`update public.pairing_slots set phone_pub = $2, sealed = 'abc' where id = $1 returning id`, [id, hex('b')]))
const visible = async (u, id) => (await as(db, u, (q) => q('select id from public.pairing_slots where id = $1', [id]))).length === 1

describe('browser pairing slots (issue 150)', () => {
  test('two-user: user 2 cannot see, fill or delete user 1 slot', async () => {
    const [u1, u2] = await pair()
    const id = await open(u1)
    assert.equal(await visible(u1, id), true)
    assert.equal(await visible(u2, id), false)
    assert.equal((await fill(u2, id)).length, 0)
    await as(db, u2, (q) => q('delete from public.pairing_slots where id = $1', [id]))
    assert.equal(await visible(u1, id), true)
  })

  test('a slot can be filled once, then not changed', async () => {
    const [u1] = await pair()
    const id = await open(u1)
    assert.equal((await fill(u1, id)).length, 1)
    assert.equal((await fill(u1, id)).length, 0)
  })

  test('an expired slot cannot be read or filled', async () => {
    const [u1] = await pair()
    const id = await open(u1)
    await db.query(`update public.pairing_slots set expires_at = now() - interval '1 second' where id = $1`, [id])
    assert.equal(await visible(u1, id), false)
    assert.equal((await fill(u1, id)).length, 0)
  })

  test('the server sets the expiry, not the client', async () => {
    const [u1] = await pair()
    await assert.rejects(as(db, u1, (q) => q(
      `insert into public.pairing_slots (browser_pub, device_label, expires_at) values ($1, 'x', now() + interval '1 year')`, [hex('a')])))
  })

  test('a phone key without a sealed key is refused, and keys must be hex', async () => {
    const [u1] = await pair()
    const id = await open(u1)
    await assert.rejects(as(db, u1, (q) => q(`update public.pairing_slots set phone_pub = $2 where id = $1`, [id, hex('b')])))
    await assert.rejects(as(db, u1, (q) => q(`insert into public.pairing_slots (browser_pub, device_label) values ('zz', 'x')`)))
  })

  test('at most five open codes at a time', async () => {
    const [u1] = await pair()
    for (let i = 0; i < 5; i++) await open(u1)
    await assert.rejects(open(u1))
  })
})
