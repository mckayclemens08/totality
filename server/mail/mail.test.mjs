import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import {
  createDecipheriv, createPrivateKey, generateKeyPairSync, randomUUID,
} from 'node:crypto'
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  AT_ONCE, Arrivals, MAILBOX_LIMIT, MAX_MESSAGE, Mailboxes, accountFrom, aead, keySchedule, mailName, readBody, seal,
  sealedForm, serve, verdict,
} from './mail.mjs'
import worker from '../mail-worker/worker.mjs'

const hex = (text) => Buffer.from(text, 'hex')
const SECRET = 'a-test-secret-for-this-file-only'
const BEARER = `Bearer ${SECRET}`
const ADDRESS = 'ada_lovelace@usetotality.com'
const LETTER = Buffer.from('From: charles@example.org\r\nSubject: The engine\r\n\r\nThe gears arrived on Tuesday.\r\n')

function x25519Private(raw, publicRaw) {
  return createPrivateKey({
    key: { kty: 'OKP', crv: 'X25519', d: raw.toString('base64url'), x: publicRaw.toString('base64url') },
    format: 'jwk',
  })
}

function newKeys() {
  const { publicKey, privateKey } = generateKeyPairSync('x25519')
  return { publicKey: Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url'), privateKey }
}

/** What the app does with CryptoKit, for the tests' sake. The server has no way to do this. */
function opened(sealed, keys, mailbox, message) {
  assert.equal(sealed[0], 1)
  const enc = sealed.subarray(1, 33)
  const info = Buffer.from('totality/mail/v1')
  const { key, nonce } = keySchedule(keys.privateKey, enc, enc, keys.publicKey, info)
  const body = sealed.subarray(33, -16)
  const decipher = createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  decipher.setAAD(Buffer.concat([info, hex(mailbox.replaceAll('-', '')), hex(message.replaceAll('-', ''))]))
  decipher.setAuthTag(sealed.subarray(-16))
  return Buffer.concat([decipher.update(body), decipher.final()])
}

describe('sealing', () => {
  test('matches the test vector in RFC 9180, appendix A.2.1', () => {
    const skEm = hex('f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600')
    const pkEm = hex('1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a')
    const pkRm = hex('4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a')
    const info = hex('4f6465206f6e2061204772656369616e2055726e')
    const { key, nonce } = keySchedule(x25519Private(skEm, pkEm), pkRm, pkEm, pkRm, info)
    assert.equal(key.toString('hex'), 'ad2744de8e17f4ebba575b3f5f5a8fa1f69c2a07f6e7500bc60ca6e3e3ec1c91')
    assert.equal(nonce.toString('hex'), '5c4d98150661b848853b547f')
    const ct = aead(key, nonce, hex('4265617574792069732074727574682c20747275746820626561757479'), hex('436f756e742d30'))
    assert.equal(ct.toString('hex'),
      '1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28')
  })

  test('only the recipient can open a sealed message', () => {
    const keys = newKeys()
    const [mailbox, message] = [randomUUID(), randomUUID()]
    const sealed = seal(LETTER, keys.publicKey, mailbox, message)
    assert.deepEqual(opened(sealed, keys, mailbox, message), LETTER)
    assert.throws(() => opened(sealed, newKeys(), mailbox, message))
  })

  test('a message cannot be moved to another mailbox or name', () => {
    const keys = newKeys()
    const [mailbox, message] = [randomUUID(), randomUUID()]
    const sealed = seal(LETTER, keys.publicKey, mailbox, message)
    assert.throws(() => opened(sealed, keys, randomUUID(), message))
    assert.throws(() => opened(sealed, keys, mailbox, randomUUID()))
  })

  test('nothing of the message shows in the sealed form', () => {
    const sealed = seal(LETTER, newKeys().publicKey, randomUUID(), randomUUID())
    for (const word of ['charles', 'Subject', 'gears']) assert.equal(sealed.includes(word), false)
  })

  test('the same message never seals to the same bytes', () => {
    const { publicKey } = newKeys()
    const [mailbox, message] = [randomUUID(), randomUUID()]
    assert.notDeepEqual(seal(LETTER, publicKey, mailbox, message), seal(LETTER, publicKey, mailbox, message))
  })

  test('the sealed form is one line of facts and then the message untouched', () => {
    const form = sealedForm(LETTER, { score: 1.5, flagged: false }, Date.UTC(2026, 10, 2, 19, 6))
    const line = form.indexOf(10)
    assert.deepEqual(JSON.parse(form.subarray(0, line)), {
      version: 1, received: '2026-11-02T19:06:00.000Z', spam: { score: 1.5, flagged: false },
    })
    assert.deepEqual(form.subarray(line + 1), LETTER)
  })
})

describe('addresses', () => {
  test('a username at the domain is a mail name', () => {
    assert.equal(mailName('ada_lovelace@usetotality.com'), 'ada_lovelace')
  })

  test('case and spaces are ignored', () => {
    assert.equal(mailName(' Ada_Lovelace@USETOTALITY.com '), 'ada_lovelace')
  })

  test('a plus tag reaches the same person', () => {
    assert.equal(mailName('ada_lovelace+receipts.2026@usetotality.com'), 'ada_lovelace')
  })

  for (const address of ['ab@usetotality.com', 'first.last@usetotality.com', 'ada@example.org', 'ada@usetotality.com.evil.example',
    'ada@sub.usetotality.com', 'a@b@usetotality.com', 'ada\n@usetotality.com', `${'a'.repeat(25)}@usetotality.com`, '', null, undefined, 7]) {
    test(`${JSON.stringify(address)} is not one of ours`, () => {
      assert.equal(mailName(address), null)
    })
  }
})

describe('spam verdicts', () => {
  for (const action of ['reject', 'rewrite subject', 'add header']) {
    test(`Rspamd's "${action}" is flagged`, () => {
      assert.deepEqual(verdict({ score: 16, action }), { score: 16, flagged: true })
    })
  }

  for (const action of ['no action', 'greylist', 'soft reject']) {
    test(`Rspamd's "${action}" is not flagged`, () => {
      assert.deepEqual(verdict({ score: 2, action }), { score: 2, flagged: false })
    })
  }

  test('its reasons are left behind', () => {
    assert.deepEqual(Object.keys(verdict({ score: 2, action: 'no action', symbols: { FROM_NAME: {} }, subject: 'Hello' })),
      ['score', 'flagged'])
  })

  test('an answer without a score is no verdict', () => {
    assert.equal(verdict({ error: 'boom' }), null)
  })
})

describe('arrivals', () => {
  let root, mailbox, keys, mailboxes, folder

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailboxes = new Mailboxes(root)
  })
  after(() => rm(root, { recursive: true, force: true }))

  let n = 0
  const fresh = async () => {
    n += 1
    mailbox = randomUUID()
    keys = newKeys()
    folder = join(root, 'boxes', mailbox)
    await mailboxes.publish(`ada_${n}`, mailbox, keys.publicKey)
    return `ada_${n}@usetotality.com`
  }

  function arrivals(overrides = {}) {
    return new Arrivals({
      secret: SECRET,
      checkSignIn: async () => null,
      checkSpam: async () => ({ score: 0.5, flagged: false }),
      mailboxes,
      ...overrides,
    })
  }

  const send = (gate, to, { method = 'POST', path = '/mail/arrive', authorization = BEARER, body = LETTER } = {}) =>
    gate.handle(method, path, authorization, to, async () => Buffer.from(body))

  const sealedFiles = async () => (await readdir(folder)).filter((name) => name.endsWith('.sealed'))

  test('a message is stored sealed, and the recipient can open it with its spam verdict', async () => {
    const to = await fresh()
    assert.equal(await send(arrivals(), to), 201)
    const [name] = await sealedFiles()
    assert.match(name, /^[0-9a-f-]{36}\.sealed$/)
    const sealed = await readFile(join(folder, name))
    assert.equal(sealed.includes('gears'), false)
    assert.equal(sealed.includes('charles'), false)
    const form = opened(sealed, keys, mailbox, name.replace('.sealed', ''))
    const line = form.indexOf(10)
    assert.deepEqual(JSON.parse(form.subarray(0, line)).spam, { score: 0.5, flagged: false })
    assert.deepEqual(form.subarray(line + 1), LETTER)
  })

  test('a plus tag lands in the same mailbox', async () => {
    const to = await fresh()
    assert.equal(await send(arrivals(), to.replace('@', '+receipts@')), 201)
    assert.equal((await sealedFiles()).length, 1)
  })

  test('only the server\'s mail user can read the files', async () => {
    const to = await fresh()
    await send(arrivals(), to)
    const [name] = await sealedFiles()
    assert.equal((await stat(join(folder, name))).mode & 0o777, 0o600)
    assert.equal((await stat(folder)).mode & 0o777, 0o700)
  })

  test('nothing but sealed files and the key is left behind', async () => {
    const to = await fresh()
    await send(arrivals(), to)
    const names = await readdir(folder)
    assert.equal(names.length, 2)
    assert.equal(names.includes('public.key'), true)
  })

  test('the memory holding the message is wiped afterwards', async () => {
    const to = await fresh()
    const body = Buffer.from(LETTER)
    assert.equal(await arrivals().handle('POST', '/mail/arrive', BEARER, to, async () => body), 201)
    assert.equal(body.every((byte) => byte === 0), true)
  })

  test('a wrong or missing secret gets nowhere, and the body is never read', async () => {
    const to = await fresh()
    let read = false
    const gate = arrivals()
    for (const authorization of [undefined, '', 'Bearer ', 'Bearer wrong', SECRET, `Basic ${SECRET}`]) {
      assert.equal(await gate.handle('POST', '/mail/arrive', authorization, to, async () => { read = true }), 401)
    }
    assert.equal(read, false)
    assert.deepEqual(await sealedFiles(), [])
  })

  test('an address nobody holds is a 410, and the body is never read', async () => {
    await fresh()
    let read = false
    const gate = arrivals()
    assert.equal(await gate.handle('POST', '/mail/arrive', BEARER, 'nobody_here@usetotality.com', async () => { read = true }), 410)
    assert.equal(await gate.handle('POST', '/mail/arrive', BEARER, 'ada@example.org', async () => { read = true }), 410)
    assert.equal(read, false)
  })

  test('only the known paths and methods exist', async () => {
    const to = await fresh()
    const gate = arrivals()
    assert.equal(await send(gate, to, { path: '/mail/other' }), 404)
    assert.equal(await send(gate, to, { path: '/mail/arrive?x=1' }), 404)
    assert.equal(await send(gate, to, { method: 'GET' }), 405)
    assert.equal(await send(gate, to, { method: 'GET', path: '/mail/key' }), 405)
    assert.equal(await send(gate, to, { method: 'GET', path: '/mail/health' }), 200)
  })

  test('a message past the limit is a 413', async () => {
    const to = await fresh()
    assert.equal(await arrivals().handle('POST', '/mail/arrive', BEARER, to, async () => null), 413)
    assert.deepEqual(await sealedFiles(), [])
  })

  const standIn = (changes) => ({ recipient: async () => ({ mailbox, publicKey: keys.publicKey }), ...changes })

  test('a full mailbox is a 507', async () => {
    const to = await fresh()
    const full = standIn({ size: async () => MAILBOX_LIMIT, add: async () => assert.fail('stored past the limit') })
    assert.equal(await send(arrivals({ mailboxes: full }), to), 507)
  })

  test('a message that would pass the limit is a 507', async () => {
    const to = await fresh()
    const nearly = standIn({ size: async () => MAILBOX_LIMIT - 10, add: async () => assert.fail('stored past the limit') })
    assert.equal(await send(arrivals({ mailboxes: nearly }), to), 507)
  })

  test('if the disk fails, the sender is told to try later', async () => {
    const to = await fresh()
    const broken = standIn({ size: async () => 0, add: async () => { throw new Error('disk') } })
    assert.equal(await send(arrivals({ mailboxes: broken }), to), 503)
  })

  test('if the spam check fails, the message is kept with no verdict', async () => {
    const to = await fresh()
    assert.equal(await send(arrivals({ checkSpam: async () => { throw new Error('down') } }), to), 201)
    const [name] = await sealedFiles()
    const form = opened(await readFile(join(folder, name)), keys, mailbox, name.replace('.sealed', ''))
    assert.equal(JSON.parse(form.subarray(0, form.indexOf(10))).spam, null)
  })

  test(`only ${AT_ONCE} messages are held at once, and the rest wait at the sender`, async () => {
    const to = await fresh()
    let release
    const waiting = new Promise((resolve) => { release = resolve })
    const gate = arrivals({ checkSpam: async () => { await waiting; return null } })
    const first = Array.from({ length: AT_ONCE }, () => send(gate, to))
    assert.equal(await send(gate, to), 503)
    release()
    assert.deepEqual(await Promise.all(first), Array(AT_ONCE).fill(201))
    assert.equal(await send(gate, to), 201)
  })

  test('the size of a mailbox counts sealed files only', async () => {
    await fresh()
    assert.equal(await mailboxes.size(mailbox), 0)
    await mailboxes.add(mailbox, randomUUID(), Buffer.alloc(40))
    assert.equal(await mailboxes.size(mailbox), 40)
  })

  test('a name or mailbox cannot walk out of the folder', async () => {
    await assert.rejects(mailboxes.size('../../etc/passwd'), /not a mailbox/)
    await assert.rejects(mailboxes.add('../outside', randomUUID(), Buffer.alloc(1)), /not a mailbox/)
    await assert.rejects(mailboxes.recipient('../../etc/passwd'), /not a name/)
  })
})

describe('publishing a key', () => {
  let root, mailboxes, gate
  const accounts = new Map()

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailboxes = new Mailboxes(root)
    gate = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => {
        if (token === 'supabase-down') throw new Error('down')
        return accounts.get(token) ?? null
      },
      checkSpam: async () => null,
      mailboxes,
    })
  })
  after(() => rm(root, { recursive: true, force: true }))

  let n = 0
  const account = () => {
    n += 1
    const token = `token_${n}`
    const signedIn = { name: `key_user_${n}`, mailbox: randomUUID() }
    accounts.set(token, signedIn)
    return { token, ...signedIn }
  }
  const publish = (token, body) => gate.handle('POST', '/mail/key', token && `Bearer ${token}`, undefined,
    async () => Buffer.from(body))
  const asJSON = (key) => JSON.stringify({ publicKey: key.toString('base64') })

  test('a signed-in account publishes its key and its address starts working', async () => {
    const person = account()
    const { publicKey } = newKeys()
    assert.equal(await mailboxes.recipient(person.name), null)
    assert.equal(await publish(person.token, asJSON(publicKey)), 201)
    assert.deepEqual(await mailboxes.recipient(person.name), { mailbox: person.mailbox, publicKey })
  })

  test('another device publishing the same key is fine', async () => {
    const person = account()
    const { publicKey } = newKeys()
    await publish(person.token, asJSON(publicKey))
    assert.equal(await publish(person.token, asJSON(publicKey)), 200)
  })

  test('a stolen session cannot replace a key', async () => {
    const person = account()
    const { publicKey } = newKeys()
    await publish(person.token, asJSON(publicKey))
    assert.equal(await publish(person.token, asJSON(newKeys().publicKey)), 409)
    assert.deepEqual((await mailboxes.recipient(person.name)).publicKey, publicKey)
  })

  test('a name another mailbox holds stays with it, so a reserved name cannot be taken', async () => {
    const person = account()
    const { publicKey } = newKeys()
    await mailboxes.publish(person.name, randomUUID(), publicKey)
    assert.equal(await publish(person.token, asJSON(newKeys().publicKey)), 409)
    assert.deepEqual((await mailboxes.recipient(person.name)).publicKey, publicKey)
  })

  test('user 2 cannot publish for user 1, because the account comes from the sign-in', async () => {
    const [user1, user2] = [account(), account()]
    const { publicKey } = newKeys()
    const smuggled = JSON.stringify({ publicKey: publicKey.toString('base64'), name: user1.name, mailbox: user1.mailbox })
    assert.equal(await publish(user2.token, smuggled), 201)
    assert.equal(await mailboxes.recipient(user1.name), null)
  })

  test('without a sign-in nothing is read', async () => {
    let read = false
    for (const authorization of [undefined, 'Bearer nonsense', `Basic ${SECRET}`, BEARER]) {
      assert.equal(await gate.handle('POST', '/mail/key', authorization, undefined, async () => { read = true }), 401)
    }
    assert.equal(read, false)
  })

  test('if the sign-in can\'t be checked, the device is told to try later', async () => {
    assert.equal(await publish('supabase-down', asJSON(newKeys().publicKey)), 503)
  })

  for (const body of ['', 'not json', '{}', '{"publicKey":7}', '{"publicKey":"c2hvcnQ="}', 'null',
    JSON.stringify({ publicKey: `${Buffer.alloc(32, 1).toString('base64')}\n` })]) {
    test(`${JSON.stringify(body)} is refused`, async () => {
      const person = account()
      assert.equal(await publish(person.token, body), 400)
      assert.equal(await mailboxes.recipient(person.name), null)
    })
  }

  test('a reserved name added by hand reaches its owner', async () => {
    const owner = account()
    const { publicKey } = newKeys()
    await publish(owner.token, asJSON(publicKey))
    await writeFile(join(root, 'names', 'abuse'), `${owner.mailbox}\n`)
    assert.deepEqual(await mailboxes.recipient('abuse'), { mailbox: owner.mailbox, publicKey })
  })

  test('an address pointing at a mailbox with no key does not exist', async () => {
    await writeFile(join(root, 'names', 'postmaster'), `${randomUUID()}\n`)
    assert.equal(await mailboxes.recipient('postmaster'), null)
  })
})

describe('reading a Supabase user', () => {
  const id = randomUUID()

  test('a username at the reserved domain is an account', () => {
    assert.deepEqual(accountFrom({ id, email: 'ada_lovelace@totality.invalid' }), { name: 'ada_lovelace', mailbox: id })
  })

  for (const user of [null, {}, { id }, { email: 'ada@totality.invalid' }, { id, email: 'ada@gmail.com' },
    { id: '../x', email: 'ada@totality.invalid' }, { id, email: 'a.b@totality.invalid' }]) {
    test(`${JSON.stringify(user)} is not`, () => {
      assert.equal(accountFrom(user), null)
    })
  }
})

describe('over a real connection', () => {
  let root, server, url, mailbox

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailbox = randomUUID()
    const mailboxes = new Mailboxes(root)
    await mailboxes.publish('ada_lovelace', mailbox, newKeys().publicKey)
    server = serve(new Arrivals({ secret: SECRET, checkSignIn: async () => null, checkSpam: async () => null, mailboxes }), 0)
    await new Promise((resolve) => { server.once('listening', resolve) })
    url = `http://127.0.0.1:${server.address().port}/mail/arrive`
  })
  after(async () => {
    server.closeAllConnections()
    server.close()
    await rm(root, { recursive: true, force: true })
  })

  const post = (body, headers = {}) => fetch(url, {
    method: 'POST', headers: { Authorization: BEARER, 'X-Mail-To': ADDRESS, ...headers }, body, duplex: 'half',
  })
  const sealedCount = async () => (await readdir(join(root, 'boxes', mailbox))).filter((name) => name.endsWith('.sealed')).length

  test('a whole message arrives and the reply says nothing', async () => {
    const reply = await post(LETTER)
    assert.equal(reply.status, 201)
    assert.equal(await reply.text(), '')
    assert.equal(await sealedCount(), 1)
  })

  test('a streamed message arrives, as Cloudflare sends it', async () => {
    const stream = new ReadableStream({ start(controller) { controller.enqueue(LETTER); controller.close() } })
    assert.equal((await post(stream)).status, 201)
  })

  test('a message past the limit is refused', async () => {
    const before = await sealedCount()
    assert.equal((await post(Buffer.alloc(MAX_MESSAGE + 1))).status, 413)
    assert.equal(await sealedCount(), before)
  })

  test('readBody hands back everything under the limit', async () => {
    const pieces = [Buffer.from('one'), Buffer.from('two')]
    assert.equal((await readBody(pieces, 10)).toString(), 'onetwo')
    assert.equal(await readBody(pieces, 5), null)
  })
})

describe('the Worker', () => {
  function message() {
    const rejected = []
    return { to: ADDRESS, raw: LETTER, rejected, setReject: (reason) => rejected.push(reason) }
  }

  async function deliver(status) {
    const realFetch = globalThis.fetch
    const calls = []
    globalThis.fetch = async (address, options) => {
      calls.push({ address, options })
      if (status instanceof Error) throw status
      return new Response(null, { status })
    }
    try {
      const mail = message()
      await worker.email(mail, { MAIL_ARRIVAL_URL: 'https://mail.test/mail/arrive', MAIL_ARRIVAL_SECRET: SECRET })
      return { mail, calls }
    } finally {
      globalThis.fetch = realFetch
    }
  }

  test('hands the message over with the secret and the address', async () => {
    const { mail, calls } = await deliver(201)
    assert.deepEqual(mail.rejected, [])
    assert.equal(calls[0].address, 'https://mail.test/mail/arrive')
    assert.equal(calls[0].options.headers.Authorization, BEARER)
    assert.equal(calls[0].options.headers['X-Mail-To'], ADDRESS)
    assert.equal(calls[0].options.body, LETTER)
  })

  for (const [status, reason] of [[410, /^5\.1\.1/], [413, /^5\.3\.4/], [507, /^5\.2\.2/]]) {
    test(`a ${status} bounces`, async () => {
      assert.match((await deliver(status)).mail.rejected[0], reason)
    })
  }

  // The trial on 2026-11-02 showed a throw makes Gmail try again, and a reject would bounce for good.
  // A 404 is on this list because a tunnel with the wrong path answers it, and that mail must not bounce.
  for (const status of [401, 403, 404, 500, 502, 503, 530]) {
    test(`a ${status} throws, so the sender tries again`, async () => {
      await assert.rejects(deliver(status), /away/)
    })
  }

  test('an unreachable server throws, so the sender tries again', async () => {
    await assert.rejects(deliver(new TypeError('fetch failed')), /fetch failed/)
  })

  test('no error says anything about the message', async () => {
    await assert.rejects(deliver(503), (error) => !error.message.includes(ADDRESS))
  })
})

describe('the server setup', () => {
  // Docker's limit of 0 doesn't stop a crash report on this host, and a report could hold readable mail.
  test('crashes leave nothing behind', async () => {
    const compose = (await readFile(new URL('../compose.yml', import.meta.url))).toString()
    assert.equal(compose.match(/^ +core: 1$/gm).length, 2)
    assert.doesNotMatch(compose, /^ +core: 0$/m)
  })

  test('only the mail service gets the arrival secret', async () => {
    const compose = (await readFile(new URL('../compose.yml', import.meta.url))).toString()
    assert.equal(compose.match(/MAIL_ARRIVAL_SECRET/g).length, 2)
    assert.doesNotMatch(compose, /env_file/)
  })
})
