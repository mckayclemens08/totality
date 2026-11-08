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

const addAlbum = (user, fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, key_ref, meta_cipher, meta_plain)
           values ($1, $2, 'photo_album', $3, $4, $5)`,
    [id, fields.owner ?? user.id, `crk:${id}`, Buffer.from('sealed name'), JSON.stringify(fields.meta_plain ?? {})])
  return id
})

describe('Photos two-user test: albums and changes (step 3)', () => {
  test("user 2 can't list, rename, or delete user 1's albums", async () => {
    const [user1, user2] = await pair()
    const id = await addAlbum(user1)
    const albumsOf = (viewer) => as(db, viewer, (q) => q(`select id from public.content_objects where kind = 'photo_album' and owner_id = $1`, [user1.id]))
    assert.deepEqual((await albumsOf(user1)).map(({ id }) => id), [id])
    assert.deepEqual(await albumsOf(user2), [])
    await as(db, user2, (q) => q('update public.content_objects set meta_cipher = $1 where id = $2', [Buffer.from('x'), id]))
    await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
    const [after] = await as(db, user1, (q) => q('select meta_cipher from public.content_objects where id = $1', [id]))
    assert.equal(Buffer.from(after.meta_cipher).toString(), 'sealed name')
  })

  test('an album name can never be stored readable, or planted under someone else', async () => {
    const [user1, user2] = await pair()
    await assert.rejects(addAlbum(user1, { meta_plain: { name: 'Zion' } }), /meta_plain_allowlist/)
    await assert.rejects(addAlbum(user2, { owner: user1.id }))
  })

  test("user 1 changes and deletes their own photo, and user 2 still can't", async () => {
    const [user1, user2] = await pair()
    const id = await addPhoto(user1)
    // A change only lands if the row is still what the device last saw.
    const changed = await as(db, user1, (q) => q(
      'update public.content_objects set meta_cipher = $1, content_hash = $2 where id = $3 and content_hash is not distinct from $4 returning id',
      [Buffer.from('new sealed details'), Buffer.from('h2'), id, null]))
    assert.equal(changed.length, 1)
    const stale = await as(db, user1, (q) => q(
      'update public.content_objects set meta_cipher = $1 where id = $2 and content_hash = $3 returning id',
      [Buffer.from('older'), id, Buffer.from('h1')]))
    assert.equal(stale.length, 0)
    await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
    assert.deepEqual(await photosOf(user1, user1), [id])
    await as(db, user1, (q) => q('delete from public.content_objects where id = $1', [id]))
    assert.deepEqual(await photosOf(user1, user1), [])
  })
})
