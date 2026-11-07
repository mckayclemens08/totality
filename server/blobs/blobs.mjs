// The sealed blob store. Photos, and Reader files after them, keep their bytes here as files on this
// server's disk until the home server exists (issue 54). Every blob was sealed on a device with that
// person's content key, so nothing here can open one. The account always comes from the sign-in, never
// from the request, and each account has its own folder. Blob IDs are random and say nothing. Nothing
// here logs a request, an ID, or a size.
//
// Uploads come in pieces, because Cloudflare stops any one request at 100 MB, and a piece that's cut off
// is simply sent again: `HEAD` says how far the upload got. A blob is finished with its size and SHA-256,
// so a file that went wrong on the way never takes a real name, and a finished blob never changes.
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { link, lstat, mkdir, open, readdir, rm, statfs, unlink } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const GiB = 1024 ** 3
const MiB = 1024 ** 2
// Agreed in issue 54: 20 GB for the owner and 2 GB for anyone else, until the home server.
export const LARGE_LIMIT = 20 * GiB
export const LIMIT = 2 * GiB
// Well under Cloudflare's 100 MB, so a piece always fits through the tunnel.
export const MAX_PIECE = 32 * MiB
// Ten minutes of 4K video, sealed, with room to spare.
export const MAX_BLOB = 5 * GiB
// Whatever the limits add up to, uploads stop while the disk has less than this free, so mail and
// Matrix always have room.
export const DISK_FLOOR = 8 * GiB
// An upload nobody finished is cleared after a week. Until then it counts towards the limit.
export const UNFINISHED_DAYS = 7
// Uploads written at once, across every account. More wait at the device, which tries again.
export const AT_ONCE = 8
// Blobs and unfinished uploads one account can hold, whatever their size, so tiny files can't use up
// the disk's room for files.
export const MAX_FILES = 200_000

const DAY = 24 * 60 * 60 * 1000
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const SHA256 = /^[0-9a-f]{64}$/
const DONE = /^([0-9a-f-]{36})\.sealed$/
const PART = /^([0-9a-f-]{36})\.part$/
const TOKEN = /^Bearer ([A-Za-z0-9._-]{1,4096})$/

/** The account behind a sign-in, or null if it doesn't look like a Totality account. */
export function accountFrom(user) {
  const name = /^([a-z0-9_]{3,24})@totality\.invalid$/.exec(user?.email ?? '')?.[1]
  if (!name || !ID.test(user?.id ?? '')) return null
  return { name, id: user.id }
}

/** `bytes=a-b`, `bytes=a-`, or `bytes=-n` against a blob of `size`: `{ start, end }`, null for no range
 *  at all, or false for a range that can't be served. Only one range is taken. */
export function rangeOf(header, size) {
  if (header === undefined) return null
  const match = /^bytes=(\d{0,19})-(\d{0,19})$/.exec(header)
  if (!match || (match[1] === '' && match[2] === '') || size === 0) return false
  let start, end
  if (match[1] === '') {
    const suffix = Number(match[2])
    if (suffix === 0) return false
    start = Math.max(0, size - suffix)
    end = size - 1
  } else {
    start = Number(match[1])
    end = match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1)
  }
  return start <= end && start < size ? { start, end } : false
}

async function lstatIfThere(path) {
  try {
    return await lstat(path)
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

/** Everything the store keeps: one folder per account, named for its ID, holding finished blobs
 *  (`<id>.sealed`) and unfinished uploads (`<id>.part`). Every name is checked before it becomes part
 *  of a path, so nothing can reach outside its own folder. */
export class Blobs {
  constructor(root) {
    this.root = root
    // What each account uses, in bytes and files, worked out once and then kept up to date by every
    // change below.
    this.usage = new Map()
    this.counts = new Map()
    this.locks = new Map()
  }

  folder(account) {
    if (!ID.test(account)) throw new Error('not an account')
    return join(this.root, 'accounts', account)
  }

  file(account, id, ending) {
    if (!ID.test(id)) throw new Error('not a blob')
    return join(this.folder(account), `${id}.${ending}`)
  }

  /** Runs `work` alone for this account, so two uploads can't both fit the last of its space. */
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

  async entries(account) {
    try {
      return await readdir(this.folder(account))
    } catch (error) {
      if (error.code === 'ENOENT') return []
      throw error
    }
  }

  /** Bytes held for an account, finished or not. */
  async used(account) {
    if (this.usage.has(account)) return this.usage.get(account)
    let total = 0
    let count = 0
    for (const name of await this.entries(account)) {
      if (!DONE.test(name) && !PART.test(name)) continue
      const info = await lstatIfThere(join(this.folder(account), name))
      if (!info?.isFile()) continue
      total += info.size
      count += 1
    }
    this.usage.set(account, total)
    this.counts.set(account, count)
    return total
  }

  /** Files held for an account, finished or not. */
  async files(account) {
    if (!this.counts.has(account)) await this.used(account)
    return this.counts.get(account)
  }

  /** `{ done: size }`, `{ offset }` for an upload still coming in, or null. */
  async status(account, id) {
    const done = await lstatIfThere(this.file(account, id, 'sealed'))
    if (done?.isFile()) return { done: done.size }
    const part = await lstatIfThere(this.file(account, id, 'part'))
    if (part?.isFile()) return { offset: part.size }
    return null
  }

  /** Finished blobs, newest first: ID, size, and when it was finished. That's all the server knows. */
  async list(account) {
    const blobs = []
    for (const name of await this.entries(account)) {
      const id = DONE.exec(name)?.[1]
      if (!id || !ID.test(id)) continue
      const info = await lstatIfThere(join(this.folder(account), name))
      if (info?.isFile()) blobs.push({ id, size: info.size, mtime: info.mtimeMs })
      if (blobs.length >= MAX_FILES) break
    }
    blobs.sort((a, b) => b.mtime - a.mtime || (a.id < b.id ? -1 : 1))
    return blobs.map(({ id, size, mtime }) => ({ id, size, stored: new Date(mtime).toISOString() }))
  }

  /** Adds one piece at `offset`, which has to be exactly where the upload got to. `room(bytes)` says
   *  whether the account and the disk can take that many more. A piece that fails partway is taken back
   *  out, so the offset is always what really arrived. Returns `{ offset }` or `{ status }`. */
  async append(account, id, offset, piece, room) {
    const current = await this.status(account, id)
    if (current?.done !== undefined) return { status: 409, done: true }
    if ((current?.offset ?? 0) !== offset) return { status: 409, offset: current?.offset ?? 0 }
    // Counted before anything is written, so the piece below is added once.
    const before = await this.used(account)
    if (!current && (await this.files(account)) >= MAX_FILES) return { status: 507 }
    await mkdir(this.folder(account), { recursive: true, mode: 0o700 })
    const path = this.file(account, id, 'part')
    const file = await open(path, current ? 'r+' : 'wx', 0o600)
    let written = 0
    let failure = null
    try {
      for await (const chunk of piece) {
        if (written + chunk.length > MAX_PIECE) { failure = 413; break }
        if (offset + written + chunk.length > MAX_BLOB) { failure = 413; break }
        if (!room(written + chunk.length)) { failure = 507; break }
        let at = 0
        while (at < chunk.length) {
          const { bytesWritten } = await file.write(chunk, at, chunk.length - at, offset + written + at)
          at += bytesWritten
        }
        written += chunk.length
      }
      if (failure === null && written === 0) failure = 400
      if (failure === null) await file.sync()
    } catch {
      failure = 400
    }
    try {
      if (failure !== null) await file.truncate(offset)
    } finally {
      await file.close()
    }
    if (failure !== null) {
      if (offset === 0) await rm(path, { force: true })
      return { status: failure }
    }
    this.usage.set(account, before + written)
    if (!current) this.counts.set(account, (await this.files(account)) + 1)
    return { offset: offset + written }
  }

  /** Gives an upload its real name once its size and SHA-256 match what the device says it sent. A
   *  finished blob never changes, so asking again for the same one is a 409. */
  async finish(account, id, size, sha256) {
    const done = this.file(account, id, 'sealed')
    if ((await lstatIfThere(done))?.isFile()) return 409
    const path = this.file(account, id, 'part')
    const part = await lstatIfThere(path)
    if (!part?.isFile()) return 404
    if (part.size !== size || size === 0) return 400
    const hash = createHash('sha256')
    for await (const chunk of createReadStream(path)) hash.update(chunk)
    if (hash.digest('hex') !== sha256) return 400
    try {
      await link(path, done)
    } catch (error) {
      if (error.code === 'EEXIST') return 409
      throw error
    }
    await unlink(path)
    return 201
  }

  /** Removes a blob and any upload under its ID, and ignores what isn't there, so asking twice is
   *  harmless. Returns whether anything went. */
  async remove(account, id) {
    let freed = 0
    let gone = 0
    let removed = false
    for (const ending of ['sealed', 'part']) {
      const path = this.file(account, id, ending)
      const info = await lstatIfThere(path)
      if (!info) continue
      try {
        await unlink(path)
        removed = true
        gone += 1
        if (info.isFile()) freed += info.size
      } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
    }
    if (this.usage.has(account)) this.usage.set(account, Math.max(0, this.usage.get(account) - freed))
    if (this.counts.has(account)) this.counts.set(account, Math.max(0, this.counts.get(account) - gone))
    return removed
  }

  /** Clears uploads nobody finished within the week. */
  async sweep(now = Date.now()) {
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
          if (!PART.test(name)) continue
          const path = join(this.folder(account), name)
          const info = await lstatIfThere(path)
          if (info && now - info.mtimeMs > UNFINISHED_DAYS * DAY) {
            await rm(path, { force: true })
            cleared += 1
          }
        }
        this.usage.delete(account)
        this.counts.delete(account)
      })
    }
    return cleared
  }
}

/** Remembers good sign-ins for a minute, so a screen of thumbnails doesn't ask Supabase once for each.
 *  Only a hash of the token is kept, and only for accounts. */
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
 *  throws if it can't tell. `limitFor(account)` is the account's limit in bytes. `diskFree()` is the
 *  bytes left on the disk. */
export class BlobGate {
  constructor({ checkSignIn, blobs, limitFor, diskFree, floor = DISK_FLOOR }) {
    Object.assign(this, { checkSignIn, blobs, limitFor, diskFree, floor })
    this.working = 0
  }

  /** `request` is `{ method, path, headers, body }`, where `body` is the request itself, read only once
   *  the caller is proven. Returns `{ status, headers, body }`, where `body` is a Buffer or a stream. */
  async respond({ method, path, headers = {}, body }) {
    if (path === '/blobs/health') return method === 'GET' ? json(200, { ok: true }) : empty(405)
    const id = /^\/blobs\/([^/]*)$/.exec(path)?.[1]
    if (id === undefined) return empty(404)
    const named = id !== 'usage' && id !== 'list'
    if (named && !ID.test(id)) return empty(404)
    const allowed = named ? ['HEAD', 'GET', 'PATCH', 'POST', 'DELETE'] : ['GET']
    if (!allowed.includes(method)) return empty(405)

    const token = TOKEN.exec(headers.authorization ?? '')?.[1]
    if (!token) return empty(401)
    let account
    try {
      account = await this.checkSignIn(token)
    } catch {
      return empty(503)
    }
    if (!account || !ID.test(account.id)) return empty(401)
    const limit = this.limitFor(account)

    try {
      if (id === 'usage') {
        const used = await this.blobs.used(account.id)
        return json(200, { used, limit })
      }
      if (id === 'list') {
        const blobs = await this.blobs.list(account.id)
        return json(200, { blobs, used: await this.blobs.used(account.id), limit })
      }
      if (method === 'HEAD') return await this.head(account, id)
      if (method === 'GET') return await this.download(account, id, headers.range)
      if (method === 'DELETE') {
        await this.blobs.alone(account.id, () => this.blobs.remove(account.id, id))
        return empty(204)
      }
      if (method === 'PATCH') return await this.holding(() => this.upload(account, id, limit, headers, body))
      return await this.finishing(account, id, body)
    } catch {
      return empty(503)
    }
  }

  async holding(work) {
    if (this.working >= AT_ONCE) return empty(503)
    this.working += 1
    try {
      return await work()
    } finally {
      this.working -= 1
    }
  }

  async head(account, id) {
    const status = await this.blobs.status(account.id, id)
    if (!status) return empty(404)
    if (status.done !== undefined) return empty(200, { 'Blob-Size': String(status.done), 'Blob-State': 'done' })
    return empty(200, { 'Upload-Offset': String(status.offset), 'Blob-State': 'uploading' })
  }

  async download(account, id, rangeHeader) {
    const path = this.blobs.file(account.id, id, 'sealed')
    let file
    try {
      file = await open(path, 'r')
    } catch (error) {
      if (error.code === 'ENOENT') return empty(404)
      throw error
    }
    const { size } = await file.stat()
    const range = rangeOf(rangeHeader, size)
    if (range === false) {
      await file.close()
      return empty(416, { 'Content-Range': `bytes */${size}` })
    }
    const { start, end } = range ?? { start: 0, end: size - 1 }
    const length = size === 0 ? 0 : end - start + 1
    const stream = length === 0 ? null : file.createReadStream({ start, end, autoClose: true })
    if (!stream) await file.close()
    return {
      status: range ? 206 : 200,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': String(length),
        'Accept-Ranges': 'bytes',
        ...(range && { 'Content-Range': `bytes ${start}-${end}/${size}` }),
      },
      body: stream ?? Buffer.alloc(0),
    }
  }

  async upload(account, id, limit, headers, body) {
    const offsetText = headers['upload-offset']
    if (typeof offsetText !== 'string' || !/^\d{1,13}$/.test(offsetText)) return empty(400)
    const offset = Number(offsetText)
    const declared = headers['content-length']
    if (declared !== undefined && Number(declared) > MAX_PIECE) return empty(413, { Connection: 'close' })
    return this.blobs.alone(account.id, async () => {
      const used = await this.blobs.used(account.id)
      const free = await this.diskFree()
      const room = (more) => used + more <= limit && free - more >= this.floor
      // Asked before anything is read, so a full account or disk costs no upload at all.
      if (!room(Math.min(Number(declared ?? 1) || 1, MAX_PIECE))) return empty(507, { Connection: 'close' })
      const result = await this.blobs.append(account.id, id, offset, body, room)
      if (result.done) return empty(409, { 'Blob-State': 'done' })
      if (result.status === 409) return empty(409, { 'Upload-Offset': String(result.offset) })
      if (result.status) return empty(result.status, { Connection: 'close' })
      return empty(204, { 'Upload-Offset': String(result.offset) })
    })
  }

  async finishing(account, id, body) {
    const text = await readBody(body, 1_024)
    if (!text) return empty(413)
    let request
    try {
      request = JSON.parse(text)
    } catch {
      return empty(400)
    }
    const { size, sha256 } = request ?? {}
    if (!Number.isSafeInteger(size) || size < 1 || typeof sha256 !== 'string' || !SHA256.test(sha256)) return empty(400)
    const status = await this.blobs.alone(account.id, () => this.blobs.finish(account.id, id, size, sha256))
    return empty(status)
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

function empty(status, headers = {}) {
  return { status, headers, body: Buffer.alloc(0) }
}

function liveGate() {
  const supabase = process.env.SUPABASE_URL.replace(/\/+$/, '')
  const publicKey = process.env.SUPABASE_ANON_KEY
  const root = process.env.BLOB_ROOT ?? '/var/lib/totality-blobs'
  // Usernames, set in .env on the server, that get the larger limit.
  const large = new Set((process.env.BLOB_LARGE_ACCOUNTS ?? '').split(',').map((name) => name.trim()).filter(Boolean))

  async function checkSignIn(token) {
    const reply = await fetch(`${supabase}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: publicKey },
      signal: AbortSignal.timeout(6_000),
    })
    if (reply.status >= 400 && reply.status < 500) return null
    if (!reply.ok) throw new Error('sign-in check failed')
    return accountFrom(await reply.json())
  }

  const blobs = new Blobs(root)
  const sweep = () => blobs.sweep().catch(() => {})
  sweep()
  setInterval(sweep, 6 * 60 * 60 * 1000).unref()

  return new BlobGate({
    checkSignIn: rememberingSignIns(checkSignIn),
    blobs,
    limitFor: (account) => (large.has(account.name) ? LARGE_LIMIT : LIMIT),
    diskFree: async () => {
      const disk = await statfs(root)
      return disk.bavail * disk.bsize
    },
  })
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
    const { status, body } = answer
    // A body that wasn't read, like one sent without a sign-in, is never read: the connection closes.
    const unread = !request.complete
    const headers = unread ? { ...answer.headers, Connection: 'close' } : answer.headers
    if (unread) response.on('finish', () => request.destroy())
    response.writeHead(status, {
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
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
  // A 32 MiB piece over a slow phone connection.
  server.requestTimeout = 10 * 60 * 1000
  server.listen(port, host)
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  serve(liveGate(), Number(process.env.PORT ?? 8080))
}

