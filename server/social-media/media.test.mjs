import { describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { randomBytes, randomUUID } from 'node:crypto'
import { mkdtemp, readdir, readFile, writeFile, mkdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import { ACCOUNT_CAP, DISK_FLOOR, MAX_FILE, MediaGate, MediaStore, accountFrom, corsHeaders, rememberingSignIns, serve } from './media.mjs'

const GiB = 1024 ** 3
const MCKAY = { name: 'mckayclemens', id: randomUUID() }
const DANA = { name: 'dana_whitfield', id: randomUUID() }
const tokens = new Map([['token-mckay', MCKAY], ['token-dana', DANA]])

const jpeg = (size = 2_000) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(size - 4)])
const m4a = (size = 2_000) => Buffer.concat([Buffer.from([0, 0, 0, 0x20]), Buffer.from('ftypM4A '), randomBytes(size - 12)])
const sealed = (size = 2_000) => randomBytes(size)

async function newGate({ free = 40 * GiB, checkSignIn, cap, daily, clock } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'totality-media-'))
  const store = new MediaStore(root, { clock })
  const gate = new MediaGate({
    checkSignIn: checkSignIn ?? (async (token) => tokens.get(token) ?? null),
    store, diskFree: async () => free, ...(cap && { cap }), ...(daily && { daily }),
  })
  return { root, store, gate }
}

const path = (owner, id) => `/social/media/${owner.id}/${id}`
function call(gate, method, at, { token = 'token-mckay', type, body, length } = {}) {
  const headers = {}
  if (token) headers.authorization = `Bearer ${token}`
  if (type) headers['content-type'] = type
  if (body) headers['content-length'] = String(length ?? body.length)
  return gate.respond({ method, path: at, headers, body: Readable.from(body ? [body] : []) })
}
const put = (gate, owner, id, body, type, token) => call(gate, 'PUT', path(owner, id), { token, type, body })

async function readAll(body) {
  if (Buffer.isBuffer(body)) return body
  const chunks = []
  for await (const chunk of body) chunks.push(chunk)
  return Buffer.concat(chunks)
}

describe('sign-in', () => {
  test('every request needs a Totality sign-in, reading included, so nothing can be hotlinked', async () => {
    const { gate } = await newGate()
    const id = randomUUID()
    assert.equal((await put(gate, MCKAY, id, jpeg(), 'image/jpeg')).status, 201)
    assert.equal((await call(gate, 'GET', path(MCKAY, id), { token: null })).status, 401)
    assert.equal((await call(gate, 'GET', path(MCKAY, id), { token: 'stranger' })).status, 401)
    assert.equal((await call(gate, 'GET', path(MCKAY, id))).status, 200)
  })

  test('a sign-in that cannot be checked is a 503, not a yes', async () => {
    const { gate } = await newGate({ checkSignIn: async () => { throw new Error('down') } })
    assert.equal((await call(gate, 'GET', path(MCKAY, randomUUID()))).status, 503)
  })

  test('only Totality accounts count', () => {
    assert.deepEqual(accountFrom({ email: 'mckayclemens@totality.invalid', id: MCKAY.id }), MCKAY)
    assert.equal(accountFrom({ email: 'someone@gmail.com', id: MCKAY.id }), null)
    assert.equal(accountFrom({ email: 'mckayclemens@totality.invalid', id: 'nope' }), null)
  })

  test('good sign-ins are remembered for a minute, by hash', async () => {
    let asked = 0
    let now = 0
    const check = rememberingSignIns(async () => { asked += 1; return MCKAY }, { clock: () => now })
    await check('t'); await check('t')
    assert.equal(asked, 1)
    now = 61_000
    await check('t')
    assert.equal(asked, 2)
  })
})

describe('reading', () => {
  test('anyone signed in can read a file by its path, served as its type', async () => {
    const { gate } = await newGate()
    const id = randomUUID()
    const photo = jpeg()
    await put(gate, MCKAY, id, photo, 'image/jpeg')
    const answer = await call(gate, 'GET', path(MCKAY, id), { token: 'token-dana' })
    assert.equal(answer.status, 200)
    assert.equal(answer.headers['Content-Type'], 'image/jpeg')
    assert.match(answer.headers['Cache-Control'], /^private/)
    assert.deepEqual(await readAll(answer.body), photo)
  })

  test('sealed and audio files keep their types', async () => {
    const { gate } = await newGate()
    const a = randomUUID()
    const b = randomUUID()
    await put(gate, MCKAY, a, m4a(), 'audio/mp4')
    await put(gate, MCKAY, b, sealed(), 'application/octet-stream')
    assert.equal((await call(gate, 'GET', path(MCKAY, a))).headers['Content-Type'], 'audio/mp4')
    assert.equal((await call(gate, 'GET', path(MCKAY, b))).headers['Content-Type'], 'application/octet-stream')
  })

  test('a missing file is a 404, and bad paths never reach the disk', async () => {
    const { gate } = await newGate()
    assert.equal((await call(gate, 'GET', path(MCKAY, randomUUID()))).status, 404)
    for (const bad of ['/social/media/../etc/passwd', `/social/media/${MCKAY.id}/..`, `/social/media/x/${randomUUID()}`, '/social/media', '/blobs/list']) {
      assert.equal((await call(gate, 'GET', bad)).status, 404, bad)
    }
  })
})

describe('writing', () => {
  test('only your own folder can be written to or emptied', async () => {
    const { gate } = await newGate()
    const id = randomUUID()
    assert.equal((await put(gate, MCKAY, id, jpeg(), 'image/jpeg', 'token-dana')).status, 403)
    assert.equal((await put(gate, MCKAY, id, jpeg(), 'image/jpeg')).status, 201)
    assert.equal((await call(gate, 'DELETE', path(MCKAY, id), { token: 'token-dana' })).status, 403)
    assert.equal((await call(gate, 'GET', path(MCKAY, id))).status, 200)
  })

  test('nothing is ever overwritten, even with another type', async () => {
    const { gate } = await newGate()
    const id = randomUUID()
    const first = jpeg()
    await put(gate, MCKAY, id, first, 'image/jpeg')
    assert.equal((await put(gate, MCKAY, id, jpeg(), 'image/jpeg')).status, 409)
    assert.equal((await put(gate, MCKAY, id, sealed(), 'application/octet-stream')).status, 409)
    assert.deepEqual(await readAll((await call(gate, 'GET', path(MCKAY, id))).body), first)
  })

  test('a file has to be what it says it is', async () => {
    const { gate } = await newGate()
    assert.equal((await put(gate, MCKAY, randomUUID(), sealed(), 'image/jpeg')).status, 415)
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(), 'audio/mp4')).status, 415)
    assert.equal((await put(gate, MCKAY, randomUUID(), Buffer.from('<html><script>'), 'text/html')).status, 415)
    assert.equal((await put(gate, MCKAY, randomUUID(), randomBytes(20), 'application/octet-stream')).status, 415)
  })

  test('a refused upload leaves nothing behind', async () => {
    const { gate, root } = await newGate()
    await put(gate, MCKAY, randomUUID(), sealed(), 'image/jpeg')
    assert.deepEqual(await readdir(join(root, 'accounts', MCKAY.id)), [])
  })

  test('files over the limit are refused, by header or by what arrives', async () => {
    const { gate } = await newGate()
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(MAX_FILE + 1), 'image/jpeg')).status, 413)
    const lying = await call(gate, 'PUT', path(MCKAY, randomUUID()), { type: 'image/jpeg', body: jpeg(MAX_FILE + 1), length: 100 })
    assert.equal(lying.status, 413)
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(MAX_FILE), 'image/jpeg')).status, 201)
  })

  test('an upload without a length is refused', async () => {
    const { gate } = await newGate()
    const answer = await gate.respond({
      method: 'PUT', path: path(MCKAY, randomUUID()),
      headers: { authorization: 'Bearer token-mckay', 'content-type': 'image/jpeg' }, body: Readable.from([jpeg()]),
    })
    assert.equal(answer.status, 411)
  })

  test('the account cap and the disk floor both stop uploads', async () => {
    const small = await newGate({ cap: 3_000 })
    assert.equal((await put(small.gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 201)
    assert.equal((await put(small.gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 507)
    assert.equal((await put(small.gate, DANA, randomUUID(), jpeg(), 'image/jpeg', 'token-dana')).status, 201)
    const full = await newGate({ free: DISK_FLOOR + 1_000 })
    assert.equal((await put(full.gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 507)
    assert.ok(ACCOUNT_CAP >= GiB)
  })

  test('there is a daily number of files, which resets the next day', async () => {
    let now = Date.UTC(2026, 10, 25, 12)
    const { gate } = await newGate({ daily: 2, clock: () => now })
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 201)
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 201)
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 429)
    now += 24 * 60 * 60 * 1000
    assert.equal((await put(gate, MCKAY, randomUUID(), jpeg(), 'image/jpeg')).status, 201)
  })

  test('removing frees the room and asking twice is harmless', async () => {
    const { gate, store } = await newGate()
    const id = randomUUID()
    await put(gate, MCKAY, id, jpeg(), 'image/jpeg')
    assert.equal(await store.used(MCKAY.id), 2_000)
    assert.equal((await call(gate, 'DELETE', path(MCKAY, id))).status, 204)
    assert.equal((await call(gate, 'DELETE', path(MCKAY, id))).status, 204)
    assert.equal(await store.used(MCKAY.id), 0)
    assert.equal((await call(gate, 'GET', path(MCKAY, id))).status, 404)
  })

  test('only GET, HEAD, PUT and DELETE', async () => {
    const { gate } = await newGate()
    assert.equal((await call(gate, 'POST', path(MCKAY, randomUUID()))).status, 405)
  })

  test('a restart mid-upload leaves nothing once swept', async () => {
    const { store, root } = await newGate()
    await mkdir(join(root, 'accounts', MCKAY.id), { recursive: true })
    await writeFile(join(root, 'accounts', MCKAY.id, `.${randomUUID()}.part`), 'x')
    assert.equal(await store.sweep(), 1)
    assert.deepEqual(await readdir(join(root, 'accounts', MCKAY.id)), [])
  })
})

describe('over HTTP', () => {
  test('a stored file can never run as a page', async () => {
    const { gate } = await newGate()
    const server = serve(gate, 0, '127.0.0.1', ['https://app.usetotality.com'])
    await new Promise((resolve) => server.once('listening', resolve))
    const base = `http://127.0.0.1:${server.address().port}`
    try {
      const id = randomUUID()
      const photo = jpeg()
      const sent = await fetch(`${base}${path(MCKAY, id)}`, {
        method: 'PUT', headers: { authorization: 'Bearer token-mckay', 'content-type': 'image/jpeg' }, body: photo,
      })
      assert.equal(sent.status, 201)
      const got = await fetch(`${base}${path(MCKAY, id)}`, { headers: { authorization: 'Bearer token-dana' } })
      assert.equal(got.status, 200)
      assert.equal(got.headers.get('x-content-type-options'), 'nosniff')
      assert.match(got.headers.get('content-security-policy'), /sandbox/)
      assert.equal(got.headers.get('cross-origin-resource-policy'), 'same-site')
      assert.deepEqual(Buffer.from(await got.arrayBuffer()), photo)
      const unsigned = await fetch(`${base}${path(MCKAY, id)}`)
      assert.equal(unsigned.status, 401)
    } finally {
      server.close()
    }
  })

  test('only Totality websites get browser access', () => {
    assert.deepEqual(corsHeaders('https://evil.example', ['https://app.usetotality.com']), {})
    assert.equal(corsHeaders('https://app.usetotality.com', ['https://app.usetotality.com'])['Access-Control-Allow-Origin'], 'https://app.usetotality.com')
  })
})

test('the tunnel carries file paths only, never health', async () => {
  const tunnel = (await readFile(new URL('../cloudflared.yml', import.meta.url))).toString()
  const rules = [...tunnel.matchAll(/^ +path: (\^\/social\/media\/.*)$/gm)].map((match) => new RegExp(match[1]))
  assert.equal(rules.length, 1)
  const [rule] = rules
  assert.match(`/social/media/${randomUUID()}/${randomUUID()}`, rule)
  for (const bad of ['/social/media/health', `/social/media/${randomUUID()}`, `/social/media/${randomUUID()}/${randomUUID()}/x`,
    `/social/media/${randomUUID()}/../${randomUUID()}`, `/social/media/${randomUUID().toUpperCase()}/${randomUUID()}`]) {
    assert.doesNotMatch(bad, rule)
  }
})
