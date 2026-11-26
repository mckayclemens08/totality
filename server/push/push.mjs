// Push: wakes a person's phones through Apple's push service (issue 164). A signed-in phone registers its
// push token here, and the server later sends it a silent push that says only "look again". Every push
// is empty apart from that, so Apple, Cloudflare and this server carry nothing about what changed.
//
// Three things wake a phone, and none of them carries what happened (issue 232):
// - Gmail, below.
// - The Matrix homeserver, as a Matrix push gateway (`/_matrix/push/v1/notify`). Its pushers use the
//   `event_id_only` format, so a note holds a room ID and an event ID and never message or post text. Push
//   reads only the device token from it and keeps nothing.
// - A poke: a signed-in phone asking to wake other accounts by username after a like, comment or follow.
//   It names no kind and no content; the woken phone asks Supabase what's new itself, so a poke with
//   nothing behind it shows nothing. Pokes are limited and held only in memory.
//
// Instant Gmail sync is the first user (non-negotiable 8). A phone links a Gmail address by showing a
// Google ID token for it, which proves the address is that person's and opens nothing in Gmail. Only a
// keyed hash of the address is kept. When the inbox changes, Google posts to `/push/gmail/notify` through
// Cloud Pub/Sub with the address and a history number, signed by Google. The server hashes the address,
// wakes the phones linked to it, and keeps nothing about the note. It never sees mail, subjects, senders,
// or any Google access or refresh token.
//
// The Apple key is on the server only. Its file is mounted from `~/totality/secrets/push/`, which git ignores,
// and its ID and team come from `.env`. Without them registration still works and nothing is sent.
// Nothing here logs a request, a token or an account.
import { createHash, createHmac, createPrivateKey, createPublicKey, randomBytes, sign, timingSafeEqual, verify } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { connect } from 'node:http2'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

// Phones one account can register. A new one past this replaces the one seen longest ago.
export const MAX_DEVICES = 10
// A phone that hasn't registered again in this long is dropped. The app registers every time it opens.
export const DEVICE_DAYS = 60
// Apple wants its sign-in token remade between 20 and 60 minutes.
export const APNS_TOKEN_MINUTES = 45
// Totality accounts one Gmail address can wake. Someone may sign in to Totality with two accounts.
export const MAX_LINKS = 3
// Gmail notes for one address closer together than this become one push, sent at the end of the gap,
// so a burst of mail or a replayed note can't flood a phone or use up Apple's budget for it.
export const QUIET_SECONDS = 10
// How far a Google token's times may be off from this server's clock.
export const SKEW_SECONDS = 300
// Usernames one poke may name, and names one account may poke a minute.
export const POKE_NAMES = 20
export const POKES_PER_MINUTE = 60
// The app ID the iPhone app's Matrix pushers use. Anything else is turned away.
export const MATRIX_APP_IDS = ['app.totality.ios', 'app.totality.ios.dev']
// Device tokens one Matrix note may name.
export const MATRIX_DEVICES = 20

const DAY = 24 * 60 * 60 * 1000
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
// Apple's device tokens are 32 bytes today; the length may grow, so this allows up to 100.
const DEVICE = /^[0-9a-f]{64,200}$/
const TOKEN = /^Bearer ([A-Za-z0-9._-]{1,4096})$/
const NAME = /^[a-z0-9_]{3,24}$/

/** The account behind a sign-in, or null if it doesn't look like a Totality account. */
export function accountFrom(user) {
  const name = /^([a-z0-9_]{3,24})@totality\.invalid$/.exec(user?.email ?? '')?.[1]
  if (!name || !ID.test(user?.id ?? '')) return null
  return { name, id: user.id }
}

/** Remembers good sign-ins for a minute. Only a hash of the token is kept. */
export function rememberingSignIns(checkSignIn, { clock = Date.now, seconds = 60, most = 1_000 } = {}) {
  const known = new Map()
  return async (token) => {
    const key = createHash('sha256').update(token).digest('base64')
    const held = known.get(key)
    if (held && held.until > clock()) return held.account
    known.delete(key)
    const account = await checkSignIn(token)
    if (account) {
      if (known.size >= most) known.delete(known.keys().next().value)
      known.set(key, { account, until: clock() + seconds * 1_000 })
    }
    return account
  }
}

/** What push keeps, in one small file: each account's phones (`{ token, sandbox, seen }`). It's written
 *  whole to a new file and renamed into place, so a crash never leaves half of it. */
export class PushStore {
  /** `nameKey` keys the hashes kept in place of usernames. Without one, a key is made for this run and
   *  the hashes are dropped on the next start, so pokes reach only phones registered since. */
  constructor(root, { clock = Date.now, nameKey = null } = {}) {
    this.file = root ? join(root, 'push.json') : null
    this.clock = clock
    this.lastingNames = Boolean(nameKey)
    this.nameKey = nameKey ?? randomBytes(32)
    // `names` maps a keyed hash of a username to its account ID, for pokes. It holds only accounts that
    // registered a phone, and never a username itself.
    this.state = { devices: {}, gmail: {}, names: {} }
    this.loaded = false
    this.writing = Promise.resolve()
  }

  async load() {
    if (this.loaded) return
    this.loaded = true
    if (!this.file) return
    try {
      const saved = JSON.parse(await readFile(this.file, 'utf8'))
      this.state = { ...this.state, ...saved }
      if (!this.lastingNames) this.state.names = {}
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
  }

  async save() {
    if (!this.file) return
    const text = JSON.stringify(this.state)
    this.writing = this.writing.then(async () => {
      const next = `${this.file}.next`
      await writeFile(next, text, { mode: 0o600 })
      await rename(next, this.file)
    })
    await this.writing
  }

  async devices(account) {
    await this.load()
    const cutoff = this.clock() - DEVICE_DAYS * DAY
    return (this.state.devices[account] ?? []).filter((device) => device.seen >= cutoff)
  }

  /** Adds or refreshes a phone. A token belongs to one account at a time, so a phone that signs in to
   *  another account moves with it. */
  async addDevice(account, token, sandbox, name = null) {
    await this.load()
    if (name && NAME.test(name)) {
      const hash = this.nameHash(name)
      for (const [other, id] of Object.entries(this.state.names)) if (id === account && other !== hash) delete this.state.names[other]
      this.state.names[hash] = account
    }
    for (const [other, list] of Object.entries(this.state.devices)) {
      if (other === account) continue
      const kept = list.filter((device) => device.token !== token)
      if (kept.length !== list.length) this.setDevices(other, kept)
    }
    const mine = (await this.devices(account)).filter((device) => device.token !== token)
    mine.push({ token, sandbox, seen: this.clock() })
    mine.sort((a, b) => b.seen - a.seen)
    this.setDevices(account, mine.slice(0, MAX_DEVICES))
    await this.save()
  }

  async removeDevice(account, token) {
    await this.load()
    const list = this.state.devices[account] ?? []
    const kept = list.filter((device) => device.token !== token)
    if (kept.length === list.length) return false
    this.setDevices(account, kept)
    await this.save()
    return true
  }

  /** Drops a token Apple said is gone, from whichever account has it. */
  async forget(token) {
    await this.load()
    let changed = false
    for (const [account, list] of Object.entries(this.state.devices)) {
      const kept = list.filter((device) => device.token !== token)
      if (kept.length !== list.length) {
        this.setDevices(account, kept)
        changed = true
      }
    }
    if (changed) await this.save()
  }

  /** The account a username belongs to, if it registered a phone here. */
  nameHash(name) {
    return createHmac('sha256', this.nameKey).update(`name:${name}`).digest('base64url')
  }

  async accountNamed(name) {
    await this.load()
    const id = this.state.names[this.nameHash(name)]
    return id && (this.state.devices[id] ?? []).length ? id : null
  }

  /** The registered phone with this token, whichever account it belongs to. */
  async device(token) {
    await this.load()
    const cutoff = this.clock() - DEVICE_DAYS * DAY
    for (const list of Object.values(this.state.devices)) {
      const found = list.find((device) => device.token === token && device.seen >= cutoff)
      if (found) return found
    }
    return null
  }

  /** The accounts a hashed Gmail address wakes. */
  async linked(hash) {
    await this.load()
    return this.state.gmail[hash] ?? []
  }

  async link(hash, account) {
    await this.load()
    const list = (this.state.gmail[hash] ?? []).filter((other) => other !== account)
    list.unshift(account)
    this.state.gmail[hash] = list.slice(0, MAX_LINKS)
    await this.save()
  }

  async unlink(hash, account) {
    await this.load()
    const list = this.state.gmail[hash] ?? []
    const kept = list.filter((other) => other !== account)
    if (kept.length === list.length) return
    if (kept.length) this.state.gmail[hash] = kept
    else delete this.state.gmail[hash]
    await this.save()
  }

  setDevices(account, list) {
    if (list.length) {
      this.state.devices[account] = list
      return
    }
    delete this.state.devices[account]
    for (const [name, id] of Object.entries(this.state.names)) if (id === account) delete this.state.names[name]
  }
}

/** Apple's sign-in for its push service: a JWT signed with the team's push key (ES256). */
export function apnsToken({ key, keyId, teamId, now = Date.now() }) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const data = `${part({ alg: 'ES256', kid: keyId })}.${part({ iss: teamId, iat: Math.floor(now / 1000) })}`
  const signature = sign('sha256', Buffer.from(data), { key, dsaEncoding: 'ieee-p1363' })
  return `${data}.${signature.toString('base64url')}`
}

/** What every push says: nothing but "wake up and look". */
export const WAKE = Buffer.from(JSON.stringify({ aps: { 'content-available': 1 } }))

/** Sends silent pushes over one HTTP/2 connection per Apple host. `request(host, headers, body)` returns
 *  `{ status, reason }`, and is swapped out in tests. */
export class APNs {
  constructor({ key, keyId, teamId, topic, clock = Date.now, request = http2Request() }) {
    Object.assign(this, { key, keyId, teamId, topic, clock, request })
    this.made = null
  }

  bearer() {
    const now = this.clock()
    if (!this.made || now - this.made.at > APNS_TOKEN_MINUTES * 60_000) {
      this.made = { at: now, token: apnsToken({ key: this.key, keyId: this.keyId, teamId: this.teamId, now }) }
    }
    return this.made.token
  }

  /** `'sent'`, `'gone'` when Apple says the token no longer works, or `'failed'`. A token Apple calls bad
   * on one service is tried once on the other before it counts as gone, because a phone can't always tell
   * which service its build uses (a TestFlight build carries no profile to read). When the other service
   * takes it, the device's `sandbox` flag is corrected in place. */
  async wake(device) {
    const first = await this.send(device.token, device.sandbox)
    if (first !== 'bad') return first
    const second = await this.send(device.token, !device.sandbox)
    if (second === 'sent') { device.sandbox = !device.sandbox; return 'sent' }
    return second === 'bad' ? 'gone' : second
  }

  async send(token, sandbox) {
    const host = sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'
    try {
      const { status, reason } = await this.request(host, {
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${this.bearer()}`,
        'apns-topic': this.topic,
        'apns-push-type': 'background',
        'apns-priority': '5',
        'apns-expiration': '0',
        'content-type': 'application/json',
      }, WAKE)
      if (status === 200) return 'sent'
      if (status === 400 && reason === 'BadDeviceToken') return 'bad'
      if (status === 410 || (status === 400 && reason === 'DeviceTokenNotForTopic')) return 'gone'
      return 'failed'
    } catch {
      return 'failed'
    }
  }
}

function http2Request() {
  const sessions = new Map()
  return (host, headers, body) => new Promise((resolve, reject) => {
    let session = sessions.get(host)
    if (!session || session.closed || session.destroyed) {
      session = connect(`https://${host}`)
      session.on('error', () => sessions.delete(host))
      session.on('close', () => sessions.delete(host))
      session.setTimeout(10 * 60_000, () => session.close())
      sessions.set(host, session)
    }
    const stream = session.request(headers)
    stream.setTimeout(10_000, () => stream.close())
    let status = 0
    const chunks = []
    stream.on('response', (answer) => { status = answer[':status'] })
    stream.on('data', (chunk) => chunks.push(chunk))
    stream.on('end', () => {
      let reason
      try { reason = JSON.parse(Buffer.concat(chunks).toString()).reason } catch {}
      resolve({ status, reason })
    })
    stream.on('error', reject)
    stream.end(body)
  })
}

/** The keyed hash kept in place of a Gmail address. Without the server's key, the file can't be matched
 *  against a list of addresses. */
export function addressHash(key, address) {
  return createHmac('sha256', key).update(String(address).trim().toLowerCase()).digest('base64url')
}

const GMAIL = /^[^\s@]{1,64}@[a-z0-9.-]{1,190}$/

/** A JWT signed by Google, checked against Google's published keys. Returns its claims when the signature,
 *  issuer, audience and times are right, or null. `keys(kid)` returns the matching public key or null. */
export async function verifyGoogleJWT(jwt, { audiences, keys, now = Date.now() }) {
  if (typeof jwt !== 'string' || jwt.length > 4096) return null
  const parts = jwt.split('.')
  if (parts.length !== 3) return null
  let header, claims
  try {
    header = JSON.parse(Buffer.from(parts[0], 'base64url'))
    claims = JSON.parse(Buffer.from(parts[1], 'base64url'))
  } catch {
    return null
  }
  if (header?.alg !== 'RS256' || typeof header.kid !== 'string') return null
  const key = await keys(header.kid)
  if (!key) return null
  const signed = verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), key, Buffer.from(parts[2], 'base64url'))
  if (!signed) return null
  const seconds = now / 1000
  if (!['https://accounts.google.com', 'accounts.google.com'].includes(claims?.iss)) return null
  if (!audiences.includes(claims.aud)) return null
  if (typeof claims.exp !== 'number' || claims.exp + SKEW_SECONDS < seconds) return null
  if (typeof claims.iat !== 'number' || claims.iat - SKEW_SECONDS > seconds) return null
  return claims
}

/** Google's signing keys, fetched from `url` and kept as long as Google says. An unknown key ID fetches
 *  again, at most once a minute, because Google rotates its keys. */
export function googleKeys({ url = 'https://www.googleapis.com/oauth2/v3/certs', load = fetch, clock = Date.now } = {}) {
  let held = new Map()
  let until = 0
  let tried = 0
  async function refresh() {
    tried = clock()
    const reply = await load(url, { signal: AbortSignal.timeout(6_000) })
    if (!reply.ok) return
    const { keys = [] } = await reply.json()
    const next = new Map()
    for (const jwk of keys) {
      if (jwk?.kty !== 'RSA' || typeof jwk.kid !== 'string') continue
      try { next.set(jwk.kid, createPublicKey({ key: jwk, format: 'jwk' })) } catch {}
    }
    held = next
    const age = /max-age=(\d+)/.exec(reply.headers.get('cache-control') ?? '')?.[1]
    until = clock() + Math.min(Number(age ?? 3600), 24 * 3600) * 1000
  }
  return async (kid) => {
    if ((clock() > until || !held.has(kid)) && clock() - tried > 60_000) {
      try { await refresh() } catch {}
    }
    return held.get(kid) ?? null
  }
}

/** Reads a small request body, or returns null once it passes `limit`. */
export async function readBody(stream, limit) {
  const chunks = []
  let total = 0
  for await (const chunk of stream ?? []) {
    total += chunk.length
    if (total > limit) return null
    chunks.push(chunk)
  }
  return Buffer.concat(chunks, total)
}

function json(status, value) {
  return { status, headers: { 'Content-Type': 'application/json' }, body: Buffer.from(JSON.stringify(value)) }
}

function empty(status) {
  return { status, headers: {}, body: Buffer.alloc(0) }
}

async function jsonBody(body, limit) {
  const text = await readBody(body, limit)
  if (!text) return undefined
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/** No sockets in here, so every rule can be tested. `checkSignIn(token)` returns an account or null and
 *  throws if it can't tell. `apns` is null while the Apple key isn't on the server. */
const ROUTES = ['/push/device', '/push/device/remove', '/push/poke', '/push/gmail/link', '/push/gmail/unlink', '/push/gmail/notify']
export const MATRIX_NOTIFY = '/_matrix/push/v1/notify'

/** `gmail` is null until the server has its address key and knows Google's Pub/Sub sender:
 *  `{ addressKey, keys, clientIDs, pubsubAudience, pubsubSender }`. */
export class PushGate {
  constructor({ checkSignIn, store, apns = null, gmail = null, clock = Date.now, later = (fn, ms) => setTimeout(fn, ms).unref?.() }) {
    Object.assign(this, { checkSignIn, store, apns, gmail, clock, later })
    this.quiet = new Map()
    // Names each account poked in the last minute: `{ at, count }`. Memory only.
    this.pokes = new Map()
  }

  async respond({ method, path, headers = {}, body }) {
    if (path === '/push/health') return method === 'GET' ? json(200, { ok: true, sending: Boolean(this.apns), gmail: Boolean(this.gmail) }) : empty(405)
    if (path === MATRIX_NOTIFY) return method === 'POST' ? this.matrix(body) : empty(405)
    if (!ROUTES.includes(path)) return empty(404)
    if (method !== 'POST') return empty(405)
    const token = TOKEN.exec(headers.authorization ?? '')?.[1]
    if (!token) return empty(401)
    if (path === '/push/gmail/notify') return this.notified(token, body)
    const account = await this.checkSignIn(token)
    if (!account) return empty(401)
    if (path.startsWith('/push/gmail/')) return this.linking(path, account, body)
    if (path === '/push/poke') return this.poke(account, body)
    const request = await jsonBody(body, 1_024)
    const device = request?.token
    if (typeof device !== 'string' || !DEVICE.test(device)) return empty(400)
    if (path === '/push/device') {
      if (typeof request.sandbox !== 'boolean') return empty(400)
      await this.store.addDevice(account.id, device, request.sandbox, account.name)
      return empty(204)
    }
    await this.store.removeDevice(account.id, device)
    return empty(204)
  }

  /** A phone linking a Gmail address with a Google ID token for it, or unlinking one. Unlinking takes
   *  the address itself, because the Google sign-in may already be gone, and only ever removes this
   *  account's own link. */
  async linking(path, account, body) {
    if (!this.gmail) return empty(503)
    const request = await jsonBody(body, 8_192)
    if (path === '/push/gmail/link') {
      const claims = await verifyGoogleJWT(request?.idToken, { audiences: this.gmail.clientIDs, keys: this.gmail.keys, now: this.clock() })
      if (!claims || claims.email_verified !== true || typeof claims.email !== 'string' || !GMAIL.test(claims.email.toLowerCase())) return empty(403)
      await this.store.link(addressHash(this.gmail.addressKey, claims.email), account.id)
      return empty(204)
    }
    const address = request?.address
    if (typeof address !== 'string' || !GMAIL.test(address.trim().toLowerCase())) return empty(400)
    await this.store.unlink(addressHash(this.gmail.addressKey, address), account.id)
    return empty(204)
  }

  /** Google's Pub/Sub push. It has to carry an OIDC token Google signed for this endpoint, as the one
   *  service account Gmail's subscription uses. Anything signed and well formed gets 204 straight away,
   *  known address or not, so Pub/Sub doesn't retry and the answer says nothing about who is linked. */
  async notified(token, body) {
    if (!this.gmail) return empty(503)
    const { pubsubAudience, pubsubSender, keys } = this.gmail
    const claims = await verifyGoogleJWT(token, { audiences: [pubsubAudience], keys, now: this.clock() })
    if (!claims || claims.email_verified !== true || !same(claims.email, pubsubSender)) return empty(401)
    const request = await jsonBody(body, 16_384)
    let note
    try {
      note = JSON.parse(Buffer.from(request?.message?.data ?? '', 'base64'))
    } catch {
      return empty(204)
    }
    const address = note?.emailAddress
    if (typeof address !== 'string' || !GMAIL.test(address.trim().toLowerCase())) return empty(204)
    this.soon(addressHash(this.gmail.addressKey, address))
    return empty(204)
  }

  /** A phone asking to wake other people's phones. It's answered the same whether or not a name is known,
   *  so a poke can't be used to find out who has Totality on a phone. */
  async poke(account, body) {
    const request = await jsonBody(body, 2_048)
    const names = request?.to
    if (!Array.isArray(names) || !names.length || names.length > POKE_NAMES || !names.every((name) => typeof name === 'string' && NAME.test(name))) return empty(400)
    const now = this.clock()
    const used = this.pokes.get(account.id)
    const window = used && now - used.at < 60_000 ? used : { at: now, count: 0 }
    if (window.count + names.length > POKES_PER_MINUTE) return empty(429)
    window.count += names.length
    this.pokes.set(account.id, window)
    if (this.pokes.size > 10_000) {
      for (const [key, value] of this.pokes) if (now - value.at >= 60_000) this.pokes.delete(key)
    }
    const ids = []
    for (const name of new Set(names)) {
      const id = await this.store.accountNamed(name)
      if (id && id !== account.id) ids.push(id)
    }
    this.waking = Promise.all(ids.map((id) => this.coalesce(`a:${id}`, () => this.wake([id])))).catch(() => 0)
    return empty(204)
  }

  /** The Matrix homeserver's note that a room has something new for these pushers. Only the device tokens
   *  are read. A token that isn't a registered phone is given back as rejected, as the Matrix spec asks,
   *  so the homeserver drops that pusher. */
  async matrix(body) {
    const request = await jsonBody(body, 16_384)
    const devices = request?.notification?.devices
    if (!Array.isArray(devices) || devices.length > MATRIX_DEVICES) return empty(400)
    const rejected = []
    const waking = []
    for (const entry of devices) {
      const token = entry?.pushkey
      if (typeof token !== 'string') continue
      const device = MATRIX_APP_IDS.includes(entry?.app_id) && DEVICE.test(token) ? await this.store.device(token) : null
      if (!device) {
        rejected.push(token)
        continue
      }
      waking.push(this.coalesce(`d:${token}`, () => this.wakeDevices([device])))
    }
    this.waking = Promise.all(waking).catch(() => 0)
    return json(200, { rejected })
  }

  /** Runs `run` now, or once at the end of the quiet gap if it ran for `key` just before. */
  coalesce(key, run) {
    const now = this.clock()
    const held = this.quiet.get(key)
    if (held && now - held.at < QUIET_SECONDS * 1000) {
      if (!held.waiting) {
        held.waiting = true
        this.later(() => {
          this.quiet.set(key, { at: this.clock(), waiting: false })
          this.waking = Promise.resolve(run()).catch(() => 0)
        }, held.at + QUIET_SECONDS * 1000 - now)
      }
      return Promise.resolve(0)
    }
    this.quiet.set(key, { at: now, waiting: false })
    if (this.quiet.size > 10_000) {
      for (const [other, value] of this.quiet) if (now - value.at > QUIET_SECONDS * 1000 && !value.waiting) this.quiet.delete(other)
    }
    return Promise.resolve(run()).catch(() => 0)
  }

  /** Wakes an address's phones now, or once at the end of the quiet gap if it woke them just before. */
  soon(hash) {
    this.coalesce(`g:${hash}`, () => this.wakeAddress(hash))
  }

  wakeAddress(hash) {
    this.waking = this.store.linked(hash).then((accounts) => this.wake(accounts)).catch(() => 0)
    return this.waking
  }

  /** Wakes every phone of these accounts, and forgets any token Apple says is gone. */
  async wake(accounts) {
    if (!this.apns) return 0
    const devices = []
    for (const account of new Set(accounts)) devices.push(...await this.store.devices(account))
    return this.wakeDevices(devices)
  }

  async wakeDevices(devices) {
    if (!this.apns) return 0
    let sent = 0
    for (const device of devices) {
      const result = await this.apns.wake(device)
      if (result === 'sent') sent += 1
      if (result === 'gone') await this.store.forget(device.token)
    }
    return sent
  }
}

function same(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false
  const left = Buffer.from(a.toLowerCase())
  const right = Buffer.from(b.toLowerCase())
  return left.length === right.length && timingSafeEqual(left, right)
}

function liveGate() {
  const supabase = process.env.SUPABASE_URL.replace(/\/+$/, '')
  const publicKey = process.env.SUPABASE_ANON_KEY
  const root = process.env.PUSH_ROOT ?? '/var/lib/totality-push'

  async function checkSignIn(token) {
    const reply = await fetch(`${supabase}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: publicKey },
      signal: AbortSignal.timeout(6_000),
    })
    if (reply.status >= 400 && reply.status < 500) return null
    if (!reply.ok) throw new Error('sign-in check failed')
    return accountFrom(await reply.json())
  }

  let apns = null
  const { APNS_KEY_FILE: keyFile, APNS_KEY_ID: keyId, APNS_TEAM_ID: teamId } = process.env
  if (keyFile && keyId && teamId) {
    try {
      const key = createPrivateKey(readFileSync(keyFile))
      apns = new APNs({ key, keyId, teamId, topic: process.env.APNS_TOPIC || 'app.totality.ios' })
    } catch {
      apns = null
    }
  }

  let gmail = null
  const { PUSH_ADDRESS_KEY: addressKey, PUBSUB_AUDIENCE: pubsubAudience, PUBSUB_SENDER: pubsubSender } = process.env
  const clientIDs = (process.env.GOOGLE_CLIENT_IDS ?? '').split(',').map((id) => id.trim()).filter(Boolean)
  if (addressKey && addressKey.length >= 32 && pubsubAudience && pubsubSender && clientIDs.length) {
    gmail = { addressKey, keys: googleKeys(), clientIDs, pubsubAudience, pubsubSender }
  }

  // Usernames are hashed with a key made from the address key, when there is one, so they last restarts.
  const nameKey = addressKey && addressKey.length >= 32 ? createHmac('sha256', addressKey).update('push names').digest() : null
  return new PushGate({ checkSignIn: rememberingSignIns(checkSignIn), store: new PushStore(root, { nameKey }), apns, gmail })
}

export function serve(gate, port, host = '0.0.0.0') {
  const server = createServer(async (request, response) => {
    let answer
    try {
      const path = new URL(request.url ?? '/', 'http://local').pathname
      answer = await gate.respond({ method: request.method, path, headers: request.headers, body: request })
    } catch {
      answer = empty(503)
    }
    if (!request.complete) response.on('finish', () => request.destroy())
    response.writeHead(answer.status, {
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Content-Length': String(answer.body.length),
      ...answer.headers,
    })
    response.end(answer.body)
  })
  server.requestTimeout = 30_000
  server.listen(port, host)
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const root = process.env.PUSH_ROOT ?? '/var/lib/totality-push'
  await mkdir(root, { recursive: true })
  serve(liveGate(), Number(process.env.PORT ?? 8080))
}
