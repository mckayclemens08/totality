// Social's server tables (issue 149). Only public social content is here; Friends and Close-friends
// posts are in Matrix and never reach these tables.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `maya_${n}`), await newUser(db, `jonah_${n}`), await newUser(db, `priya_${n}`)]
}
const post = (user, fields = {}) => as(db, user, async (q) => (await q(
  `insert into public.social_posts (title, body, tags) values ($1, $2, $3) returning *`,
  [fields.title ?? null, fields.body ?? 'Sourdough attempt #4: finally an open crumb.', fields.tags ?? []]))[0])
const follow = (a, b) => as(db, a, (q) => q('select public.social_follow($1)', [b.handle]))
const unfollow = (a, b) => as(db, a, (q) => q('select public.social_unfollow($1)', [b.handle]))
const like = (u, p) => as(db, u, (q) => q('insert into public.social_likes (post_id) values ($1)', [p.id]))
const comment = (u, p, body, parent = null) => as(db, u, async (q) => (await q(
  'insert into public.social_comments (post_id, parent_id, body) values ($1, $2, $3) returning *', [p.id, parent, body]))[0])
const block = (a, b) => as(db, a, (q) => q('select public.block_contact($1)', [b.id]))
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const forYou = (u, tag = null) => rpc(u, 'select * from public.social_for_you(30, $1)', [tag])
const following = (u) => rpc(u, 'select * from public.social_following_feed()')

describe('schema', () => {
  test('the Social tables pass the invariant check', async () => {
    assert.deepEqual((await db.query(check)).rows, [])
  })

  test('plaintext is allowed only on a table pinned to public', async () => {
    const fresh = await newDatabase()
    await fresh.exec(`
      create table public.loose (id uuid primary key, owner_id uuid, visibility public.visibility_t default 'public',
        created_at timestamptz, updated_at timestamptz, body text);
      alter table public.loose enable row level security;
      create policy loose_select on public.loose for select using (true);`)
    const rows = (await fresh.query(check)).rows
    assert.deepEqual(rows, [{ table_name: 'loose', problem: 'plaintext content column: body' }])
  })

  test('a public table cannot be given a private row', async () => {
    const [u] = await pair()
    await assert.rejects(rpc(u, `insert into public.social_posts (body, visibility) values ('x', 'private')`), /permission denied/)
    await assert.rejects(db.query(`insert into public.social_posts (owner_id, body, visibility) values ($1, 'x', 'contacts')`, [u.id]), /check/)
  })

  test('nobody can post, like or comment as someone else', async () => {
    const [u1, u2] = await pair()
    await assert.rejects(rpc(u2, `insert into public.social_posts (owner_id, body) values ($1, 'as you')`, [u1.id]), /permission denied/)
    const p = await post(u1)
    await assert.rejects(rpc(u2, `insert into public.social_likes (owner_id, post_id) values ($1, $2)`, [u1.id, p.id]), /permission denied/)
    await assert.rejects(rpc(u2, `insert into public.social_comments (owner_id, post_id, body) values ($1, $2, 'x')`, [u1.id, p.id]), /permission denied/)
    await assert.rejects(rpc(u2, `insert into public.social_follows (owner_id, followee_id) values ($1, $2)`, [u1.id, u2.id]), /permission denied/)
  })

  test('anon can read nothing', async () => {
    const [u] = await pair()
    await post(u)
    for (const t of ['social_posts', 'social_follows', 'social_likes', 'social_comments', 'social_seen']) {
      await assert.rejects(rpc(null, `select * from public.${t}`), /permission denied/, t)
    }
    await assert.rejects(rpc(null, 'select * from public.social_for_you()'), /permission denied/)
  })

  test('tags are checked: lower case, no repeats, at most ten', async () => {
    const [u] = await pair()
    await post(u, { tags: ['food', 'ramen_2026'] })
    for (const tags of [['Food'], ['food', 'food'], ['has space'], Array.from({ length: 11 }, (_, i) => `t${i}`)]) {
      await assert.rejects(post(u, { tags }), /check/, JSON.stringify(tags))
    }
  })

  test('an empty post is refused, and an edit is marked', async () => {
    const [u] = await pair()
    await assert.rejects(post(u, { body: '   ' }), /check/)
    const p = await post(u)
    assert.equal(p.edited_at, null)
    const [edited] = await rpc(u, `update public.social_posts set body = 'Attempt #5 was better.' where id = $1 returning edited_at`, [p.id])
    assert.ok(edited.edited_at)
  })

  test('posting is rate limited', async () => {
    const [u] = await pair()
    await db.query(`insert into public.social_posts (owner_id, body)
                    select $1, 'post ' || g from generate_series(1, 60) g`, [u.id])
    await assert.rejects(post(u), /too many posts/)
  })
})

describe('follows', () => {
  test('follow and unfollow by handle, with counts on the profile', async () => {
    const [u1, u2] = await pair()
    await follow(u2, u1)
    let [p] = await rpc(u2, 'select * from public.social_profile($1)', [u1.handle])
    assert.equal(Number(p.followers), 1)
    assert.equal(p.i_follow, true)
    assert.equal(p.follows_me, false)
    await follow(u2, u1) // twice is fine
    await unfollow(u2, u1)
    ;[p] = await rpc(u2, 'select * from public.social_profile($1)', [u1.handle])
    assert.equal(Number(p.followers), 0)
    assert.equal(p.i_follow, false)
  })

  test('you cannot follow yourself or someone who does not exist', async () => {
    const [u] = await pair()
    await assert.rejects(follow(u, u), /yourself/)
    await assert.rejects(follow(u, { handle: 'nobody_here_xyz' }), /no such user/)
  })

  test('friends are people you follow who follow you back', async () => {
    const [u1, u2, u3] = await pair()
    await follow(u1, u2); await follow(u2, u1)
    await follow(u1, u3)
    assert.deepEqual(await rpc(u1, 'select * from public.social_friends()'), [{ handle: u2.handle }])
    assert.deepEqual(await rpc(u3, 'select * from public.social_friends()'), [])
  })

  test('followers and following lists', async () => {
    const [u1, u2, u3] = await pair()
    await follow(u2, u1); await follow(u3, u1)
    const followers = await rpc(u2, 'select handle from public.social_people($1, true)', [u1.handle])
    assert.deepEqual(followers.map((r) => r.handle).sort(), [u2.handle, u3.handle].sort())
    const followingList = await rpc(u2, 'select handle from public.social_people($1, false)', [u2.handle])
    assert.deepEqual(followingList.map((r) => r.handle), [u1.handle])
  })
})

describe('feeds', () => {
  test('Following shows your posts and the people you follow, newest first', async () => {
    const [u1, u2, u3] = await pair()
    const a = await post(u1, { body: 'Out the door at 4:30.' })
    const b = await post(u3, { body: 'Not followed.' })
    const c = await post(u2, { body: 'My own post.' })
    await follow(u2, u1)
    const ids = (await following(u2)).map((r) => r.id)
    assert.deepEqual(ids, [c.id, a.id])
    assert.ok(!ids.includes(b.id))
  })

  test('For You ranks, explains itself, skips your own and never repeats', async () => {
    const [u1, u2, u3] = await pair()
    const old = await post(u1, { body: 'Older and unliked.' })
    await db.query(`update public.social_posts set created_at = now() - interval '5 days' where id = $1`, [old.id])
    const ramen = await post(u1, { title: 'The best miso ramen in Sapporo, ranked', tags: ['food'] })
    const mine = await post(u2, { body: 'My own.' })
    await like(u3, ramen)
    let feed = await forYou(u2)
    assert.ok(!feed.some((r) => r.id === mine.id), 'never your own')
    assert.equal(feed[0].id, ramen.id)
    assert.ok(feed.every((r) => r.reason.length > 0))
    await rpc(u2, 'select public.social_mark_seen($1)', [[ramen.id]])
    feed = await forYou(u2)
    assert.ok(!feed.some((r) => r.id === ramen.id), 'never twice')
  })

  test('liked tags count up and say so; Not interested turns them down', async () => {
    const [u1, u2, u3] = await pair()
    const liked = await post(u1, { tags: ['hiking'], body: 'Sunrise on Timpanogos.' })
    await like(u2, liked)
    const hike = await post(u3, { tags: ['hiking'], body: 'Saddle at first light.' })
    const bake = await post(u3, { tags: ['baking'], body: 'Twelve hours in the fridge.' })
    let feed = await forYou(u2)
    const top = feed.find((r) => r.id === hike.id)
    assert.equal(top.reason, 'You liked posts tagged #hiking.')
    assert.ok(feed.findIndex((r) => r.id === hike.id) < feed.findIndex((r) => r.id === bake.id))
    const tagged = await forYou(u2, 'baking')
    assert.deepEqual(tagged.map((r) => r.id), [bake.id])
  })

  test('posts from people your follows follow say so', async () => {
    const [u1, u2, u3] = await pair()
    await follow(u2, u3); await follow(u3, u1)
    const p = await post(u1, { body: 'Penguin Classics this year.' })
    const row = (await forYou(u2)).find((r) => r.id === p.id)
    assert.equal(row.reason, `People you follow follow them, like @${u3.handle}.`)
  })
})

describe('likes and comments', () => {
  test('likes count once each and can be taken back', async () => {
    const [u1, u2] = await pair()
    const p = await post(u1)
    await like(u2, p)
    await assert.rejects(like(u2, p), /duplicate|unique/)
    let [row] = await rpc(u2, 'select * from public.social_post($1)', [p.id])
    assert.equal(Number(row.likes), 1)
    assert.equal(row.liked, true)
    await rpc(u2, 'delete from public.social_likes where post_id = $1', [p.id])
    ;[row] = await rpc(u2, 'select * from public.social_post($1)', [p.id])
    assert.equal(Number(row.likes), 0)
  })

  test('replies sit under a comment on the same post', async () => {
    const [u1, u2] = await pair()
    const p = await post(u1)
    const other = await post(u1, { body: 'Another post.' })
    const c = await comment(u2, p, 'What hydration?')
    const r = await comment(u1, p, '72%. Go lower before you go longer.', c.id)
    await assert.rejects(comment(u2, other, 'Wrong post.', c.id), /reply/)
    await assert.rejects(comment(u2, p, 'Too deep.', r.id), /reply/)
    const list = await rpc(u2, 'select id, parent_id from public.social_comments_of($1)', [p.id])
    assert.deepEqual(list.map((x) => x.id), [c.id, r.id])
  })

  test('the post owner can remove a comment; others cannot', async () => {
    const [u1, u2, u3] = await pair()
    const p = await post(u1)
    const c = await comment(u2, p, 'Sumire over Shingen? Bold.')
    const gone = await rpc(u3, 'delete from public.social_comments where id = $1 returning id', [c.id])
    assert.deepEqual(gone, [])
    const removed = await rpc(u1, 'delete from public.social_comments where id = $1 returning id', [c.id])
    assert.deepEqual(removed, [{ id: c.id }])
  })
})

describe('Social two-user test', () => {
  test('user 2 cannot change or delete user 1 posts', async () => {
    const [u1, u2] = await pair()
    const p = await post(u1)
    assert.deepEqual(await rpc(u2, `update public.social_posts set body = 'hijacked' where id = $1 returning id`, [p.id]), [])
    assert.deepEqual(await rpc(u2, 'delete from public.social_posts where id = $1 returning id', [p.id]), [])
    const [row] = await rpc(u1, 'select body from public.social_posts where id = $1', [p.id])
    assert.equal(row.body, p.body)
  })

  test('user 2 cannot read user 1 For You history', async () => {
    const [u1, u2, u3] = await pair()
    const p = await post(u3)
    await rpc(u1, 'select public.social_mark_seen($1, true)', [[p.id]])
    assert.deepEqual(await rpc(u2, 'select * from public.social_seen where owner_id = $1', [u1.id]), [])
  })

  test('user 2 follows user 1, sees the post in Following, likes and comments; user 1 sees both', async () => {
    const [u1, u2] = await pair()
    const p = await post(u1, { title: 'Trailhead at dawn', tags: ['hiking'] })
    await follow(u2, u1)
    assert.ok((await following(u2)).some((r) => r.id === p.id))
    await like(u2, p)
    await comment(u2, p, 'Worth the 4:30 alarm.')
    const [row] = await rpc(u1, 'select * from public.social_post($1)', [p.id])
    assert.equal(Number(row.likes), 1)
    assert.equal(Number(row.comments), 1)
    const comments = await rpc(u1, 'select handle, body from public.social_comments_of($1)', [p.id])
    assert.deepEqual(comments, [{ handle: u2.handle, body: 'Worth the 4:30 alarm.' }])
  })

  test('after a block neither side sees the other, and a follow is quietly dropped', async () => {
    const [u1, u2] = await pair()
    const p = await post(u1)
    await block(u1, u2)
    assert.deepEqual(await rpc(u2, 'select id from public.social_posts where owner_id = $1', [u1.id]), [])
    assert.deepEqual(await rpc(u2, 'select * from public.social_profile($1)', [u1.handle]), [])
    await follow(u2, u1) // looks like it worked
    assert.deepEqual(await rpc(u1, 'select * from public.social_people($1, true)', [u1.handle]), [])
    await assert.rejects(like(u2, p), /row-level security/)
    assert.ok(!(await forYou(u2)).some((r) => r.id === p.id))
    const u2post = await post(u2)
    assert.deepEqual(await rpc(u1, 'select id from public.social_posts where id = $1', [u2post.id]), [])
  })

  test('the server never holds a Friends or Close-friends post', async () => {
    const { rows } = await db.query(`select count(*)::int as n from public.social_posts where visibility <> 'public'`)
    assert.equal(rows[0].n, 0)
  })
})
