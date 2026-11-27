// The Matrix guard: Messages' "Who can message me" (issue 149 §4, step 8), enforced where a modified app
// can't skip it. Every Matrix client request from the tunnel passes through here on its way to Tuwunel.
// Almost all of it is passed on untouched. Anything that could invite someone is held first:
//
//   POST .../rooms/{room}/invite                  the invite itself
//   POST .../createRoom                           with people in `invite`
//   PUT  .../rooms/{room}/state/m.room.member/{u} with membership "invite"
//
// For those the guard asks Tuwunel who is signed in (whoami), then asks Supabase's message-gate function
// whether that person may invite each one. Only if every answer is yes does the request reach Tuwunel, as
// the exact JSON that was checked. Invites by email (3pid), member events in a new room's initial state, and
// anyone outside this server are refused outright. If the gate can't be reached, nothing is invited.
// Federation is off, so the Matrix client API is the only way an invite can be made.
//
// A broadcast channel is recognised by its power levels, which the app can't change without the channel
// stopping being one: posting needs level 50 or more (events_default). Everyone invited to a channel must
// follow the person inviting them, as well as pass "who can message me", so a channel can't be used to reach
// people who never chose to hear from the inviter. The gate is asked with channel: true.
//
// Message content never passes the guard's checks: an invite carries none, and messages themselves are
// end-to-end encrypted and streamed straight through. Nothing here logs a request, a token or a name.
import { createServer, request as httpRequest } from 'node:http'
import { pathToFileURL } from 'node:url'

export const MAX_BODY = 256 * 1024
const HANDLE = /^[a-z0-9_]{3,24}$/
const HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer', 'host', 'content-length'])
/// What a room's events_default must reach for it to be a broadcast channel. Matches ChannelPower.post in the app.
export const CHANNEL_POST_LEVEL = 50
const MEMBERSHIPS_WITHOUT_INVITE = new Set(['join', 'leave', 'ban', 'knock'])

export class Refusal extends Error {
  constructor(status, errcode, message) {
    super(message)
    this.status = status
    this.errcode = errcode
  }
}

/// What a request could do, from its path alone. The path is decoded one segment at a time, as Tuwunel
/// reads it, and a path that would decode differently there is refused.
export function classify(method, url) {
  const raw = url.split('?')[0]
  if (!raw.startsWith('/_matrix/client/')) return { gated: false }
  const segments = raw.split('/').map((s) => {
    let decoded
    try { decoded = decodeURIComponent(s) } catch { throw new Refusal(400, 'M_UNRECOGNIZED', 'Unreadable path.') }
    if (decoded.includes('/') || decoded === '.' || decoded === '..') throw new Refusal(400, 'M_UNRECOGNIZED', 'Unreadable path.')
    return decoded
  })
  const lower = segments.map((s) => s.toLowerCase())
  const createRoom = lower.includes('createroom')
  const invite = lower.includes('invite')
  const stateAt = lower.findIndex((s, i) => s === 'state' && lower[i + 1] === 'm.room.member')
  const member = stateAt >= 0
  if (!createRoom && !invite && !member) return { gated: false }
  if (['GET', 'HEAD', 'OPTIONS'].includes(method)) return { gated: false }
  if (method !== 'POST' && method !== 'PUT') throw new Refusal(405, 'M_UNRECOGNIZED', 'Method not allowed.')
  const roomAt = lower.indexOf('rooms')
  const room = roomAt >= 0 ? (segments[roomAt + 1] ?? null) : null
  return { gated: true, createRoom, invite, member, room, stateKey: member ? (segments[stateAt + 2] ?? '') : null }
}

const postsNeedLevel = (levels) =>
  levels !== null && typeof levels === 'object' && Number(levels.events_default) >= CHANNEL_POST_LEVEL

/// Whether a new room's own settings make it a channel: the power levels it asks for, either way they can be given.
export function createsChannel(body) {
  if (postsNeedLevel(body.power_level_content_override)) return true
  return Array.isArray(body.initial_state) && body.initial_state.some((e) => e.type === 'm.room.power_levels' && postsNeedLevel(e.content))
}

/// The usernames this body would invite. Throws a Refusal for anything that may never be sent.
export function invitees(kind, body, serverName) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) throw new Refusal(400, 'M_NOT_JSON', 'Expected a JSON object.')
  const ids = []
  if (kind.invite) {
    if ('id_server' in body || 'medium' in body || 'address' in body) throw new Refusal(403, 'M_FORBIDDEN', 'Invites by email are off.')
    ids.push(body.user_id)
  }
  if (kind.createRoom) {
    if (Array.isArray(body.invite_3pid) ? body.invite_3pid.length > 0 : body.invite_3pid !== undefined) {
      throw new Refusal(403, 'M_FORBIDDEN', 'Invites by email are off.')
    }
    if (body.initial_state !== undefined) {
      if (!Array.isArray(body.initial_state)) throw new Refusal(400, 'M_BAD_JSON', 'initial_state must be a list.')
      if (body.initial_state.some((e) => !e || typeof e !== 'object' || e.type === 'm.room.member')) {
        throw new Refusal(403, 'M_FORBIDDEN', 'Members join by invite.')
      }
    }
    if (body.invite !== undefined) {
      if (!Array.isArray(body.invite)) throw new Refusal(400, 'M_BAD_JSON', 'invite must be a list.')
      ids.push(...body.invite)
    }
  }
  if (kind.member) {
    if (body.membership === 'invite') ids.push(kind.stateKey)
    else if (!MEMBERSHIPS_WITHOUT_INVITE.has(body.membership)) throw new Refusal(403, 'M_FORBIDDEN', 'Unknown membership.')
  }
  const names = new Set()
  for (const id of ids) {
    const name = localpart(id, serverName)
    if (!name) throw new Refusal(403, 'M_FORBIDDEN', 'Only Totality usernames can be invited.')
    names.add(name)
  }
  return [...names]
}

export function localpart(id, serverName) {
  if (typeof id !== 'string' || !id.startsWith('@')) return null
  const at = id.indexOf(':')
  if (at < 0 || id.slice(at + 1) !== serverName) return null
  const name = id.slice(1, at)
  return HANDLE.test(name) ? name : null
}

function matrixError(res, status, errcode, error) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
  res.end(JSON.stringify({ errcode, error }))
}

function forwardHeaders(headers) {
  const out = {}
  for (const [k, v] of Object.entries(headers)) if (!HOP.has(k)) out[k] = v
  return out
}

/// Asks Supabase's message-gate function. Answers { name: true|false } or throws.
export function liveGate({ url, secret, fetcher = fetch, timeoutMs = 8_000 }) {
  return async (sender, recipients, channel = false) => {
    const answer = await fetcher(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Gate-Secret': secret },
      body: JSON.stringify(channel ? { sender, recipients, channel: true } : { sender, recipients }),
      signal: AbortSignal.timeout(timeoutMs),
    })
    if (!answer.ok) throw new Error('gate refused')
    const { allowed } = await answer.json()
    if (!allowed || typeof allowed !== 'object') throw new Error('gate unreadable')
    return allowed
  }
}

export function guard({ upstream, serverName, gate }) {
  const target = new URL(upstream)

  function pass(req, res, body) {
    const headers = forwardHeaders(req.headers)
    if (body !== undefined) {
      delete headers['content-encoding']
      headers['content-type'] = 'application/json'
      headers['content-length'] = Buffer.byteLength(body)
    } else if (req.headers['content-length'] !== undefined) {
      headers['content-length'] = req.headers['content-length']
    } else if (req.headers['transfer-encoding']) {
      headers['transfer-encoding'] = 'chunked'
    }
    const out = httpRequest({ host: target.hostname, port: target.port, method: req.method, path: req.url, headers }, (up) => {
      res.writeHead(up.statusCode ?? 502, forwardHeaders(up.headers))
      up.pipe(res)
    })
    out.on('error', () => { if (!res.headersSent) matrixError(res, 502, 'M_UNKNOWN', 'The Matrix server is unreachable.'); else res.destroy() })
    req.on('aborted', () => out.destroy())
    if (body !== undefined) out.end(body)
    else req.pipe(out)
  }

  /// Whether an existing room is a channel, from its power levels as the sender sees them. A room the sender
  /// can't read, or one without power levels, isn't one: Tuwunel refuses an invite from outside the room anyway.
  async function roomIsChannel(req, room) {
    if (!room) return false
    const query = new URLSearchParams(req.url.split('?')[1] ?? '')
    const token = query.get('access_token')
    const path = `/_matrix/client/v3/rooms/${encodeURIComponent(room)}/state/m.room.power_levels` + (token ? `?access_token=${encodeURIComponent(token)}` : '')
    const headers = {}
    if (req.headers.authorization) headers.authorization = req.headers.authorization
    const answer = await fetch(new URL(path, target), { headers, signal: AbortSignal.timeout(8_000) })
    if (answer.status === 404 || answer.status === 403) return false
    if (!answer.ok) throw new Error('power levels unreadable')
    return postsNeedLevel(await answer.json())
  }

  async function whoami(req) {
    const query = new URLSearchParams(req.url.split('?')[1] ?? '')
    const token = query.get('access_token')
    const path = '/_matrix/client/v3/account/whoami' + (token ? `?access_token=${encodeURIComponent(token)}` : '')
    const headers = {}
    if (req.headers.authorization) headers.authorization = req.headers.authorization
    const answer = await fetch(new URL(path, target), { headers, signal: AbortSignal.timeout(8_000) })
    const text = await answer.text()
    if (!answer.ok) return { status: answer.status, text }
    return { user: JSON.parse(text).user_id }
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = []
      let size = 0
      req.on('data', (c) => {
        size += c.length
        if (size > MAX_BODY) { reject(new Refusal(413, 'M_TOO_LARGE', 'Too large.')); req.destroy() } else chunks.push(c)
      })
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
      req.on('error', reject)
    })
  }

  async function gated(req, res, kind) {
    const encoding = (req.headers['content-encoding'] ?? 'identity').toLowerCase()
    if (encoding !== 'identity') throw new Refusal(415, 'M_UNRECOGNIZED', 'Send this uncompressed.')
    const text = await readBody(req)
    let body
    try { body = JSON.parse(text) } catch { throw new Refusal(400, 'M_NOT_JSON', 'Expected JSON.') }
    const names = invitees(kind, body, serverName)
    // The body Tuwunel gets is the one checked, written out again, so no trick in the original survives.
    const checked = JSON.stringify(body)
    if (names.length === 0) return pass(req, res, checked)
    const who = await whoami(req)
    if (who.status) {
      res.writeHead(who.status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
      return res.end(who.text)
    }
    const sender = localpart(who.user, serverName)
    if (!sender) throw new Refusal(403, 'M_FORBIDDEN', 'Only Totality accounts can invite.')
    let channel
    try {
      channel = kind.createRoom ? createsChannel(body) : await roomIsChannel(req, kind.room)
    } catch { throw new Refusal(503, 'M_UNKNOWN', 'Try again in a moment.') }
    let allowed
    try { allowed = await gate(sender, names, channel) } catch { throw new Refusal(503, 'M_UNKNOWN', 'Try again in a moment.') }
    if (!names.every((n) => allowed[n] === true)) {
      throw new Refusal(403, 'M_FORBIDDEN', channel
        ? 'You can only invite people who follow you to a channel.'
        : 'Who can message them does not include you. Send a message request.')
    }
    pass(req, res, checked)
  }

  return async (req, res) => {
    try {
      const kind = classify(req.method, req.url)
      if (!kind.gated) return pass(req, res)
      await gated(req, res, kind)
    } catch (error) {
      if (res.headersSent) return res.destroy()
      if (error instanceof Refusal) return matrixError(res, error.status, error.errcode, error.message)
      matrixError(res, 500, 'M_UNKNOWN', 'Something went wrong.')
    }
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const { SUPABASE_URL, MESSAGE_GATE_SECRET, UPSTREAM = 'http://tuwunel:8008', SERVER_NAME = 'usetotality.com' } = process.env
  if (!SUPABASE_URL || !MESSAGE_GATE_SECRET || MESSAGE_GATE_SECRET.length < 32) {
    throw new Error('SUPABASE_URL and MESSAGE_GATE_SECRET (32+ characters) are needed')
  }
  const gate = liveGate({ url: `${SUPABASE_URL}/functions/v1/message-gate`, secret: MESSAGE_GATE_SECRET })
  const handler = guard({ upstream: UPSTREAM, serverName: SERVER_NAME, gate })
  createServer((req, res) => {
    if (req.url === '/guard/health') { res.writeHead(200); return res.end('ok') }
    handler(req, res)
  }).listen(Number(process.env.PORT ?? 8080))
}
