// Mail's cases for the brief §6 two-user test, at the database layer. The encryption cases are in
// Tests/TotalityMailTests. Only marks, settings, and drafts come here, as ciphertext rows that stay with their
// owner. Messages live on the mail server, sealed to the account's mail key, and have no row at all.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `mail1_${n}`), await newUser(db, `mail2_${n}`)]
}
const insert = (user, kind, fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, key_ref, meta_cipher, meta_plain)
           values ($1, $2, $3, $4, $5, $6)`,
    [id, user.id, kind, fields.key_ref ?? `crk:${id}`, Buffer.from('sealed'), JSON.stringify(fields.meta_plain ?? {})])
  return id
})
const visible = async (user, id) =>
  (await as(db, user, (q) => q('select id from public.content_objects where id = $1', [id]))).length === 1

describe('Mail two-user test', () => {
  for (const kind of ['mail_marks', 'mail_settings', 'mail_draft']) {
    test(`${kind} is visible to its owner alone`, async () => {
      const [user1, user2] = await pair()
      const id = await insert(user1, kind)
      assert.equal(await visible(user1, id), true)
      assert.equal(await visible(user2, id), false)
      await assert.rejects(visible(null, id), /permission denied/)
    })

    test(`user 2 cannot change or delete user 1's ${kind}`, async () => {
      const [user1, user2] = await pair()
      const id = await insert(user1, kind)
      await as(db, user2, (q) => q('update public.content_objects set meta_cipher = $1 where id = $2', [Buffer.from('x'), id]))
      await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
      const [row] = await as(db, user1, (q) => q('select meta_cipher from public.content_objects where id = $1', [id]))
      assert.equal(Buffer.from(row.meta_cipher).toString(), 'sealed')
    })

    test(`${kind} cannot be stored unencrypted or with readable details`, async () => {
      const [user1] = await pair()
      await assert.rejects(insert(user1, kind, { key_ref: 'plain:' }), /plain_is_public/)
      for (const key of ['subject', 'from', 'folder', 'blocked']) {
        await assert.rejects(insert(user1, kind, { meta_plain: { [key]: 'x' } }), /meta_plain_allowlist/)
      }
    })
  }

  test('user 2 cannot plant a row under user 1', async () => {
    const [user1, user2] = await pair()
    await assert.rejects(as(db, user2, (q) => q(
      `insert into public.content_objects (id, owner_id, kind, key_ref, meta_cipher) values ($1, $2, 'mail_marks', $3, $4)`,
      [randomUUID(), user1.id, `crk:${randomUUID()}`, Buffer.from('sealed')])))
  })
})
