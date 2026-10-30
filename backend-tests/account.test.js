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
