import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { mkdtemp, readdir, readFile, rm, stat, utimes } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import {
  AT_ONCE, BlobGate, Blobs, DISK_FLOOR, LARGE_LIMIT, LIMIT, MAX_FILES, MAX_PIECE, UNFINISHED_DAYS, accountFrom, rangeOf,
  rememberingSignIns, serve,
} from './blobs.mjs'

const GiB = 1024 ** 3
const sha = (data) => createHash('sha256').update(data).digest('hex')
const MCKAY = { name: 'mckayclemens', id: randomUUID() }
const DANA = { name: 'dana_whitfield', id: randomUUID() }
const tokens = new Map([['token-mckay', MCKAY], ['token-dana', DANA]])

async function newGate({ limit = LIMIT, free = 40 * GiB, checkSignIn } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'totality-blobs-'))
  const blobs = new Blobs(root)
  const gate = new BlobGate({
    checkSignIn: checkSignIn ?? (async (token) => tokens.get(token) ?? null),
    blobs,
    limitFor: () => limit,
    diskFree: async () => free,
  })
  return { root, blobs, gate }
}

const as = (token) => ({ authorization: `Bearer ${token}` })
const call = (gate, method, path, { token = 'token-mckay', headers = {}, body } = {}) =>
  gate.respond({
    method, path, headers: { ...(token && as(token)), ...headers },
    body: Readable.from(body === undefined ? [] : [Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body))]),
  })
const piece = (gate, id, offset, data, token) =>
  call(gate, 'PATCH', `/blobs/${id}`, { token, headers: { 'upload-offset': String(offset), 'content-length': String(data.length) }, body: data })
const finish = (gate, id, data, token) => call(gate, 'POST', `/blobs/${id}`, { token, body: { size: data.length, sha256: sha(data) } })
async function readAll(body) {
  if (Buffer.isBuffer(body)) return body
  const chunks = []
  for await (const chunk of body) chunks.push(chunk)
  return Buffer.concat(chunks)
}
async function upload(gate, data, token = 'token-mckay', id = randomUUID()) {
  assert.equal((await piece(gate, id, 0, data, token)).status, 204)
  assert.equal((await finish(gate, id, data, token)).status, 201)
  return id
}

describe('ranges', () => {
  test('reads the three forms and refuses the rest', () => {
    assert.equal(rangeOf(undefined, 100), null)
    assert.deepEqual(rangeOf('bytes=0-9', 100), { start: 0, end: 9 })
    assert.deepEqual(rangeOf('bytes=90-', 100), { start: 90, end: 99 })
    assert.deepEqual(rangeOf('bytes=-10', 100), { start: 90, end: 99 })
    assert.deepEqual(rangeOf('bytes=95-500', 100), { start: 95, end: 99 })
    assert.deepEqual(rangeOf('bytes=-500', 100), { start: 0, end: 99 })
    for (const bad of ['bytes=100-', 'bytes=9-0', 'bytes=-0', 'bytes=-', 'bytes=0-1,4-5', 'items=0-1', 'bytes= 0-1']) {
      assert.equal(rangeOf(bad, 100), false, bad)
    }
  })
})

describe('accounts', () => {
  test('come only from a Totality sign-in', () => {
    const id = randomUUID()
    assert.deepEqual(accountFrom({ id, email: 'mckayclemens@totality.invalid' }), { name: 'mckayclemens', id })
    assert.equal(accountFrom({ id, email: 'mckay@gmail.com' }), null)
    assert.equal(accountFrom({ id: '../x', email: 'mckayclemens@totality.invalid' }), null)
    assert.equal(accountFrom(null), null)
  })

  test('a good sign-in is remembered for a minute, a bad one never', async () => {
    let now = 0
    let asked = 0
    const check = rememberingSignIns(async (token) => { asked += 1; return token === 'good' ? MCKAY : null }, { clock: () => now })
    assert.equal(await check('good'), MCKAY)
    assert.equal(await check('good'), MCKAY)
    assert.equal(asked, 1)
    assert.equal(await check('bad'), null)
    assert.equal(await check('bad'), null)
    assert.equal(asked, 3)
    now += 61_000
    assert.equal(await check('good'), MCKAY)
    assert.equal(asked, 4)
  })

  test('the limits are the ones agreed in issue 54', () => {
    assert.equal(LARGE_LIMIT, 20 * GiB)
    assert.equal(LIMIT, 2 * GiB)
    assert.ok(MAX_PIECE < 100 * 1000 * 1000, 'a piece has to fit through Cloudflare')
  })
})

describe('the store', () => {
  let root, blobs, gate
  before(async () => ({ root, blobs, gate } = await newGate()))
  after(() => rm(root, { recursive: true, force: true }))

  test('takes a blob in pieces, finishes it, and gives it back whole or in part', async () => {
    const data = randomBytes(300_000)
    const id = randomUUID()
    assert.equal((await piece(gate, id, 0, data.subarray(0, 100_000))).status, 204)
    const halfway = await call(gate, 'HEAD', `/blobs/${id}`)
    assert.deepEqual([halfway.status, halfway.headers['Upload-Offset'], halfway.headers['Blob-State']], [200, '100000', 'uploading'])
    // Not finished, so not readable.
    assert.equal((await call(gate, 'GET', `/blobs/${id}`)).status, 404)
    const second = await piece(gate, id, 100_000, data.subarray(100_000))
    assert.deepEqual([second.status, second.headers['Upload-Offset']], [204, '300000'])
    assert.equal((await finish(gate, id, data)).status, 201)

    const done = await call(gate, 'HEAD', `/blobs/${id}`)
    assert.deepEqual([done.headers['Blob-Size'], done.headers['Blob-State']], ['300000', 'done'])
    const whole = await call(gate, 'GET', `/blobs/${id}`)
    assert.equal(whole.status, 200)
    assert.ok((await readAll(whole.body)).equals(data))
    const part = await call(gate, 'GET', `/blobs/${id}`, { headers: { range: 'bytes=1000-1999' } })
    assert.deepEqual([part.status, part.headers['Content-Range'], part.headers['Content-Length']], [206, 'bytes 1000-1999/300000', '1000'])
    assert.ok((await readAll(part.body)).equals(data.subarray(1000, 2000)))
    const outside = await call(gate, 'GET', `/blobs/${id}`, { headers: { range: 'bytes=400000-' } })
    assert.deepEqual([outside.status, outside.headers['Content-Range']], [416, 'bytes */300000'])
  })

  test('a piece at the wrong place is refused with where the upload really is', async () => {
    const id = randomUUID()
    const data = randomBytes(1_000)
    assert.equal((await piece(gate, id, 0, data)).status, 204)
    const wrong = await piece(gate, id, 500, data)
    assert.deepEqual([wrong.status, wrong.headers['Upload-Offset']], [409, '1000'])
    const ahead = await piece(gate, randomUUID(), 10, data)
    assert.deepEqual([ahead.status, ahead.headers['Upload-Offset']], [409, '0'])
    assert.equal((await piece(gate, id, 0, data)).status, 409)
  })

  test('a blob is only finished when its size and hash match, and then it never changes', async () => {
    const id = randomUUID()
    const data = randomBytes(2_000)
    await piece(gate, id, 0, data)
    assert.equal((await call(gate, 'POST', `/blobs/${id}`, { body: { size: 1_999, sha256: sha(data) } })).status, 400)
    assert.equal((await call(gate, 'POST', `/blobs/${id}`, { body: { size: 2_000, sha256: sha(randomBytes(4)) } })).status, 400)
    assert.equal((await call(gate, 'POST', `/blobs/${id}`, { body: { size: 2_000, sha256: 'ABC' } })).status, 400)
    assert.equal((await call(gate, 'POST', `/blobs/${id}`, { body: Buffer.from('not json') })).status, 400)
    assert.equal((await finish(gate, id, data)).status, 201)
    assert.equal((await finish(gate, id, data)).status, 409)
    const more = await piece(gate, id, 2_000, randomBytes(10))
    assert.deepEqual([more.status, more.headers['Blob-State']], [409, 'done'])
    assert.equal((await piece(gate, id, 0, randomBytes(10))).status, 409)
    assert.ok((await readAll((await call(gate, 'GET', `/blobs/${id}`)).body)).equals(data))
    assert.equal((await finish(gate, randomUUID(), data)).status, 404)
  })

  test('deleting frees the space, and deleting twice is harmless', async () => {
    const before = JSON.parse((await call(gate, 'GET', '/blobs/usage')).body).used
    const id = await upload(gate, randomBytes(5_000))
    assert.equal(JSON.parse((await call(gate, 'GET', '/blobs/usage')).body).used, before + 5_000)
    assert.equal((await call(gate, 'DELETE', `/blobs/${id}`)).status, 204)
    assert.equal((await call(gate, 'DELETE', `/blobs/${id}`)).status, 204)
    assert.equal((await call(gate, 'GET', `/blobs/${id}`)).status, 404)
    assert.equal(JSON.parse((await call(gate, 'GET', '/blobs/usage')).body).used, before)
  })

  test('the list holds finished blobs only, with sizes and nothing else', async () => {
    const { gate } = await newGate()
    const kept = await upload(gate, randomBytes(10))
    await piece(gate, randomUUID(), 0, randomBytes(10))
    const listed = JSON.parse((await call(gate, 'GET', '/blobs/list')).body)
    assert.deepEqual(listed.blobs.map(({ id, size }) => ({ id, size })), [{ id: kept, size: 10 }])
    assert.deepEqual(Object.keys(listed.blobs[0]).sort(), ['id', 'size', 'stored'])
    assert.deepEqual([listed.used, listed.limit], [20, LIMIT])
  })

  test('only names it knows reach the disk, and each only with the right method', async () => {
    const id = randomUUID()
    for (const path of ['/blobs/', '/blobs/x', `/blobs/${id.toUpperCase()}`, `/blobs/${id}/x`, '/blobs/..%2Fetc', `/blobs/../${id}`, '/other']) {
      assert.equal((await call(gate, 'GET', path)).status, 404, path)
    }
    assert.equal((await call(gate, 'PUT', `/blobs/${id}`)).status, 405)
    assert.equal((await call(gate, 'POST', '/blobs/list')).status, 405)
    assert.equal((await call(gate, 'DELETE', '/blobs/usage')).status, 405)
    assert.equal((await call(gate, 'PATCH', `/blobs/${id}`, { headers: { 'upload-offset': '-1' } })).status, 400)
    assert.equal((await call(gate, 'PATCH', `/blobs/${id}`)).status, 400)
    assert.equal((await call(gate, 'GET', '/blobs/health', { token: null })).status, 200)
  })

  test('nothing works without a real sign-in, and a sign-in check that fails is a 503', async () => {
    const id = await upload(gate, randomBytes(10))
    for (const headers of [{}, { authorization: 'token-mckay' }, { authorization: 'Bearer ' }, { authorization: 'Bearer forged' }, { authorization: 'Bearer token mckay' }]) {
      for (const [method, path] of [['GET', `/blobs/${id}`], ['HEAD', `/blobs/${id}`], ['DELETE', `/blobs/${id}`], ['GET', '/blobs/list'], ['GET', '/blobs/usage']]) {
        assert.equal((await gate.respond({ method, path, headers, body: Readable.from([]) })).status, 401)
      }
    }
    const { gate: broken } = await newGate({ checkSignIn: async () => { throw new Error('down') } })
    assert.equal((await call(broken, 'GET', '/blobs/list')).status, 503)
    assert.equal((await call(gate, 'HEAD', `/blobs/${id}`)).status, 200)
  })
})

describe('limits', () => {
  test('an account past its limit gets 507, and nothing of the piece is kept', async () => {
    const { gate, blobs, root } = await newGate({ limit: 10_000 })
    await upload(gate, randomBytes(8_000))
    const id = randomUUID()
    const full = await piece(gate, id, 0, randomBytes(3_000))
    assert.equal(full.status, 507)
    assert.equal((await call(gate, 'HEAD', `/blobs/${id}`)).status, 404)
    // A piece that says nothing of its length is stopped as it passes the limit, and taken back out.
    const sneaky = await call(gate, 'PATCH', `/blobs/${id}`, { headers: { 'upload-offset': '0' }, body: randomBytes(3_000) })
    assert.equal(sneaky.status, 507)
    assert.equal(await blobs.used(MCKAY.id), 8_000)
    assert.equal((await piece(gate, id, 0, randomBytes(2_000))).status, 204)
    assert.equal(await blobs.used(MCKAY.id), 10_000)
    await rm(root, { recursive: true, force: true })
  })

  test('uploads stop while the disk is near its floor, whatever the account has left', async () => {
    const { gate, root } = await newGate({ free: DISK_FLOOR + 1_000 })
    assert.equal((await piece(gate, randomUUID(), 0, randomBytes(500))).status, 204)
    assert.equal((await piece(gate, randomUUID(), 0, randomBytes(2_000))).status, 507)
    await rm(root, { recursive: true, force: true })
  })

  test('a piece bigger than Cloudflare can carry is refused before it is read', async () => {
    const { gate, root } = await newGate()
    let read = false
    const body = Readable.from((async function* () { read = true; yield Buffer.alloc(1) })())
    const answer = await gate.respond({
      method: 'PATCH', path: `/blobs/${randomUUID()}`,
      headers: { ...as('token-mckay'), 'upload-offset': '0', 'content-length': String(MAX_PIECE + 1) }, body,
    })
    assert.equal(answer.status, 413)
    assert.equal(read, false)
    await rm(root, { recursive: true, force: true })
  })

  test('an empty piece is refused, and an account can only hold so many files', async () => {
    const { gate, blobs, root } = await newGate()
    const id = randomUUID()
    assert.equal((await piece(gate, id, 0, Buffer.alloc(0))).status, 400)
    assert.equal((await call(gate, 'HEAD', `/blobs/${id}`)).status, 404)
    const kept = await upload(gate, randomBytes(10))
    assert.equal(await blobs.files(MCKAY.id), 1)
    blobs.counts.set(MCKAY.id, MAX_FILES)
    assert.equal((await piece(gate, randomUUID(), 0, randomBytes(10))).status, 507)
    // Room comes back when something goes.
    await call(gate, 'DELETE', `/blobs/${kept}`)
    assert.equal((await piece(gate, randomUUID(), 0, randomBytes(10))).status, 204)
    await rm(root, { recursive: true, force: true })
  })

  test('only so many uploads are written at once', async () => {
    const { gate, root } = await newGate()
    gate.working = AT_ONCE
    assert.equal((await piece(gate, randomUUID(), 0, randomBytes(10))).status, 503)
    gate.working = 0
    await rm(root, { recursive: true, force: true })
  })

  test('two pieces racing for the last of the space can\'t both have it', async () => {
    const { gate, blobs, root } = await newGate({ limit: 1_500 })
    const results = await Promise.all([piece(gate, randomUUID(), 0, randomBytes(1_000)), piece(gate, randomUUID(), 0, randomBytes(1_000))])
    assert.deepEqual(results.map(({ status }) => status).sort(), [204, 507])
    assert.equal(await blobs.used(MCKAY.id), 1_000)
    await rm(root, { recursive: true, force: true })
  })

  test('uploads nobody finished are cleared after a week, and stop counting', async () => {
    const { gate, blobs, root } = await newGate()
    const stale = randomUUID()
    const fresh = randomUUID()
    await piece(gate, stale, 0, randomBytes(100))
    await piece(gate, fresh, 0, randomBytes(100))
    const finished = await upload(gate, randomBytes(100))
    const old = new Date(Date.now() - (UNFINISHED_DAYS + 1) * 24 * 60 * 60 * 1000)
    await utimes(blobs.file(MCKAY.id, stale, 'part'), old, old)
    await utimes(blobs.file(MCKAY.id, finished, 'sealed'), old, old)
    assert.equal(await blobs.sweep(), 1)
    assert.equal((await call(gate, 'HEAD', `/blobs/${stale}`)).status, 404)
    assert.equal((await call(gate, 'HEAD', `/blobs/${fresh}`)).status, 200)
    assert.equal((await call(gate, 'HEAD', `/blobs/${finished}`)).status, 200)
    assert.equal(await blobs.used(MCKAY.id), 200)
    await rm(root, { recursive: true, force: true })
  })
})

// The brief §6 two-user test for the store, through real HTTP, the way anyone with a sign-in could ask
// it directly, without the app.
describe('Blob store two-user test (issue 54)', () => {
  let root, blobs, server, base
  before(async () => {
    ;({ root, blobs } = await newGate())
    const gate = new BlobGate({
      checkSignIn: async (token) => tokens.get(token) ?? null,
      blobs,
      limitFor: (account) => (account.name === 'mckayclemens' ? LARGE_LIMIT : LIMIT),
      diskFree: async () => 40 * GiB,
    })
    server = serve(gate, 0, '127.0.0.1')
    await new Promise((resolve) => server.once('listening', resolve))
    base = `http://127.0.0.1:${server.address().port}`
  })
  after(async () => {
    await new Promise((resolve) => server.close(resolve))
    await rm(root, { recursive: true, force: true })
  })

  const ask = (token, method, path, { headers = {}, body } = {}) =>
    fetch(`${base}${path}`, { method, headers: { ...(token && as(token)), ...headers }, body })
  const put = async (token, data, id = randomUUID()) => {
    const sent = await ask(token, 'PATCH', `/blobs/${id}`, { headers: { 'Upload-Offset': '0' }, body: data })
    assert.equal(sent.status, 204)
    const done = await ask(token, 'POST', `/blobs/${id}`, { body: JSON.stringify({ size: data.length, sha256: sha(data) }) })
    assert.equal(done.status, 201)
    return id
  }

  test('user 2 can\'t list, read, change, finish, or delete user 1\'s blobs, and nobody signed out can do anything', async () => {
    // What a device sealed. The store can't tell, and never needs to.
    const photo = randomBytes(64_000)
    const id = await put('token-mckay', photo)
    const unfinished = randomUUID()
    await ask('token-mckay', 'PATCH', `/blobs/${unfinished}`, { headers: { 'Upload-Offset': '0' }, body: randomBytes(100) })

    // User 1 has it.
    const mine = await ask('token-mckay', 'GET', `/blobs/${id}`)
    assert.equal(mine.status, 200)
    assert.ok(Buffer.from(await mine.arrayBuffer()).equals(photo))

    // User 2 asks for it every way there is, and finds nothing.
    assert.equal((await ask('token-dana', 'GET', `/blobs/${id}`)).status, 404)
    assert.equal((await ask('token-dana', 'GET', `/blobs/${id}`, { headers: { Range: 'bytes=0-10' } })).status, 404)
    assert.equal((await ask('token-dana', 'HEAD', `/blobs/${id}`)).status, 404)
    assert.equal((await ask('token-dana', 'HEAD', `/blobs/${unfinished}`)).status, 404)
    const theirs = await (await ask('token-dana', 'GET', '/blobs/list')).json()
    assert.deepEqual(theirs.blobs, [])
    assert.equal(theirs.used, 0)
    assert.equal(theirs.limit, LIMIT)
    assert.equal((await (await ask('token-mckay', 'GET', '/blobs/usage')).json()).limit, LARGE_LIMIT)

    // Deleting, adding to, or finishing under the same ID only ever touches user 2's own folder.
    assert.equal((await ask('token-dana', 'DELETE', `/blobs/${id}`)).status, 204)
    assert.equal((await ask('token-dana', 'DELETE', `/blobs/${unfinished}`)).status, 204)
    assert.equal((await ask('token-dana', 'POST', `/blobs/${unfinished}`, { body: JSON.stringify({ size: 100, sha256: sha(Buffer.alloc(100)) }) })).status, 404)
    const planted = randomBytes(64_000)
    await put('token-dana', planted, id)
    const still = await ask('token-mckay', 'GET', `/blobs/${id}`)
    assert.ok(Buffer.from(await still.arrayBuffer()).equals(photo))
    assert.equal((await ask('token-mckay', 'HEAD', `/blobs/${unfinished}`)).headers.get('upload-offset'), '100')

    // Signed out, or with a made-up sign-in, nothing at all.
    for (const token of [null, 'forged']) {
      for (const [method, path] of [['GET', `/blobs/${id}`], ['HEAD', `/blobs/${id}`], ['DELETE', `/blobs/${id}`], ['POST', `/blobs/${id}`], ['GET', '/blobs/list'], ['GET', '/blobs/usage']]) {
        assert.equal((await ask(token, method, path)).status, 401, `${token} ${method} ${path}`)
      }
      assert.equal((await ask(token, 'PATCH', `/blobs/${randomUUID()}`, { headers: { 'Upload-Offset': '0' }, body: 'x' })).status, 401)
    }

    // Paths that try to leave the account's folder never reach it.
    for (const path of [`/blobs/..%2F${MCKAY.id}%2F${id}`, `/blobs/%2e%2e/accounts/${MCKAY.id}/${id}.sealed`, `/accounts/${MCKAY.id}/${id}.sealed`]) {
      assert.equal((await ask('token-dana', 'GET', path)).status, 404, path)
    }

    // On disk, each account is its own folder, readable by the store alone.
    const folders = (await readdir(join(root, 'accounts'))).sort()
    assert.deepEqual(folders, [MCKAY.id, DANA.id].sort())
    for (const folder of folders) assert.equal((await stat(join(root, 'accounts', folder))).mode & 0o777, 0o700)
    assert.equal((await stat(blobs.file(MCKAY.id, id, 'sealed'))).mode & 0o777, 0o600)
    assert.ok((await readFile(blobs.file(DANA.id, id, 'sealed'))).equals(planted))
  })

  test('answers are never cached, and blobs are never sniffed as anything but bytes', async () => {
    const id = await put('token-mckay', randomBytes(100))
    const answer = await ask('token-mckay', 'GET', `/blobs/${id}`)
    assert.equal(answer.headers.get('cache-control'), 'no-store')
    assert.equal(answer.headers.get('content-type'), 'application/octet-stream')
    assert.equal(answer.headers.get('x-content-type-options'), 'nosniff')
    await answer.arrayBuffer()
  })
})
