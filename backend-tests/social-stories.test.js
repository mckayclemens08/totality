// Social step 4 (issue 149): video posts and stories. Only public stories are rows here; Friends and
// Close-friends stories live in Matrix. Views are readable by the viewer and the author only.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

let db, n = 0
before(async () => { db = await newDatabase() })

const three = async () => {
  n += 1
  return [await newUser(db, `maya_${n}`), await newUser(db, `jonah_${n}`), await newUser(db, `priya_${n}`)]
}
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const file = (owner, kind, extra = {}) => ({ kind, path: `${owner.id}/${randomUUID()}`, size: 1000, store: 'totality', ...extra })
const shelf = (owner, kind, extra = {}) => file(owner, kind, { store: 'stories', ...extra })
const story = (u, fields = {}) => as(db, u, async (q) => (await q(
  'insert into public.social_stories (kind, body, background, media) values ($1, $2, $3, $4) returning *',
  [fields.kind ?? 'text', fields.body ?? 'Moving day. If you have a dolly I owe you dinner.', fields.background ?? null,
    JSON.stringify(fields.media ?? [])]))[0])
const stories = (u) => rpc(u, 'select * from public.social_stories()')
const view = (u, s, author) => rpc(u, 'select public.social_view_story($1, $2)', [s.id ?? s, author.handle])
const viewers = (u, s) => rpc(u, 'select * from public.social_story_viewers($1)', [s.id ?? s])

describe('schema', () => {
  test('the story tables pass the invariant check', async () => {
    assert.deepEqual((await db.query(check)).rows, [])
  })
})

describe('video posts', () => {
  const postWith = (u, media) => rpc(u, `insert into public.social_posts (body, media) values ('Sunset from the Y trail.', $1) returning id`, [JSON.stringify(media)])

  test('a post can carry one video and its poster', async () => {
    const [maya] = await three()
    await postWith(maya, [file(maya, 'video', { duration: 42 }), file(maya, 'photo')])
    await postWith(maya, [file(maya, 'video', { duration: 180 })])
  })

  test('a video is three minutes at most, says how long it is, and never comes with audio or more photos', async () => {
    const [maya] = await three()
    await assert.rejects(postWith(maya, [file(maya, 'video', { duration: 200 })]), /check/)
    await assert.rejects(postWith(maya, [file(maya, 'video')]), /check/)
    await assert.rejects(postWith(maya, [file(maya, 'video', { duration: 30 }), file(maya, 'audio')]), /check/)
    await assert.rejects(postWith(maya, [file(maya, 'video', { duration: 30 }), file(maya, 'photo'), file(maya, 'photo')]), /check/)
    await assert.rejects(postWith(maya, [file(maya, 'video', { duration: 30 }), file(maya, 'video', { duration: 30 })]), /check/)
    const { store, ...old } = file(maya, 'video', { duration: 30 })
    await assert.rejects(postWith(maya, [old]), /check/)
  })
})

describe('stories', () => {
  test('a photo, video or text story, each with the right media, in your own folder and never with a key', async () => {
    const [maya, jonah] = await three()
    await story(maya, { kind: 'photo', body: '', media: [shelf(maya, 'photo')] })
    await story(maya, { kind: 'video', body: '', media: [shelf(maya, 'video', { duration: 30 }), shelf(maya, 'photo')] })
    await story(maya, { kind: 'text', background: 'sage' })
    await assert.rejects(story(maya, { kind: 'photo', media: [] }), /check/)
    // A story's file has to be on the shelf whose files go after a day.
    await assert.rejects(story(maya, { kind: 'photo', media: [file(maya, 'photo')] }), /check/)
    await assert.rejects(story(maya, { kind: 'photo', media: [shelf(jonah, 'photo')] }), /check/)
    await assert.rejects(story(maya, { kind: 'photo', media: [shelf(maya, 'photo', { key: 'abc' })] }), /check/)
    await assert.rejects(story(maya, { kind: 'video', media: [shelf(maya, 'video', { duration: 30 })] }), /check/)
    await assert.rejects(story(maya, { kind: 'text', body: '   ' }), /check/)
    await assert.rejects(story(maya, { kind: 'text', background: 'url(x)' }), /check/)
  })

  test('nobody can post a story as someone else, make one last longer, or make one private', async () => {
    const [maya, jonah] = await three()
    await assert.rejects(rpc(jonah, `insert into public.social_stories (owner_id, kind, body) values ($1, 'text', 'x')`, [maya.id]), /permission denied/)
    await assert.rejects(rpc(maya, `insert into public.social_stories (kind, body, expires_at) values ('text', 'x', now() + interval '9 days')`), /permission denied/)
    await assert.rejects(rpc(maya, `insert into public.social_stories (kind, body, visibility) values ('text', 'x', 'private')`), /permission denied/)
    await assert.rejects(rpc(maya, `update public.social_stories set body = 'changed'`), /permission denied/)
    const s = await story(maya)
    const day = (new Date(s.expires_at) - new Date(s.created_at)) / 3_600_000
    assert.equal(day, 24)
  })

  test('your stories and those of people you follow, oldest first, marked when you have seen them', async () => {
    const [maya, jonah, priya] = await three()
    await follow(jonah, maya)
    const first = await story(maya, { body: 'First' })
    const second = await story(maya, { body: 'Second' })
    await story(priya, { body: 'Not followed' })
    let got = await stories(jonah)
    assert.deepEqual(got.map((s) => s.body), ['First', 'Second'])
    assert.deepEqual(got.map((s) => s.viewed), [false, false])
    await view(jonah, first, maya)
    await view(jonah, first, maya)
    got = await stories(jonah)
    assert.deepEqual(got.map((s) => s.viewed), [true, false])
    assert.equal(got[0].handle, maya.handle)
    assert.deepEqual((await stories(maya)).map((s) => s.id), [first.id, second.id])
  })

  test('an expired story is never read, and goes on the next story posted', async () => {
    const [maya, jonah] = await three()
    await follow(jonah, maya)
    const old = await story(maya, { body: 'Yesterday' })
    await db.query(`update public.social_stories set expires_at = now() - interval '1 minute' where id = $1`, [old.id])
    assert.deepEqual(await stories(jonah), [])
    assert.deepEqual(await rpc(jonah, 'select id from public.social_stories where id = $1', [old.id]), [])
    await story(maya, { body: 'Today' })
    assert.equal((await db.query('select count(*)::int as n from public.social_stories where id = $1', [old.id])).rows[0].n, 0)
  })

  test('a private account’s stories reach approved followers only, and blocks and mutes hide them', async () => {
    const [maya, jonah, priya] = await three()
    await rpc(maya, `select public.social_set_settings('anyone', 'anyone', true, false)`)
    await follow(jonah, maya)
    await story(maya)
    assert.deepEqual(await stories(jonah), [])
    await rpc(maya, 'select public.social_approve_follower($1)', [jonah.handle])
    assert.equal((await stories(jonah)).length, 1)
    await follow(priya, jonah)
    await story(jonah)
    await rpc(priya, 'insert into public.social_mutes (muted_id) values ($1)', [jonah.id])
    assert.deepEqual(await stories(priya), [])
    await rpc(jonah, 'select public.block_contact($1)', [maya.id])
    assert.deepEqual((await stories(jonah)).filter((s) => s.handle === maya.handle), [])
  })

  test('only the author sees who viewed a story', async () => {
    const [maya, jonah, priya] = await three()
    await follow(jonah, maya)
    await follow(priya, maya)
    const s = await story(maya)
    await view(jonah, s, maya)
    assert.deepEqual((await viewers(maya, s)).map((v) => v.handle), [jonah.handle])
    assert.deepEqual(await viewers(jonah, s), [])
    assert.deepEqual(await viewers(priya, s), [])
    assert.deepEqual(await rpc(priya, 'select * from public.social_story_views'), [])
    // Viewing your own story is nothing.
    await view(maya, s, maya)
    assert.equal((await viewers(maya, s)).length, 1)
  })

  test('an encrypted story’s view names only its ID and author, and a public story’s must name its real author', async () => {
    const [maya, jonah, priya] = await three()
    const sealedStory = randomUUID()
    await view(jonah, sealedStory, maya)
    assert.deepEqual((await viewers(maya, sealedStory)).map((v) => v.handle), [jonah.handle])
    await follow(jonah, maya)
    const s = await story(maya)
    await assert.rejects(rpc(jonah, 'insert into public.social_story_views (author_id, story_id) values ($1, $2)', [priya.id, s.id]), /row-level security/)
    await assert.rejects(rpc(jonah, 'insert into public.social_story_views (owner_id, author_id, story_id) values ($1, $2, $3)', [priya.id, maya.id, randomUUID()]), /permission denied/)
  })

  test('a blocked person can’t leave a view, and views go with the story’s day', async () => {
    const [maya, jonah] = await three()
    await rpc(maya, 'select public.block_contact($1)', [jonah.id])
    await assert.rejects(rpc(jonah, 'insert into public.social_story_views (author_id, story_id) values ($1, $2)', [maya.id, randomUUID()]), /row-level security/)
    // Through the app's call it's quietly nothing, so it never reveals the block.
    await view(jonah, randomUUID(), maya)
    assert.deepEqual(await rpc(jonah, 'select * from public.social_story_views'), [])
    const [ana, ben] = await three()
    const id = randomUUID()
    await view(ben, id, ana)
    await db.query(`update public.social_story_views set expires_at = now() - interval '1 minute' where story_id = $1`, [id])
    assert.deepEqual(await viewers(ana, id), [])
    await story(ana)
    assert.equal((await db.query('select count(*)::int as n from public.social_story_views where story_id = $1', [id])).rows[0].n, 0)
  })

  test('your stories and views are in your export', async () => {
    const [maya, jonah] = await three()
    await story(maya)
    await view(jonah, randomUUID(), maya)
    const [mine] = await rpc(maya, 'select public.export_my_data() as x')
    assert.equal(mine.x.social_stories.length, 1)
    const [theirs] = await rpc(jonah, 'select public.export_my_data() as x')
    assert.equal(theirs.x.social_story_views.length, 1)
  })
})
