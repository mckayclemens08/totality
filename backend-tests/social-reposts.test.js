// Social reposts: public posts only, shown to the reposter's followers, counted, and undone by deleting.
import { test, before } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

let db, n = 0
before(async () => { db = await newDatabase() })

const trio = async () => {
  n += 1
  return [await newUser(db, `ana_${n}`), await newUser(db, `eli_${n}`), await newUser(db, `kai_${n}`)]
}
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const post = (u, body = 'Glazing day: three pots, one keeper.') => as(db, u, async (q) =>
  (await q('insert into public.social_posts (body) values ($1) returning *', [body]))[0])
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const repost = (u, p) => rpc(u, 'insert into public.social_reposts (post_id) values ($1)', [p.id])
const feed = (u) => rpc(u, 'select * from public.social_reposts_feed()')
const stats = async (u, p) => (await rpc(u, 'select * from public.social_repost_stats($1)', [[p.id]]))[0]

test('the table passes the invariant check', async () => {
  assert.deepEqual((await db.query(check)).rows, [])
})

test('a repost shows in the followers\' Following with who reposted it, and counts', async () => {
  const [ana, eli, kai] = await trio()
  const p = await post(ana)
  await follow(eli, kai) // eli follows kai, not ana
  await repost(kai, p)
  const rows = await feed(eli)
  assert.equal(rows.length, 1)
  assert.equal(rows[0].reposter_handle, kai.handle)
  assert.equal(rows[0].post.id, p.id)
  assert.equal(rows[0].post.handle, ana.handle)
  const s = await stats(eli, p)
  assert.equal(Number(s.reposts), 1)
  assert.equal(s.reposted, false)
  assert.equal((await stats(kai, p)).reposted, true)
  // Someone who doesn't follow kai doesn't get it in Following, but sees it on kai's profile.
  assert.deepEqual(await feed(ana), [])
  assert.equal((await rpc(ana, 'select * from public.social_reposts_by($1)', [kai.handle])).length, 1)
})

test('undo removes it, and nobody can repost or undo as someone else', async () => {
  const [ana, eli, kai] = await trio()
  const p = await post(ana)
  await follow(eli, kai)
  await repost(kai, p)
  await assert.rejects(rpc(eli, 'insert into public.social_reposts (owner_id, post_id) values ($1, $2)', [kai.id, p.id]), /permission denied/)
  await rpc(eli, 'delete from public.social_reposts where owner_id = $1', [kai.id])
  assert.equal((await feed(eli)).length, 1)
  await rpc(kai, 'delete from public.social_reposts where post_id = $1', [p.id])
  assert.deepEqual(await feed(eli), [])
  assert.equal(Number((await stats(eli, p)).reposts), 0)
})

test('you can\'t repost your own post, or the same post twice', async () => {
  const [ana, eli] = await trio()
  const p = await post(ana)
  await assert.rejects(repost(ana, p), /row-level security/)
  await repost(eli, p)
  await assert.rejects(repost(eli, p), /duplicate|unique/)
})

test('a private account\'s post can\'t be reposted', async () => {
  const [ana, eli, kai] = await trio()
  await rpc(ana, 'select public.social_set_settings($1, $2, $3, $4)', ['anyone', 'anyone', true, false])
  const p = await post(ana)
  await follow(eli, ana)
  await rpc(ana, 'select public.social_approve_follower($1)', [eli.handle])
  await assert.rejects(repost(eli, p), /row-level security/)
  assert.deepEqual(await feed(kai), [])
})

test('a muted reposter is skipped, and a block hides the repost', async () => {
  const [ana, eli, kai] = await trio()
  const p = await post(ana)
  await follow(eli, kai)
  await repost(kai, p)
  assert.equal((await feed(eli)).length, 1)
  await rpc(eli, 'insert into public.social_mutes (muted_id) values ($1)', [kai.id])
  assert.deepEqual(await feed(eli), [])
  await rpc(eli, 'delete from public.social_mutes where muted_id = $1', [kai.id])
  assert.equal((await feed(eli)).length, 1)
  // The author blocks eli: eli can't read the post, so can't see a repost of it.
  await rpc(ana, 'select public.block_contact($1)', [eli.id])
  assert.deepEqual(await feed(eli), [])
  assert.equal((await rpc(eli, 'select * from public.social_reposts_by($1)', [kai.handle])).length, 0)
})

test('deleting a post removes its reposts, and anon reads nothing', async () => {
  const [ana, eli] = await trio()
  const p = await post(ana)
  await repost(eli, p)
  await rpc(ana, 'delete from public.social_posts where id = $1', [p.id])
  assert.deepEqual(await rpc(eli, 'select * from public.social_reposts where post_id = $1', [p.id]), [])
  await assert.rejects(rpc(null, 'select * from public.social_reposts'), /permission denied/)
  await assert.rejects(rpc(null, 'select * from public.social_reposts_feed()'), /permission denied/)
})
