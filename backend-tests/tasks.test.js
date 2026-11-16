// Tasks' cases for the brief §6 two-user test, at the database layer (issue 123). The encryption cases are
// in Tests/TotalityTasksTests. Each task and each list is one row with everything sealed in meta_cipher and
// no storage_key, and it stays with its owner. Sharing lists comes in step 6.
import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { newDatabase, newUser, as } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })

const pair = async () => {
  n += 1
  return [await newUser(db, `tasks1_${n}`), await newUser(db, `tasks2_${n}`)]
}
const insertTask = (user, kind = 'task', fields = {}) => as(db, user, async (q) => {
  const id = randomUUID()
  await q(`insert into public.content_objects (id, owner_id, kind, key_ref, meta_cipher, meta_plain)
           values ($1, $2, $3, $4, $5, $6)`,
    [id, fields.owner ?? user.id, kind, fields.key_ref ?? `crk:${id}`, Buffer.from('sealed task'),
      JSON.stringify(fields.meta_plain ?? {})])
  return id
})
const visible = async (user, id) =>
  (await as(db, user, (q) => q('select id from public.content_objects where id = $1', [id]))).length === 1

describe('Tasks two-user test', () => {
  for (const kind of ['task', 'task_list']) {
    test(`a ${kind} is visible to its owner alone`, async () => {
      const [user1, user2] = await pair()
      const id = await insertTask(user1, kind)
      assert.equal(await visible(user1, id), true)
      assert.equal(await visible(user2, id), false)
      await assert.rejects(visible(null, id), /permission denied/)
    })

    test(`user 2 cannot change or delete user 1's ${kind}`, async () => {
      const [user1, user2] = await pair()
      const id = await insertTask(user1, kind)
      await as(db, user2, (q) => q('update public.content_objects set meta_cipher = $1 where id = $2', [Buffer.from('x'), id]))
      await as(db, user2, (q) => q('delete from public.content_objects where id = $1', [id]))
      const [row] = await as(db, user1, (q) => q('select meta_cipher from public.content_objects where id = $1', [id]))
      assert.equal(Buffer.from(row.meta_cipher).toString(), 'sealed task')
    })

    test(`a ${kind} cannot be stored unencrypted or planted under someone else`, async () => {
      const [user1, user2] = await pair()
      await assert.rejects(insertTask(user1, kind, { key_ref: 'plain:' }), /plain_is_public/)
      await assert.rejects(insertTask(user2, kind, { owner: user1.id }))
    })
  }

  test('a title, note, tag, date or list name cannot be stored in plaintext', async () => {
    const [user1] = await pair()
    for (const key of ['title', 'notes', 'tags', 'when', 'deadline', 'checklist', 'name', 'list']) {
      await assert.rejects(insertTask(user1, 'task', { meta_plain: { [key]: 'x' } }), /meta_plain_allowlist/)
    }
  })

  test("user 2's list of tasks never includes user 1's", async () => {
    const [user1, user2] = await pair()
    await insertTask(user1, 'task')
    await insertTask(user1, 'task_list')
    const mine = await insertTask(user2, 'task')
    const rows = await as(db, user2, (q) => q(`select id from public.content_objects where kind in ('task', 'task_list')`))
    assert.deepEqual(rows.map(({ id }) => id), [mine])
  })
})
