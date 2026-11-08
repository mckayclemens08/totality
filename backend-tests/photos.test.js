// Photos' cases for the brief §6 two-user test, at the database layer (issue 54). A photo is one row of
// kind 'photo': sealed details in meta_cipher, and its original's key in the sealed store as
// <owner>/sealed/<blob>. The bytes live on the Oracle server, whose own two-user cases are in
// server/blobs/blobs.test.mjs. The device's cases are in Tests/TotalityPhotosTests.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `photos1_${n}`), await newUser(db, `photos2_${n}`)]
}
const addPhoto = (user, fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, key_ref, storage_key, meta_cipher, meta_plain, byte_size)
           values ($1, $2, 'photo', $3, $4, $5, $6, 1000)`,
    [id, fields.owner ?? user.id, fields.key_ref ?? `crk:${id}`, fields.storage_key ?? `${user.id}/sealed/${randomUUID()}`,
      Buffer.from('sealed details'), JSON.stringify(fields.meta_plain ?? {})])
  return id
})
const photosOf = async (viewer, owner) =>
  (await as(db, viewer, (q) => q(`select id from public.content_objects where kind = 'photo' and owner_id = $1`, [owner.id]))).map(({ id }) => id)

describe('Photos two-user test', () => {
  test("user 2 can't list or read user 1's photos, and nobody signed out can", async () => {
    const [user1, user2] = await pair()
    const id = await addPhoto(user1)
    assert.deepEqual(await photosOf(user1, user1), [id])
    assert.deepEqual(await photosOf(user2, user1), [])
    await assert.rejects(photosOf(null, user1), /permission denied/)
  })

  test("user 2 can't change, move, or delete user 1's photo", async () => {
    const [user1, user2] = await pair()
    const id = await addPhoto(user1)
    const [before] = await as(db, user1, (q) => q('select storage_key from public.content_objects where id = $1', [id]))
    await as(db, user2, (q) => q('update public.content_objects set meta_cipher = $1, storage_key = $2 where id = $3',
      [Buffer.from('x'), `${user2.id}/sealed/${randomUUID()}`, id]))
    await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
    const [after] = await as(db, user1, (q) => q('select storage_key, meta_cipher from public.content_objects where id = $1', [id]))
    assert.equal(after.storage_key, before.storage_key)
    assert.equal(Buffer.from(after.meta_cipher).toString(), 'sealed details')
  })

  test("nobody can plant a photo under someone else, or name someone else's blob", async () => {
    const [user1, user2] = await pair()
    await assert.rejects(addPhoto(user2, { owner: user1.id, storage_key: `${user1.id}/sealed/${randomUUID()}` }))
    await assert.rejects(addPhoto(user2, { storage_key: `${user1.id}/sealed/${randomUUID()}` }), /storage_key_in_owner_folder/)
  })

  test('a photo can never be stored readable, or with readable details', async () => {
    const [user1] = await pair()
    await assert.rejects(addPhoto(user1, { key_ref: 'plain:' }), /plain_is_public/)
    for (const key of ['caption', 'taken', 'place', 'album', 'filename']) {
      await assert.rejects(addPhoto(user1, { meta_plain: { [key]: 'x' } }), /meta_plain_allowlist/)
    }
  })
})
