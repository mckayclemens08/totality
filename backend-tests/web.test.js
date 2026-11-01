// Web's cases for the brief §6 two-user test, at the database layer. The encryption cases are in
// Tests/TotalityWebTests. Bookmarks are the only thing Web syncs, as ciphertext rows that stay with
// their owner. History and open tabs have no row at all, and the gateway stores no searches.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `web1_${n}`), await newUser(db, `web2_${n}`)]
}
const insertBookmark = (user, fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, storage_key, key_ref, meta_cipher, meta_plain)
           values ($1, $2, 'bookmark', $3, $4, $5, $6)`,
    [id, user.id, `${user.id}/${id}`, fields.key_ref ?? `crk:${id}`,
      Buffer.from('sealed'), JSON.stringify(fields.meta_plain ?? {})])
  return id
})
const visible = async (user, id) =>
  (await as(db, user, (q) => q('select id from public.content_objects where id = $1', [id]))).length === 1

describe('Web two-user test', () => {
  test('a bookmark is visible to its owner alone', async () => {
    const [user1, user2] = await pair()
    const id = await insertBookmark(user1)
    assert.equal(await visible(user1, id), true)
    assert.equal(await visible(user2, id), false)
    await assert.rejects(visible(null, id), /permission denied/)
  })

  test('user 2 cannot change or delete a bookmark of user 1', async () => {
    const [user1, user2] = await pair()
    const id = await insertBookmark(user1)
    await as(db, user2, (q) => q('update public.content_objects set meta_cipher = $1 where id = $2', [Buffer.from('x'), id]))
    await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
    const [row] = await as(db, user1, (q) => q('select meta_cipher from public.content_objects where id = $1', [id]))
    assert.equal(Buffer.from(row.meta_cipher).toString(), 'sealed')
  })

  test('a title or address cannot be stored in plaintext', async () => {
    const [user1] = await pair()
    for (const key of ['title', 'url', 'folder']) {
      await assert.rejects(insertBookmark(user1, { meta_plain: { [key]: 'x' } }), /meta_plain_allowlist/)
    }
  })

  test('a bookmark cannot be stored unencrypted', async () => {
    const [user1] = await pair()
    await assert.rejects(insertBookmark(user1, { key_ref: 'plain:' }), /plain_is_public/)
  })
})
