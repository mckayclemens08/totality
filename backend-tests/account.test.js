// Device rows, which the app writes right after sign-in, and the rules on accounts themselves.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `device1_${n}`), await newUser(db, `device2_${n}`)]
}
const key = (byte) => Buffer.alloc(32, byte, 'hex')
const addDevice = (user, owner, pub) => as(db, user, (q) => q(
  `insert into public.devices (owner_id, name, platform, device_pub) values ($1, 'iPhone', 'ios', $2)`, [owner, pub]))
const devices = (user) => as(db, user, (q) => q('select id from public.devices'))

describe('devices', () => {
  test('a user can add and read their own device', async () => {
    const [user1] = await pair()
    await addDevice(user1, user1.id, key('a1'))
    assert.equal((await devices(user1)).length, 1)
  })

  test('user 2 cannot see user 1 devices', async () => {
    const [user1, user2] = await pair()
    await addDevice(user1, user1.id, key('a2'))
    assert.equal((await devices(user2)).length, 0)
  })

  test('nobody can add a device to someone else', async () => {
    const [user1, user2] = await pair()
    await assert.rejects(addDevice(user2, user1.id, key('a3')), /row-level security/)
  })

  test('signed-out callers cannot read devices', async () => {
    await assert.rejects(devices(null), /permission denied/)
  })

  test('a device key must be 32 bytes', async () => {
    const [user1] = await pair()
    await assert.rejects(addDevice(user1, user1.id, Buffer.from('a1', 'hex')), /device_pub/)
  })
})

describe('usernames', () => {
  const addAccount = (email) => db.query('insert into auth.users (id, email) values ($1, $2)', [randomUUID(), email])

  test('an account is a valid username at the reserved address', async () => {
    await addAccount('real_name_1@totality.invalid')
  })

  for (const address of ['owner@gmail.com', 'Owner@totality.invalid', 'ab@totality.invalid', 'a.b.c@totality.invalid',
    'owner@totality.invalid.evil.example', 'x@y\n@totality.invalid']) {
    test(`auth cannot create ${JSON.stringify(address)}`, async () => {
      await assert.rejects(addAccount(address), /username/)
    })
  }

  test('an account with no address is refused', async () => {
    await assert.rejects(addAccount(null), /username/)
  })

  test('a username cannot change, so a freed name cannot be reused', async () => {
    const user = await newUser(db, null)
    await assert.rejects(db.query(`update auth.users set email = 'other_name@totality.invalid' where id = $1`, [user.id]), /username/)
    await assert.rejects(db.query(`update auth.users set email = 'owner@gmail.com' where id = $1`, [user.id]), /username/)
  })

  test('other account updates still work', async () => {
    const user = await newUser(db, null)
    await db.query('update auth.users set email = email where id = $1', [user.id])
  })

  test('a handle must be the account username', async () => {
    const user = await newUser(db, null, 'my_own_name')
    await assert.rejects(as(db, user, (q) => q(`select public.claim_handle('someone_else')`)), /username/)
    await as(db, user, (q) => q(`select public.claim_handle('my_own_name')`))
  })

  test('the rule cannot be called or dropped by clients', async () => {
    const user = await newUser(db, null)
    await assert.rejects(as(db, user, (q) => q('select private.enforce_username_address()')), /permission denied|trigger/)
    await assert.rejects(as(db, user, (q) => q('drop trigger enforce_username_address on auth.users')), /permission denied|must be owner/)
  })
})

describe('profiles', () => {
  const edit = (user, set, values) => as(db, user, (q) => q(
    `update public.profiles set ${set} where id = $1 returning id`, [user.id, ...values]))
  const upload = (user, name, bucket = 'avatars') => as(db, user, (q) => q(
    'insert into storage.objects (bucket_id, name) values ($1, $2)', [bucket, name]))
  const remove = (user, name) => as(db, user, (q) => q(
    `delete from storage.objects where bucket_id = 'avatars' and name = $1 returning id`, [name]))

  test('a configured server gives a new profile its Matrix address', async () => {
    const user = await newUser(db, 'addressed_user')
    const [row] = await as(db, user, (q) => q('select mxid from public.profiles where id = $1', [user.id]))
    assert.equal(row.mxid, '@addressed_user:totality.test')
  })

  test('you can edit your own profile and others can read it', async () => {
    const [user1, user2] = await pair()
    await edit(user1, 'display_name = $2, bio = $3', ['McKay Clemens', 'Building Totality.'])
    const rows = await as(db, user2, (q) => q('select display_name, bio from public.profiles where id = $1', [user1.id]))
    assert.deepEqual(rows, [{ display_name: 'McKay Clemens', bio: 'Building Totality.' }])
  })

  test('nobody can edit someone else', async () => {
    const [user1, user2] = await pair()
    const rows = await as(db, user2, (q) => q(`update public.profiles set bio = 'hijacked' where id = $1 returning id`, [user1.id]))
    assert.equal(rows.length, 0)
  })

  test('a handle or Matrix address cannot be edited directly', async () => {
    const [user1] = await pair()
    await assert.rejects(edit(user1, `handle = 'stolen_name'`, []), /permission denied/)
    await assert.rejects(edit(user1, `mxid = '@stolen:x'`, []), /permission denied/)
  })

  test('names stop at 50 characters and bios at 160', async () => {
    const [user1] = await pair()
    await edit(user1, 'display_name = $2, bio = $3', ['n'.repeat(50), 'b'.repeat(160)])
    await assert.rejects(edit(user1, 'display_name = $2', ['n'.repeat(51)]), /display_name/)
    await assert.rejects(edit(user1, 'bio = $2', ['b'.repeat(161)]), /bio/)
  })

  test('your photo must come from your own folder', async () => {
    const [user1, user2] = await pair()
    await edit(user1, 'avatar_key = $2', [`${user1.id}/${randomUUID()}.jpg`])
    await assert.rejects(edit(user1, 'avatar_key = $2', [`${user2.id}/${randomUUID()}.jpg`]), /avatar/)
    await assert.rejects(edit(user1, 'avatar_key = $2', ['https://evil.example/tracker.jpg']), /avatar/)
    await assert.rejects(edit(user1, 'avatar_key = $2', [`${user1.id}/../${user2.id}/${randomUUID()}.jpg`]), /avatar/)
    await assert.rejects(edit(user1, 'avatar_key = $2', [`${user1.id}/photo.svg`]), /avatar/)
  })

  test('photos are public, JPEG only, and capped in size', async () => {
    const { rows } = await db.query(`select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'avatars'`)
    assert.deepEqual(rows.map((r) => ({ ...r, file_size_limit: Number(r.file_size_limit) })),
      [{ public: true, file_size_limit: 1048576, allowed_mime_types: ['image/jpeg'] }])
  })

  test('you can upload and remove photos in your own folder only', async () => {
    const [user1, user2] = await pair()
    const name = `${user1.id}/${randomUUID()}.jpg`
    await upload(user1, name)
    await assert.rejects(upload(user2, `${user1.id}/${randomUUID()}.jpg`), /row-level security/)
    assert.equal((await remove(user2, name)).length, 0)
    assert.equal((await remove(user1, name)).length, 1)
  })

  test('signed-out callers cannot upload a photo', async () => {
    const [user1] = await pair()
    await assert.rejects(upload(null, `${user1.id}/${randomUUID()}.jpg`), /row-level security|permission denied/)
  })

  test('the avatar rules leave private content alone', async () => {
    const [user1, user2] = await pair()
    await assert.rejects(upload(user2, `${user1.id}/${randomUUID()}`, 'content'), /row-level security/)
  })
})
