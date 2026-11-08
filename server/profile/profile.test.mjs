import assert from 'node:assert/strict'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Cards, Profiles, accountFrom, cardFrom, escapeHTML, homePage, pageHeaders, privacyPage } from './profile.mjs'

const MCKAY = { name: 'mckay', id: '11111111-2222-4333-8444-555555555555' }
const DANA = { name: 'dana_w', id: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' }
const PHOTO = `${MCKAY.id}/0f8e2c1a-9b7d-4e6f-a5c4-3b2a19087654.jpg`
const ROWS = {
  [MCKAY.id]: { handle: 'mckay', display_name: 'McKay Clemens', bio: 'Building Totality in Utah.', avatar_key: PHOTO, visibility: 'public' },
  [DANA.id]: { handle: 'dana_w', display_name: 'Dana Whitfield', bio: 'Trail runner.', avatar_key: null, visibility: 'public' },
}
const roots = []
after(async () => { for (const root of roots) await rm(root, { recursive: true, force: true }) })

async function make({ rows = ROWS, signIn } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'profiles-'))
  roots.push(root)
  const tokens = { 'token-mckay': MCKAY, 'token-dana': DANA }
  const profiles = new Profiles({
    checkSignIn: signIn ?? (async (token) => tokens[token] ?? null),
    // Each sign-in reads only its own row, as the database's rules allow.
    readProfile: async (token, account) => (tokens[token] === account ? rows[account.id] ?? null : null),
    cards: new Cards(root),
    photoBase: 'https://project.supabase.co/storage/v1/object/public/avatars',
    photoOrigin: 'https://project.supabase.co',
  })
  return { profiles, root }
}
const ask = (profiles, method, path, token) => profiles.respond(method, path, token && `Bearer ${token}`)
const text = (reply) => reply.body.toString()

test('a profile has no page until its owner shares it', async () => {
  const { profiles } = await make()
  assert.equal((await ask(profiles, 'GET', '/@mckay')).status, 404)
  assert.deepEqual(JSON.parse(text(await ask(profiles, 'GET', '/profile/mine', 'token-mckay'))), { published: false })
  assert.equal((await ask(profiles, 'POST', '/profile/publish', 'token-mckay')).status, 200)
  const page = await ask(profiles, 'GET', '/@mckay')
  assert.equal(page.status, 200)
  assert.match(text(page), /McKay Clemens/)
  assert.match(text(page), /@mckay/)
  assert.match(text(page), /Building Totality in Utah\./)
  assert.match(text(page), new RegExp(`avatars/${PHOTO}`))
  assert.match(text(page), /href="totality:\/\/profile\/mckay"/)
  assert.deepEqual(JSON.parse(text(await ask(profiles, 'GET', '/profile/mine', 'token-mckay'))), { published: true })
})

test('usernames match whatever their case', async () => {
  const { profiles } = await make()
  await ask(profiles, 'POST', '/profile/publish', 'token-mckay')
  assert.equal((await ask(profiles, 'GET', '/@McKay')).status, 200)
})

test('stopping takes the page down', async () => {
  const { profiles } = await make()
  await ask(profiles, 'POST', '/profile/publish', 'token-mckay')
  assert.equal((await ask(profiles, 'POST', '/profile/unpublish', 'token-mckay')).status, 200)
  assert.equal((await ask(profiles, 'GET', '/@mckay')).status, 404)
})

test('two users: each can only publish or remove their own page', async () => {
  const { profiles } = await make()
  await ask(profiles, 'POST', '/profile/publish', 'token-mckay')
  // Dana's sign-in publishes Dana, never McKay, whatever the request looks like.
  await ask(profiles, 'POST', '/profile/publish?username=mckay', 'token-dana')
  assert.match(text(await ask(profiles, 'GET', '/@mckay')), /McKay Clemens/)
  assert.match(text(await ask(profiles, 'GET', '/@dana_w')), /Dana Whitfield/)
  await ask(profiles, 'POST', '/profile/unpublish', 'token-dana')
  assert.equal((await ask(profiles, 'GET', '/@mckay')).status, 200)
  assert.equal((await ask(profiles, 'GET', '/@dana_w')).status, 404)
})

test('publishing and status need a sign-in', async () => {
  const { profiles, root } = await make()
  for (const [method, path] of [['POST', '/profile/publish'], ['POST', '/profile/unpublish'], ['GET', '/profile/mine']]) {
    assert.equal((await ask(profiles, method, path)).status, 401)
    assert.equal((await ask(profiles, method, path, 'token-nobody')).status, 401)
    assert.equal((await profiles.respond(method, path, 'Basic token-mckay')).status, 401)
  }
  assert.deepEqual(await readdir(root), [])
})

test('a sign-in that cannot be checked publishes nothing', async () => {
  const { profiles, root } = await make({ signIn: async () => { throw new Error('down') } })
  assert.equal((await ask(profiles, 'POST', '/profile/publish', 'token-mckay')).status, 503)
  assert.deepEqual(await readdir(root), [])
})

test('the wrong methods are refused', async () => {
  const { profiles } = await make()
  assert.equal((await ask(profiles, 'GET', '/profile/publish', 'token-mckay')).status, 405)
  assert.equal((await ask(profiles, 'POST', '/@mckay', 'token-mckay')).status, 405)
  assert.equal((await ask(profiles, 'GET', '/profile/other', 'token-mckay')).status, 404)
})

test('only the name, photo, and bio are kept', () => {
  const card = cardFrom({ ...ROWS[MCKAY.id], mxid: '@mckay:usetotality.com', id: MCKAY.id }, MCKAY)
  assert.deepEqual(Object.keys(card).sort(), ['bio', 'name', 'photo'])
})

test('a photo outside the owner folder is dropped', () => {
  for (const key of [`${DANA.id}/0f8e2c1a-9b7d-4e6f-a5c4-3b2a19087654.jpg`, `${MCKAY.id}/../x.jpg`,
    `${MCKAY.id}/0f8e2c1a-9b7d-4e6f-a5c4-3b2a19087654.jpg?x`, 'https://elsewhere.example/a.jpg']) {
    assert.equal(cardFrom({ ...ROWS[MCKAY.id], avatar_key: key }, MCKAY).photo, null, key)
  }
})

test('a profile that is not public gets no page', async () => {
  for (const visibility of ['contacts', 'private', undefined]) {
    assert.equal(cardFrom({ ...ROWS[MCKAY.id], visibility }, MCKAY), null, String(visibility))
  }
  const { profiles, root } = await make({ rows: { [MCKAY.id]: { ...ROWS[MCKAY.id], visibility: 'contacts' } } })
  assert.equal((await ask(profiles, 'POST', '/profile/publish', 'token-mckay')).status, 409)
  assert.deepEqual(await readdir(root), [])
})

test('a row for another username is refused', () => {
  assert.equal(cardFrom(ROWS[DANA.id], MCKAY), null)
  assert.equal(cardFrom(null, MCKAY), null)
})

test('long text is cut to the database limits', () => {
  const card = cardFrom({ handle: 'mckay', display_name: 'N'.repeat(80), bio: 'B'.repeat(400), visibility: 'public' }, MCKAY)
  assert.equal(card.name.length, 50)
  assert.equal(card.bio.length, 160)
})

test('everything a person typed is escaped', async () => {
  const rows = { [MCKAY.id]: { handle: 'mckay', display_name: '<script>alert(1)</script>', bio: '"><img src=x onerror=alert(1)>', visibility: 'public' } }
  const { profiles } = await make({ rows })
  await ask(profiles, 'POST', '/profile/publish', 'token-mckay')
  const page = text(await ask(profiles, 'GET', '/@mckay'))
  assert.doesNotMatch(page, /<script/)
  assert.doesNotMatch(page, /<img src=x/)
  assert.match(page, /&lt;script&gt;/)
  assert.equal(escapeHTML(`<&>"'`), '&lt;&amp;&gt;&quot;&#39;')
})

test('pages run no scripts and load photos from one place', async () => {
  const { profiles } = await make()
  const reply = await ask(profiles, 'GET', '/@nobody_here')
  const policy = reply.headers['Content-Security-Policy']
  assert.match(policy, /default-src 'none'/)
  assert.doesNotMatch(policy, /script-src/)
  assert.match(policy, /img-src https:\/\/project\.supabase\.co;/)
  assert.deepEqual(reply.headers, pageHeaders('https://project.supabase.co'))
})

test('odd usernames never touch the disk', async () => {
  const { profiles } = await make()
  for (const path of ['/@..', '/@../../etc/passwd', '/@a', '/@%2e%2e', `/@${'x'.repeat(30)}`]) {
    assert.equal((await ask(profiles, 'GET', path)).status, 404, path)
  }
})

test('the account comes from the sign-in email alone', () => {
  assert.deepEqual(accountFrom({ email: 'mckay@totality.invalid', id: MCKAY.id }), MCKAY)
  assert.equal(accountFrom({ email: 'mckay@example.com', id: MCKAY.id }), null)
  assert.equal(accountFrom({ email: 'mckay@totality.invalid', id: 'not-an-id' }), null)
})

test('the homepage and privacy policy are fixed pages anyone can read', async () => {
  const { profiles } = await make()
  for (const path of ['/', '/privacy']) {
    const reply = await ask(profiles, 'GET', path)
    assert.equal(reply.status, 200)
    assert.equal(reply.type, 'text/html; charset=utf-8')
    // No scripts, no pictures, and nothing loaded from anywhere.
    assert.match(reply.headers['Content-Security-Policy'], /default-src 'none'; style-src 'sha256-[^']+'; img-src 'none'/)
    assert.doesNotMatch(text(reply), /<script|<img|noindex/)
    assert.equal((await ask(profiles, 'POST', path)).status, 405)
  }
  assert.match(text(await ask(profiles, 'GET', '/')), /href="\/privacy"/)
  const policy = privacyPage()
  // What Google asks a Gmail app to say, and the promises the app's design keeps.
  assert.match(policy, /Limited Use requirements/)
  assert.match(policy, /isn't used for ads/)
  assert.match(policy, /no ads, no analytics, and no tracking/)
  assert.ok(homePage().includes('Privacy policy'))
  assert.equal((await ask(profiles, 'GET', '/privacy/')).status, 404)
})
