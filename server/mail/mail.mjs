// The only way mail gets in. Cloudflare's Worker hands a message here, and it's checked for spam and
// sealed to the recipient's public key before anything touches the disk. Outside mail is readable for
// that moment, in memory only, which is the one exception to sealing on the device. Nothing here logs
// an address, a subject, or a word of a message, and a stored message can't be opened by this server.
import {
  createCipheriv, createHash, createHmac, createPublicKey, diffieHellman, generateKeyPairSync, randomUUID,
  timingSafeEqual,
} from 'node:crypto'
import { link, lstat, mkdir, open, readFile, readdir, rm, stat, unlink } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

// Cloudflare stops a message at 25 MiB, then adds its own headers, so a little more has to fit.
export const MAX_MESSAGE = 26 * 1024 * 1024
export const MAILBOX_LIMIT = 1024 ** 3
// Each message sits in memory until it's sealed, so this caps the memory mail can use. Anything past
// it waits at the sender's server, which tries again.
export const AT_ONCE = 4
const MAX_KEY_REQUEST = 1_024
const MAX_DELETE_REQUEST = 64 * 1024
export const MAX_DELETE = 500
// The Worker bounces this for good. It's not 404, because a broken tunnel answers 404 by itself, and
// that must never bounce someone's mail.
export const NO_SUCH_ADDRESS = 410

const ADDRESS = /^([a-z0-9_]{3,24})(\+[^@\s]{0,64})?@usetotality\.com$/

/** The username part of an address, with any +tag dropped, or null if it can't be one of ours. */
export function mailName(address) {
  if (typeof address !== 'string') return null
  return ADDRESS.exec(address.trim().toLowerCase())?.[1] ?? null
}

// HPKE, RFC 9180, in base mode with X25519, HKDF-SHA256, and ChaCha20-Poly1305. The app opens it with
// CryptoKit's HPKE, and the RFC's own test vector runs against this in the tests.
const KEM_SUITE = Buffer.from('KEM\x00\x20', 'latin1')
const SUITE = Buffer.from('HPKE\x00\x20\x00\x01\x00\x03', 'latin1')
const VERSION_LABEL = Buffer.from('HPKE-v1')

function extract(salt, ikm) {
  return createHmac('sha256', salt.length ? salt : Buffer.alloc(32)).update(ikm).digest()
}

function expand(prk, info, length) {
  const output = []
  let block = Buffer.alloc(0)
  for (let round = 1; output.length * 32 < length; round += 1) {
    block = createHmac('sha256', prk).update(block).update(info).update(Buffer.from([round])).digest()
    output.push(block)
  }
  return Buffer.concat(output).subarray(0, length)
}

function labeledExtract(suite, salt, label, ikm) {
  return extract(salt, Buffer.concat([VERSION_LABEL, suite, Buffer.from(label), ikm]))
}

function labeledExpand(suite, prk, label, info, length) {
  const size = Buffer.from([length >> 8, length & 255])
  return expand(prk, Buffer.concat([size, VERSION_LABEL, suite, Buffer.from(label), info]), length)
}

function x25519Public(raw) {
  return createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: raw.toString('base64url') }, format: 'jwk' })
}

/** The steps of RFC 9180 from a key agreement to the AEAD's key and nonce. Sealing passes this
 *  message's private key and the recipient's public key. Opening passes them the other way round. */
export function keySchedule(privateKey, peer, enc, recipient, info) {
  const shared = diffieHellman({ privateKey, publicKey: x25519Public(peer) })
  const eaePrk = labeledExtract(KEM_SUITE, Buffer.alloc(0), 'eae_prk', shared)
  const secretInput = labeledExpand(KEM_SUITE, eaePrk, 'shared_secret', Buffer.concat([enc, recipient]), 32)
  const context = Buffer.concat([
    Buffer.alloc(1),
    labeledExtract(SUITE, Buffer.alloc(0), 'psk_id_hash', Buffer.alloc(0)),
    labeledExtract(SUITE, Buffer.alloc(0), 'info_hash', info),
  ])
  const secret = labeledExtract(SUITE, secretInput, 'secret', Buffer.alloc(0))
  return {
    key: labeledExpand(SUITE, secret, 'key', context, 32),
    nonce: labeledExpand(SUITE, secret, 'base_nonce', context, 12),
  }
}

export function aead(key, nonce, plaintext, associated) {
  const cipher = createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  cipher.setAAD(associated)
  const body = cipher.update(plaintext)
  cipher.final()
  return Buffer.concat([body, cipher.getAuthTag()])
}

const SEAL_VERSION = 1
const SEAL_INFO = Buffer.from('totality/mail/v1')

function uuidBytes(id) {
  return Buffer.from(id.replaceAll('-', ''), 'hex')
}

/** Layout: version (1) · HPKE encapsulated key (32) · ciphertext and tag. The mailbox and message IDs
 *  are authenticated, so a stored message can't be moved to another mailbox or another name. */
export function seal(plaintext, recipientPublicKey, mailbox, message) {
  const { publicKey, privateKey } = generateKeyPairSync('x25519')
  const enc = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url')
  const { key, nonce } = keySchedule(privateKey, recipientPublicKey, enc, recipientPublicKey, SEAL_INFO)
  const associated = Buffer.concat([SEAL_INFO, uuidBytes(mailbox), uuidBytes(message)])
  return Buffer.concat([Buffer.from([SEAL_VERSION]), enc, aead(key, nonce, plaintext, associated)])
}

/** What gets sealed: one line of facts the device can't work out, then the message exactly as it came.
 *  `spam` is null when the check couldn't run, so a broken filter never costs anyone their mail. */
export function sealedForm(raw, spam, received) {
  const facts = { version: 1, received: new Date(received).toISOString(), spam }
  return Buffer.concat([Buffer.from(`${JSON.stringify(facts)}\n`), raw])
}

/** Writes `data` to `path` only if nothing is there, all at once, and flushed first. A crash never
 *  leaves part of a file under its real name. Returns false if the name was already taken. */
async function writeOnce(path, data) {
  const held = `${path}.${randomUUID()}.tmp`
  try {
    const file = await open(held, 'wx', 0o600)
    try {
      await file.writeFile(data)
      await file.sync()
    } finally {
      await file.close()
    }
    await link(held, path)
    return true
  } catch (error) {
    if (error.code === 'EEXIST') return false
    throw error
  } finally {
    await rm(held, { force: true })
  }
}

async function readIfThere(path) {
  try {
    return await readFile(path)
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

const NAME = /^[a-z0-9_]{3,24}$/
const MAILBOX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
// Only a whole message's name, so the key and half-written files never show.
const MESSAGE_FILE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.sealed$/

/** Everything mail keeps, on this server's disk. Each mailbox is a folder of sealed files and the public
 *  key they're sealed to. `names` says which mailbox an address belongs to, and reserved names like
 *  `abuse` are added there by hand on the server. None of it opens a message. */
export class Mailboxes {
  constructor(root) {
    this.root = root
  }

  folder(mailbox) {
    if (!MAILBOX.test(mailbox)) throw new Error('not a mailbox')
    return join(this.root, 'boxes', mailbox)
  }

  nameFile(name) {
    if (!NAME.test(name)) throw new Error('not a name')
    return join(this.root, 'names', name)
  }

  /** The mailbox and key for a name, or null if nobody can receive at it yet. */
  async recipient(name) {
    const mailbox = (await readIfThere(this.nameFile(name)))?.toString().trim()
    if (!mailbox) return null
    const publicKey = await readIfThere(join(this.folder(mailbox), 'public.key'))
    return publicKey && { mailbox, publicKey }
  }

  /** One key per mailbox, for good, so once it's published a stolen session can't swap in its own and
   *  read what arrives afterwards. A name held by another mailbox stays with it, which covers reserved
   *  names. The name goes last, so an address never exists without a key. Returns a status. */
  async publish(name, mailbox, publicKey) {
    const folder = this.folder(mailbox)
    const nameFile = this.nameFile(name)
    const holder = (await readIfThere(nameFile))?.toString().trim()
    if (holder && holder !== mailbox) return 409
    await mkdir(folder, { recursive: true, mode: 0o700 })
    await mkdir(join(this.root, 'names'), { recursive: true, mode: 0o700 })
    const keyFile = join(folder, 'public.key')
    const added = await writeOnce(keyFile, publicKey)
    if (!added && !(await readFile(keyFile)).equals(publicKey)) return 409
    await writeOnce(nameFile, mailbox)
    return added ? 201 : 200
  }

  async size(mailbox) {
    const folder = this.folder(mailbox)
    let names
    try {
      names = await readdir(folder)
    } catch (error) {
      if (error.code === 'ENOENT') return 0
      throw error
    }
    let total = 0
    for (const name of names) {
      if (name.endsWith('.sealed')) total += (await stat(join(folder, name))).size
    }
    return total
  }

  async add(mailbox, message, sealed) {
    await writeOnce(this.messageFile(mailbox, message), sealed)
  }

  /** The ID is checked before it becomes part of a path, so it can't name anything but a message in
   *  this one mailbox. */
  messageFile(mailbox, message) {
    if (!MAILBOX.test(message)) throw new Error('not a message')
    return join(this.folder(mailbox), `${message}.sealed`)
  }

  /** Every message in a mailbox, newest first, with sizes and arrival times and nothing else. A mailbox
   *  with no folder yet is simply empty. */
  async list(mailbox) {
    const folder = this.folder(mailbox)
    let names
    try {
      names = await readdir(folder)
    } catch (error) {
      if (error.code === 'ENOENT') return []
      throw error
    }
    const messages = []
    for (const name of names) {
      const id = MESSAGE_FILE.exec(name)?.[1]
      if (!id) continue
      let info
      try {
        info = await lstat(join(folder, name))
      } catch (error) {
        // Deleted by another device since the folder was read.
        if (error.code === 'ENOENT') continue
        throw error
      }
      if (info.isFile()) messages.push({ id, size: info.size, mtime: info.mtimeMs })
    }
    messages.sort((a, b) => b.mtime - a.mtime || (a.id < b.id ? -1 : 1))
    return messages.map(({ id, size, mtime }) => ({ id, size, received: new Date(mtime).toISOString() }))
  }

  /** A message's sealed bytes, or null if this mailbox has no such message. */
  async message(mailbox, message) {
    return readIfThere(this.messageFile(mailbox, message))
  }

  /** Removes what's there and ignores what isn't, so asking twice is harmless. Returns how many went. */
  async remove(mailbox, messages) {
    const files = [...new Set(messages)].map((message) => this.messageFile(mailbox, message))
    let removed = 0
    for (const file of files) {
      try {
        await unlink(file)
        removed += 1
      } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
    }
    return removed
  }
}

function sameSecret(given, secret) {
  // Hashed first, because comparing needs two strings of one length.
  const left = createHash('sha256').update(String(given)).digest()
  const right = createHash('sha256').update(secret).digest()
  return timingSafeEqual(left, right)
}

/** Who a Supabase user is, as far as mail is concerned, or null if they don't look like an account. */
export function accountFrom(user) {
  const name = /^([a-z0-9_]{3,24})@totality\.invalid$/.exec(user?.email ?? '')?.[1]
  return name && MAILBOX.test(user?.id ?? '') ? { name, mailbox: user.id } : null
}

/** No sockets in here, so every rule can be tested. `checkSignIn` returns an account or null, and throws
 *  if it can't tell. `checkSpam` returns a verdict and may throw. */
export class Arrivals {
  constructor({ secret, checkSignIn, checkSpam, mailboxes, clock = Date.now, newID = randomUUID }) {
    if (!secret) throw new Error('no secret')
    Object.assign(this, { secret, checkSignIn, checkSpam, mailboxes, clock, newID })
    this.working = 0
  }

  /** The status alone, for callers that only need to know how it went. */
  async handle(method, path, authorization, to, read) {
    return (await this.respond(method, path, authorization, to, read)).status
  }

  /** Returns `{ status, body, type }`. Only `/mail/message/<id>` ever carries a message, and only to the
   *  account it belongs to. `read` takes a limit, gets the body, and returns null past the limit.
   *  Nothing is read until the caller is proven. */
  async respond(method, path, authorization, to, read) {
    if (method === 'GET' && path === '/mail/health') return { status: 200 }
    const message = /^\/mail\/message\/([^/]*)$/.exec(path)?.[1]
    if (message !== undefined) {
      if (!MAILBOX.test(message)) return { status: 404 }
      if (method !== 'GET') return { status: 405 }
    } else if (path === '/mail/list') {
      if (method !== 'GET') return { status: 405 }
    } else if (path === '/mail/arrive' || path === '/mail/key' || path === '/mail/delete') {
      if (method !== 'POST') return { status: 405 }
    } else {
      return { status: 404 }
    }
    try {
      if (path === '/mail/arrive') return { status: await this.arriveWithSecret(authorization, to, read) }
      if (path === '/mail/key') return { status: await this.publishKey(authorization, read) }
      // The mailbox is always the signed-in account's own, never one named in the request.
      const account = await this.signedIn(authorization)
      if (!account) return { status: 401 }
      if (path === '/mail/list') return await this.list(account)
      if (path === '/mail/delete') return await this.remove(account, read)
      const sealed = await this.mailboxes.message(account.mailbox, message)
      return sealed ? { status: 200, body: sealed, type: 'application/octet-stream' } : { status: 404 }
    } catch {
      // Anything unexpected is a 503, so the Worker fails and the sender's server tries again later.
      return { status: 503 }
    }
  }

  async signedIn(authorization) {
    if (!authorization?.startsWith('Bearer ')) return null
    return this.checkSignIn(authorization.slice(7))
  }

  async list(account) {
    const messages = await this.mailboxes.list(account.mailbox)
    const used = messages.reduce((total, { size }) => total + size, 0)
    return json(200, { messages, used, limit: MAILBOX_LIMIT })
  }

  async remove(account, read) {
    const body = await read(MAX_DELETE_REQUEST)
    if (!body) return { status: 413 }
    let ids
    try {
      ids = JSON.parse(body).ids
    } catch {
      return { status: 400 }
    }
    if (!Array.isArray(ids) || ids.length > MAX_DELETE) return { status: 400 }
    if (!ids.every((id) => typeof id === 'string' && MAILBOX.test(id))) return { status: 400 }
    return json(200, { deleted: await this.mailboxes.remove(account.mailbox, ids) })
  }

  async arriveWithSecret(authorization, to, read) {
    if (!authorization?.startsWith('Bearer ') || !sameSecret(authorization.slice(7), this.secret)) return 401
    if (this.working >= AT_ONCE) return 503
    this.working += 1
    try {
      return await this.arrive(to, read)
    } finally {
      this.working -= 1
    }
  }

  /** The account comes from the sign-in, never the request, so nobody can publish for someone else. */
  async publishKey(authorization, read) {
    const account = await this.signedIn(authorization)
    if (!account) return 401
    const body = await read(MAX_KEY_REQUEST)
    if (!body) return 413
    let given
    try {
      given = JSON.parse(body).publicKey
    } catch {
      return 400
    }
    if (typeof given !== 'string') return 400
    const publicKey = Buffer.from(given, 'base64')
    if (publicKey.length !== 32 || publicKey.toString('base64') !== given) return 400
    return this.mailboxes.publish(account.name, account.mailbox, publicKey)
  }

  async arrive(to, read) {
    const name = mailName(to)
    if (!name) return NO_SUCH_ADDRESS
    const recipient = await this.mailboxes.recipient(name)
    if (!recipient) return NO_SUCH_ADDRESS
    const stored = await this.mailboxes.size(recipient.mailbox)
    if (stored >= MAILBOX_LIMIT) return 507
    const raw = await read(MAX_MESSAGE)
    if (!raw) return 413
    try {
      let spam = null
      try {
        spam = await this.checkSpam(raw)
      } catch {
        // Stored without a verdict. Losing someone's mail is worse than missing one spam message.
      }
      const message = this.newID()
      const plain = sealedForm(raw, spam, this.clock())
      const sealed = seal(plain, recipient.publicKey, recipient.mailbox, message)
      plain.fill(0)
      if (stored + sealed.length > MAILBOX_LIMIT) return 507
      await this.mailboxes.add(recipient.mailbox, message, sealed)
      return 201
    } finally {
      raw.fill(0)
    }
  }
}

function json(status, value) {
  return { status, body: Buffer.from(JSON.stringify(value)), type: 'application/json' }
}

/** Rspamd's action becomes one yes or no. Its reasons stay behind, because they'd describe the message. */
export function verdict(answer) {
  const spammy = ['reject', 'rewrite subject', 'add header']
  if (typeof answer?.score !== 'number' || typeof answer?.action !== 'string') return null
  return { score: answer.score, flagged: spammy.includes(answer.action) }
}

function liveArrivals() {
  const supabase = process.env.SUPABASE_URL.replace(/\/+$/, '')
  const publicKey = process.env.SUPABASE_ANON_KEY
  const rspamd = process.env.RSPAMD_URL ?? 'http://rspamd:11333'

  async function checkSignIn(token) {
    if (!/^[A-Za-z0-9._-]{1,4096}$/.test(token)) return null
    const reply = await fetch(`${supabase}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: publicKey },
      signal: AbortSignal.timeout(6_000),
    })
    if (reply.status >= 400 && reply.status < 500) return null
    if (!reply.ok) throw new Error('sign-in check failed')
    return accountFrom(await reply.json())
  }

  async function checkSpam(raw) {
    const reply = await fetch(`${rspamd}/checkv2`, { method: 'POST', body: raw, signal: AbortSignal.timeout(20_000) })
    if (!reply.ok) throw new Error('check failed')
    return verdict(await reply.json())
  }

  return new Arrivals({
    secret: process.env.MAIL_ARRIVAL_SECRET,
    checkSignIn,
    checkSpam,
    mailboxes: new Mailboxes(process.env.MAILBOX_ROOT ?? '/var/lib/totality-mail'),
  })
}

/** Reads a request body, or returns null once it passes `limit`. */
export async function readBody(request, limit) {
  const chunks = []
  let total = 0
  for await (const chunk of request) {
    total += chunk.length
    if (total > limit) {
      for (const held of chunks) held.fill(0)
      return null
    }
    chunks.push(chunk)
  }
  const body = Buffer.concat(chunks, total)
  for (const held of chunks) held.fill(0)
  return body
}

export function serve(arrivals, port) {
  const server = createServer(async (request, response) => {
    let tooBig = false
    const { status, body, type } = await arrivals.respond(request.method, request.url, request.headers.authorization,
      request.headers['x-mail-to'], async (limit) => {
        const given = await readBody(request, limit)
        tooBig = !given
        return given
      })
    response.writeHead(status, {
      'Content-Length': body?.length ?? 0,
      'Cache-Control': 'no-store',
      ...(type && { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff' }),
      ...(tooBig && { Connection: 'close' }),
    })
    response.end(body)
  })
  server.requestTimeout = 120_000
  server.listen(port, '0.0.0.0')
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  serve(liveArrivals(), Number(process.env.PORT ?? 8080))
}
