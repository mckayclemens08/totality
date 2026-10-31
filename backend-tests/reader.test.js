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

describe('encrypted sync two-user test', () => {
  const hash = (byte) => Buffer.alloc(32, byte)
  const newObject = (user, fields = {}) => as(db, user, async (q) => {
    const id = randomUUID()
    const key = `${user.id}/${id}/${randomUUID()}.body`
    await q(`insert into public.content_objects (id, owner_id, kind, storage_key, key_ref, meta_cipher, content_hash, byte_size)
             values ($1, $2, 'note', $3, $4, $5, $6, 10)`,
      [id, user.id, key, `crk:${id}`, Buffer.from('sealed'), hash(fields.byte ?? 1)])
    await q(`insert into storage.objects (bucket_id, name) values ('content', $1)`, [key])
    return { id, key }
  })
  const tombstone = (user, id) => as(db, user, (q) => q(
    `update public.content_objects set deleted_at = now(), meta_cipher = null, storage_key = null, content_hash = null
     where id = $1 returning id`, [id]))
  const blobs = (user, key) => as(db, user, (q) => q('select name from storage.objects where name = $1', [key]))

  test('user 2 cannot read user 1 synced content, in the table or in storage', async () => {
    const [user1, user2] = await trio()
    const { id, key } = await newObject(user1)
    assert.equal(await visible(user2, id), false)
    assert.equal((await blobs(user2, key)).length, 0)
    assert.equal((await blobs(user1, key)).length, 1)
  })

  test('signed-out callers cannot read synced blobs', async () => {
    const [user1] = await trio()
    const { key } = await newObject(user1)
    assert.equal((await blobs(null, key)).length, 0)
  })

  test('you can read your own older version, which has no row, so it can be cleaned up', async () => {
    const [user1, user2] = await trio()
    const old = `${user1.id}/${randomUUID()}/old.body`
    await as(db, user1, (q) => q(`insert into storage.objects (bucket_id, name) values ('content', $1)`, [old]))
    assert.equal((await blobs(user1, old)).length, 1)
    assert.equal((await blobs(user2, old)).length, 0)
  })

  test('user 2 cannot write into user 1 storage or point a row at it', async () => {
    const [user1, user2] = await trio()
    const { key } = await newObject(user1)
    await assert.rejects(as(db, user2, (q) => q(
      `insert into storage.objects (bucket_id, name) values ('content', $1)`, [`${user1.id}/${randomUUID()}/x.body`])), /row-level security/)
    const { id } = await newObject(user2)
    await assert.rejects(as(db, user2, (q) => q(
      'update public.content_objects set storage_key = $1 where id = $2', [key, id])), /storage_key_in_owner_folder/)
  })

  test('user 2 cannot delete or tombstone user 1 content', async () => {
    const [user1, user2] = await trio()
    const { id, key } = await newObject(user1)
    assert.equal((await tombstone(user2, id)).length, 0)
    assert.equal((await as(db, user2, (q) => q(`delete from storage.objects where name = $1 returning id`, [key]))).length, 0)
    assert.equal(await visible(user1, id), true)
  })

  test('a deleted item keeps a row with no content', async () => {
    const [user1] = await trio()
    const { id } = await newObject(user1)
    assert.equal((await tombstone(user1, id)).length, 1)
    const [row] = await as(db, user1, (q) => q(
      'select meta_cipher, storage_key, content_hash, deleted_at from public.content_objects where id = $1', [id]))
    assert.equal(row.meta_cipher, null)
    assert.equal(row.storage_key, null)
    assert.notEqual(row.deleted_at, null)
  })

  test('an update naming an old version changes nothing', async () => {
    const [user1] = await trio()
    const { id } = await newObject(user1, { byte: 1 })
    const rows = await as(db, user1, (q) => q(
      'update public.content_objects set byte_size = 99 where id = $1 and content_hash = $2 returning id', [id, hash(2)]))
    assert.equal(rows.length, 0)
  })

  test('private content can never be stored unencrypted', async () => {
    const [user1] = await trio()
    await assert.rejects(as(db, user1, (q) => q(
      `insert into public.content_objects (owner_id, kind, key_ref) values ($1, 'note', 'plain:')`, [user1.id])), /plain_is_public/)
  })
})
