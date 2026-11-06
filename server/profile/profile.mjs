// Public profile pages at usetotality.com/@username. A page exists only after its owner pressed Share in
// the app. The device asks for its page to be published, and this server reads the profile with that
// device's own sign-in, so it holds nothing it couldn't read anyway and can't be told what to say. The
// username always comes from the account, never from the request. Only the name, photo, and bio are kept,
// all of which are public already. Nothing here logs a request.
import { createHash } from 'node:crypto'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const USERNAME = /^[a-z0-9_]{3,24}$/
const ACCOUNT = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
// The database stops longer ones, and this stops a stored file that somehow isn't.
const MAX_NAME = 50
const MAX_BIO = 160

/** The account behind a sign-in: its username and ID, or null. */
export function accountFrom(user) {
  const name = /^([a-z0-9_]{3,24})@totality\.invalid$/.exec(user?.email ?? '')?.[1]
  if (!name || !ACCOUNT.test(user?.id ?? '')) return null
  return { name, id: user.id }
}

/** What's kept from a profile row: text cut to the database's limits, and a photo only from the owner's
 *  own folder, so a page can never point anywhere else. */
export function cardFrom(row, account) {
  // A profile kept to contacts, or hidden, never gets a public page.
  if (!row || row.handle?.toLowerCase() !== account.name || row.visibility !== 'public') return null
  const text = (value, limit) => (typeof value === 'string' && value.trim() ? [...value.trim()].slice(0, limit).join('') : null)
  const photo = typeof row.avatar_key === 'string' && new RegExp(`^${account.id}/[0-9a-f-]{36}\\.jpg$`).test(row.avatar_key)
    ? row.avatar_key : null
  return { name: text(row.display_name, MAX_NAME), bio: text(row.bio, MAX_BIO), photo }
}

const escapes = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }
export const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => escapes[c])

// The palette follows Sources/TotalityUI/Tokens.swift: pale surfaces, dark grey text, one accent.
export const STYLE = `
:root{--bg:#E8EBEF;--surface:#EDEFF2;--text:#15181D;--text2:#555C68;--accent:#1F5FBF;--light:#FFFFFF;--shade:#C3C9D3}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px;
background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{width:100%;max-width:380px;padding:40px 28px;border-radius:28px;background:var(--surface);text-align:center;
box-shadow:-8px -8px 18px var(--light),8px 8px 18px var(--shade)}
.photo{width:120px;height:120px;border-radius:50%;object-fit:cover;display:block;margin:0 auto 20px;
box-shadow:-5px -5px 12px var(--light),5px 5px 12px var(--shade)}
.blank{display:flex;align-items:center;justify-content:center;font-size:44px;color:var(--text2);background:var(--surface)}
h1{margin:0;font-size:26px;font-weight:700;overflow-wrap:anywhere}
.handle{margin:4px 0 0;color:var(--text2)}
.bio{margin:20px 0 0;white-space:pre-line;overflow-wrap:anywhere}
.open{display:inline-block;margin-top:28px;padding:14px 26px;border-radius:999px;color:var(--accent);
font-weight:600;text-decoration:none;background:var(--surface);box-shadow:-5px -5px 12px var(--light),5px 5px 12px var(--shade)}
.note{margin:22px 0 0;font-size:14px;color:var(--text2)}`

const styleHash = createHash('sha256').update(STYLE).digest('base64')

/** The headers every page gets: no scripts at all, the one style above, and photos only from `photoOrigin`. */
export function pageHeaders(photoOrigin) {
  return {
    'Content-Security-Policy': `default-src 'none'; style-src 'sha256-${styleHash}'; img-src ${photoOrigin}; ` +
      `base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
  }
}

function page(title, inner) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">` +
    `<title>${escapeHTML(title)}</title><style>${STYLE}</style></head><body><main>${inner}</main></body></html>`
}

/** The page for one card. Every piece of it that a person typed is escaped. */
export function profilePage(username, card, photoBase) {
  const shown = card.name ?? `@${username}`
  const photo = card.photo
    ? `<img class="photo" src="${escapeHTML(`${photoBase}/${card.photo}`)}" alt="">`
    : `<div class="photo blank" aria-hidden="true">&#9679;</div>`
  return page(`${shown} on Totality`,
    photo +
    `<h1>${escapeHTML(shown)}</h1>` +
    (card.name ? `<p class="handle">@${escapeHTML(username)}</p>` : '') +
    (card.bio ? `<p class="bio">${escapeHTML(card.bio)}</p>` : '') +
    `<a class="open" href="totality://profile/${escapeHTML(username)}">Open in Totality</a>` +
    `<p class="note">${escapeHTML(shown)} is on Totality.</p>`)
}

export const missingPage = () => page('Not on the web', '<h1>No page here</h1>' +
  `<p class="bio">Either nobody has this username, or they haven't shared their profile on the web.</p>`)

/** Cards on disk, one file per username, written whole or not at all. */
export class Cards {
  constructor(root) { this.root = root }
  path(username) { return join(this.root, `${username}.json`) }

  async read(username) {
    try {
      const card = JSON.parse(await readFile(this.path(username), 'utf8'))
      return card && typeof card === 'object' ? card : null
    } catch { return null }
  }

  async write(username, card) {
    await mkdir(this.root, { recursive: true })
    const temporary = `${this.path(username)}.${process.pid}.${Date.now()}.tmp`
    await writeFile(temporary, JSON.stringify(card), { mode: 0o600 })
    await rename(temporary, this.path(username))
  }

  async remove(username) { await rm(this.path(username), { force: true }) }
}

/** No sockets in here, so every rule can be tested. `checkSignIn(token)` returns an account or null and
 *  throws if it can't tell. `readProfile(token, account)` returns the row the owner's sign-in can read. */
export class Profiles {
  constructor({ checkSignIn, readProfile, cards, photoBase, photoOrigin }) {
    Object.assign(this, { checkSignIn, readProfile, cards, photoBase, photoOrigin })
  }

  async respond(method, url, authorization) {
    const path = new URL(url ?? '/', 'http://local').pathname
    if (path === '/profile/health') return json(200, { ok: true })

    const shown = /^\/@([A-Za-z0-9_]{3,24})$/.exec(path)
    if (shown) {
      if (method !== 'GET' && method !== 'HEAD') return json(405, { error: 'method' })
      const username = shown[1].toLowerCase()
      const card = USERNAME.test(username) ? await this.cards.read(username) : null
      const body = Buffer.from(card ? profilePage(username, card, this.photoBase) : missingPage())
      return { status: card ? 200 : 404, body, type: 'text/html; charset=utf-8', headers: pageHeaders(this.photoOrigin), cache: card ? 'public, max-age=60' : 'no-store' }
    }

    const action = /^\/profile\/(publish|unpublish|mine)$/.exec(path)?.[1]
    if (!action) return json(404, { error: 'not found' })
    if (method !== (action === 'mine' ? 'GET' : 'POST')) return json(405, { error: 'method' })

    const token = /^Bearer ([A-Za-z0-9._-]{1,4096})$/.exec(authorization ?? '')?.[1]
    if (!token) return json(401, { error: 'sign in' })
    let account
    try { account = await this.checkSignIn(token) } catch { return json(503, { error: 'busy' }) }
    if (!account) return json(401, { error: 'sign in' })

    if (action === 'mine') return json(200, { published: (await this.cards.read(account.name)) !== null })
    if (action === 'unpublish') {
      await this.cards.remove(account.name)
      return json(200, { published: false })
    }
    let row
    try { row = await this.readProfile(token, account) } catch { return json(503, { error: 'busy' }) }
    const card = cardFrom(row, account)
    if (!card) return json(409, { error: 'no profile' })
    await this.cards.write(account.name, card)
    return json(200, { published: true })
  }
}

function json(status, value) {
  return { status, body: Buffer.from(JSON.stringify(value)), type: 'application/json', cache: 'no-store' }
}

function liveProfiles() {
  const supabase = process.env.SUPABASE_URL.replace(/\/+$/, '')
  const publicKey = process.env.SUPABASE_ANON_KEY
  const headers = (token) => ({ Authorization: `Bearer ${token}`, apikey: publicKey })

  async function checkSignIn(token) {
    const reply = await fetch(`${supabase}/auth/v1/user`, { headers: headers(token), signal: AbortSignal.timeout(6_000) })
    if (reply.status >= 400 && reply.status < 500) return null
    if (!reply.ok) throw new Error('sign-in check failed')
    return accountFrom(await reply.json())
  }

  // The owner's own sign-in reads the row, so the database's rules decide what this server can see.
  async function readProfile(token, account) {
    const query = `select=handle,display_name,bio,avatar_key,visibility&id=eq.${account.id}`
    const reply = await fetch(`${supabase}/rest/v1/profiles?${query}`, { headers: headers(token), signal: AbortSignal.timeout(6_000) })
    if (!reply.ok) throw new Error('profile read failed')
    const rows = await reply.json()
    return Array.isArray(rows) ? rows[0] ?? null : null
  }

  return new Profiles({
    checkSignIn, readProfile,
    cards: new Cards(process.env.PROFILE_ROOT ?? '/var/lib/totality-profiles'),
    photoBase: `${supabase}/storage/v1/object/public/avatars`,
    photoOrigin: new URL(supabase).origin,
  })
}

export function serve(profiles, port) {
  const server = createServer(async (request, response) => {
    // Nothing is read from a request body, so nothing is accepted in one.
    request.resume()
    const { status, body, type, headers = {}, cache } = await profiles.respond(request.method, request.url, request.headers.authorization)
    response.writeHead(status, {
      'Content-Length': body.length, 'Content-Type': type, 'Cache-Control': cache,
      'X-Content-Type-Options': 'nosniff', ...headers,
    })
    response.end(request.method === 'HEAD' ? undefined : body)
  })
  server.requestTimeout = 20_000
  server.listen(port, '0.0.0.0')
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  serve(liveProfiles(), Number(process.env.PORT ?? 8080))
}
