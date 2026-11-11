// Messages' two-user test against a real Matrix server running Totality's own config (brief §6).
// Run by CI after setup.mjs has started the server. Each run signs in fresh people with the same
// kind of one-minute pass the account server hands out.
import { test, describe, before } from 'node:test'
import assert from 'node:assert/strict'
import { createSign, randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'

const base = process.env.MATRIX_URL ?? 'http://127.0.0.1:8008'
const dir = process.env.MATRIX_TEST_DIR ?? '/tmp/matrix-test'
const server = 'usetotality.com'
const privateKey = readFileSync(`${dir}/jwt-private.pem`)

const b64 = (data) => Buffer.from(data).toString('base64url')

function pass(handle) {
  const header = b64(JSON.stringify({ alg: 'ES256', typ: 'JWT' }))
  const now = Math.floor(Date.now() / 1000)
  const claims = b64(JSON.stringify({ iss: 'totality', aud: 'matrix.usetotality.com', sub: handle, iat: now, exp: now + 60 }))
  const signer = createSign('SHA256')
  signer.update(`${header}.${claims}`)
  return `${header}.${claims}.${b64(signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }))}`
}

async function call(token, method, path, body) {
  const response = await fetch(`${base}/_matrix/client/v3${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  return { status: response.status, json: text ? JSON.parse(text) : {} }
}

async function signIn(handle) {
  const { status, json } = await call(null, 'POST', '/login', { type: 'org.matrix.login.jwt', token: pass(handle) })
  assert.equal(status, 200, JSON.stringify(json))
  return { token: json.access_token, id: json.user_id }
}

const tx = () => randomUUID()

// The server refuses with 403, or 404 so as not to say the chat exists. Either is a no.
const refused = (status) => status === 403 || status === 404

// No messages reached this person: refused outright, or an answer with no message events in it.
async function seesNothing(who, room) {
  const { status, json } = await read(who, room)
  if (refused(status)) return true
  return status === 200 && !(json.chunk ?? []).some((e) => e.type === 'm.room.encrypted' || e.type === 'm.room.message')
}

// Looks like what the app sends: Megolm ciphertext the server can't open.
const sealed = (n) => ({
  algorithm: 'm.megolm.v1.aes-sha2', sender_key: 'k', session_id: 's', device_id: 'D', ciphertext: `opaque-${n}`,
})

async function newChat(owner, invite, extra = {}) {
  const { status, json } = await call(owner.token, 'POST', '/createRoom', {
    preset: 'private_chat', visibility: 'private', invite: invite.map((p) => p.id),
    initial_state: [{ type: 'm.room.encryption', state_key: '', content: { algorithm: 'm.megolm.v1.aes-sha2' } }],
    ...extra,
  })
  assert.equal(status, 200, JSON.stringify(json))
  return json.room_id
}

const send = (who, room, n) =>
  call(who.token, 'PUT', `/rooms/${encodeURIComponent(room)}/send/m.room.encrypted/${tx()}`, sealed(n))

const read = (who, room) => call(who.token, 'GET', `/rooms/${encodeURIComponent(room)}/messages?dir=b&limit=50`)

const run = randomUUID().slice(0, 8)
let one, two, three

before(async () => {
  one = await signIn(`one_${run}`)
  two = await signIn(`two_${run}`)
  three = await signIn(`three_${run}`)
  assert.equal(one.id, `@one_${run}:${server}`)
})

describe('Messages two-user test', () => {
  test('a pass for someone else, or an expired one, signs nobody in', async () => {
    const forged = pass('one').split('.')
    forged[2] = forged[2].split('').reverse().join('')
    assert.notEqual((await call(null, 'POST', '/login', { type: 'org.matrix.login.jwt', token: forged.join('.') })).status, 200)
    assert.notEqual((await call(null, 'POST', '/login', { type: 'm.login.password', user: `one_${run}`, password: 'x' })).status, 200)
  })

  test('nobody can register without a pass', async () => {
    const { status } = await call(null, 'POST', '/register', { username: `sneak_${run}`, password: 'long-enough-password' })
    assert.notEqual(status, 200)
  })

  test('user 2 cannot read user 1 chat until they accept, and then can', async () => {
    const room = await newChat(one, [two])
    assert.equal((await send(one, room, 1)).status, 200)
    assert.ok(await seesNothing(two, room), 'an invited person read messages before accepting')
    assert.equal((await call(two.token, 'POST', `/rooms/${encodeURIComponent(room)}/join`, {})).status, 200)
    const { status, json } = await read(two, room)
    assert.equal(status, 200)
    const texts = json.chunk.filter((e) => e.type === 'm.room.encrypted').map((e) => e.content.ciphertext)
    assert.deepEqual(texts, ['opaque-1'])
    assert.equal((await send(two, room, 2)).status, 200)
    const back = await read(one, room)
    assert.ok(back.json.chunk.some((e) => e.content?.ciphertext === 'opaque-2'))
  })

  test('user 3, who is not in the chat, cannot read it, its members, or join it', async () => {
    const room = await newChat(one, [two], { name: 'Lake trip' })
    await send(one, room, 3)
    const path = encodeURIComponent(room)
    assert.ok(await seesNothing(three, room))
    assert.ok(refused((await call(three.token, 'GET', `/rooms/${path}/state`)).status))
    assert.ok(refused((await call(three.token, 'GET', `/rooms/${path}/state/m.room.name/`)).status))
    assert.ok(refused((await call(three.token, 'GET', `/rooms/${path}/members`)).status))
    assert.notEqual((await call(three.token, 'POST', `/rooms/${path}/join`, {})).status, 200)
    assert.notEqual((await send(three, room, 4)).status, 200)
  })

  test('a chat list belongs to its own account', async () => {
    const room = await newChat(one, [])
    const mine = await call(one.token, 'GET', '/joined_rooms')
    const theirs = await call(three.token, 'GET', '/joined_rooms')
    assert.ok(mine.json.joined_rooms.includes(room))
    assert.ok(!theirs.json.joined_rooms.includes(room))
  })

  test('a person who was never invited cannot see a request to them', async () => {
    const room = await newChat(one, [two])
    const sync = await call(three.token, 'GET', '/sync?timeout=0')
    assert.equal(sync.status, 200)
    assert.ok(!Object.keys(sync.json.rooms?.invite ?? {}).includes(room))
  })

  test('the server only relays ciphertext the app sent', async () => {
    const room = await newChat(one, [two])
    await call(two.token, 'POST', `/rooms/${encodeURIComponent(room)}/join`, {})
    await send(one, room, 'secret')
    const { json } = await read(two, room)
    const event = json.chunk.find((e) => e.type === 'm.room.encrypted')
    assert.equal(event.content.ciphertext, 'opaque-secret')
    assert.equal(event.content.body, undefined)
  })

  test('nobody else can read your secret storage or key backup', async () => {
    const enc = (id) => encodeURIComponent(id)
    const key = { algorithm: 'm.secret_storage.v1.aes-hmac-sha2', passphrase: { algorithm: 'm.pbkdf2', iterations: 500000, salt: 's' } }
    assert.equal((await call(one.token, 'PUT', `/user/${enc(one.id)}/account_data/m.secret_storage.key.k1`, key)).status, 200)
    assert.equal((await call(one.token, 'PUT', `/user/${enc(one.id)}/account_data/m.secret_storage.default_key`, { key: 'k1' })).status, 200)
    assert.equal((await call(one.token, 'GET', `/user/${enc(one.id)}/account_data/m.secret_storage.default_key`)).json.key, 'k1')
    assert.ok(refused((await call(three.token, 'GET', `/user/${enc(one.id)}/account_data/m.secret_storage.default_key`)).status))
    assert.ok(refused((await call(three.token, 'GET', `/user/${enc(one.id)}/account_data/m.secret_storage.key.k1`)).status))
    assert.notEqual((await call(three.token, 'PUT', `/user/${enc(one.id)}/account_data/m.secret_storage.default_key`, { key: 'evil' })).status, 200)

    const backup = await call(one.token, 'POST', '/room_keys/version', {
      algorithm: 'm.megolm_backup.v1.curve25519-aes-sha2', auth_data: { public_key: 'one-public-key' },
    })
    assert.equal(backup.status, 200)
    // Each person's backup is their own: user 3 sees none, and can't reach user 1's by its version.
    assert.equal((await call(three.token, 'GET', '/room_keys/version')).status, 404)
    const theirs = await call(three.token, 'GET', `/room_keys/keys?version=${backup.json.version}`)
    assert.ok(theirs.status !== 200 || Object.keys(theirs.json.rooms ?? {}).length === 0)
  })

  test('media needs a signed-in person', async () => {
    const upload = await fetch(`${base}/_matrix/media/v3/upload`, {
      method: 'POST',
      headers: { authorization: `Bearer ${one.token}`, 'content-type': 'application/octet-stream' },
      body: Buffer.from('ciphertext-only'),
    })
    assert.equal(upload.status, 200)
    const { content_uri: uri } = await upload.json()
    const [, mediaServer, id] = uri.match(/^mxc:\/\/([^/]+)\/(.+)$/)
    const anonymous = await fetch(`${base}/_matrix/client/v1/media/download/${mediaServer}/${id}`)
    assert.equal(anonymous.status, 401)
  })
})
