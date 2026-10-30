// Device rows, which the app writes right after sign-in.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
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
