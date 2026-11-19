import { test, before, describe } from 'node:test'
import assert from 'node:assert/strict'
import { newDatabase, newUser, as, signIn } from './harness.js'

let db, n = 0
before(async () => { db = await newDatabase() })
const person = async () => { n += 1; return newUser(db, `brw_${n}`) }
const checkIn = (s, label = 'Safari on Mac') => as(db, s, async (q) => (await q('select public.browser_check_in($1) as r', [label]))[0].r)
const list = (s) => as(db, s, (q) => q('select * from public.my_browsers()'))
const remove = (s, id) => as(db, s, async (q) => (await q('select public.remove_browser($1) as r', [id]))[0].r)
const sessionAlive = async (s) => (await db.query('select 1 from auth.sessions where id = $1', [s.session])).rows.length === 1

describe('paired browsers (Devices on the iPhone)', () => {
  test('a browser adds itself on check-in, and the iPhone lists it', async () => {
    const u = await person()
    const phone = await signIn(db, u), web = await signIn(db, u)
    assert.equal(await checkIn(web), 'ok')
    assert.equal(await checkIn(web), 'ok', 'checking in again keeps one row')
    const rows = await list(phone)
    assert.equal(rows.length, 1)
    assert.equal(rows[0].device_label, 'Safari on Mac')
  })

  test('removing ends the browser\'s sign-in, returns its Matrix device, and the browser learns it was removed', async () => {
    const u = await person()
    const phone = await signIn(db, u), web = await signIn(db, u)
    await checkIn(web)
    await as(db, web, (q) => q('select public.browser_set_matrix_device($1)', ['ABCDEFGHIJ']))
    const [row] = await list(phone)
    assert.equal(row.matrix_device, 'ABCDEFGHIJ')
    assert.equal(await remove(phone, row.id), 'ABCDEFGHIJ')
    assert.equal(await sessionAlive(web), false, 'its session (and so its refresh tokens) is gone')
    assert.equal(await checkIn(web), 'removed')
    assert.equal((await list(phone)).length, 0)
    assert.equal(await remove(phone, row.id), null, 'removing twice does nothing')
  })

  test('two-user: user 2 cannot see, remove or change user 1\'s browsers', async () => {
    const u1 = await person(), u2 = await person()
    const web1 = await signIn(db, u1), phone2 = await signIn(db, u2), phone1 = await signIn(db, u1)
    await checkIn(web1)
    const [row] = await list(phone1)
    assert.equal((await list(phone2)).length, 0)
    assert.equal((await as(db, phone2, (q) => q('select id from public.web_browsers'))).length, 0)
    assert.equal(await remove(phone2, row.id), null)
    assert.equal(await sessionAlive(web1), true)
    await as(db, phone2, (q) => q('select public.browser_set_matrix_device($1)', ['EVIL']))
    assert.equal((await list(phone1))[0].matrix_device, null)
    assert.equal(await checkIn(web1), 'ok')
  })

  test('nobody writes rows directly, and anon can call nothing', async () => {
    const u = await person()
    const web = await signIn(db, u)
    await checkIn(web)
    await assert.rejects(as(db, web, (q) => q(`insert into public.web_browsers (session_id, device_label) values (gen_random_uuid(), 'x')`)))
    await assert.rejects(as(db, web, (q) => q(`update public.web_browsers set removed_at = null`)))
    await assert.rejects(as(db, web, (q) => q(`delete from public.web_browsers`)))
    await assert.rejects(as(db, null, (q) => q(`select public.my_browsers()`)))
    await assert.rejects(as(db, null, (q) => q(`select public.browser_check_in('x')`)))
    await assert.rejects(as(db, web, (q) => q(`select public.current_session_id()`)), 'internal helper only')
  })

  test('the iPhone can\'t remove the session it\'s using, and a token without a session can\'t check in', async () => {
    const u = await person()
    const web = await signIn(db, u)
    await checkIn(web)
    const [row] = await list(web)
    await assert.rejects(remove(web, row.id))
    await assert.rejects(checkIn(u), 'no session_id in the token')
  })

  test('signing out takes the row; ended sessions drop off the list and are cleared', async () => {
    const u = await person()
    const phone = await signIn(db, u), a = await signIn(db, u), b = await signIn(db, u)
    await checkIn(a); await checkIn(b, 'Chrome on Windows')
    await as(db, a, (q) => q('select public.browser_forget()'))
    assert.deepEqual((await list(phone)).map((r) => r.device_label), ['Chrome on Windows'])
    await db.query('delete from auth.sessions where id = $1', [b.session])
    assert.equal((await list(phone)).length, 0)
    const c = await signIn(db, u)
    await checkIn(c, 'Firefox on Linux')
    assert.equal((await db.query('select count(*)::int as n from public.web_browsers where owner_id = $1', [u.id])).rows[0].n, 1)
  })

  test('labels are checked, and at most 20 browsers at once', async () => {
    const u = await person()
    await assert.rejects(checkIn(await signIn(db, u), ''))
    await assert.rejects(checkIn(await signIn(db, u), 'x'.repeat(81)))
    for (let i = 0; i < 20; i++) await checkIn(await signIn(db, u))
    await assert.rejects(checkIn(await signIn(db, u)))
  })
})
