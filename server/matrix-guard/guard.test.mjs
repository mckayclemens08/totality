import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer, request } from 'node:http'
import { classify, guard, invitees, liveGate, localpart, MAX_BODY } from './guard.mjs'

const SERVER = 'usetotality.com'
const TOKENS = { 'token-leo': '@leo_m:usetotality.com', 'token-mia': '@mia_r:usetotality.com' }
// Mia takes messages from anyone who isn't Leo; Leo takes them from everyone.
const allows = (sender, to) => !(sender === 'leo_m' && to === 'mia_r')

let upstream, front, seen, gateCalls, gateDown
before(async () => {
  upstream = createServer((req, res) => {
    if (req.url.startsWith('/_matrix/client/v3/account/whoami')) {
      const token = (req.headers.authorization ?? '').replace('Bearer ', '') || new URL(req.url, 'http://x').searchParams.get('access_token')
      const user = TOKENS[token]
      res.writeHead(user ? 200 : 401, { 'Content-Type': 'application/json' })
      return res.end(JSON.stringify(user ? { user_id: user } : { errcode: 'M_UNKNOWN_TOKEN' }))
    }
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, body: Buffer.concat(chunks).toString(), headers: req.headers })
      res.writeHead(200, { 'Content-Type': 'application/json', 'X-Up': 'yes' })
      res.end('{"ok":true}')
    })
  }).listen(0)
  await new Promise((r) => upstream.once('listening', r))
  const gate = async (sender, recipients) => {
    gateCalls.push({ sender, recipients })
    if (gateDown) throw new Error('down')
    return Object.fromEntries(recipients.map((r) => [r, allows(sender, r)]))
  }
  front = createServer(guard({ upstream: `http://127.0.0.1:${upstream.address().port}`, serverName: SERVER, gate })).listen(0)
  await new Promise((r) => front.once('listening', r))
})
after(() => { upstream.close(); front.close() })

function send(method, path, { body, token = 'token-leo', headers = {} } = {}) {
  seen = []; gateCalls = []
  return new Promise((resolve, reject) => {
    const req = request({ port: front.address().port, method, path, headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers,
    } }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString() }))
    })
    req.on('error', reject)
    req.end(body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body))
  })
}
const json = (r) => JSON.parse(r.text)

describe('passes everything that invites no one', () => {
  test('sync, sending and media go straight through, untouched', async () => {
    let r = await send('GET', '/_matrix/client/v3/sync?timeout=0')
    assert.equal(r.status, 200)
    assert.equal(r.headers['x-up'], 'yes')
    assert.equal(seen[0].url, '/_matrix/client/v3/sync?timeout=0')
    r = await send('PUT', '/_matrix/client/v3/rooms/!a:usetotality.com/send/m.room.encrypted/t1', { body: '{"ciphertext":"x"}' })
    assert.equal(r.status, 200)
    assert.equal(seen[0].body, '{"ciphertext":"x"}')
    assert.equal(gateCalls.length, 0)
  })

  test('a new room with no one invited, and leaving, are not checked', async () => {
    let r = await send('POST', '/_matrix/client/v3/createRoom', { body: { preset: 'private_chat' } })
    assert.equal(r.status, 200)
    assert.equal(gateCalls.length, 0)
    r = await send('PUT', '/_matrix/client/v3/rooms/!a:usetotality.com/state/m.room.member/@leo_m:usetotality.com', { body: { membership: 'leave' } })
    assert.equal(r.status, 200)
    r = await send('GET', '/_matrix/client/v3/rooms/!a:usetotality.com/state/m.room.member/@mia_r:usetotality.com')
    assert.equal(r.status, 200)
  })
})

describe('checks every way to invite', () => {
  test('an allowed invite reaches the server as the JSON that was checked', async () => {
    const r = await send('POST', '/_matrix/client/v3/rooms/!a:usetotality.com/invite', { body: '{"user_id":"@ana_k:usetotality.com","reason":"hi"}' })
    assert.equal(r.status, 200)
    assert.deepEqual(gateCalls, [{ sender: 'leo_m', recipients: ['ana_k'] }])
    assert.deepEqual(JSON.parse(seen[0].body), { user_id: '@ana_k:usetotality.com', reason: 'hi' })
  })

  test('an invite the setting refuses never reaches the server', async () => {
    const r = await send('POST', '/_matrix/client/v3/rooms/!a:usetotality.com/invite', { body: { user_id: '@mia_r:usetotality.com' } })
    assert.equal(r.status, 403)
    assert.equal(json(r).errcode, 'M_FORBIDDEN')
    assert.equal(seen.length, 0)
  })

  test('createRoom with a refused person in it is refused whole', async () => {
    const r = await send('POST', '/_matrix/client/v3/createRoom', { body: { is_direct: true, invite: ['@ana_k:usetotality.com', '@mia_r:usetotality.com'] } })
    assert.equal(r.status, 403)
    assert.equal(seen.length, 0)
    const ok = await send('POST', '/_matrix/client/v3/createRoom', { token: 'token-mia', body: { invite: ['@leo_m:usetotality.com'] } })
    assert.equal(ok.status, 200)
    assert.deepEqual(gateCalls, [{ sender: 'mia_r', recipients: ['leo_m'] }])
  })

  test('a member event that invites is checked like an invite', async () => {
    const r = await send('PUT', '/_matrix/client/v3/rooms/!a:usetotality.com/state/m.room.member/@mia_r:usetotality.com', { body: { membership: 'invite' } })
    assert.equal(r.status, 403)
    assert.equal(seen.length, 0)
  })

  test('encoded, unstable and differently-cased paths are caught too', async () => {
    for (const path of [
      '/_matrix/client/r0/rooms/%21a%3Ausetotality.com/%69nvite',
      '/_matrix/client/unstable/rooms/!a:usetotality.com/invite',
      '/_matrix/client/v3/CreateRoom',
      '/_matrix/client/v3/rooms/!a:usetotality.com/state/m.room.member/%40mia_r%3Ausetotality.com',
    ]) {
      const body = path.includes('ateRoom') ? { invite: ['@mia_r:usetotality.com'] }
        : path.includes('member') ? { membership: 'invite' } : { user_id: '@mia_r:usetotality.com' }
      const r = await send(path.includes('member') ? 'PUT' : 'POST', path, { body })
      assert.equal(r.status, 403, path)
      assert.equal(seen.length, 0, path)
    }
    const r = await send('POST', '/_matrix/client/v3/rooms/!a:x/in%2Fvite', { body: {} })
    assert.equal(r.status, 400)
  })

  test('a duplicate key can not hide a refused person', async () => {
    const r = await send('POST', '/_matrix/client/v3/rooms/!a:usetotality.com/invite',
      { body: '{"user_id":"@ana_k:usetotality.com","user_id":"@mia_r:usetotality.com"}' })
    // JSON.parse keeps the last one, which is what's checked and what's sent on.
    assert.equal(r.status, 403)
    assert.equal(seen.length, 0)
  })

  test('email invites, initial member events, other servers and odd names are refused outright', async () => {
    const cases = [
      ['POST', '/_matrix/client/v3/rooms/!a:usetotality.com/invite', { id_server: 'x.org', medium: 'email', address: 'a@b.c' }],
      ['POST', '/_matrix/client/v3/createRoom', { invite_3pid: [{ medium: 'email' }] }],
      ['POST', '/_matrix/client/v3/createRoom', { initial_state: [{ type: 'm.room.member', state_key: '@mia_r:usetotality.com', content: { membership: 'invite' } }] }],
      ['POST', '/_matrix/client/v3/createRoom', { invite: ['@mia_r:evil.example'] }],
      ['POST', '/_matrix/client/v3/createRoom', { invite: ['@conduit:usetotality.com:usetotality.com'] }],
      ['POST', '/_matrix/client/v3/createRoom', { invite: '@mia_r:usetotality.com' }],
      ['PUT', '/_matrix/client/v3/rooms/!a:usetotality.com/state/m.room.member/@mia_r:usetotality.com', { membership: 'weird' }],
      ['POST', '/_matrix/client/v3/rooms/!a:usetotality.com/invite', ['@mia_r:usetotality.com']],
    ]
    for (const [method, path, body] of cases) {
      const r = await send(method, path, { body })
      assert.ok(r.status === 403 || r.status === 400, `${path} ${JSON.stringify(body)} -> ${r.status}`)
      assert.equal(seen.length, 0)
    }
  })

  test('compressed, oversized or unreadable bodies are refused', async () => {
    let r = await send('POST', '/_matrix/client/v3/createRoom', { body: '{}', headers: { 'content-encoding': 'gzip' } })
    assert.equal(r.status, 415)
    r = await send('POST', '/_matrix/client/v3/createRoom', { body: '{"invite":["' + 'a'.repeat(MAX_BODY) + '"]}' }).catch(() => ({ status: 413 }))
    assert.equal(r.status, 413)
    r = await send('POST', '/_matrix/client/v3/createRoom', { body: '{nope' })
    assert.equal(r.status, 400)
    r = await send('DELETE', '/_matrix/client/v3/rooms/!a:usetotality.com/invite')
    assert.equal(r.status, 405)
  })

  test('a signed-out invite gets the server\'s own answer, and the gate is never asked', async () => {
    const r = await send('POST', '/_matrix/client/v3/createRoom', { token: 'bad', body: { invite: ['@ana_k:usetotality.com'] } })
    assert.equal(r.status, 401)
    assert.equal(gateCalls.length, 0)
    assert.equal(seen.length, 0)
  })

  test('a token in the query string is the one checked', async () => {
    const r = await send('POST', '/_matrix/client/v3/createRoom?access_token=token-leo', { token: null, body: { invite: ['@mia_r:usetotality.com'] } })
    assert.equal(r.status, 403)
    assert.deepEqual(gateCalls, [{ sender: 'leo_m', recipients: ['mia_r'] }])
  })

  test('when the gate is down nothing is invited', async () => {
    gateDown = true
    try {
      const r = await send('POST', '/_matrix/client/v3/createRoom', { body: { invite: ['@ana_k:usetotality.com'] } })
      assert.equal(r.status, 503)
      assert.equal(seen.length, 0)
    } finally { gateDown = false }
  })
})

describe('pieces', () => {
  test('localpart takes only this server\'s usernames', () => {
    assert.equal(localpart('@mia_r:usetotality.com', SERVER), 'mia_r')
    assert.equal(localpart('@Mia:usetotality.com', SERVER), null)
    assert.equal(localpart('mia_r:usetotality.com', SERVER), null)
    assert.equal(localpart(7, SERVER), null)
  })

  test('classify ignores reads and paths outside the client API', () => {
    assert.equal(classify('GET', '/_matrix/client/v3/rooms/!a:x/invite').gated, false)
    assert.equal(classify('POST', '/_matrix/media/v3/upload').gated, false)
    assert.equal(classify('PUT', '/_matrix/client/v3/rooms/!a:x/state/m.room.member/').stateKey, '')
  })

  test('a member invite with no one named is refused', () => {
    assert.throws(() => invitees({ member: true, stateKey: '' }, { membership: 'invite' }, SERVER), /usernames/)
  })

  test('the live gate sends the secret and reads only a yes', async () => {
    let sent
    const fetcher = async (url, init) => { sent = { url, init }; return { ok: true, json: async () => ({ allowed: { mia_r: true, ana_k: 'yes' } }) } }
    const ask = liveGate({ url: 'https://x/functions/v1/message-gate', secret: 's'.repeat(40), fetcher })
    const allowed = await ask('leo_m', ['mia_r', 'ana_k'])
    assert.equal(sent.init.headers['X-Gate-Secret'], 's'.repeat(40))
    assert.equal(allowed.mia_r, true)
    assert.notEqual(allowed.ana_k, true)
    const refused = liveGate({ url: 'x', secret: 's', fetcher: async () => ({ ok: false }) })
    await assert.rejects(refused('leo_m', ['mia_r']))
  })
})
