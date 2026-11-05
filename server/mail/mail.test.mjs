import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import {
  createDecipheriv, createPrivateKey, generateKeyPairSync, randomUUID,
} from 'node:crypto'
import { mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  AT_ONCE, Arrivals, MAILBOX_LIMIT, MAX_DELETE, MAX_MESSAGE, MAX_SEALED_REQUEST, Mailboxes, NEW_ACCOUNT_DAYS, OUTSIDE_PER_DAY,
  OUTSIDE_PER_MONTH, SendLedger, accountFrom, aead, keySchedule, mailName, outsideMessage, readBody, seal, sealedForm, serve, verdict,
} from './mail.mjs'
import worker from '../mail-worker/worker.mjs'
import sender from '../send-worker/worker.mjs'

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
    assert.deepEqual(accountFrom({ id, email: 'ada_lovelace@totality.invalid' }), { name: 'ada_lovelace', mailbox: id, created: null })
    assert.deepEqual(accountFrom({ id, email: 'ada_lovelace@totality.invalid', created_at: '2026-10-01T12:00:00.5Z' }),
      { name: 'ada_lovelace', mailbox: id, created: Date.UTC(2026, 9, 1, 12, 0, 0, 500) })
  })

  for (const user of [null, {}, { id }, { email: 'ada@totality.invalid' }, { id, email: 'ada@gmail.com' },
    { id: '../x', email: 'ada@totality.invalid' }, { id, email: 'a.b@totality.invalid' }]) {
    test(`${JSON.stringify(user)} is not`, () => {
      assert.equal(accountFrom(user), null)
    })
  }
})

describe('reading mail', () => {
  let root, mailboxes, gate
  const accounts = new Map()
  let supabaseDown = false

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailboxes = new Mailboxes(root)
    gate = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => {
        if (supabaseDown) throw new Error('down')
        return accounts.get(token) ?? null
      },
      checkSpam: async () => null,
      mailboxes,
    })
  })
  after(() => rm(root, { recursive: true, force: true }))

  let n = 0
  const person = async () => {
    n += 1
    const token = `reader_${n}`
    const keys = newKeys()
    const signedIn = { name: `reader_${n}`, mailbox: randomUUID() }
    accounts.set(token, signedIn)
    await mailboxes.publish(signedIn.name, signedIn.mailbox, keys.publicKey)
    return { token, keys, ...signedIn, folder: join(root, 'boxes', signedIn.mailbox) }
  }
  // Two arrivals can share a timestamp, so the new one is whichever wasn't there before.
  const deliver = async (to, body = LETTER) => {
    const before = new Set((await mailboxes.list(to.mailbox)).map(({ id }) => id))
    assert.equal(await gate.handle('POST', '/mail/arrive', BEARER, `${to.name}@usetotality.com`, async () => Buffer.from(body)), 201)
    return (await mailboxes.list(to.mailbox)).find(({ id }) => !before.has(id)).id
  }
  const ask = (token, method, path, body) =>
    gate.respond(method, path, token && `Bearer ${token}`, undefined, async () => body === undefined ? null : Buffer.from(body))
  const listed = async (token) => {
    const reply = await ask(token, 'GET', '/mail/list')
    assert.equal(reply.status, 200)
    assert.equal(reply.type, 'application/json')
    return JSON.parse(reply.body)
  }
  const remove = (token, ids) => ask(token, 'POST', '/mail/delete', JSON.stringify({ ids }))

  test('a mailbox lists its messages newest first, with sizes and arrival times', async () => {
    const ada = await person()
    const older = await deliver(ada)
    const newer = await deliver(ada, 'Subject: Later\r\n\r\nA second note.\r\n')
    await utimes(join(ada.folder, `${older}.sealed`), new Date('2026-11-01T08:00:00Z'), new Date('2026-11-01T08:00:00Z'))
    await utimes(join(ada.folder, `${newer}.sealed`), new Date('2026-11-03T09:30:00Z'), new Date('2026-11-03T09:30:00Z'))
    const { messages, used, limit } = await listed(ada.token)
    assert.deepEqual(messages.map(({ id }) => id), [newer, older])
    assert.equal(messages[0].received, '2026-11-03T09:30:00.000Z')
    assert.equal(messages[0].size, (await stat(join(ada.folder, `${newer}.sealed`))).size)
    assert.equal(used, messages[0].size + messages[1].size)
    assert.equal(limit, MAILBOX_LIMIT)
    assert.deepEqual(Object.keys(messages[0]), ['id', 'size', 'received'])
  })

  test('an account with no mailbox yet has an empty list', async () => {
    const token = 'no_folder_yet'
    accounts.set(token, { name: 'no_folder_yet', mailbox: randomUUID() })
    assert.deepEqual(await listed(token), { messages: [], used: 0, limit: MAILBOX_LIMIT })
  })

  test('the list leaves out the key, half-written files, and anything else', async () => {
    const ada = await person()
    const id = await deliver(ada)
    await writeFile(join(ada.folder, `${randomUUID()}.sealed.${randomUUID()}.tmp`), 'half')
    await writeFile(join(ada.folder, `${randomUUID().toUpperCase()}.sealed`), 'odd')
    await writeFile(join(ada.folder, 'notes.sealed'), 'odd')
    await mkdir(join(ada.folder, `${randomUUID()}.sealed`))
    assert.deepEqual((await listed(ada.token)).messages.map((message) => message.id), [id])
  })

  test('nothing in the list says what a message holds', async () => {
    const ada = await person()
    await deliver(ada)
    const { body } = await ask(ada.token, 'GET', '/mail/list')
    for (const word of ['charles', 'Subject', 'gears', ada.name]) assert.equal(body.includes(word), false)
  })

  test('a fetch returns exactly the sealed bytes, and they still open', async () => {
    const ada = await person()
    const id = await deliver(ada)
    const reply = await ask(ada.token, 'GET', `/mail/message/${id}`)
    assert.equal(reply.status, 200)
    assert.equal(reply.type, 'application/octet-stream')
    assert.deepEqual(reply.body, await readFile(join(ada.folder, `${id}.sealed`)))
    const form = opened(reply.body, ada.keys, ada.mailbox, id)
    assert.deepEqual(form.subarray(form.indexOf(10) + 1), LETTER)
  })

  test('a message that isn\'t there is a 404', async () => {
    const ada = await person()
    assert.equal((await ask(ada.token, 'GET', `/mail/message/${randomUUID()}`)).status, 404)
  })

  test('user 2 cannot list user 1\'s mail', async () => {
    const [user1, user2] = [await person(), await person()]
    await deliver(user1)
    assert.deepEqual((await listed(user2.token)).messages, [])
  })

  test('user 2 cannot fetch user 1\'s message, even knowing its ID', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = await deliver(user1)
    const reply = await ask(user2.token, 'GET', `/mail/message/${id}`)
    assert.equal(reply.status, 404)
    assert.equal(reply.body, undefined)
  })

  test('user 2 cannot delete user 1\'s message, even knowing its ID', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = await deliver(user1)
    const reply = await remove(user2.token, [id])
    assert.equal(reply.status, 200)
    assert.deepEqual(JSON.parse(reply.body), { deleted: 0 })
    assert.deepEqual((await listed(user1.token)).messages.map((message) => message.id), [id])
  })

  test('a mailbox named in the request is ignored', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = await deliver(user1)
    const smuggled = JSON.stringify({ ids: [id], mailbox: user1.mailbox, name: user1.name })
    assert.deepEqual(JSON.parse((await ask(user2.token, 'POST', '/mail/delete', smuggled)).body), { deleted: 0 })
    assert.equal((await listed(user1.token)).messages.length, 1)
  })

  for (const path of ['/mail/message/../public.key', '/mail/message/..%2Fpublic.key', '/mail/message/public.key',
    '/mail/message/%2e%2e%2f%2e%2e%2fnames%2fada', '/mail/message/', '/mail/message',
    `/mail/message/${'0'.repeat(8)}-0000-0000-0000-${'0'.repeat(13)}`, `/mail/message/${randomUUID()}0`,
    `/mail/message/${randomUUID().toUpperCase()}`, `/mail/message/${randomUUID()}.sealed`,
    `/mail/message/${randomUUID()}/`, `/mail/message/${randomUUID()}?x=1`]) {
    test(`${path} is refused`, async () => {
      const ada = await person()
      await deliver(ada)
      const reply = await ask(ada.token, 'GET', path)
      assert.equal(reply.status, 404)
      assert.equal(reply.body, undefined)
    })
  }

  test('a message cannot be fetched from another account\'s folder by a crafted path', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = await deliver(user1)
    const reply = await ask(user2.token, 'GET', `/mail/message/../${user1.mailbox}/${id}`)
    assert.equal(reply.status, 404)
  })

  test('the store itself refuses an ID that isn\'t one', async () => {
    const ada = await person()
    await assert.rejects(mailboxes.message(ada.mailbox, '../public.key'), /not a message/)
    await assert.rejects(mailboxes.remove(ada.mailbox, ['public.key']), /not a message/)
  })

  test('deleting removes only the caller\'s named messages', async () => {
    const [ada, other] = [await person(), await person()]
    const [gone, kept] = [await deliver(ada), await deliver(ada)]
    const theirs = await deliver(other)
    assert.deepEqual(JSON.parse((await remove(ada.token, [gone])).body), { deleted: 1 })
    assert.deepEqual((await listed(ada.token)).messages.map((message) => message.id), [kept])
    assert.deepEqual((await listed(other.token)).messages.map((message) => message.id), [theirs])
    assert.equal((await readdir(ada.folder)).includes('public.key'), true)
  })

  test('deleting twice is harmless, and unknown IDs are ignored', async () => {
    const ada = await person()
    const id = await deliver(ada)
    assert.deepEqual(JSON.parse((await remove(ada.token, [id, id, randomUUID()])).body), { deleted: 1 })
    assert.deepEqual(JSON.parse((await remove(ada.token, [id])).body), { deleted: 0 })
  })

  test('deleting nothing deletes nothing', async () => {
    const ada = await person()
    await deliver(ada)
    assert.deepEqual(JSON.parse((await remove(ada.token, [])).body), { deleted: 0 })
    assert.equal((await listed(ada.token)).messages.length, 1)
  })

  test(`at most ${MAX_DELETE} messages go in one request`, async () => {
    const ada = await person()
    const ids = Array.from({ length: MAX_DELETE + 1 }, () => randomUUID())
    assert.equal((await remove(ada.token, ids)).status, 400)
    assert.equal((await remove(ada.token, ids.slice(1))).status, 200)
  })

  for (const body of ['', 'not json', 'null', '{}', '{"ids":"x"}', '{"ids":[7]}', '{"ids":["../public.key"]}',
    '{"ids":["public.key"]}', JSON.stringify({ ids: [randomUUID().toUpperCase()] }), JSON.stringify({ ids: [`${randomUUID()}\n`] })]) {
    test(`a delete of ${JSON.stringify(body)} is refused and removes nothing`, async () => {
      const ada = await person()
      await deliver(ada)
      assert.equal((await ask(ada.token, 'POST', '/mail/delete', body)).status, 400)
      assert.equal((await listed(ada.token)).messages.length, 1)
    })
  }

  test('a delete past the size limit is a 413', async () => {
    const ada = await person()
    assert.equal((await gate.respond('POST', '/mail/delete', `Bearer ${ada.token}`, undefined, async () => null)).status, 413)
  })

  test('without a sign-in nothing is listed, fetched, deleted, or read', async () => {
    const ada = await person()
    const id = await deliver(ada)
    let read = false
    for (const authorization of [undefined, '', 'Bearer ', 'Bearer nonsense', BEARER, `Basic ${ada.token}`, ada.token]) {
      for (const [method, path] of [['GET', '/mail/list'], ['GET', `/mail/message/${id}`], ['POST', '/mail/delete']]) {
        const reply = await gate.respond(method, path, authorization, undefined, async () => { read = true })
        assert.equal(reply.status, 401)
        assert.equal(reply.body, undefined)
      }
    }
    assert.equal(read, false)
    assert.equal((await listed(ada.token)).messages.length, 1)
  })

  test('if the sign-in can\'t be checked, the device is told to try later', async () => {
    const ada = await person()
    const id = await deliver(ada)
    supabaseDown = true
    try {
      assert.equal((await ask(ada.token, 'GET', '/mail/list')).status, 503)
      assert.equal((await ask(ada.token, 'GET', `/mail/message/${id}`)).status, 503)
      assert.equal((await remove(ada.token, [id])).status, 503)
    } finally {
      supabaseDown = false
    }
    assert.equal((await listed(ada.token)).messages.length, 1)
  })

  test('each path takes only its own method', async () => {
    const ada = await person()
    assert.equal((await ask(ada.token, 'POST', '/mail/list', '{}')).status, 405)
    assert.equal((await ask(ada.token, 'GET', '/mail/delete')).status, 405)
    assert.equal((await ask(ada.token, 'DELETE', `/mail/message/${randomUUID()}`)).status, 405)
    assert.equal((await ask(ada.token, 'GET', '/mail/list?x=1')).status, 404)
    assert.equal((await ask(ada.token, 'GET', '/mail/lists')).status, 404)
  })
})

describe('mail between accounts', () => {
  let root, mailboxes, gate
  const accounts = new Map()
  let supabaseDown = false
  const NOW = Date.UTC(2026, 10, 5, 14, 30)

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailboxes = new Mailboxes(root)
    gate = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => {
        if (supabaseDown) throw new Error('down')
        return accounts.get(token) ?? null
      },
      checkSpam: async () => assert.fail('mail between accounts is never read by the spam check'),
      mailboxes,
      clock: () => NOW,
    })
  })
  after(() => rm(root, { recursive: true, force: true }))

  let n = 0
  const person = async ({ publish = true } = {}) => {
    n += 1
    const token = `direct_${n}`
    const keys = newKeys()
    const signedIn = { name: `grace_${n}`, mailbox: randomUUID() }
    accounts.set(token, signedIn)
    if (publish) await mailboxes.publish(signedIn.name, signedIn.mailbox, keys.publicKey)
    return { token, keys, ...signedIn, folder: join(root, 'boxes', signedIn.mailbox) }
  }
  const ask = (token, method, path, body) =>
    gate.respond(method, path, token && `Bearer ${token}`, undefined, async () => body === undefined ? null : Buffer.from(body))
  // What the sender's device would have sealed for the recipient. The server never opens it.
  const DEVICE_SEALED = Buffer.concat([Buffer.from([1]), Buffer.alloc(32, 7), Buffer.from('a sealed note about the engine')])
  const deliver = (from, fields) => ask(from.token, 'POST', '/mail/deliver', JSON.stringify(fields))
  const letter = (to, id = randomUUID(), sealed = DEVICE_SEALED) => ({ to: to.name, id, sealed: sealed.toString('base64') })
  // A Sent copy as a device seals it, under a key from the content key. The server never opens it either.
  const SENT_SEALED = Buffer.concat([Buffer.from([2]), Buffer.alloc(12, 3), Buffer.from('a sealed copy of the note about the engine')])
  const keep = (from, id = randomUUID(), sealed = SENT_SEALED) =>
    ask(from.token, 'POST', '/mail/keep', JSON.stringify({ id, sealed: sealed.toString('base64') }))
  const listed = async (who) => JSON.parse((await ask(who.token, 'GET', '/mail/list')).body).messages.map(({ id }) => id)
  const factsAndBody = (form) => {
    const line = form.indexOf(10)
    return [JSON.parse(form.subarray(0, line)), form.subarray(line + 1)]
  }

  test('user 1 finds user 2\'s key by name, and never their mailbox', async () => {
    const [user1, user2] = [await person(), await person()]
    const reply = await ask(user1.token, 'GET', `/mail/recipient/${user2.name}`)
    assert.equal(reply.status, 200)
    assert.equal(reply.type, 'application/json')
    assert.deepEqual(JSON.parse(reply.body), { publicKey: user2.keys.publicKey.toString('base64') })
    assert.equal(reply.body.includes(user2.mailbox), false)
    assert.equal(reply.body.includes(user2.mailbox.replaceAll('-', '')), false)
  })

  test('a name nobody holds, or one with no key yet, has no recipient', async () => {
    const [user1, keyless] = [await person(), await person({ publish: false })]
    await writeFile(join(root, 'names', 'hostmaster'), `${keyless.mailbox}\n`)
    for (const name of ['nobody_here', 'hostmaster', keyless.name]) {
      const reply = await ask(user1.token, 'GET', `/mail/recipient/${name}`)
      assert.equal(reply.status, 404)
      assert.equal(reply.body, undefined)
    }
  })

  for (const name of ['ab', 'Grace', 'grace.hopper', '..', '..%2Fnames%2Fgrace', 'a'.repeat(25), '']) {
    test(`a recipient named ${JSON.stringify(name)} is a 404`, async () => {
      const user1 = await person()
      assert.equal((await ask(user1.token, 'GET', `/mail/recipient/${name}`)).status, 404)
    })
  }

  test('user 1 delivers to user 2, who lists, fetches, and opens it with who sent it', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = randomUUID()
    assert.equal((await deliver(user1, letter(user2, id))).status, 201)
    assert.deepEqual(await listed(user2), [id])
    const reply = await ask(user2.token, 'GET', `/mail/message/${id}`)
    assert.equal(reply.status, 200)
    const [facts, body] = factsAndBody(opened(reply.body, user2.keys, user2.mailbox, id))
    assert.deepEqual(facts, { version: 1, received: '2026-11-05T14:30:00.000Z', spam: null, from: user1.name, to: user2.name })
    assert.deepEqual(body, DEVICE_SEALED)
    assert.equal(reply.body.includes(user1.name), false)
  })

  test('the delivered message lands in user 2\'s box only, and nothing in user 1\'s', async () => {
    const [user1, user2] = [await person(), await person()]
    await deliver(user1, letter(user2))
    assert.deepEqual(await listed(user1), [])
    assert.equal((await listed(user2)).length, 1)
  })

  test('sending to yourself is allowed', async () => {
    const user1 = await person()
    const id = randomUUID()
    assert.equal((await deliver(user1, letter(user1, id))).status, 201)
    const [facts] = factsAndBody(opened(await mailboxes.message(user1.mailbox, id), user1.keys, user1.mailbox, id))
    assert.equal(facts.from, user1.name)
  })

  test('user 1 cannot choose who it says it\'s from, or which mailbox it lands in', async () => {
    const [user1, user2, user3] = [await person(), await person(), await person()]
    const id = randomUUID()
    const smuggled = { ...letter(user2, id), from: user3.name, name: user3.name, mailbox: user3.mailbox, spam: { flagged: false },
      received: '2020-01-01T00:00:00.000Z', version: 2 }
    assert.equal((await deliver(user1, smuggled)).status, 201)
    const [facts] = factsAndBody(opened(await mailboxes.message(user2.mailbox, id), user2.keys, user2.mailbox, id))
    assert.deepEqual(facts, { version: 1, received: '2026-11-05T14:30:00.000Z', spam: null, from: user1.name, to: user2.name })
    assert.deepEqual(await listed(user3), [])
  })

  test('the memory holding the message is wiped afterwards', async () => {
    const [user1, user2] = [await person(), await person()]
    const body = Buffer.from(JSON.stringify(letter(user2)))
    assert.equal(await gate.handle('POST', '/mail/deliver', `Bearer ${user1.token}`, undefined, async () => body), 201)
    assert.equal(body.every((byte) => byte === 0), true)
  })

  test('an unknown or keyless recipient is a 404, and nothing is stored', async () => {
    const [user1, keyless] = [await person(), await person({ publish: false })]
    for (const to of ['nobody_here', keyless.name, 'Grace_1', '../x', 'ab']) {
      assert.equal((await deliver(user1, { ...letter(user1), to })).status, 404)
    }
    assert.deepEqual(await listed(user1), [])
  })

  test('a full mailbox is a 507', async () => {
    const [user1, user2] = [await person(), await person()]
    const full = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => accounts.get(token) ?? null,
      checkSpam: async () => null,
      mailboxes: Object.assign(Object.create(mailboxes), {
        size: async () => MAILBOX_LIMIT - Math.min(DEVICE_SEALED.length, SENT_SEALED.length),
        add: async () => assert.fail('stored past the limit'),
      }),
    })
    const post = (path, body) => full.handle('POST', path, `Bearer ${user1.token}`, undefined, async () => Buffer.from(body))
    assert.equal(await post('/mail/deliver', JSON.stringify(letter(user2))), 507)
    assert.equal(await post('/mail/keep', JSON.stringify({ id: randomUUID(), sealed: Buffer.concat([SENT_SEALED, Buffer.alloc(1)]).toString('base64') })), 507)
  })

  test('a message past the limit is a 413', async () => {
    const [user1, user2] = [await person(), await person()]
    const tooBig = Buffer.alloc(MAX_MESSAGE + 1, 1)
    assert.equal((await deliver(user1, letter(user2, randomUUID(), tooBig))).status, 413)
    assert.equal((await keep(user1, randomUUID(), Buffer.alloc(MAX_MESSAGE + 1, 2))).status, 413)
    assert.equal((await gate.respond('POST', '/mail/deliver', `Bearer ${user1.token}`, undefined, async () => null)).status, 413)
    assert.deepEqual(await listed(user2), [])
    assert.ok(MAX_SEALED_REQUEST > Math.ceil(MAX_MESSAGE / 3) * 4)
  })

  test('the same id twice is a 409, and the first stays as it was', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = randomUUID()
    assert.equal((await deliver(user1, letter(user2, id))).status, 201)
    const first = await readFile(join(user2.folder, `${id}.sealed`))
    assert.equal((await deliver(user1, letter(user2, id, Buffer.from('a replacement')))).status, 409)
    assert.deepEqual(await readFile(join(user2.folder, `${id}.sealed`)), first)
    assert.equal((await keep(user2, id)).status, 409)
    assert.deepEqual(await readFile(join(user2.folder, `${id}.sealed`)), first)
    assert.deepEqual(await listed(user2), [id])
  })

  test('a Sent copy is kept exactly as sent, in the caller\'s own box', async () => {
    const user1 = await person()
    const id = randomUUID()
    assert.equal((await keep(user1, id)).status, 201)
    const reply = await ask(user1.token, 'GET', `/mail/message/${id}`)
    assert.deepEqual(reply.body, SENT_SEALED)
  })

  // Anyone can seal version 1 to a public key, so a stolen sign-in could plant mail claiming a sender,
  // or claiming to be a Sent copy, if keep took it. It doesn't, however well-formed it is.
  test('keep refuses version 1, even a real seal to the caller\'s own key that claims a sender', async () => {
    const user1 = await person()
    const id = randomUUID()
    const forged = Buffer.from('{"version":1,"received":"2026-11-05T14:30:00.000Z","spam":null,"from":"mckay","to":"grace_1"}\n' +
      'From: mckay@usetotality.com\r\n\r\nPlease wire the deposit today.\r\n')
    for (const sealed of [seal(forged, user1.keys.publicKey, user1.mailbox, id), DEVICE_SEALED]) {
      assert.equal((await keep(user1, id, sealed)).status, 400)
    }
    assert.deepEqual(await listed(user1), [])
  })

  test('user 1 cannot keep anything in user 2\'s box', async () => {
    const [user1, user2] = [await person(), await person()]
    const id = randomUUID()
    const smuggled = JSON.stringify({ id, sealed: SENT_SEALED.toString('base64'), to: user2.name, mailbox: user2.mailbox,
      name: user2.name })
    assert.equal((await ask(user1.token, 'POST', '/mail/keep', smuggled)).status, 201)
    assert.deepEqual(await listed(user2), [])
    assert.deepEqual(await listed(user1), [id])
  })

  test('an account with no key yet has nowhere to keep a copy', async () => {
    const keyless = await person({ publish: false })
    assert.equal((await keep(keyless)).status, 404)
    await assert.rejects(readdir(keyless.folder), { code: 'ENOENT' })
  })

  for (const [label, sealed] of [['an empty file', Buffer.alloc(0)], ['a bare header', Buffer.concat([Buffer.from([2]), Buffer.alloc(28)])],
    ['version 1', Buffer.concat([Buffer.from([1]), Buffer.alloc(64)])], ['another version', Buffer.concat([Buffer.from([3]), Buffer.alloc(64)])]]) {
    test(`keeping ${label} is refused`, async () => {
      const user1 = await person()
      assert.equal((await keep(user1, randomUUID(), sealed)).status, 400)
      assert.deepEqual(await listed(user1), [])
    })
  }

  const id = randomUUID()
  const good = DEVICE_SEALED.toString('base64')
  // Refused by both, because the id or the sealed bytes are wrong. `to` is there for delivery and ignored by keep.
  for (const body of ['', 'not json', 'null', '7', '[]', '{}', JSON.stringify({ to: 'grace_1', sealed: good }),
    JSON.stringify({ to: 'grace_1', id: id.toUpperCase(), sealed: good }), JSON.stringify({ to: 'grace_1', id: `${id}\n`, sealed: good }),
    JSON.stringify({ to: 'grace_1', id: '../public.key', sealed: good }), JSON.stringify({ to: 'grace_1', id, sealed: 7 }),
    JSON.stringify({ to: 'grace_1', id }), JSON.stringify({ to: 'grace_1', id, sealed: `${good}\n` }),
    JSON.stringify({ to: 'grace_1', id, sealed: 'not base64!' }), JSON.stringify({ to: 'grace_1', id, sealed: '' })]) {
    test(`a delivery or keep of ${JSON.stringify(body).slice(0, 90)} is refused`, async () => {
      const user1 = await person()
      assert.equal((await ask(user1.token, 'POST', '/mail/deliver', body)).status, 400)
      assert.equal((await ask(user1.token, 'POST', '/mail/keep', body)).status, 400)
      assert.deepEqual(await listed(user1), [])
    })
  }

  for (const body of [JSON.stringify({ to: 7, id, sealed: good }), JSON.stringify({ id, sealed: good })]) {
    test(`a delivery of ${body.slice(0, 60)} is refused`, async () => {
      const user1 = await person()
      assert.equal((await ask(user1.token, 'POST', '/mail/deliver', body)).status, 400)
    })
  }

  test('without a sign-in nothing is looked up, delivered, kept, or read', async () => {
    const user2 = await person()
    let read = false
    for (const authorization of [undefined, '', 'Bearer ', 'Bearer nonsense', BEARER, `Basic ${user2.token}`, user2.token]) {
      for (const [method, path] of [['GET', `/mail/recipient/${user2.name}`], ['POST', '/mail/deliver'], ['POST', '/mail/keep']]) {
        const reply = await gate.respond(method, path, authorization, undefined, async () => { read = true })
        assert.equal(reply.status, 401)
        assert.equal(reply.body, undefined)
      }
    }
    assert.equal(read, false)
    assert.deepEqual(await listed(user2), [])
  })

  test('if the sign-in can\'t be checked, the device is told to try later', async () => {
    const [user1, user2] = [await person(), await person()]
    supabaseDown = true
    try {
      assert.equal((await ask(user1.token, 'GET', `/mail/recipient/${user2.name}`)).status, 503)
      assert.equal((await deliver(user1, letter(user2))).status, 503)
      assert.equal((await keep(user1)).status, 503)
    } finally {
      supabaseDown = false
    }
    assert.deepEqual(await listed(user2), [])
  })

  test('if the disk fails, the device is told to try later', async () => {
    const [user1, user2] = [await person(), await person()]
    const broken = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => accounts.get(token) ?? null,
      checkSpam: async () => null,
      mailboxes: Object.assign(Object.create(mailboxes), { add: async () => { throw new Error('disk') } }),
    })
    const post = (path, body) => broken.handle('POST', path, `Bearer ${user1.token}`, undefined, async () => Buffer.from(body))
    assert.equal(await post('/mail/deliver', JSON.stringify(letter(user2))), 503)
    assert.equal(await post('/mail/keep', JSON.stringify({ id: randomUUID(), sealed: SENT_SEALED.toString('base64') })), 503)
  })

  test('each path takes only its own method', async () => {
    const user1 = await person()
    assert.equal((await ask(user1.token, 'POST', `/mail/recipient/${user1.name}`, '{}')).status, 405)
    assert.equal((await ask(user1.token, 'GET', '/mail/deliver')).status, 405)
    assert.equal((await ask(user1.token, 'GET', '/mail/keep')).status, 405)
    assert.equal((await ask(user1.token, 'GET', `/mail/recipient/${user1.name}/`)).status, 404)
    assert.equal((await ask(user1.token, 'GET', '/mail/recipient')).status, 404)
    assert.equal((await ask(user1.token, 'POST', '/mail/deliver?to=x', '{}')).status, 404)
  })
})

describe('over a real connection', () => {
  let root, server, url, mailbox, keys

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-mail-'))
    mailbox = randomUUID()
    keys = newKeys()
    const mailboxes = new Mailboxes(root)
    await mailboxes.publish('ada_lovelace', mailbox, keys.publicKey)
    const checkSignIn = async (token) => (token === 'ada-session' ? { name: 'ada_lovelace', mailbox } : null)
    server = serve(new Arrivals({ secret: SECRET, checkSignIn, checkSpam: async () => null, mailboxes }), 0)
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

  test('a signed-in device lists, fetches, and deletes its mail', async () => {
    assert.equal((await post(LETTER)).status, 201)
    const signedIn = { Authorization: 'Bearer ada-session' }
    const base = url.replace('/arrive', '')
    const list = await fetch(`${base}/list`, { headers: signedIn })
    assert.equal(list.status, 200)
    assert.equal(list.headers.get('content-type'), 'application/json')
    assert.equal(list.headers.get('cache-control'), 'no-store')
    const [{ id, size }] = (await list.json()).messages
    const fetched = await fetch(`${base}/message/${id}`, { headers: signedIn })
    assert.equal(fetched.headers.get('content-type'), 'application/octet-stream')
    const sealed = Buffer.from(await fetched.arrayBuffer())
    assert.equal(sealed.length, size)
    assert.deepEqual(sealed, await readFile(join(root, 'boxes', mailbox, `${id}.sealed`)))
    const form = opened(sealed, keys, mailbox, id)
    assert.deepEqual(form.subarray(form.indexOf(10) + 1), LETTER)
    const before = await sealedCount()
    const removed = await fetch(`${base}/delete`, {
      method: 'POST', headers: { ...signedIn, 'Content-Type': 'application/json' }, body: JSON.stringify({ ids: [id] }),
    })
    assert.deepEqual(await removed.json(), { deleted: 1 })
    assert.equal(await sealedCount(), before - 1)
  })

  test('without a sign-in the reply is empty', async () => {
    const reply = await fetch(url.replace('/arrive', '/list'))
    assert.equal(reply.status, 401)
    assert.equal(await reply.text(), '')
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

describe('mail to outside addresses', () => {
  let root, mailboxes, gate
  const accounts = new Map()
  const handed = []
  let next = () => ({ sent: true })
  let now = Date.UTC(2026, 10, 5, 14, 30)
  const OLD = Date.UTC(2026, 9, 1)

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'totality-send-'))
    mailboxes = new Mailboxes(root)
    gate = new Arrivals({
      secret: SECRET,
      checkSignIn: async (token) => accounts.get(token) ?? null,
      checkSpam: async () => assert.fail('sending is never read by the spam check'),
      mailboxes,
      clock: () => now,
      sendOutside: async (message) => {
        handed.push(message)
        return next(message)
      },
    })
  })
  after(() => rm(root, { recursive: true, force: true }))

  let n = 0
  const person = (created = OLD) => {
    n += 1
    const signedIn = { name: `ada_${n}`, mailbox: randomUUID(), created }
    accounts.set(`out_${n}`, signedIn)
    return { token: `out_${n}`, ...signedIn }
  }
  const note = (fields = {}) => ({
    id: randomUUID(), to: ['charles@example.org'], subject: 'The engine', text: 'The gears arrived on Tuesday.', ...fields,
  })
  const send = async (who, fields, gateway = gate) => {
    const reply = await gateway.respond('POST', '/mail/send', who && `Bearer ${who.token}`, undefined,
      async () => Buffer.from(typeof fields === 'string' ? fields : JSON.stringify(fields)))
    return { status: reply.status, reason: reply.body && JSON.parse(reply.body).reason }
  }

  test('a message goes out from the signed-in account, whatever the request says', async () => {
    const user1 = person()
    handed.length = 0
    const reply = await send(user1, note({ from: 'someone_else@usetotality.com', cc: ['ada@example.com'], bcc: ['b@example.net'],
      inReplyTo: '<one@example.org>', references: ['<zero@example.org>', '<one@example.org>'],
      attachments: [{ filename: 'gears.txt', type: 'text/plain', content: Buffer.from('twelve').toString('base64') }] }))
    assert.deepEqual(reply, { status: 200, reason: undefined })
    assert.equal(handed.length, 1)
    const [message] = handed
    assert.equal(message.from, `${user1.name}@usetotality.com`)
    assert.deepEqual([message.to, message.cc, message.bcc], [['charles@example.org'], ['ada@example.com'], ['b@example.net']])
    assert.deepEqual(message.headers, { 'In-Reply-To': '<one@example.org>', References: '<zero@example.org> <one@example.org>' })
    assert.deepEqual(message.attachments, [{ filename: 'gears.txt', type: 'text/plain', content: 'dHdlbHZl', disposition: 'attachment' }])
    assert.deepEqual(Object.keys(message).sort(), ['attachments', 'bcc', 'cc', 'from', 'headers', 'subject', 'text', 'to'])
  })

  test('without a sign-in nothing is read or sent', async () => {
    handed.length = 0
    let read = false
    for (const authorization of [undefined, '', 'Bearer ', 'Bearer nonsense', BEARER]) {
      const reply = await gate.respond('POST', '/mail/send', authorization, undefined, async () => { read = true })
      assert.equal(reply.status, 401)
    }
    assert.equal(read, false)
    assert.equal(handed.length, 0)
    assert.equal((await gate.respond('GET', '/mail/send', 'Bearer out_1', undefined, async () => null)).status, 405)
  })

  test('an account under seven days old can only mail other Totality accounts', async () => {
    handed.length = 0
    assert.deepEqual(await send(person(now - (NEW_ACCOUNT_DAYS * 24 - 1) * 3_600_000), note()), { status: 403, reason: 'new' })
    assert.deepEqual(await send(person(null), note()), { status: 403, reason: 'new' })
    assert.equal(handed.length, 0)
    assert.equal((await send(person(now - NEW_ACCOUNT_DAYS * 24 * 3_600_000), note())).status, 200)
  })

  test('each account gets twenty outside recipients a day, and the count resets the next day', async () => {
    const user1 = person()
    const user2 = person()
    const ten = Array.from({ length: 10 }, (_, i) => `reader${i}@example.org`)
    assert.equal((await send(user1, note({ to: ten }))).status, 200)
    assert.equal((await send(user1, note({ to: ten.slice(0, 9) }))).status, 200)
    assert.deepEqual(await send(user1, note({ to: ['one@example.org', 'two@example.org'] })), { status: 429, reason: 'daily' })
    assert.equal((await send(user1, note())).status, 200)
    assert.deepEqual(await send(user1, note()), { status: 429, reason: 'daily' })
    assert.equal((await send(user2, note())).status, 200, 'one account\'s limit is not another\'s')
    const saved = now
    now += 24 * 3_600_000
    try {
      assert.equal((await send(user1, note())).status, 200)
    } finally {
      now = saved
    }
    assert.equal(OUTSIDE_PER_DAY, 20)
  })

  test('the whole server stops short of the included sends in any 31 days, whenever the billing cycle starts', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'totality-ledger-'))
    const ledger = new SendLedger(folder)
    const start = Date.UTC(2026, 10, 20)
    let used = 0
    while (used + 10 <= OUTSIDE_PER_MONTH) {
      assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 10, start), 'ok')
      used += 10
    }
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, start), 'monthly')
    // A new calendar month doesn't reset it, because a billing cycle can span the two.
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, Date.UTC(2026, 11, 1)), 'monthly')
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, start + 30 * 86_400_000), 'monthly')
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, start + 31 * 86_400_000), 'ok')
    assert.ok(OUTSIDE_PER_MONTH < 3_000)
    // A count that can't be read stops sending instead of starting again from nothing.
    await writeFile(join(folder, 'sending', 'recent.json'), '{"2026-12-21": 4')
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, start + 31 * 86_400_000), 'monthly')
    await writeFile(join(folder, 'sending', 'recent.json'), '{"2026-12-21": -9000}')
    assert.equal(await ledger.reserve(randomUUID(), randomUUID(), 1, start + 31 * 86_400_000), 'monthly')
  })

  test('sends at once can\'t both take the last places', async () => {
    const ledger = new SendLedger(await mkdtemp(join(tmpdir(), 'totality-ledger-')))
    const mailbox = randomUUID()
    const results = await Promise.all(Array.from({ length: 25 }, () => ledger.reserve(mailbox, randomUUID(), 1, now)))
    assert.equal(results.filter((result) => result === 'ok').length, OUTSIDE_PER_DAY)
    assert.equal(results.filter((result) => result === 'daily').length, 5)
  })

  test('past four at once, the device is told to try again and keeps its places', async () => {
    const user1 = person()
    let release
    const waiting = new Promise((resolve) => { release = resolve })
    next = async () => { await waiting; return { sent: true } }
    try {
      const held = Array.from({ length: AT_ONCE }, () => send(user1, note()))
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(await send(user1, note()), { status: 503, reason: 'busy' })
      release()
      for (const reply of await Promise.all(held)) assert.equal(reply.status, 200)
    } finally {
      next = () => ({ sent: true })
    }
    // Four went and the busy one gave its place back, so sixteen are left.
    for (let i = 0; i < OUTSIDE_PER_DAY - AT_ONCE; i += 1) assert.equal((await send(user1, note())).status, 200)
    assert.deepEqual(await send(user1, note()), { status: 429, reason: 'daily' })
  })

  test('a message ID is sent only once', async () => {
    const user1 = person()
    const fields = note()
    assert.equal((await send(user1, fields)).status, 200)
    assert.deepEqual(await send(user1, fields), { status: 409, reason: 'again' })
  })

  test('only a refusal that took nothing gives the places back', async () => {
    const user1 = person()
    const ten = Array.from({ length: 10 }, (_, i) => `reader${i}@example.org`)
    const one = ['charles@example.org']
    try {
      for (const [code, recipients, expected] of [
        ['E_RECIPIENT_SUPPRESSED', ten, { status: 422, reason: 'refused' }],
        ['E_DAILY_LIMIT_EXCEEDED', ten, { status: 429, reason: 'busy' }],
        ['E_SENDER_NOT_VERIFIED', ten, { status: 502, reason: 'failed' }],
        ['E_NOT_ALLOWED', ten, { status: 502, reason: 'failed' }],
        // These may have gone, so each keeps its place.
        ['E_DELIVERY_FAILED', one, { status: 422, reason: 'refused' }],
        ['E_INTERNAL_SERVER_ERROR', one, { status: 504, reason: 'unknown' }],
        ['E_SOMETHING_NEW', one, { status: 504, reason: 'unknown' }],
      ]) {
        next = () => ({ code })
        assert.deepEqual(await send(user1, note({ to: recipients })), expected, code)
      }
      next = () => { throw new Error('timed out') }
      assert.deepEqual(await send(user1, note()), { status: 504, reason: 'unknown' })
    } finally {
      next = () => ({ sent: true })
    }
    // Four kept their places, so sixteen are left.
    assert.equal((await send(user1, note({ to: ten }))).status, 200)
    assert.equal((await send(user1, note({ to: ten.slice(0, 6) }))).status, 200)
    assert.deepEqual(await send(user1, note()), { status: 429, reason: 'daily' })
  })

  test('with sending off, nothing is read', async () => {
    const off = new Arrivals({ secret: SECRET, checkSignIn: async (token) => accounts.get(token) ?? null, checkSpam: async () => null, mailboxes })
    let read = false
    const reply = await off.respond('POST', '/mail/send', `Bearer ${person().token}`, undefined, async () => { read = true })
    assert.equal(reply.status, 503)
    assert.equal(read, false)
  })

  test('the counts on disk hold no addresses or words', async () => {
    const user1 = person()
    await send(user1, note({ to: ['private.person@example.org'], subject: 'Secret plans' }))
    for (const file of await readdir(join(root, 'sending'))) {
      const text = (await readFile(join(root, 'sending', file))).toString()
      assert.doesNotMatch(text, /example|Secret|engine|@/)
    }
  })

  const id = randomUUID()
  for (const [why, fields] of [
    ['no id', { id: undefined }], ['a bad id', { id: 'x' }], ['no recipients', { to: [] }],
    ['eleven recipients', { to: Array.from({ length: 11 }, (_, i) => `r${i}@example.org`) }],
    ['a Totality address', { to: ['grace@usetotality.com'] }], ['a Totality subdomain', { to: ['a@mail.usetotality.com'] }],
    ['a Totality address in Bcc', { bcc: ['GRACE@UseTotality.com'] }],
    ['a repeated address', { to: ['a@example.org'], cc: ['A@example.org'] }], ['no domain dot', { to: ['a@localhost'] }],
    ['a header break', { to: ['a@example.org\r\nBcc: b@example.org'] }], ['a display name', { to: ['Ada <a@example.org>'] }],
    ['a list that isn\'t', { to: 'a@example.org' }], ['a subject with a line break', { subject: 'Hi\r\nBcc: b@example.org' }],
    ['no text', { text: undefined }], ['a bad In-Reply-To', { inReplyTo: 'one@example.org' }],
    ['a broken reference', { references: ['<a@b>\r\nX: y'] }], ['too many references', { references: Array(21).fill('<a@b>') }],
    ['an attachment with no name', { attachments: [{ filename: '', type: 'text/plain', content: '' }] }],
    ['an attachment with a line break', { attachments: [{ filename: 'a\r\n.txt', type: 'text/plain', content: '' }] }],
    ['a bad type', { attachments: [{ filename: 'a.txt', type: 'text', content: '' }] }],
    ['bad base64', { attachments: [{ filename: 'a.txt', type: 'text/plain', content: 'not base64!' }] }],
    ['base64 padded in the middle', { attachments: [{ filename: 'a.txt', type: 'text/plain', content: 'ab==cdef' }] }],
    ['base64 of the wrong length', { attachments: [{ filename: 'a.txt', type: 'text/plain', content: 'abcde' }] }],
  ]) {
    test(`a message with ${why} is refused`, async () => {
      handed.length = 0
      assert.equal((await send(person(), { ...note(), ...fields, ...(why === 'no id' && { id: undefined }) })).status, 400)
      assert.equal(handed.length, 0)
    })
  }

  test('a message over 25 MiB is refused', () => {
    const content = Buffer.alloc(25 * 1024 * 1024).toString('base64')
    assert.equal(outsideMessage({ ...note(), id, attachments: [{ filename: 'big.bin', type: 'application/octet-stream', content }] }).status, 413)
  })

  test('a request that isn\'t JSON is refused', async () => {
    assert.equal((await send(person(), 'not json')).status, 400)
    assert.equal((await send(person(), 'null')).status, 400)
  })
})

describe('the sending Worker', () => {
  const env = (send) => ({ MAIL_SEND_SECRET: SECRET, EMAIL: { send } })
  const ask = (body, { authorization = BEARER, method = 'POST', path = '/' } = {}) => new Request(`https://totality-send.example.workers.dev${path}`, {
    method, headers: { Authorization: authorization, 'Content-Type': 'application/json' }, ...(method === 'POST' && { body: JSON.stringify(body) }),
  })
  const message = { from: 'ada_lovelace@usetotality.com', to: ['charles@example.org'], cc: [], bcc: [], subject: 'The engine',
    text: 'The gears arrived on Tuesday.', headers: { 'In-Reply-To': '<one@example.org>' }, attachments: [] }

  test('the mail server\'s message goes to Cloudflare as it was checked', async () => {
    const sent = []
    const reply = await sender.fetch(ask(message), env(async (given) => { sent.push(given); return { messageId: 'x' } }))
    assert.equal(reply.status, 200)
    assert.deepEqual(await reply.json(), { sent: true })
    assert.deepEqual(sent, [{ from: message.from, to: message.to, subject: message.subject, text: message.text, headers: message.headers }])
  })

  test('nobody without the secret can send', async () => {
    for (const authorization of ['', 'Bearer ', 'Bearer wrong', SECRET, `Bearer ${SECRET}x`]) {
      const reply = await sender.fetch(ask(message, { authorization }), env(async () => assert.fail('sent')))
      assert.equal(reply.status, 401)
    }
    assert.equal((await sender.fetch(ask(message), { EMAIL: { send: async () => assert.fail('sent') } })).status, 503)
  })

  for (const [why, change] of [['another domain', { from: 'ada@example.org' }], ['a +tag', { from: 'ada+x@usetotality.com' }],
    ['a header it can\'t set', { headers: { 'Reply-To': 'x@example.org' } }], ['no list', { to: 'charles@example.org' }]]) {
    test(`a message with ${why} is refused`, async () => {
      const reply = await sender.fetch(ask({ ...message, ...change }), env(async () => assert.fail('sent')))
      assert.equal(reply.status, 400)
    })
  }

  test('a refusal comes back as its code alone', async () => {
    const reply = await sender.fetch(ask(message), env(async () => {
      throw Object.assign(new Error('charles@example.org is suppressed'), { code: 'E_RECIPIENT_SUPPRESSED' })
    }))
    assert.equal(reply.status, 502)
    const text = await reply.text()
    assert.deepEqual(JSON.parse(text), { code: 'E_RECIPIENT_SUPPRESSED' })
    assert.doesNotMatch(text, /example/)
  })

  test('only POST to the root sends', async () => {
    assert.equal((await sender.fetch(ask(message, { method: 'GET' }), env(async () => assert.fail('sent')))).status, 404)
    assert.equal((await sender.fetch(ask(message, { path: '/x' }), env(async () => assert.fail('sent')))).status, 404)
  })
})

describe('the server setup', () => {
  // Docker's limit of 0 doesn't stop a crash report on this host, and a report could hold readable mail.
  test('crashes leave nothing behind', async () => {
    const compose = (await readFile(new URL('../compose.yml', import.meta.url))).toString()
    assert.equal(compose.match(/^ +core: 1$/gm).length, 2)
    assert.doesNotMatch(compose, /^ +core: 0$/m)
  })

  test('the tunnel carries exactly the public mail paths', async () => {
    const tunnel = (await readFile(new URL('../cloudflared.yml', import.meta.url))).toString()
    const rules = [...tunnel.matchAll(/^ +path: (\^\/mail\/.*)$/gm)].map((match) => new RegExp(match[1]))
    assert.equal(rules.length, 1)
    const [rule] = rules
    for (const path of ['/mail/arrive', '/mail/key', '/mail/list', '/mail/delete', '/mail/deliver', '/mail/keep',
      '/mail/send', '/mail/recipient/ada_lovelace', `/mail/message/${randomUUID()}`]) {
      assert.match(path, rule)
    }
    for (const path of ['/mail/health', '/mail/message/public.key', '/mail/message/../x', `/mail/message/${randomUUID()}0`,
      '/mail/lists', '/mail/', '/mail/list/', '/mail/recipient/', '/mail/recipient/ab', '/mail/recipient/Ada',
      '/mail/recipient/../names/ada', `/mail/recipient/${'a'.repeat(25)}`, '/mail/recipient/ada/', '/mail/keeps', '/mail/sends',
      '/mail/send/']) {
      assert.doesNotMatch(path, rule)
    }
  })

  test('outside sending is off unless the server is given both settings', async () => {
    const compose = (await readFile(new URL('../compose.yml', import.meta.url))).toString()
    assert.match(compose, /MAIL_SEND_URL: \$\{MAIL_SEND_URL:-\}/)
    assert.equal(compose.match(/MAIL_SEND_SECRET/g).length, 2)
  })

  test('the sending Worker keeps no logs and no preview copies', async () => {
    const toml = (await readFile(new URL('../send-worker/wrangler.toml', import.meta.url))).toString()
    assert.match(toml, /\[observability\]\nenabled = false/)
    assert.match(toml, /preview_urls = false/)
    const code = (await readFile(new URL('../send-worker/worker.mjs', import.meta.url))).toString()
    assert.doesNotMatch(code, /console\./)
  })

  test('only the mail service gets the arrival secret', async () => {
    const compose = (await readFile(new URL('../compose.yml', import.meta.url))).toString()
    assert.equal(compose.match(/MAIL_ARRIVAL_SECRET/g).length, 2)
    assert.doesNotMatch(compose, /env_file/)
  })
})
