// Social safety (issue 149 §6): mute, report, who can comment, private accounts, hidden like counts, saves,
// and the "Who can message me" setting.
import { test, before, describe } from 'node:test'
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
const post = (u, body = 'Ceramics, climbing, too many houseplants.') => as(db, u, async (q) =>
  (await q('insert into public.social_posts (body) values ($1) returning *', [body]))[0])
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const settings = (u, s = {}) => rpc(u, 'select public.social_set_settings($1, $2, $3, $4)',
  [s.comment ?? 'anyone', s.message ?? 'anyone', s.private ?? false, s.hideLikes ?? false])
const profile = async (viewer, of) => (await rpc(viewer, 'select * from public.social_profile($1)', [of.handle]))[0]
const comment = (u, p, body = 'Lovely glaze.') => rpc(u, 'insert into public.social_comments (post_id, body) values ($1, $2)', [p.id, body])
const sees = async (u, p) => (await rpc(u, 'select id from public.social_posts where id = $1', [p.id])).length === 1

test('the new tables pass the invariant check', async () => {
  assert.deepEqual((await db.query(check)).rows, [])
})

describe('private accounts', () => {
  test('a follow is a request until approved, and only approved followers see posts', async () => {
    const [ana, eli, kai] = await trio()
    await settings(ana, { private: true })
    const p = await post(ana)
    await follow(eli, ana)
    assert.equal(await sees(eli, p), false)
    let view = await profile(eli, ana)
    assert.equal(view.requested, true)
    assert.equal(view.i_follow, false)
    assert.equal(view.private_account, true)
    assert.deepEqual((await rpc(ana, 'select handle from public.social_follow_requests()')).map((r) => r.handle), [eli.handle])
    assert.deepEqual(await rpc(kai, 'select handle from public.social_follow_requests()'), [])
    await rpc(ana, 'select public.social_approve_follower($1)', [eli.handle])
    assert.equal(await sees(eli, p), true)
    assert.equal(await sees(kai, p), false)
    view = await profile(eli, ana)
    assert.equal(view.i_follow, true)
    assert.equal(Number(view.followers), 1)
  })

  test('a pending request does not count as a follower or a friend', async () => {
    const [ana, eli] = await trio()
    await settings(ana, { private: true })
    await follow(eli, ana); await follow(ana, eli)
    assert.deepEqual(await rpc(eli, 'select * from public.social_friends()'), [])
    assert.deepEqual(await rpc(eli, 'select * from public.social_people($1, true)', [ana.handle]), [])
  })

  test('a request can be turned down, and going public lets the rest in', async () => {
    const [ana, eli, kai] = await trio()
    await settings(ana, { private: true })
    await follow(eli, ana); await follow(kai, ana)
    await rpc(ana, 'select public.social_remove_follower($1)', [eli.handle])
    assert.equal((await profile(eli, ana)).requested, false)
    await settings(ana, { private: false })
    assert.equal((await profile(kai, ana)).i_follow, true)
  })

  test('the owner always sees their own posts', async () => {
    const [ana] = await trio()
    await settings(ana, { private: true })
    assert.equal(await sees(ana, await post(ana)), true)
  })
})


describe('who can comment', () => {
  test('anyone, followers, friends, no one', async () => {
    const [ana, eli, kai] = await trio()
    const p = await post(ana)
    await follow(eli, ana)
    await settings(ana, { comment: 'followers' })
    await comment(eli, p)
    await assert.rejects(comment(kai, p), /row-level security/)
    await settings(ana, { comment: 'friends' })
    await assert.rejects(comment(eli, p), /row-level security/)
    await follow(ana, eli)
    await comment(eli, p)
    await settings(ana, { comment: 'no_one' })
    await assert.rejects(comment(eli, p), /row-level security/)
    await comment(ana, p, 'The author can always reply.')
    assert.equal((await profile(eli, ana)).can_comment, false)
  })
})

describe('who can message me', () => {
  test('the setting is readable as can_message, and no one is not a choice', async () => {
    const [ana, eli] = await trio()
    await settings(ana, { message: 'friends' })
    assert.equal((await profile(eli, ana)).can_message, false)
    await follow(eli, ana); await follow(ana, eli)
    assert.equal((await profile(eli, ana)).can_message, true)
    await assert.rejects(settings(ana, { message: 'no_one' }), /check/)
  })

  test('only you can change your settings', async () => {
    const [ana, eli] = await trio()
    await settings(ana, { private: true })
    assert.deepEqual(await rpc(eli, 'update public.social_settings set private_account = false where owner_id = $1 returning owner_id', [ana.id]), [])
    assert.equal((await rpc(ana, 'select * from public.social_my_settings()'))[0].private_account, true)
  })
})

describe('mutes, saves, hidden likes, reports', () => {
  test('a mute hides someone from your feeds, and only you know', async () => {
    const [ana, eli] = await trio()
    const p = await post(ana)
    await follow(eli, ana)
    await rpc(eli, 'insert into public.social_mutes (muted_id) values ($1)', [ana.id])
    assert.ok(!(await rpc(eli, 'select id from public.social_following_feed()')).some((r) => r.id === p.id))
    assert.ok(!(await rpc(eli, 'select id from public.social_for_you()')).some((r) => r.id === p.id))
    assert.equal((await profile(eli, ana)).muted, true)
    assert.deepEqual(await rpc(ana, 'select * from public.social_mutes'), [])
  })

  test('saves are private and come back as a list', async () => {
    const [ana, eli] = await trio()
    const p = await post(ana)
    await rpc(eli, 'insert into public.social_saves (post_id) values ($1)', [p.id])
    const saved = await rpc(eli, 'select id, saved from public.social_saved()')
    assert.deepEqual(saved, [{ id: p.id, saved: true }])
    assert.deepEqual(await rpc(ana, 'select * from public.social_saves'), [])
  })

  test('hidden like counts are null to others and shown to the author', async () => {
    const [ana, eli] = await trio()
    const p = await post(ana)
    await rpc(eli, 'insert into public.social_likes (post_id) values ($1)', [p.id])
    await settings(ana, { hideLikes: true })
    assert.equal((await rpc(eli, 'select likes, liked from public.social_post($1)', [p.id]))[0].likes, null)
    assert.equal((await rpc(eli, 'select liked from public.social_post($1)', [p.id]))[0].liked, true)
    assert.equal(Number((await rpc(ana, 'select likes from public.social_post($1)', [p.id]))[0].likes), 1)
  })

  test('a report names the person and the post, and only its sender reads it', async () => {
    const [ana, eli, kai] = await trio()
    const p = await post(ana)
    await rpc(eli, 'select public.social_report($1, $2, null, $3)', [ana.handle, p.id, 'Spam'])
    assert.equal((await rpc(eli, 'select * from public.reports where social_post_id = $1', [p.id])).length, 1)
    assert.deepEqual(await rpc(kai, 'select * from public.reports where social_post_id = $1', [p.id]), [])
    assert.deepEqual(await rpc(ana, 'select * from public.reports where social_post_id = $1', [p.id]), [])
    await assert.rejects(rpc(eli, 'select public.social_report($1, null, null, $2)', [ana.handle, '']), /check/)
  })
})
