import { describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { generateKeyPairSync, randomUUID, sign, verify } from 'node:crypto'
import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import { APNs, DEVICE_DAYS, MAX_DEVICES, PushGate, PushStore, QUIET_SECONDS, WAKE, accountFrom, addressHash, apnsToken, googleKeys } from './push.mjs'

const MCKAY = { name: 'mckayclemens', id: randomUUID() }
const DANA = { name: 'dana_whitfield', id: randomUUID() }
const signIns = new Map([['token-mckay', MCKAY], ['token-dana', DANA]])
const phone = (n) => n.toString(16).padStart(64, '0')
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })

function fakeApple(answers = {}) {
  const sent = []
  const request = async (host, headers, body) => {
    const token = headers[':path'].split('/').pop()
    sent.push({ host, headers, body, token })
    return answers[token] ?? { status: 200 }
  }
  return { sent, apns: new APNs({ key: privateKey, keyId: 'KEY1234567', teamId: 'TEAM123456', topic: 'app.totality.ios', request }) }
}

async function newGate({ answers, clock } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'totality-push-'))
  const store = new PushStore(root, { clock })
  const apple = fakeApple(answers)
  const gate = new PushGate({ checkSignIn: async (token) => signIns.get(token) ?? null, store, apns: apple.apns })
  return { root, store, gate, sent: apple.sent }
}

const call = (gate, path, { token = 'token-mckay', body, method = 'POST' } = {}) =>
  gate.respond({
    method, path, headers: token ? { authorization: `Bearer ${token}` } : {},
    body: Readable.from(body === undefined ? [] : [Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]),
  })

describe('accounts', () => {
  test('only Totality accounts count', () => {
    assert.deepEqual(accountFrom({ id: MCKAY.id, email: 'mckayclemens@totality.invalid' }), MCKAY)
    assert.equal(accountFrom({ id: MCKAY.id, email: 'someone@gmail.com' }), null)
    assert.equal(accountFrom({ id: 'nope', email: 'mckayclemens@totality.invalid' }), null)
  })
})

describe('registering a phone', () => {
  test('needs a sign-in', async () => {
    const { gate } = await newGate()
    assert.equal((await call(gate, '/push/device', { token: null, body: { token: phone(1), sandbox: true } })).status, 401)
    assert.equal((await call(gate, '/push/device', { token: 'forged', body: { token: phone(1), sandbox: true } })).status, 401)
  })

  test('takes only a real-looking token and says which Apple host', async () => {
    const { gate } = await newGate()
    for (const body of [{ token: 'abc', sandbox: true }, { token: phone(1) }, { token: 'AB'.repeat(32), sandbox: false }, 'not json']) {
      assert.equal((await call(gate, '/push/device', { body })).status, 400)
    }
    assert.equal((await call(gate, '/push/device', { body: { token: 'a'.repeat(2_000), sandbox: true } })).status, 400)
  })

  test('other paths and methods are refused', async () => {
    const { gate } = await newGate()
    assert.equal((await call(gate, '/push/device', { method: 'GET' })).status, 405)
    assert.equal((await call(gate, '/push/devices', {})).status, 404)
    assert.equal((await call(gate, '/push/health', { method: 'GET', token: null })).status, 200)
  })

  test('is kept on disk and survives a restart', async () => {
    const { root, gate } = await newGate()
    assert.equal((await call(gate, '/push/device', { body: { token: phone(1), sandbox: true } })).status, 204)
    const again = new PushStore(root)
    assert.deepEqual((await again.devices(MCKAY.id)).map((d) => d.token), [phone(1)])
    const text = await readFile(join(root, 'push.json'), 'utf8')
    assert.ok(!text.includes('mckayclemens'), 'no username on disk')
  })

  test('a phone belongs to one account at a time', async () => {
    const { gate, store } = await newGate()
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: true } })
    await call(gate, '/push/device', { token: 'token-dana', body: { token: phone(1), sandbox: true } })
    assert.deepEqual(await store.devices(MCKAY.id), [])
    assert.equal((await store.devices(DANA.id)).length, 1)
  })

  test('an account keeps at most MAX_DEVICES, newest first', async () => {
    let now = 1_000_000
    const { gate, store } = await newGate({ clock: () => now })
    for (let n = 1; n <= MAX_DEVICES + 2; n++) {
      now += 1
      await call(gate, '/push/device', { body: { token: phone(n), sandbox: false } })
    }
    const kept = (await store.devices(MCKAY.id)).map((d) => d.token)
    assert.equal(kept.length, MAX_DEVICES)
    assert.ok(!kept.includes(phone(1)) && !kept.includes(phone(2)))
  })

  test('a phone not seen for DEVICE_DAYS is dropped', async () => {
    let now = Date.now()
    const { gate, store } = await newGate({ clock: () => now })
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: false } })
    now += (DEVICE_DAYS + 1) * 24 * 60 * 60 * 1000
    assert.deepEqual(await store.devices(MCKAY.id), [])
  })

  test('removing only touches your own phones', async () => {
    const { gate, store } = await newGate()
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: true } })
    assert.equal((await call(gate, '/push/device/remove', { token: 'token-dana', body: { token: phone(1) } })).status, 204)
    assert.equal((await store.devices(MCKAY.id)).length, 1)
    await call(gate, '/push/device/remove', { body: { token: phone(1) } })
    assert.deepEqual(await store.devices(MCKAY.id), [])
  })
})

describe('waking phones', () => {
  test('sends an empty silent push to each of the account’s phones', async () => {
    const { gate, sent } = await newGate()
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: true } })
    await call(gate, '/push/device', { body: { token: phone(2), sandbox: false } })
    await call(gate, '/push/device', { token: 'token-dana', body: { token: phone(3), sandbox: false } })
    assert.equal(await gate.wake([MCKAY.id]), 2)
    assert.deepEqual(sent.map((s) => s.host).sort(), ['api.push.apple.com', 'api.sandbox.push.apple.com'])
    for (const { headers, body } of sent) {
      assert.equal(headers['apns-push-type'], 'background')
      assert.equal(headers['apns-priority'], '5')
      assert.equal(headers['apns-topic'], 'app.totality.ios')
      assert.deepEqual(body, WAKE)
    }
    assert.deepEqual(JSON.parse(WAKE), { aps: { 'content-available': 1 } })
  })

  test('forgets a token Apple says is gone', async () => {
    const { gate, store } = await newGate({ answers: { [phone(1)]: { status: 410 }, [phone(2)]: { status: 400, reason: 'BadDeviceToken' }, [phone(3)]: { status: 500 } } })
    for (const n of [1, 2, 3]) await call(gate, '/push/device', { body: { token: phone(n), sandbox: false } })
    assert.equal(await gate.wake([MCKAY.id]), 0)
    assert.deepEqual((await store.devices(MCKAY.id)).map((d) => d.token), [phone(3)])
  })

  test('sends nothing while the Apple key is missing', async () => {
    const root = await mkdtemp(join(tmpdir(), 'totality-push-'))
    const gate = new PushGate({ checkSignIn: async (t) => signIns.get(t) ?? null, store: new PushStore(root) })
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: true } })
    assert.equal(await gate.wake([MCKAY.id]), 0)
  })
})

describe("Apple's sign-in token", () => {
  test('is an ES256 JWT for the team, made again after 45 minutes', () => {
    const token = apnsToken({ key: privateKey, keyId: 'KEY1234567', teamId: 'TEAM123456', now: 1_700_000_000_000 })
    const [head, claims, signature] = token.split('.')
    assert.deepEqual(JSON.parse(Buffer.from(head, 'base64url')), { alg: 'ES256', kid: 'KEY1234567' })
    assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'TEAM123456', iat: 1_700_000_000 })
    assert.ok(verify('sha256', Buffer.from(`${head}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')))

    let now = 0
    const apns = new APNs({ key: privateKey, keyId: 'K', teamId: 'T', topic: 'x', clock: () => now, request: async () => ({ status: 200 }) })
    const first = apns.bearer()
    now += 44 * 60_000
    assert.equal(apns.bearer(), first)
    now += 2 * 60_000
    assert.notEqual(apns.bearer(), first)
  })
})

// Google's side, with a key made for the test.
const google = generateKeyPairSync('rsa', { modulusLength: 2048 })
const stranger = generateKeyPairSync('rsa', { modulusLength: 2048 })
const CLIENT = '973899545310-test.apps.googleusercontent.com'
const AUDIENCE = 'https://usetotality.com/push/gmail/notify'
const SENDER = 'gmail-push@totality-test.iam.gserviceaccount.com'
const ADDRESS_KEY = 'k'.repeat(48)
const seconds = () => Math.floor(Date.now() / 1000)
function jwt(claims, { key = google.privateKey, kid = 'g1', alg = 'RS256' } = {}) {
  const part = (v) => Buffer.from(JSON.stringify(v)).toString('base64url')
  const data = `${part({ alg, kid, typ: 'JWT' })}.${part({ iss: 'https://accounts.google.com', iat: seconds(), exp: seconds() + 3600, ...claims })}`
  return `${data}.${sign('RSA-SHA256', Buffer.from(data), key).toString('base64url')}`
}
const idToken = (email, extra = {}) => jwt({ aud: CLIENT, email, email_verified: true, ...extra })
const pubsubToken = (extra = {}) => jwt({ aud: AUDIENCE, email: SENDER, email_verified: true, ...extra })
const note = (emailAddress, historyId = 9_876_543) => ({
  message: { data: Buffer.from(JSON.stringify({ emailAddress, historyId })).toString('base64'), messageId: '1', publishTime: new Date().toISOString() },
  subscription: 'projects/totality-test/subscriptions/gmail-push',
})

async function gmailGate({ clock = Date.now } = {}) {
  const made = await newGate({ clock })
  const timers = []
  made.gate.gmail = { addressKey: ADDRESS_KEY, keys: async (kid) => (kid === 'g1' ? google.publicKey : null), clientIDs: [CLIENT], pubsubAudience: AUDIENCE, pubsubSender: SENDER }
  made.gate.clock = clock
  made.gate.later = (fn, ms) => timers.push({ fn, ms })
  made.timers = timers
  return made
}
const notify = async (gate, body, token = pubsubToken()) => {
  const answer = await call(gate, '/push/gmail/notify', { token, body })
  await gate.waking
  return answer.status
}

describe('linking a Gmail address', () => {
  test('needs a Totality sign-in and a Google ID token for that address', async () => {
    const { gate, store } = await gmailGate()
    assert.equal((await call(gate, '/push/gmail/link', { token: null, body: { idToken: idToken('mckay@gmail.com') } })).status, 401)
    for (const bad of [
      idToken('mckay@gmail.com', { email_verified: false }),
      idToken('mckay@gmail.com', { aud: 'someone-else.apps.googleusercontent.com' }),
      idToken('mckay@gmail.com', { iss: 'https://evil.example' }),
      idToken('mckay@gmail.com', { exp: seconds() - 3600 }),
      jwt({ aud: CLIENT, email: 'mckay@gmail.com', email_verified: true }, { key: stranger.privateKey }),
      jwt({ aud: CLIENT, email: 'mckay@gmail.com', email_verified: true }, { kid: 'unknown' }),
      jwt({ aud: CLIENT, email: 'mckay@gmail.com', email_verified: true }, { alg: 'none' }),
      'not.a.jwt', undefined,
    ]) {
      assert.equal((await call(gate, '/push/gmail/link', { body: { idToken: bad } })).status, 403)
    }
    assert.equal((await call(gate, '/push/gmail/link', { body: { idToken: idToken('McKay@Gmail.com') } })).status, 204)
    assert.deepEqual(await store.linked(addressHash(ADDRESS_KEY, 'mckay@gmail.com')), [MCKAY.id])
  })

  test('keeps only a keyed hash of the address', async () => {
    const { gate, root } = await gmailGate()
    await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })
    const text = await readFile(join(root, 'push.json'), 'utf8')
    assert.ok(!text.toLowerCase().includes('mckay'), 'no address on disk')
    assert.notEqual(addressHash(ADDRESS_KEY, 'mckay@gmail.com'), addressHash('other'.repeat(10), 'mckay@gmail.com'))
  })

  test('unlinking only removes your own link', async () => {
    const { gate, store } = await gmailGate()
    await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })
    await call(gate, '/push/gmail/unlink', { token: 'token-dana', body: { address: 'mckay@gmail.com' } })
    assert.deepEqual(await store.linked(addressHash(ADDRESS_KEY, 'mckay@gmail.com')), [MCKAY.id])
    await call(gate, '/push/gmail/unlink', { body: { address: 'mckay@gmail.com' } })
    assert.deepEqual(await store.linked(addressHash(ADDRESS_KEY, 'mckay@gmail.com')), [])
  })

  test('is off until the server has its Gmail settings', async () => {
    const { gate } = await newGate()
    assert.equal((await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })).status, 503)
    assert.equal((await call(gate, '/push/gmail/notify', { token: pubsubToken(), body: note('mckay@gmail.com') })).status, 503)
  })
})

describe("Google's Pub/Sub note", () => {
  test('wakes the phones linked to that address, and only those', async () => {
    const { gate, sent } = await gmailGate()
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: false } })
    await call(gate, '/push/device', { token: 'token-dana', body: { token: phone(2), sandbox: false } })
    await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })
    assert.equal(await notify(gate, note('mckay@gmail.com')), 204)
    assert.deepEqual(sent.map((s) => s.token), [phone(1)])
    assert.deepEqual(sent[0].body, WAKE)
  })

  test('has to be signed by Google for this endpoint, as the Gmail sender', async () => {
    const { gate, sent } = await gmailGate()
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: false } })
    await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })
    for (const bad of [
      pubsubToken({ aud: 'https://elsewhere.example/push' }),
      pubsubToken({ email: 'attacker@evil.iam.gserviceaccount.com' }),
      pubsubToken({ email_verified: false }),
      pubsubToken({ exp: seconds() - 3600 }),
      jwt({ aud: AUDIENCE, email: SENDER, email_verified: true }, { key: stranger.privateKey }),
      idToken('mckay@gmail.com'),
    ]) {
      assert.equal(await notify(gate, note('mckay@gmail.com'), bad), 401)
    }
    assert.equal((await call(gate, '/push/gmail/notify', { token: null, body: note('mckay@gmail.com') })).status, 401)
    assert.equal(sent.length, 0)
  })

  test('answers the same for an unknown address or a broken note', async () => {
    const { gate, sent } = await gmailGate()
    assert.equal(await notify(gate, note('nobody@gmail.com')), 204)
    assert.equal(await notify(gate, { message: { data: 'not base64 json' } }), 204)
    assert.equal(await notify(gate, {}), 204)
    assert.equal(sent.length, 0)
  })

  test('a burst of notes becomes one push now and one at the end of the quiet gap', async () => {
    let now = Date.now()
    const { gate, sent, timers } = await gmailGate({ clock: () => now })
    await call(gate, '/push/device', { body: { token: phone(1), sandbox: false } })
    await call(gate, '/push/gmail/link', { body: { idToken: idToken('mckay@gmail.com') } })
    for (let i = 0; i < 5; i++) {
      await notify(gate, note('mckay@gmail.com', 100 + i))
      now += 1000
    }
    assert.equal(sent.length, 1)
    assert.equal(timers.length, 1)
    assert.ok(timers[0].ms > 0 && timers[0].ms <= QUIET_SECONDS * 1000)
    now += QUIET_SECONDS * 1000
    timers[0].fn()
    await gate.waking
    assert.equal(sent.length, 2)
  })
})

describe("Google's keys", () => {
  test('are fetched once, and again for a new key ID at most once a minute', async () => {
    let now = 0
    let loads = 0
    const jwk = { ...google.publicKey.export({ format: 'jwk' }), kid: 'g1' }
    const load = async () => { loads += 1; return { ok: true, headers: new Headers({ 'cache-control': 'public, max-age=20000' }), json: async () => ({ keys: [jwk] }) } }
    const keys = googleKeys({ load, clock: () => now })
    now = 100_000
    assert.ok(await keys('g1'))
    assert.ok(await keys('g1'))
    assert.equal(loads, 1)
    assert.equal(await keys('g2'), null)
    assert.equal(loads, 1)
    now += 61_000
    assert.equal(await keys('g2'), null)
    assert.equal(loads, 2)
  })
})
