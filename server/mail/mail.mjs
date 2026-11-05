// The only way mail gets in. Cloudflare's Worker hands a message here, and it's checked for spam and
// sealed to the recipient's public key before anything touches the disk. Outside mail is readable for
// that moment, in memory only, which is the one exception to sealing on the device. Nothing here logs
// an address, a subject, or a word of a message, and a stored message can't be opened by this server.
import {
  createCipheriv, createHash, createHmac, createPublicKey, diffieHellman, generateKeyPairSync, randomUUID,
  timingSafeEqual,
} from 'node:crypto'
import { link, lstat, mkdir, open, readFile, readdir, rename, rm, stat, unlink, writeFile } from 'node:fs/promises'
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
// A device's message comes as base64 in a little JSON, so the request is a third bigger than the message.
export const MAX_SEALED_REQUEST = Math.ceil(MAX_MESSAGE * 4 / 3) + 4_096
export const MAX_DELETE = 500
// The Worker bounces this for good. It's not 404, because a broken tunnel answers 404 by itself, and
// that must never bounce someone's mail.
export const NO_SUCH_ADDRESS = 410

const ADDRESS = /^([a-z0-9_]{3,24})(\+[^@\s]{0,64})?@usetotality\.com$/

// Sending to outside addresses, agreed in issue 37. Every account shares one domain's reputation and one
// Cloudflare quota, so these aren't optional.
export const OUTSIDE_PER_DAY = 20
export const OUTSIDE_PER_MESSAGE = 10
export const NEW_ACCOUNT_DAYS = 7
// Workers Paid includes 3,000 outside emails a month and charges past that. The cost rule allows none
// of that, so the whole server stops a little short, whatever each account has left. Cloudflare counts
// by billing cycle, which can start on any day, so the cap holds for any 31 days in a row: no cycle is
// longer, so none can fit more.
export const OUTSIDE_PER_MONTH = 2_900
const MONTH_DAYS = 31
const DAY = 24 * 60 * 60 * 1000
// An outside address as a sending service takes it: one @, a dotted domain, nothing that could break a
// header. Our own domain is never outside, because that mail goes sealed between accounts.
const OUTSIDE = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@(?=.{1,253}$)[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+$/
const MESSAGE_ID = /^<[\x21-\x3b\x3d\x3f-\x7e]{1,250}>$/
const MIME_TYPE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$/i
// Linear on purpose: a file can be 25 MiB of it.
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/
const MAX_ATTACHMENTS = 32

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
/** A Sent copy: version 2 (1 byte) · nonce (12) · ciphertext and tag (16 or more). Only a device seals these. */
const SENT_VERSION = 2
const SENT_HEADER = 1 + 12 + 16
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
 *  `spam` is null when the check couldn't run, so a broken filter never costs anyone their mail. `from`
 *  is there only for mail between Totality accounts, and it's the sender's sign-in, never their say-so. */
export function sealedForm(raw, spam, received, from, to) {
  // `to` is the name it was delivered to, which can be a reserved name on its owner's mailbox. The
  // sender sealed the inner part to that name, so the device needs it to open the message.
  const facts = { version: 1, received: new Date(received).toISOString(), spam, ...(from !== undefined && { from, to }) }
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

  /** Returns false if the mailbox already has a message with this ID, which is left as it was. */
  async add(mailbox, message, sealed) {
    return writeOnce(this.messageFile(mailbox, message), sealed)
  }

  /** Whether a mailbox has published its key, which is when it starts to exist. */
  async hasKey(mailbox) {
    return (await readIfThere(join(this.folder(mailbox), 'public.key'))) !== null
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
  if (!name || !MAILBOX.test(user?.id ?? '')) return null
  // When the account was made, for the new-account rule. Unknown counts as brand new.
  const created = Date.parse(user.created_at ?? '')
  return { name, mailbox: user.id, created: Number.isFinite(created) ? created : null }
}

/** No sockets in here, so every rule can be tested. `checkSignIn` returns an account or null, and throws
 *  if it can't tell. `checkSpam` returns a verdict and may throw. */
export class Arrivals {
  /** `sendOutside` hands a message to the sending Worker and returns `{ sent: true }` or `{ code }`, and
   *  throws if it can't tell whether it went. Without it, outside sending is off. */
  constructor({ secret, checkSignIn, checkSpam, mailboxes, clock = Date.now, newID = randomUUID, sendOutside = null }) {
    if (!secret) throw new Error('no secret')
    Object.assign(this, { secret, checkSignIn, checkSpam, mailboxes, clock, newID, sendOutside })
    this.working = 0
  }

  /** The status alone, for callers that only need to know how it went. */
  async handle(method, path, authorization, to, read) {
    return (await this.respond(method, path, authorization, to, read)).status
  }

  /** Returns `{ status, body, type }`. Only `/mail/message/<id>` ever carries a message, and only to the
   *  account it belongs to. `/mail/recipient/<name>` carries a public key and never a mailbox.
   *  `read` takes a limit, gets the body, and returns null past the limit. Nothing is read until the
   *  caller is proven. */
  async respond(method, path, authorization, to, read) {
    if (method === 'GET' && path === '/mail/health') return { status: 200 }
    const message = /^\/mail\/message\/([^/]*)$/.exec(path)?.[1]
    const name = /^\/mail\/recipient\/([^/]*)$/.exec(path)?.[1]
    if (message !== undefined) {
      if (!MAILBOX.test(message)) return { status: 404 }
      if (method !== 'GET') return { status: 405 }
    } else if (name !== undefined) {
      if (!NAME.test(name)) return { status: 404 }
      if (method !== 'GET') return { status: 405 }
    } else if (path === '/mail/list') {
      if (method !== 'GET') return { status: 405 }
    } else if (['/mail/arrive', '/mail/key', '/mail/delete', '/mail/deliver', '/mail/keep', '/mail/send'].includes(path)) {
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
      if (name !== undefined) return await this.publicKeyFor(name)
      if (path === '/mail/deliver') return { status: await this.holding(() => this.deliver(account, read)) }
      if (path === '/mail/keep') return { status: await this.holding(() => this.keep(account, read)) }
      if (path === '/mail/send') return await this.sendOut(account, read)
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
    return this.holding(() => this.arrive(to, read))
  }

  /** Arrivals and devices share one cap, because it's what bounds the memory mail can use. */
  async holding(work) {
    if (this.working >= AT_ONCE) return 503
    this.working += 1
    try {
      return await work()
    } finally {
      this.working -= 1
    }
  }

  /** A public key is for anyone to seal with. The mailbox it belongs to stays on the server. */
  async publicKeyFor(name) {
    const recipient = await this.mailboxes.recipient(name)
    return recipient ? json(200, { publicKey: recipient.publicKey.toString('base64') }) : { status: 404 }
  }

  /** A device's JSON with its `sealed` field decoded, or a status. The request is wiped once read, and
   *  the caller wipes `bytes`. */
  async sealedRequest(read) {
    const body = await read(MAX_SEALED_REQUEST)
    if (!body) return { status: 413 }
    try {
      let request
      try {
        request = JSON.parse(body)
      } catch {
        return { status: 400 }
      }
      const { id, sealed } = request ?? {}
      if (typeof id !== 'string' || !MAILBOX.test(id) || typeof sealed !== 'string') return { status: 400 }
      const bytes = Buffer.from(sealed, 'base64')
      if (bytes.toString('base64') !== sealed) {
        bytes.fill(0)
        return { status: 400 }
      }
      return { request, id, bytes }
    } finally {
      body.fill(0)
    }
  }

  /** Mail to another Totality account. The sender's device sealed it for that person, and this seals it
   *  again into their mailbox with who sent it, taken from the sign-in. Nothing in the request can name
   *  the sender or the mailbox. Sending to yourself is allowed. */
  async deliver(account, read) {
    const given = await this.sealedRequest(read)
    if (given.status) return given.status
    const { request, id, bytes } = given
    try {
      if (typeof request.to !== 'string' || bytes.length === 0) return 400
      const recipient = NAME.test(request.to) ? await this.mailboxes.recipient(request.to) : null
      if (!recipient) return 404
      if (bytes.length > MAX_MESSAGE) return 413
      const stored = await this.mailboxes.size(recipient.mailbox)
      if (stored >= MAILBOX_LIMIT) return 507
      const plain = sealedForm(bytes, null, this.clock(), account.name, request.to)
      const sealed = seal(plain, recipient.publicKey, recipient.mailbox, id)
      plain.fill(0)
      if (stored + sealed.length > MAILBOX_LIMIT) return 507
      return (await this.mailboxes.add(recipient.mailbox, id, sealed)) ? 201 : 409
    } finally {
      bytes.fill(0)
    }
  }

  /** A Sent copy, kept exactly as it came, and only ever in the caller's own mailbox. It has its own
   *  format, version 2, sealed with a key that comes from the person's content key, which this server
   *  never sees. Version 1 is what this server seals to a public key, which anyone can do, so a stolen
   *  sign-in could use it to plant mail that looks like it came from someone. Only version 2 is taken.
   *  The server can't check the seal, only its shape. A mailbox exists once its key does, so an
   *  account without one has nowhere to keep it. */
  async keep(account, read) {
    const given = await this.sealedRequest(read)
    if (given.status) return given.status
    const { id, bytes } = given
    try {
      if (bytes.length <= SENT_HEADER || bytes[0] !== SENT_VERSION) return 400
      if (bytes.length > MAX_MESSAGE) return 413
      if (!(await this.mailboxes.hasKey(account.mailbox))) return 404
      const stored = await this.mailboxes.size(account.mailbox)
      if (stored + bytes.length > MAILBOX_LIMIT) return 507
      return (await this.mailboxes.add(account.mailbox, id, bytes)) ? 201 : 409
    } finally {
      bytes.fill(0)
    }
  }

  /** Mail to outside addresses. It has to leave readable, so this is the other half of the one
   *  exception to sealing: it's held in memory only, never logged, and passed straight to the sending
   *  Worker. The From address comes from the sign-in, never the request. The device keeps its own
   *  sealed Sent copy through `keep`. Answers with JSON naming the reason when it doesn't send. */
  async sendOut(account, read) {
    if (!this.sendOutside) return json(503, { reason: 'off' })
    this.ledger ??= new SendLedger(this.mailboxes.root)
    const body = await read(MAX_SEALED_REQUEST)
    if (!body) return { status: 413 }
    let request
    try {
      request = JSON.parse(body)
    } catch {
      return { status: 400 }
    } finally {
      body.fill(0)
    }
    const message = outsideMessage(request)
    if (message.status) return { status: message.status }
    const now = this.clock()
    if (account.created == null || now - account.created < NEW_ACCOUNT_DAYS * DAY) return json(403, { reason: 'new' })
    const count = message.to.length + message.cc.length + message.bcc.length
    return this.holding(async () => {
      const held = await this.ledger.reserve(account.mailbox, request.id, count, now)
      if (held !== 'ok') return held === 'again' ? json(409, { reason: 'again' }) : json(429, { reason: held })
      let answer
      try {
        answer = await this.sendOutside({ ...message, from: `${account.name}@usetotality.com` })
      } catch {
        // It may have gone, so nothing is given back and the device says it can't tell.
        return json(504, { reason: 'unknown' })
      }
      if (answer?.sent === true) return json(200, { sent: true })
      const [status, reason, nothingWent] = refusal(answer?.code)
      // Places come back only when Cloudflare said plainly that it took nothing. Anything else may have
      // gone, and may count toward the month.
      if (nothingWent) await this.ledger.release(account.mailbox, request.id, count, now)
      return json(status, { reason })
    }).then((reply) => typeof reply === 'number' ? json(reply, { reason: 'busy' }) : reply)
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

/** What Cloudflare's answer means: a status, a reason for the person, and whether it's certain nothing
 *  went. Only codes that mean the message was turned down before sending are certain. A failed delivery
 *  was sent and counts; an unknown code, or none, can't be told apart from a send. */
const REFUSED_BEFORE_SENDING = new Set([
  'E_VALIDATION_ERROR', 'E_FIELD_MISSING', 'E_TOO_MANY_RECIPIENTS', 'E_TOO_MANY_ATTACHMENTS', 'E_RECIPIENT_NOT_ALLOWED',
  'E_RECIPIENT_SUPPRESSED', 'E_SENDER_NOT_VERIFIED', 'E_ACCOUNT_SUSPENDED', 'E_SENDER_DOMAIN_NOT_AVAILABLE', 'E_CONTENT_TOO_LARGE',
  'E_RATE_LIMIT_EXCEEDED', 'E_DAILY_LIMIT_EXCEEDED', 'E_HEADER_NOT_ALLOWED', 'E_HEADER_USE_API_FIELD', 'E_HEADER_VALUE_INVALID',
  'E_HEADER_VALUE_TOO_LONG', 'E_HEADER_NAME_INVALID', 'E_HEADERS_TOO_LARGE', 'E_HEADERS_TOO_MANY',
  // The Worker's own: it wasn't set up, or didn't take the request, so it never called Cloudflare.
  'E_NOT_SET_UP', 'E_NOT_ALLOWED', 'E_NOT_FOUND',
])

function refusal(code) {
  const nothingWent = REFUSED_BEFORE_SENDING.has(code)
  switch (code) {
    case 'E_DAILY_LIMIT_EXCEEDED':
    case 'E_RATE_LIMIT_EXCEEDED':
      return [429, 'busy', nothingWent]
    case 'E_RECIPIENT_SUPPRESSED':
    case 'E_RECIPIENT_NOT_ALLOWED':
    case 'E_DELIVERY_FAILED':
      return [422, 'refused', nothingWent]
    case 'E_CONTENT_TOO_LARGE':
      return [413, 'big', nothingWent]
    default:
      return nothingWent ? [502, 'failed', true] : [504, 'unknown', false]
  }
}

const list = (value) => value === undefined ? [] : value
const oneLine = (value, limit) => typeof value === 'string' && value.length <= limit && !/[\r\n\0]/.test(value)

/** The parts of an outside message a device may set, checked, or `{ status: 400 or 413 }`. Our own
 *  addresses aren't allowed: that mail goes sealed between accounts, never through Cloudflare. */
export function outsideMessage(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) return { status: 400 }
  const { id, subject, text, inReplyTo, references } = request
  const [to, cc, bcc] = [list(request.to), list(request.cc), list(request.bcc)]
  if (typeof id !== 'string' || !MAILBOX.test(id)) return { status: 400 }
  if (![to, cc, bcc].every(Array.isArray)) return { status: 400 }
  const everyone = [...to, ...cc, ...bcc]
  if (everyone.length === 0 || everyone.length > OUTSIDE_PER_MESSAGE) return { status: 400 }
  const seen = new Set()
  for (const address of everyone) {
    if (typeof address !== 'string' || !OUTSIDE.test(address)) return { status: 400 }
    const lower = address.toLowerCase()
    const domain = lower.slice(lower.lastIndexOf('@') + 1)
    if (domain === 'usetotality.com' || domain.endsWith('.usetotality.com') || seen.has(lower)) return { status: 400 }
    seen.add(lower)
  }
  if (!oneLine(subject, 998) || typeof text !== 'string') return { status: 400 }
  const headers = {}
  if (inReplyTo !== undefined) {
    if (typeof inReplyTo !== 'string' || !MESSAGE_ID.test(inReplyTo)) return { status: 400 }
    headers['In-Reply-To'] = inReplyTo
  }
  if (references !== undefined) {
    if (!Array.isArray(references) || references.length > 20 || !references.every((ref) => typeof ref === 'string' && MESSAGE_ID.test(ref))) {
      return { status: 400 }
    }
    const joined = references.join(' ')
    if (joined.length > 2_048) return { status: 400 }
    if (joined) headers.References = joined
  }
  const attachments = list(request.attachments)
  if (!Array.isArray(attachments) || attachments.length > MAX_ATTACHMENTS) return { status: 400 }
  let size = Buffer.byteLength(text) + Buffer.byteLength(subject)
  const files = []
  for (const file of attachments) {
    const { filename, type, content } = file ?? {}
    if (!oneLine(filename, 255) || !filename || typeof type !== 'string' || !MIME_TYPE.test(type)) return { status: 400 }
    if (typeof content !== 'string' || content.length % 4 !== 0 || !BASE64.test(content)) return { status: 400 }
    size += content.length / 4 * 3 - (content.endsWith('==') ? 2 : content.endsWith('=') ? 1 : 0)
    files.push({ filename, type, content, disposition: 'attachment' })
  }
  if (size > 25 * 1024 * 1024) return { status: 413 }
  return { to, cc, bcc, subject, text, headers, attachments: files }
}

/** Counts of outside recipients: each account's today, and the whole server's this month, in UTC. They
 *  hold numbers and message IDs, never an address or a word of a message. One process writes them, so a
 *  queue is enough to keep two sends from both taking the last place. */
export class SendLedger {
  constructor(root) {
    this.folder = join(root, 'sending')
    this.queue = Promise.resolve()
  }

  serially(work) {
    const turn = this.queue.then(work)
    this.queue = turn.catch(() => {})
    return turn
  }

  async load(name, period) {
    const kept = await readIfThere(join(this.folder, name))
    let parsed = null
    try {
      parsed = kept && JSON.parse(kept)
    } catch {
      // A torn file can't be trusted to say there's room, so it counts as full until the period ends.
      return { period, count: Infinity, ids: [] }
    }
    return parsed?.period === period ? parsed : { period, count: 0, ids: [] }
  }

  async save(name, value) {
    await mkdir(this.folder, { recursive: true, mode: 0o700 })
    const file = join(this.folder, name)
    await writeFile(`${file}.new`, JSON.stringify(value), { mode: 0o600 })
    await rename(`${file}.new`, file)
  }

  /** 'ok' once the places are held, or why not: 'daily', 'monthly', or 'again' for an ID already used. */
  reserve(mailbox, id, count, now) {
    if (!MAILBOX.test(mailbox)) throw new Error('not a mailbox')
    return this.serially(async () => {
      const day = today(now)
      const mine = await this.load(`${mailbox}.json`, day)
      const recent = await this.recent(now)
      if (mine.ids.includes(id)) return 'again'
      if (mine.count + count > OUTSIDE_PER_DAY) return 'daily'
      if (total(recent) + count > OUTSIDE_PER_MONTH) return 'monthly'
      await this.save('recent.json', { ...recent, [day]: (recent[day] ?? 0) + count })
      await this.save(`${mailbox}.json`, { period: day, count: mine.count + count, ids: [...mine.ids, id] })
      return 'ok'
    })
  }

  /** Gives places back when Cloudflare took nothing. The ID stays used. */
  release(mailbox, id, count, now) {
    return this.serially(async () => {
      const day = today(now)
      const mine = await this.load(`${mailbox}.json`, day)
      const recent = await this.recent(now)
      if (Number.isFinite(total(recent))) await this.save('recent.json', { ...recent, [day]: Math.max(0, (recent[day] ?? 0) - count) })
      if (Number.isFinite(mine.count)) {
        await this.save(`${mailbox}.json`, { period: day, count: Math.max(0, mine.count - count), ids: mine.ids })
      }
    })
  }

  /** The server's outside recipients for each of the last 31 days, older days dropped. A torn file is
   *  full, so nothing sends on a count that can't be read. */
  async recent(now) {
    const kept = await readIfThere(join(this.folder, 'recent.json'))
    let days = {}
    try {
      days = kept ? JSON.parse(kept) : {}
    } catch {
      return { [today(now)]: Infinity }
    }
    if (!days || typeof days !== 'object' || Array.isArray(days)) return { [today(now)]: Infinity }
    const oldest = today(now - (MONTH_DAYS - 1) * DAY)
    const fresh = {}
    for (const [day, count] of Object.entries(days)) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || typeof count !== 'number' || !(count >= 0)) return { [today(now)]: Infinity }
      if (day >= oldest) fresh[day] = count
    }
    return fresh
  }
}

const today = (now) => new Date(now).toISOString().slice(0, 10)
const total = (days) => Object.values(days).reduce((sum, count) => sum + count, 0)


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

  // Outside sending is on only once both are set, so the server can be deployed with it off.
  const sendURL = process.env.MAIL_SEND_URL
  const sendSecret = process.env.MAIL_SEND_SECRET
  async function sendOutside(message) {
    const reply = await fetch(sendURL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${sendSecret}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(message),
      signal: AbortSignal.timeout(60_000),
    })
    const answer = await reply.json().catch(() => null)
    if (reply.ok && answer?.sent === true) return { sent: true }
    // Without a code from the Worker, there's no telling what happened, so it may have gone.
    if (typeof answer?.code !== 'string') throw new Error('unknown')
    return { code: answer.code }
  }

  return new Arrivals({
    secret: process.env.MAIL_ARRIVAL_SECRET,
    checkSignIn,
    checkSpam,
    sendOutside: sendURL && sendSecret ? sendOutside : null,
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
