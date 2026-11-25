// Social's photos and voice clips (issue 149), on this server's disk instead of Supabase Storage, whose
// free 1 GB was shared by everyone. A public post's file is kept readable, so For You can show it. A
// Friends or Close-friends post's file was sealed on the phone with its own key, and that key lives only in
// the post's end-to-end encrypted Matrix event, so nothing here can open it.
//
// Posts never count against anyone's storage (owner, 2026-11-21): this is its own folder, apart from the
// sealed blob store and its limits. There's still a much larger cap per account, a daily number of files,
// and a floor of free disk, so nobody can fill the disk.
//
// Every request needs a Totality sign-in, reading included, so a file can't be hotlinked from elsewhere on
// the web. The account always comes from the sign-in: you can add or remove files only in your own folder,
// and nothing is ever overwritten. Nothing here logs a request, a path, or a size.
import { createHash, randomUUID } from 'node:crypto'
import { link, lstat, mkdir, open, readdir, rm, statfs, unlink } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const GiB = 1024 ** 3
const MiB = 1024 ** 2
// Matches the app's `MediaLimits.fileBytes` plus the nonce and tag a sealed file carries.
export const MAX_FILE = 4 * MiB + 28
// Not storage, which posts never use, just a ceiling nobody reaches by posting.
export const ACCOUNT_CAP = 1 * GiB
// Files one account can add in a day. Four photos a post, so a hundred posts a day.
export const DAILY_FILES = 400
// Shared with the blob store's floor, so mail and Matrix always have room.
export const DISK_FLOOR = 8 * GiB
// Uploads written at once, across every account.
export const AT_ONCE = 8

const DAY = 24 * 60 * 60 * 1000
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TOKEN = /^Bearer ([A-Za-z0-9._-]{1,4096})$/
const PATH = /^\/social\/media\/([^/]+)\/([^/]+)$/

/** What a post may hold, by the type a device says it's sending: its ending on disk, the type it's served
 *  as, and a check of its first bytes, so a file can't claim to be a photo when it isn't. */
export const KINDS = {
  'image/jpeg': { ending: 'jpg', looksRight: (head) => head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff },
  'audio/mp4': { ending: 'm4a', looksRight: (head) => head.length >= 12 && head.toString('latin1', 4, 8) === 'ftyp' },
  // Sealed: AES-GCM's nonce and tag at the least. Its bytes are random to anyone without the key.
  'application/octet-stream': { ending: 'sealed', looksRight: (head, size) => size > 28 },
}
const SERVED = Object.fromEntries(Object.entries(KINDS).map(([type, { ending }]) => [ending, type]))
const STORED = /^([0-9a-f-]{36})\.(jpg|m4a|sealed)$/

/** The account behind a sign-in, or null if it doesn't look like a Totality account. */
export function accountFrom(user) {
  const name = /^([a-z0-9_]{3,24})@totality\.invalid$/.exec(user?.email ?? '')?.[1]
  if (!name || !ID.test(user?.id ?? '')) return null
  return { name, id: user.id }
}

async function lstatIfThere(path) {
  try {
    return await lstat(path)
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

/** One folder per account, named for its ID, holding `<id>.<ending>`. Every name is checked before it
 *  becomes part of a path, so nothing can reach outside its own folder. */
export class MediaStore {
  constructor(root, { clock = Date.now } = {}) {
    this.root = root
    this.clock = clock
    this.usage = new Map()
    this.today = new Map()
    this.locks = new Map()
  }

  folder(account) {
    if (!ID.test(account)) throw new Error('not an account')
    return join(this.root, 'accounts', account)
  }

  async entries(account) {
    try {
      return await readdir(this.folder(account))
    } catch (error) {
      if (error.code === 'ENOENT') return []
      throw error
    }
  }

  /** The stored file for an ID, whatever its ending: `{ path, ending, size }` or null. */
  async find(account, id) {
    if (!ID.test(id)) return null
    for (const ending of Object.keys(SERVED)) {
      const path = join(this.folder(account), `${id}.${ending}`)
      const info = await lstatIfThere(path)
      if (info?.isFile()) return { path, ending, size: info.size }
    }
    return null
  }

  async used(account) {
    if (this.usage.has(account)) return this.usage.get(account)
    let total = 0
    for (const name of await this.entries(account)) {
      if (!STORED.test(name)) continue
      const info = await lstatIfThere(join(this.folder(account), name))
      if (info?.isFile()) total += info.size
    }
    this.usage.set(account, total)
    return total
  }

  /** Files added today, counted in memory: a restart forgets, which only ever lets someone post more. */
  addedToday(account) {
    const day = Math.floor(this.clock() / DAY)
    const held = this.today.get(account)
    return held?.day === day ? held.count : 0
  }

  countAdded(account) {
    const day = Math.floor(this.clock() / DAY)
    this.today.set(account, { day, count: this.addedToday(account) + 1 })
  }

  async alone(account, work) {
    const before = this.locks.get(account) ?? Promise.resolve()
    let release
    const mine = new Promise((resolve) => { release = resolve })
    const tail = before.then(() => mine)
    this.locks.set(account, tail)
    await before
    try {
      return await work()
    } finally {
      release()
      if (this.locks.get(account) === tail) this.locks.delete(account)
    }
  }

  /** Writes a whole file under a temporary name, checks it, then gives it its real name. `room(bytes)`
   *  says whether the account and the disk can take that many. Returns an HTTP status. */
  async add(account, id, type, body, room) {
    const kind = KINDS[type]
    if (!kind || !ID.test(id)) return 400
    if (await this.find(account, id)) return 409
    await mkdir(this.folder(account), { recursive: true, mode: 0o700 })
    const temporary = join(this.folder(account), `.${randomUUID()}.part`)
    const file = await open(temporary, 'wx', 0o600)
    let written = 0
    let failure = null
    const head = []
    try {
      for await (const chunk of body) {
        if (written + chunk.length > MAX_FILE) { failure = 413; break }
        if (!room(written + chunk.length)) { failure = 507; break }
        if (written < 16) head.push(chunk.subarray(0, 16 - written))
        let at = 0
        while (at < chunk.length) {
          const { bytesWritten } = await file.write(chunk, at, chunk.length - at, written + at)
          at += bytesWritten
        }
        written += chunk.length
      }
      if (failure === null && !kind.looksRight(Buffer.concat(head), written)) failure = 415
      if (failure === null) await file.sync()
    } catch {
      failure = 400
    } finally {
      await file.close()
    }
    try {
      if (failure !== null) return failure
      try {
        await link(temporary, join(this.folder(account), `${id}.${kind.ending}`))
      } catch (error) {
        if (error.code === 'EEXIST') return 409
        throw error
      }
      this.usage.set(account, (await this.used(account)) + written)
      this.countAdded(account)
      return 201
    } finally {
      await rm(temporary, { force: true })
    }
  }

  /** Removes a file, and ignores one that isn't there, so asking twice is harmless. */
  async remove(account, id) {
    const found = await this.find(account, id)
    if (!found) return false
    try {
      await unlink(found.path)
    } catch (error) {
      if (error.code === 'ENOENT') return false
      throw error
    }
    if (this.usage.has(account)) this.usage.set(account, Math.max(0, this.usage.get(account) - found.size))
    return true
  }

  /** Clears temporary files left by a restart mid-upload. */
  async sweep() {
    let folders
    try {
      folders = await readdir(join(this.root, 'accounts'))
    } catch (error) {
      if (error.code === 'ENOENT') return 0
      throw error
    }
    let cleared = 0
    for (const account of folders.filter((name) => ID.test(name))) {
      await this.alone(account, async () => {
        for (const name of await this.entries(account)) {
          if (!/^\.[0-9a-f-]{36}\.part$/.test(name)) continue
          await rm(join(this.folder(account), name), { force: true })
          cleared += 1
        }
      })
    }
    return cleared
  }
}

/** Remembers good sign-ins for a minute, so a feed of photos doesn't ask Supabase once for each. Only a
 *  hash of the token is kept. */
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

/** No sockets in here, so every rule can be tested. `checkSignIn(token)` returns an account or null, and
 *  throws if it can't tell. `diskFree()` is the bytes left on the disk. */
export class MediaGate {
  constructor({ checkSignIn, store, diskFree, cap = ACCOUNT_CAP, daily = DAILY_FILES, floor = DISK_FLOOR }) {
    Object.assign(this, { checkSignIn, store, diskFree, cap, daily, floor })
    this.working = 0
  }

  /** `request` is `{ method, path, headers, body }`, where `body` is the request itself, read only once
   *  the caller is proven. Returns `{ status, headers, body }`, where `body` is a Buffer or a stream. */
  async respond({ method, path, headers = {}, body }) {
    if (path === '/social/media/health') return method === 'GET' ? empty(200) : empty(405)
    const match = PATH.exec(path)
    if (!match || !ID.test(match[1]) || !ID.test(match[2])) return empty(404)
    const [, owner, id] = match
    if (!['GET', 'HEAD', 'PUT', 'DELETE'].includes(method)) return empty(405)

    const token = TOKEN.exec(headers.authorization ?? '')?.[1]
    if (!token) return empty(401)
    let account
    try {
      account = await this.checkSignIn(token)
    } catch {
      return empty(503)
    }
    if (!account || !ID.test(account.id)) return empty(401)

    try {
      if (method === 'GET' || method === 'HEAD') return await this.read(owner, id)
      // Only your own folder can change.
      if (owner !== account.id) return empty(403)
      if (method === 'DELETE') {
        await this.store.alone(owner, () => this.store.remove(owner, id))
        return empty(204)
      }
      return await this.upload(owner, id, headers, body)
    } catch {
      return empty(503)
    }
  }

  async read(owner, id) {
    const found = await this.store.find(owner, id)
    if (!found) return empty(404)
    const file = await open(found.path, 'r')
    const { size } = await file.stat()
    return {
      status: 200,
      headers: {
        'Content-Type': SERVED[found.ending],
        'Content-Length': String(size),
        // A finished file never changes. Kept only by the device that asked, never by a shared cache.
        'Cache-Control': 'private, max-age=31536000, immutable',
      },
      body: size === 0 ? (await file.close(), Buffer.alloc(0)) : file.createReadStream({ autoClose: true }),
    }
  }

  async upload(owner, id, headers, body) {
    const type = (headers['content-type'] ?? '').split(';')[0].trim().toLowerCase()
    if (!KINDS[type]) return empty(415, { Connection: 'close' })
    const declared = headers['content-length']
    if (declared === undefined || !/^\d{1,10}$/.test(declared)) return empty(411, { Connection: 'close' })
    if (Number(declared) > MAX_FILE) return empty(413, { Connection: 'close' })
    if (this.working >= AT_ONCE) return empty(503, { 'Retry-After': '5', Connection: 'close' })
    this.working += 1
    try {
      return await this.store.alone(owner, async () => {
        if (this.store.addedToday(owner) >= this.daily) return empty(429, { Connection: 'close' })
        const used = await this.store.used(owner)
        const free = await this.diskFree()
        const room = (more) => used + more <= this.cap && free - more >= this.floor
        // Asked before anything is read, so a full account or disk costs no upload at all.
        if (!room(Number(declared))) return empty(507, { Connection: 'close' })
        const status = await this.store.add(owner, id, type, body, room)
        return empty(status, status === 201 ? {} : { Connection: 'close' })
      })
    } finally {
      this.working -= 1
    }
  }
}

function empty(status, headers = {}) {
  return { status, headers, body: Buffer.alloc(0) }
}

function liveGate() {
  const supabase = process.env.SUPABASE_URL.replace(/\/+$/, '')
  const publicKey = process.env.SUPABASE_ANON_KEY
  const root = process.env.MEDIA_ROOT ?? '/var/lib/totality-social-media'

  async function checkSignIn(token) {
    const reply = await fetch(`${supabase}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: publicKey },
      signal: AbortSignal.timeout(6_000),
    })
    if (reply.status >= 400 && reply.status < 500) return null
    if (!reply.ok) throw new Error('sign-in check failed')
    return accountFrom(await reply.json())
  }

  const store = new MediaStore(root)
  store.sweep().catch(() => {})
  return new MediaGate({
    checkSignIn: rememberingSignIns(checkSignIn),
    store,
    diskFree: async () => {
      const disk = await statfs(root)
      return disk.bavail * disk.bsize
    },
  })
}

/** Websites that may read media from a browser. Exact origins only. The sign-in still decides; this only
 *  lets the browser through. */
export const WEBSITE_ORIGINS = (process.env.ALLOWED_ORIGINS ?? 'https://app.usetotality.com').split(',').map((o) => o.trim()).filter(Boolean)

export function corsHeaders(origin, allowed = WEBSITE_ORIGINS) {
  if (!origin || !allowed.includes(origin)) return {}
  return { 'Access-Control-Allow-Origin': origin, 'Access-Control-Expose-Headers': 'Content-Length', Vary: 'Origin' }
}

export function serve(gate, port, host = '0.0.0.0', allowed = WEBSITE_ORIGINS) {
  const server = createServer(async (request, response) => {
    const cors = corsHeaders(request.headers.origin, allowed)
    if (request.method === 'OPTIONS') {
      response.writeHead(Object.keys(cors).length ? 204 : 403, {
        ...cors,
        'Access-Control-Allow-Methods': 'GET, HEAD, PUT, DELETE',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type',
        'Access-Control-Max-Age': '600',
        'Cache-Control': 'no-store',
      })
      response.end()
      return
    }
    let answer
    try {
      const path = new URL(request.url ?? '/', 'http://local').pathname
      answer = await gate.respond({ method: request.method, path, headers: request.headers, body: request })
    } catch {
      answer = empty(503)
    }
    const { status, body } = answer
    // A body that wasn't read, like one sent without a sign-in, is never read: the connection closes.
    const unread = !request.complete
    const headers = unread ? { ...answer.headers, Connection: 'close' } : answer.headers
    if (unread) response.on('finish', () => request.destroy())
    response.writeHead(status, {
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      // A stored file is never a page: nothing in it can run, even opened on its own.
      'Content-Security-Policy': "default-src 'none'; sandbox",
      'Cross-Origin-Resource-Policy': 'same-site',
      ...cors,
      ...(Buffer.isBuffer(body) && { 'Content-Length': String(body.length) }),
      ...headers,
    })
    if (Buffer.isBuffer(body) || request.method === 'HEAD') {
      if (!Buffer.isBuffer(body)) body.destroy()
      response.end(request.method === 'HEAD' ? undefined : body)
    } else {
      body.on('error', () => response.destroy())
      response.on('close', () => body.destroy())
      body.pipe(response)
    }
  })
  // Four megabytes over a slow phone connection.
  server.requestTimeout = 2 * 60 * 1000
  server.listen(port, host)
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  serve(liveGate(), Number(process.env.PORT ?? 8080))
}
