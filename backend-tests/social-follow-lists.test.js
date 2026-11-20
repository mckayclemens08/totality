// Social followers and following lists (owner, 2026-11-19): private lists hidden from non-followers,
// counts kept, each row's relationship, paging and search.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

let db, n = 0
before(async () => { db = await newDatabase() })

const four = async () => {
  n += 1
  return [await newUser(db, `ana_${n}`), await newUser(db, `eli_${n}`), await newUser(db, `kai_${n}`), await newUser(db, `mia_${n}`)]
}
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const approve = (owner, who) => rpc(owner, 'select public.social_approve_follower($1)', [who.handle])
const goPrivate = (u) => rpc(u, `select public.social_set_settings('anyone', 'anyone', true, false)`)
const block = (a, b) => rpc(a, 'select public.block_contact($1)', [b.id])
const people = async (viewer, of, followers, extra = {}) =>
  rpc(viewer, 'select * from public.social_people($1, $2, $3, $4, $5, $6)',
    [of.handle, followers, extra.query ?? null, extra.beforeAt ?? null, extra.beforeHandle ?? null, extra.limit ?? 50])
const handles = (rows) => rows.map((r) => r.handle).sort()
const tableRows = (viewer, who) => rpc(viewer,
  'select owner_id, followee_id from public.social_follows where owner_id = $1 or followee_id = $1', [who.id])
const profile = async (viewer, of) => (await rpc(viewer, 'select * from public.social_profile($1)', [of.handle]))[0]

test('the schema still passes the invariant check', async () => {
  assert.deepEqual((await db.query(check)).rows, [])
})

describe('private accounts', () => {
  test("a private account's lists, both ways, are for it and its approved followers only", async () => {
    const [ana, eli, kai, mia] = await four()
    await goPrivate(ana)
    await follow(eli, ana); await approve(ana, eli)
    await follow(ana, mia)
    await follow(kai, ana) // pending
    // Ana herself, and Eli (approved), see both lists.
    for (const viewer of [ana, eli]) {
      assert.deepEqual(handles(await people(viewer, ana, true)), [eli.handle])
      assert.deepEqual(handles(await people(viewer, ana, false)), [mia.handle])
    }
    // Kai's request is pending, so Kai sees neither list, and the table gives nothing more.
    assert.deepEqual(await people(kai, ana, true), [])
    assert.deepEqual(await people(kai, ana, false), [])
    const kaiSees = await tableRows(kai, ana)
    assert.deepEqual(kaiSees.map((r) => r.owner_id), [kai.id]) // only Kai's own request
    // Mia is followed by Ana but doesn't follow her: Mia sees only the row she's in.
    assert.deepEqual(handles(await people(mia, ana, false)), [mia.handle])
    assert.deepEqual(await people(mia, ana, true), [])
    assert.deepEqual((await tableRows(mia, ana)).map((r) => r.owner_id), [ana.id])
  })

  test("a private follower is left off a public account's list for strangers", async () => {
    const [ana, eli, kai] = await four()
    await goPrivate(eli)
    await follow(eli, ana) // Ana is public
    assert.deepEqual(handles(await people(kai, ana, true)), [])
    assert.deepEqual(handles(await people(ana, ana, true)), [eli.handle]) // Ana is in the row
  })

  test('a private profile still shows its counts, as numbers', async () => {
    const [ana, eli, kai] = await four()
    await goPrivate(ana)
    await follow(eli, ana); await approve(ana, eli)
    await follow(ana, eli)
    const view = await profile(kai, ana)
    assert.equal(Number(view.followers), 1)
    assert.equal(Number(view.following), 1)
    assert.equal(view.private_account, true)
  })

  test('public lists stay public', async () => {
    const [ana, eli, kai] = await four()
    await follow(eli, ana)
    assert.deepEqual(handles(await people(kai, ana, true)), [eli.handle])
    assert.equal((await tableRows(kai, ana)).length, 1)
  })

  test('feeds and friends still work with a private account', async () => {
    const [ana, eli, kai] = await four()
    await goPrivate(eli)
    await follow(ana, eli); await approve(eli, ana)
    await follow(eli, ana)
    await follow(eli, kai)
    assert.deepEqual((await rpc(ana, 'select handle from public.social_friends()')).map((r) => r.handle), [eli.handle])
    await rpc(kai, `insert into public.social_posts (body) values ('Sourdough, day three.')`)
    // Ana follows Eli, who follows Kai: For You can say so, because Ana is allowed to see Eli's list.
    const why = (await rpc(ana, 'select handle, reason from public.social_for_you(30, null)')).find((r) => r.handle === kai.handle)
    assert.match(why.reason, new RegExp(eli.handle))
  })
})

describe('rows', () => {
  test('each row says how you relate to them, with their photo key', async () => {
    const [ana, eli, kai, mia] = await four()
    await goPrivate(mia)
    await follow(eli, ana); await follow(kai, ana); await follow(mia, ana)
    await follow(ana, kai) // Kai: Friends
    await follow(ana, mia) // Mia is private: requested
    await rpc(eli, `update public.profiles set avatar_key = $2 where id = $1`, [eli.id, `${eli.id}/6f1c2b3a-9d8e-4f70-a1b2-c3d4e5f60718.jpg`])
    const rows = Object.fromEntries((await people(ana, ana, true)).map((r) => [r.handle, r]))
    assert.deepEqual([rows[eli.handle].i_follow, rows[eli.handle].follows_me, rows[eli.handle].requested], [false, true, false])
    assert.deepEqual([rows[kai.handle].i_follow, rows[kai.handle].follows_me], [true, true])
    assert.deepEqual([rows[mia.handle].i_follow, rows[mia.handle].requested], [false, true])
    assert.equal(rows[eli.handle].avatar_key, `${eli.id}/6f1c2b3a-9d8e-4f70-a1b2-c3d4e5f60718.jpg`)
    assert.equal(rows[eli.handle].id, eli.id)
    await rpc(ana, 'insert into public.social_mutes (muted_id) values ($1)', [eli.id])
    assert.equal((await people(ana, ana, true, { query: eli.handle }))[0].muted, true)
  })

  test('a block hides them from every list', async () => {
    const [ana, eli, kai] = await four()
    await follow(eli, ana); await follow(kai, ana)
    await block(kai, eli)
    assert.deepEqual(handles(await people(kai, ana, true)), [kai.handle])
    assert.deepEqual(handles(await people(eli, ana, true)), [eli.handle])
  })
})

describe('paging and search', () => {
  test('pages with a cursor, newest first, with no repeats', async () => {
    const [ana] = await four()
    const fans = []
    for (let i = 0; i < 7; i++) { const u = await newUser(db, `fan${i}_${n}`); fans.push(u); await follow(u, ana) }
    const seen = []
    let cursor = {}
    for (;;) {
      const page = await people(ana, ana, true, { limit: 3, ...cursor })
      if (page.length === 0) break
      seen.push(...page.map((r) => r.handle))
      const last = page[page.length - 1]
      cursor = { beforeAt: last.followed_at, beforeHandle: last.handle }
    }
    assert.equal(seen.length, 7)
    assert.equal(new Set(seen).size, 7)
    assert.equal(seen[0], fans[6].handle)
  })

  test('search matches the start of a username, a name, or a word in it', async () => {
    const [ana, eli, kai, mia] = await four()
    for (const u of [eli, kai, mia]) await follow(u, ana)
    await rpc(eli, `update public.profiles set display_name = 'Maya Chen' where id = $1`, [eli.id])
    await rpc(kai, `update public.profiles set display_name = 'Kai Mart' where id = $1`, [kai.id])
    assert.deepEqual(handles(await people(ana, ana, true, { query: 'ma' })), [eli.handle, kai.handle].sort())
    assert.deepEqual(handles(await people(ana, ana, true, { query: 'CHEN' })), [eli.handle])
    assert.deepEqual(handles(await people(ana, ana, true, { query: '@mia_' })), [mia.handle])
    assert.deepEqual(await people(ana, ana, true, { query: '%' }), [])
    assert.deepEqual(await people(ana, ana, true, { query: 'ia_' }), [])
    assert.equal((await people(ana, ana, true, { query: '  ' })).length, 3)
  })
})
