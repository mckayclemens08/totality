import { randomUUID } from 'node:crypto'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { as, newDatabase, newUser } from './harness.js'

test('a Social background follows ownership, publication, and two-way block rules', async () => {
  const db = await newDatabase()
  try {
    const maren = await newUser(db, 'maren')
    const tobias = await newUser(db, 'tobias')
    const key = `${maren.id}/${randomUUID()}.jpg`
    const upload = (user) => as(db, user, q => q(
      "insert into storage.objects (bucket_id, name) values ('profile-backgrounds', $1)", [key]))
    const swap = async (user, previous, next) => (await as(db, user, q => q(
      'select public.set_profile_background($1, $2) as changed', [previous, next])))[0].changed
    const read = (user, operation = 'object.get_authenticated') => as(db, user, async q => {
      await q("select set_config('storage.test_operation', $1, true)", [operation])
      return q("select name from storage.objects where bucket_id = 'profile-backgrounds' and name = $1", [key])
    })
    await assert.rejects(upload(tobias), /row-level security/)
    await upload(maren)
    assert.deepEqual(await read(tobias), [])
    assert.equal(await swap(tobias, null, key), false)
    assert.equal(await swap(maren, null, key), true)
    assert.equal(await swap(maren, null, null), false)
    assert.deepEqual(await read(tobias), [{ name: key }])
    assert.deepEqual(await read(null), [])
    assert.deepEqual(await read(tobias, 'object.sign'), [])
    await as(db, maren, q => q(
      "select public.block_contact($1)", [tobias.id]))
    assert.deepEqual(await read(tobias), [])
    assert.deepEqual(await as(db, tobias, q => q("select * from public.social_profile('maren')")), [])
    assert.deepEqual(await read(maren), [{ name: key }])
    await assert.rejects(as(db, tobias, q => q(
      'select public.clear_reported_profile_background($1, $2)', [maren.id, key])), /permission denied/)
    assert.equal(await swap(maren, key, null), true)
    assert.deepEqual(await read(maren), [])
    assert.equal(await swap(maren, null, key), true)
    const moderatorCleared = await db.transaction(async tx => {
      await tx.exec('set local role service_role')
      return (await tx.query('select public.clear_reported_profile_background($1, $2) as changed', [maren.id, key])).rows[0].changed
    })
    assert.equal(moderatorCleared, true)
    assert.deepEqual(await read(maren), [])
  } finally {
    await db.close()
  }
})
