// The Reader's cases for the brief §6 two-user test, at the database layer. The encryption cases are
// in Tests/TotalityReaderTests. The Reader stores on the device for now, so these pin the rules its
// sync will run under: note and file rows hold only ciphertext and stay with their owner.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const trio = async () => {
  n += 1
  return [await newUser(db, `reader1_${n}`), await newUser(db, `reader2_${n}`), await newUser(db, `reader3_${n}`)]
}
const insertItem = (user, kind, fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, storage_key, key_ref, meta_cipher, meta_plain)
           values ($1, $2, $3, $4, $5, $6, $7)`,
    [id, user.id, kind, `${user.id}/${id}`, fields.key_ref ?? `crk:${id}`,
      Buffer.from('sealed'), JSON.stringify(fields.meta_plain ?? {})])
  return id
})
const visible = async (user, id) =>
  (await as(db, user, (q) => q('select id from public.content_objects where id = $1', [id]))).length === 1

describe('Reader two-user test', () => {
  for (const kind of ['note', 'file']) {
    test(`a private ${kind} is visible to its owner alone`, async () => {
      const [user1, user2] = await trio()
      const id = await insertItem(user1, kind)
      assert.equal(await visible(user1, id), true)
      assert.equal(await visible(user2, id), false)
      await assert.rejects(visible(null, id), /permission denied/)
    })

    test(`a shared ${kind} opens for user 2 and not for user 3`, async () => {
      const [user1, user2, user3] = await trio()
      const id = await insertItem(user1, kind)
      await as(db, user1, (q) => q(
        'insert into public.content_shares (owner_id, object_id, grantee_id, wrapped_key) values ($1, $2, $3, $4)',
        [user1.id, id, user2.id, Buffer.from('wrapped')]))
      assert.equal(await visible(user2, id), true)
      assert.equal(await visible(user3, id), false)
    })
  }

  test('a title or filename cannot be stored in plaintext', async () => {
    const [user1] = await trio()
    for (const key of ['title', 'filename', 'collection', 'listen_position']) {
      await assert.rejects(insertItem(user1, 'note', { meta_plain: { [key]: 'x' } }), /meta_plain_allowlist/)
    }
  })

  test('a note cannot be stored unencrypted', async () => {
    const [user1] = await trio()
    await assert.rejects(insertItem(user1, 'note', { key_ref: 'plain:' }), /plain_is_public/)
  })

  test('user 2 cannot delete or rewrite user 1 content', async () => {
    const [user1, user2] = await trio()
    const id = await insertItem(user1, 'note')
    await as(db, user2, async (q) => {
      await q('delete from public.content_objects where id = $1', [id])
      await q('update public.content_objects set byte_size = 1 where id = $1', [id])
    })
    const [row] = await as(db, user1, (q) => q('select byte_size from public.content_objects where id = $1', [id]))
    assert.equal(row.byte_size, null)
  })
})
