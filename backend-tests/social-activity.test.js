// Social activity for notifications (issue 232): what a woken phone asks for. It must return only what
// the person could already read, skip blocks and mutes both ways, and never their own activity.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const four = async () => {
  n += 1
  return [await newUser(db, `ana_a${n}`), await newUser(db, `eli_a${n}`), await newUser(db, `kai_a${n}`), await newUser(db, `mia_a${n}`)]
}
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const post = async (u, body) => (await rpc(u, 'insert into public.social_posts (body) values ($1) returning id', [body]))[0]
const like = (u, p) => rpc(u, 'insert into public.social_likes (post_id) values ($1)', [p.id])
const comment = async (u, p, body, parent = null) => (await rpc(u,
  'insert into public.social_comments (post_id, parent_id, body) values ($1, $2, $3) returning id', [p.id, parent, body]))[0]
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const activity = (u, since = '1970-01-01') =>
  rpc(u, 'select kind, handle, post_snippet, snippet from public.social_activity($1, 50)', [since])
const kinds = (rows) => rows.map((r) => `${r.kind}:${r.handle}`).sort()

describe('social_activity', () => {
  test('gathers follows, requests, likes, comments and replies to you', async () => {
    const [ana, eli, kai, mia] = await four()
    const p = await post(ana, 'First frost on the Wasatch this morning')
    await follow(eli, ana)
    await like(eli, p)
    await rpc(eli, 'insert into public.social_reposts (post_id) values ($1)', [p.id])
    const top = await comment(kai, p, 'Gorgeous light.')
    await comment(ana, p, 'Thanks!', top.id)
    // Mia replies to Kai's comment on Ana's post: Ana hears of it as a comment, Kai as a reply.
    await comment(mia, p, 'Agreed', top.id)
    await rpc(mia, `select public.social_set_settings('anyone', 'anyone', true, false)`)
    await follow(kai, mia)

    assert.deepEqual(kinds(await activity(ana)),
      [`comment:${kai.handle}`, `comment:${mia.handle}`, `follower:${eli.handle}`, `like:${eli.handle}`, `repost:${eli.handle}`])
    assert.deepEqual(kinds(await activity(kai)), [`reply:${ana.handle}`, `reply:${mia.handle}`])
    assert.deepEqual(kinds(await activity(mia)), [`request:${kai.handle}`])
    const [liked] = (await activity(ana)).filter((r) => r.kind === 'like')
    assert.equal(liked.post_snippet, 'First frost on the Wasatch this morning')
  })

  test('skips your own activity, and anything older than asked', async () => {
    const [ana, eli] = await four()
    const p = await post(ana, 'Sourdough, day three.')
    await like(ana, p)
    await comment(ana, p, 'Update: it rose.')
    assert.deepEqual(await activity(ana), [])
    await like(eli, p)
    assert.deepEqual(await activity(ana, new Date(Date.now() + 60_000).toISOString()), [])
  })

  test('leaves out people you muted or blocked, and people who blocked you', async () => {
    const [ana, eli, kai, mia] = await four()
    const p = await post(ana, 'Trail notes')
    for (const u of [eli, kai, mia]) await like(u, p)
    await rpc(ana, 'insert into public.social_mutes (muted_id) values ($1)', [eli.id])
    await rpc(ana, 'select public.block_contact($1)', [kai.id])
    await rpc(mia, 'select public.block_contact($1)', [ana.id])
    assert.deepEqual(await activity(ana), [])
  })

  test("is nobody's but the caller's", async () => {
    const [ana, eli] = await four()
    const p = await post(ana, 'Mine')
    await like(eli, p)
    assert.equal((await activity(eli)).length, 0)
  })
})
