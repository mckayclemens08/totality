// Messages' "Who can message me" (issue 149 §4, step 8): the setting, message requests, and the check the
// Matrix guard asks before an invite reaches the Matrix server.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { newDatabase, newUser, as } from './harness.js'

const check = readFileSync(new URL('../scripts/check-schema-invariants.sql', import.meta.url), 'utf8')

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `mia_${n}`), await newUser(db, `leo_${n}`), await newUser(db, `zoe_${n}`)]
}
const rpc = (u, sql, params = []) => as(db, u, (q) => q(sql, params))
const one = async (u, sql, params) => Object.values((await rpc(u, sql, params))[0])[0]
const reach = (u, other) => one(u, 'select public.message_reach($1)', [other.handle])
const setReach = (u, r) => rpc(u, 'select public.message_set_reach($1)', [r])
const ask = (u, other) => rpc(u, 'select public.message_request_send($1)', [other.handle])
const answer = (u, other, yes) => rpc(u, 'select public.message_request_answer($1, $2)', [other.handle, yes])
const incoming = async (u) => (await rpc(u, 'select handle from public.message_requests_incoming()')).map((r) => r.handle)
const follow = (a, b) => rpc(a, 'select public.social_follow($1)', [b.handle])
const block = (a, b) => rpc(a, 'select public.block_contact($1)', [b.id])
// What the guard learns, through the edge function's service role.
const gate = async (sender, recipients) => {
  await db.exec('set role service_role')
  try {
    return Object.fromEntries((await db.query('select * from public.message_gate($1, $2)', [sender, recipients])).rows
      .map((r) => [r.handle, r.allowed]))
  } finally { await db.exec('reset role') }
}

test('the new table passes the invariant check', async () => {
  assert.deepEqual((await db.query(check)).rows, [])
})

test('only the service role can ask the gate', async () => {
  const [mia, leo] = await pair()
  await assert.rejects(rpc(mia, 'select * from public.message_gate($1, $2)', [mia.handle, [leo.handle]]), /permission denied/)
  await assert.rejects(rpc(null, 'select * from public.message_gate($1, $2)', [mia.handle, [leo.handle]]), /permission denied/)
})

describe('the setting', () => {
  test('starts at Anyone and changes nothing else in Social settings', async () => {
    const [mia, leo] = await pair()
    assert.equal(await one(mia, 'select public.message_my_reach()'), 'anyone')
    await rpc(mia, 'select public.social_set_settings($1, $2, $3, $4)', ['followers', 'anyone', true, true])
    await setReach(mia, 'friends')
    const [s] = await rpc(mia, 'select * from public.social_my_settings()')
    assert.deepEqual(s, { who_can_comment: 'followers', who_can_message: 'friends', private_account: true, hide_like_counts: true })
    assert.equal(await reach(leo, mia), 'ask')
  })

  test('has no Nobody choice, as in the spec', async () => {
    const [mia] = await pair()
    await assert.rejects(setReach(mia, 'no_one'), /check/)
  })

  test('Anyone lets everyone in, Followers only followers, Friends only both ways', async () => {
    const [mia, leo, zoe] = await pair()
    assert.equal(await reach(leo, mia), 'allowed')
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: true })

    await setReach(mia, 'followers')
    assert.equal(await reach(leo, mia), 'ask')
    await follow(leo, mia)
    assert.equal(await reach(leo, mia), 'allowed')
    assert.equal(await reach(zoe, mia), 'ask')
    assert.deepEqual(await gate(leo.handle, [mia.handle, zoe.handle]), { [mia.handle]: true, [zoe.handle]: true })
    assert.deepEqual(await gate(zoe.handle, [mia.handle]), { [mia.handle]: false })

    await setReach(mia, 'friends')
    assert.equal(await reach(leo, mia), 'ask')
    await follow(mia, leo)
    assert.equal(await reach(leo, mia), 'allowed')
  })

  test('a follow request a private account has not approved does not count', async () => {
    const [mia, leo] = await pair()
    await rpc(mia, 'select public.social_set_settings($1, $2, $3, $4)', ['anyone', 'followers', true, false])
    await follow(leo, mia)
    assert.equal(await reach(leo, mia), 'ask')
  })

  test('the gate never allows an unknown name or yourself', async () => {
    const [mia] = await pair()
    assert.deepEqual(await gate(mia.handle, ['nobody_here', mia.handle]), { nobody_here: false, [mia.handle]: false })
    assert.deepEqual(await gate('nobody_here', [mia.handle]), { [mia.handle]: false })
  })
})

describe('requests', () => {
  test('a request holds no message, reaches only its recipient, and accepting opens the way both ways', async () => {
    const [mia, leo, zoe] = await pair()
    await setReach(mia, 'friends')
    await setReach(leo, 'friends')
    await ask(leo, mia)
    assert.equal(await reach(leo, mia), 'asked')
    assert.deepEqual(await incoming(mia), [leo.handle])
    assert.deepEqual(await incoming(zoe), [])
    assert.deepEqual(await rpc(leo, 'select * from public.message_requests'), [])
    assert.deepEqual(await rpc(zoe, 'select * from public.message_requests'), [])
    const columns = (await db.query(`select column_name from information_schema.columns
      where table_name = 'message_requests' order by 1`)).rows.map((r) => r.column_name)
    assert.deepEqual(columns, ['created_at', 'id', 'owner_id', 'recipient_id', 'state', 'updated_at', 'visibility'])

    // While it waits, Mia may already start the chat Leo asked for, but Leo can't.
    assert.deepEqual(await gate(mia.handle, [leo.handle]), { [leo.handle]: true })
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: false })

    await answer(mia, leo, true)
    assert.deepEqual(await incoming(mia), [])
    assert.equal(await reach(leo, mia), 'allowed')
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: true })
    assert.deepEqual((await rpc(leo, 'select handle from public.message_requests_accepted()')).map((r) => r.handle), [mia.handle])
    assert.deepEqual(await rpc(mia, 'select handle from public.message_requests_accepted()'), [])
  })

  test('a declined request still reads as waiting to its sender, and can not be sent again', async () => {
    const [mia, leo] = await pair()
    await setReach(mia, 'followers')
    await ask(leo, mia)
    await answer(mia, leo, false)
    assert.equal(await reach(leo, mia), 'asked')
    await ask(leo, mia)
    assert.deepEqual(await incoming(mia), [])
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: false })
    await assert.rejects(answer(mia, leo, true), /no such request/)
  })

  test('only the recipient can answer, and nobody can write a request directly', async () => {
    const [mia, leo, zoe] = await pair()
    await setReach(mia, 'followers')
    await ask(leo, mia)
    await assert.rejects(answer(zoe, leo, true), /no such request/)
    await assert.rejects(answer(leo, mia, true), /no such request/)
    await assert.rejects(rpc(zoe, 'insert into public.message_requests (recipient_id) values ($1)', [mia.id]), /row-level security|permission/)
    await assert.rejects(rpc(leo, `update public.message_requests set state = 'accepted'`), /permission/)
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: false })
  })

  test('across a block there is no one to ask, either way, and nothing gets through', async () => {
    const [mia, leo] = await pair()
    await ask(leo, mia) // allowed already, so nothing is filed
    assert.deepEqual(await incoming(mia), [])
    await setReach(mia, 'followers')
    await ask(leo, mia)
    await block(mia, leo)
    assert.deepEqual(await incoming(mia), [])
    assert.equal(await reach(leo, mia), 'unknown')
    assert.equal(await reach(mia, leo), 'unknown')
    await assert.rejects(ask(leo, mia), /no such user/)
    await setReach(mia, 'anyone')
    assert.deepEqual(await gate(leo.handle, [mia.handle]), { [mia.handle]: false })
    assert.deepEqual(await gate(mia.handle, [leo.handle]), { [leo.handle]: false })
  })

  test('at most 30 new requests a day', async () => {
    const leo = await newUser(db, `spam_${++n}`)
    for (let i = 0; i < 30; i++) {
      const u = await newUser(db, `quiet_${n}_${i}`)
      await setReach(u, 'friends')
      await ask(leo, u)
    }
    const last = await newUser(db, `quiet_${n}_x`)
    await setReach(last, 'friends')
    await assert.rejects(ask(leo, last), /too many message requests/)
  })

  test('your export holds the requests you were sent', async () => {
    const [mia, leo] = await pair()
    await setReach(mia, 'followers')
    await ask(leo, mia)
    const data = await one(mia, 'select public.export_my_data()')
    assert.equal(data.message_requests_received.length, 1)
  })
})
