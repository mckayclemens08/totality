import { describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { generateKeyPairSync, randomUUID, verify } from 'node:crypto'
import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import { APNs, DEVICE_DAYS, MAX_DEVICES, PushGate, PushStore, WAKE, accountFrom, apnsToken } from './push.mjs'

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
