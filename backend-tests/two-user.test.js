import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { newDatabase, newUser, as, addObject, SERVER_NAME } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const trio = async () => {
  n += 1
  return [await newUser(db, `user1_${n}`), await newUser(db, `user2_${n}`), await newUser(db, `user3_${n}`)]
}
const canSee = async (user, objectId) =>
  (await as(db, user, (q) => q('select id from public.content_objects where id = $1', [objectId]))).length === 1
const canFetchBlob = async (user, name) =>
  (await as(db, user, (q) => q('select id from storage.objects where name = $1', [name]))).length === 1
const invite = (user, fields = {}) => as(db, user, async (q) =>
  (await q(`insert into public.invites (owner_id, email, expires_at)
            values ($1, $2, coalesce($3::timestamptz, now() + interval '14 days')) returning code`,
    [user.id, fields.email ?? null, fields.expires_at ?? null]))[0].code)
const redeem = (user, code) => as(db, user, (q) => q('select * from public.redeem_invite($1)', [code]))
const connect = async (a, b) => {
  await redeem(b, await invite(a))
  await as(db, a, (q) => q('update public.contacts set can_see_private_posts = true where peer_id = $1', [b.id]))
}
const share = (owner, object, grantee) => as(db, owner, (q) => q(
  `insert into public.content_shares (owner_id, object_id, grantee_id, wrapped_key) values ($1, $2, $3, '\\x00')`,
  [owner.id, object.id, grantee.id]))

describe('brief §6 two-user test', () => {
  test('user 2 cannot select user 1 private rows', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    assert.equal(await canSee(u1, o.id), true)
    assert.equal(await canSee(u2, o.id), false)
  })

  test('user 2 cannot fetch user 1 storage object', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    assert.equal(await canFetchBlob(u1, o.storage_key), true)
    assert.equal(await canFetchBlob(u2, o.storage_key), false)
  })

  test('user 2 can redeem an invite and both become contacts', async () => {
    const [u1, u2] = await trio()
    await redeem(u2, await invite(u1))
    for (const [a, b] of [[u1, u2], [u2, u1]]) {
      const rows = await as(db, a, (q) => q('select peer_id, state, key_verified_at from public.contacts'))
      assert.deepEqual(rows, [{ peer_id: b.id, state: 'accepted', key_verified_at: null }])
    }
  })

  test('a shared object opens for user 2 and not for user 3', async () => {
    const [u1, u2, u3] = await trio()
    const o = await addObject(db, u1)
    await share(u1, o, u2)
    assert.equal(await canSee(u2, o.id), true)
    assert.equal(await canFetchBlob(u2, o.storage_key), true)
    assert.equal(await canSee(u3, o.id), false)
    assert.equal(await canFetchBlob(u3, o.storage_key), false)
  })

  test('a shared object gives user 2 no write access', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    await share(u1, o, u2)
    const changed = await as(db, u2, (q) => q(
      `update public.content_objects set visibility = 'contacts' where id = $1 returning id`, [o.id]))
    assert.equal(changed.length, 0)
  })

  test('contacts content needs the owner to allow it', async () => {
    const [u1, u2] = await trio()
    await redeem(u2, await invite(u1))
    const o = await addObject(db, u1, { visibility: 'contacts' })
    assert.equal(await canSee(u2, o.id), false)
    await as(db, u1, (q) => q('update public.contacts set can_see_private_posts = true where peer_id = $1', [u2.id]))
    assert.equal(await canSee(u2, o.id), true)
  })

  test('a blocked contact loses access to existing and new content', async () => {
    const [u1, u2] = await trio()
    await connect(u1, u2)
    const before = await addObject(db, u1, { visibility: 'contacts' })
    const shared = await addObject(db, u1)
    await share(u1, shared, u2)
    assert.equal(await canSee(u2, before.id), true)
    await as(db, u1, (q) => q('select public.block_contact($1)', [u2.id]))
    const after = await addObject(db, u1, { visibility: 'contacts' })
    for (const o of [before, shared, after]) assert.equal(await canSee(u2, o.id), false)
    assert.equal(await canFetchBlob(u2, shared.storage_key), false)
  })

  test('deleting a share removes access', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    await share(u1, o, u2)
    await as(db, u1, (q) => q('delete from public.content_shares where object_id = $1', [o.id]))
    assert.equal(await canSee(u2, o.id), false)
  })

  test('export holds all of user 1 and none of user 2', async () => {
    const [u1, u2] = await trio()
    const mine = await addObject(db, u1)
    const theirs = await addObject(db, u2)
    await share(u2, theirs, u1)
    const [{ export_my_data: data }] = await as(db, u1, (q) => q('select public.export_my_data()'))
    assert.equal(data.profile.id, u1.id)
    assert.deepEqual(data.content.map((o) => o.id), [mine.id])
  })

  test('deleting an account removes its rows and its shares', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    await share(u1, o, u2)
    await db.query('delete from auth.users where id = $1', [u1.id])
    assert.equal((await db.query('select 1 from public.content_objects where owner_id = $1', [u1.id])).rows.length, 0)
    assert.equal((await db.query('select 1 from public.profiles where id = $1', [u1.id])).rows.length, 0)
    assert.equal((await db.query('select 1 from public.content_shares where object_id = $1', [o.id])).rows.length, 0)
  })
})

describe('invites', () => {
  test('an invite works once', async () => {
    const [u1, u2, u3] = await trio()
    const code = await invite(u1)
    await redeem(u2, code)
    await assert.rejects(redeem(u3, code), /invite is not valid/)
  })
  test('an expired invite is refused', async () => {
    const [u1, u2] = await trio()
    await assert.rejects(redeem(u2, await invite(u1, { expires_at: '2020-01-01' })), /invite is not valid/)
  })
  test('a pre-addressed invite only works for that email', async () => {
    const [u1, u2, u3] = await trio()
    const code = await invite(u1, { email: u2.email.toUpperCase() })
    await assert.rejects(redeem(u3, code), /invite is not valid/)
    await redeem(u2, code)
  })
  test('you cannot redeem your own invite', async () => {
    const [u1] = await trio()
    await assert.rejects(redeem(u1, await invite(u1)), /your own invite/)
  })
  test('nobody can read another user\'s invite codes', async () => {
    const [u1, u2] = await trio()
    await invite(u1)
    assert.equal((await as(db, u2, (q) => q('select * from public.invites where owner_id = $1', [u1.id]))).length, 0)
  })
  test('an invite cannot undo a block', async () => {
    const [u1, u2] = await trio()
    await as(db, u1, (q) => q('select public.block_contact($1)', [u2.id]))
    await redeem(u2, await invite(u1))
    const rows = await as(db, u1, (q) => q('select state from public.contacts where peer_id = $1', [u2.id]))
    assert.deepEqual(rows, [{ state: 'blocked' }])
  })
})

describe('contact requests', () => {
  test('a request needs accepting', async () => {
    const [u1, u2] = await trio()
    await as(db, u1, (q) => q('select public.request_contact($1)', [u2.id]))
    assert.deepEqual(await as(db, u2, (q) => q('select state from public.contacts')), [{ state: 'pending_in' }])
    await as(db, u2, (q) => q('select public.accept_contact($1)', [u1.id]))
    assert.deepEqual(await as(db, u1, (q) => q('select state from public.contacts')), [{ state: 'accepted' }])
  })
  test('the sender cannot accept their own request', async () => {
    const [u1, u2] = await trio()
    await as(db, u1, (q) => q('select public.request_contact($1)', [u2.id]))
    await assert.rejects(as(db, u1, (q) => q('select public.accept_contact($1)', [u2.id])), /no pending request/)
  })
  test('a blocked sender reaches nobody and is not told', async () => {
    const [u1, u2] = await trio()
    await as(db, u1, (q) => q('select public.block_contact($1)', [u2.id]))
    const [row] = await as(db, u2, (q) => q('select state from public.request_contact($1)', [u1.id]))
    assert.equal(row.state, 'pending_out')
    assert.deepEqual(await as(db, u1, (q) => q('select state from public.contacts')), [{ state: 'blocked' }])
  })
  test('a blocked user cannot see public content or the profile', async () => {
    const [u1, u2, u3] = await trio()
    const o = await addObject(db, u1, { visibility: 'public', key_ref: 'plain:' })
    await as(db, u1, (q) => q('select public.block_contact($1)', [u2.id]))
    assert.equal(await canSee(u2, o.id), false)
    assert.equal(await canSee(u3, o.id), true)
    const find = (u) => as(db, u, (q) => q('select id from public.profiles where id = $1', [u1.id]))
    assert.equal((await find(u2)).length, 0)
    assert.equal((await find(u3)).length, 1)
  })
})

describe('forgery attempts', () => {
  const refused = /permission denied|violates row-level security|violates check constraint/

  test('anon reads nothing and calls nothing', async () => {
    const [u1] = await trio()
    const o = await addObject(db, u1, { visibility: 'public', key_ref: 'plain:' })
    await assert.rejects(as(db, null, (q) => q('select * from public.content_objects where id = $1', [o.id])), /permission denied/)
    await assert.rejects(as(db, null, (q) => q('select * from public.profiles')), /permission denied/)
    await assert.rejects(as(db, null, (q) => q(`select public.redeem_invite('x')`)), /permission denied/)
    assert.equal((await as(db, null, (q) => q('select id from storage.objects'))).length, 0)
  })
  test('you cannot rewrite your own mxid, did, or handle', async () => {
    const [u1] = await trio()
    for (const set of [`mxid = '@owner:${SERVER_NAME}'`, `did = 'did:plc:x'`, `handle = 'owner'`]) {
      await assert.rejects(as(db, u1, (q) => q(`update public.profiles set ${set} where id = $1`, [u1.id])), refused)
    }
  })
  test('you cannot claim a second handle or insert a profile by hand', async () => {
    const [u1] = await trio()
    await assert.rejects(as(db, u1, (q) => q(`select public.claim_handle('second_handle')`)), /duplicate key/)
    await assert.rejects(as(db, u1, (q) => q(
      `insert into public.profiles (id, handle, mxid) values ($1, 'forged', '@forged:x')`, [u1.id])), refused)
  })
  test('handles must be lowercase', async () => {
    const u = await newUser(db, null)
    await assert.rejects(as(db, u, (q) => q(`select public.claim_handle('McKay')`)), /check constraint/)
  })
  test('you cannot write a contact row or its state directly', async () => {
    const [u1, u2] = await trio()
    await assert.rejects(as(db, u1, (q) => q(
      `insert into public.contacts (owner_id, peer_id, state) values ($1, $2, 'accepted')`, [u1.id, u2.id])), refused)
    await redeem(u2, await invite(u1))
    await assert.rejects(as(db, u1, (q) => q(`update public.contacts set state = 'pending_in'`)), refused)
  })
  test('you cannot mark a contact key as verified from SQL', async () => {
    const [u1, u2] = await trio()
    await redeem(u2, await invite(u1))
    await assert.rejects(as(db, u1, (q) => q(`update public.contacts set key_verified_at = now()`)), refused)
  })
  test('you cannot create or move a row into someone else\'s name', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    await assert.rejects(as(db, u1, (q) => q(
      `insert into public.content_objects (owner_id, kind, key_ref) values ($1, 'file', 'crk:x')`, [u2.id])), refused)
    await assert.rejects(as(db, u1, (q) => q(
      `update public.content_objects set owner_id = $1 where id = $2`, [u2.id, o.id])), refused)
  })
  test('you cannot share an object you do not own', async () => {
    const [u1, u2, u3] = await trio()
    const o = await addObject(db, u1)
    await assert.rejects(share(u2, o, u3), refused)
  })
  test('you cannot point a row at someone else\'s blob', async () => {
    const [u1, u2] = await trio()
    const o = await addObject(db, u1)
    await assert.rejects(as(db, u2, (q) => q(
      `insert into public.content_objects (owner_id, kind, key_ref, storage_key) values ($1, 'file', 'crk:x', $2)`,
      [u2.id, `${u1.id}/other`])), refused)
    assert.equal(await canFetchBlob(u2, o.storage_key), false)
  })
  test('you cannot upload into someone else\'s folder', async () => {
    const [u1, u2] = await trio()
    await assert.rejects(as(db, u2, (q) => q(
      `insert into storage.objects (bucket_id, name) values ('content', $1)`, [`${u1.id}/planted`])), refused)
  })
  test('the audit log cannot be written or edited by clients', async () => {
    const [u1] = await trio()
    await assert.rejects(as(db, u1, (q) => q(`insert into public.audit_log (action) values ('x')`)), refused)
    await assert.rejects(as(db, u1, (q) => q(`delete from public.audit_log`)), refused)
    await assert.rejects(as(db, u1, (q) => q(`select public.write_audit('x', '{}')`)), refused)
  })
  test('identity keys cannot be replaced', async () => {
    const [u1] = await trio()
    const zero = `'\\x${'00'.repeat(32)}'`
    const sig = `'\\x${'00'.repeat(64)}'`
    await as(db, u1, (q) => q(`insert into public.identity_keys (user_id, signing_pub, kex_pub, self_sig) values ($1, ${zero}, ${zero}, ${sig})`, [u1.id]))
    await assert.rejects(as(db, u1, (q) => q(`update public.identity_keys set kex_pub = ${zero}`)), refused)
  })
})

describe('content rules', () => {
  const insert = (u, set) => as(db, u, (q) => q(
    `insert into public.content_objects (owner_id, kind, visibility, key_ref, meta_plain)
     values ($1, 'file', $2, $3, $4)`, [u.id, set.visibility ?? 'private', set.key_ref ?? 'crk:x', set.meta_plain ?? {}]))

  test('private content cannot be stored unencrypted', async () => {
    const [u1] = await trio()
    await assert.rejects(insert(u1, { key_ref: 'plain:' }), /plain_is_public/)
    await assert.rejects(insert(u1, { key_ref: 'plain:', visibility: 'contacts' }), /plain_is_public/)
  })
  test('an unencrypted public object cannot be made private', async () => {
    const [u1] = await trio()
    const o = await addObject(db, u1, { visibility: 'public', key_ref: 'plain:' })
    await assert.rejects(as(db, u1, (q) => q(
      `update public.content_objects set visibility = 'private' where id = $1`, [o.id])), /plain_is_public/)
  })
  test('filenames cannot go in plaintext metadata', async () => {
    const [u1] = await trio()
    await assert.rejects(insert(u1, { meta_plain: { filename: 'tax-return.pdf' } }), /meta_plain_allowlist/)
    await insert(u1, { meta_plain: { mime: 'application/pdf' } })
  })
  test('key references must be a known kind', async () => {
    const [u1] = await trio()
    await assert.rejects(insert(u1, { key_ref: 'server:123' }), /check constraint/)
  })
})

describe('AI permissions', () => {
  test('a new user has no grants', async () => {
    const [u1] = await trio()
    assert.deepEqual(await as(db, u1, (q) => q('select * from public.ai_grants')), [])
  })
  test('grant and revoke are audited, and stay private to the owner', async () => {
    const [u1, u2] = await trio()
    await as(db, u1, async (q) => {
      await q(`insert into public.ai_grants (owner_id, module, scope) values ($1, 'reader', 'read')`, [u1.id])
      await q(`update public.ai_grants set revoked_at = now() where module = 'reader'`)
    })
    const actions = (await as(db, u1, (q) => q(`select action from public.audit_log order by id`))).map((r) => r.action)
    assert.deepEqual(actions, ['ai.grant.insert', 'ai.grant.update'])
    assert.equal((await as(db, u2, (q) => q('select * from public.ai_grants'))).length, 0)
    assert.equal((await as(db, u2, (q) => q('select * from public.audit_log'))).length, 0)
  })
})
