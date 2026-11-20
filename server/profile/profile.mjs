// Totality's homepage and privacy policy at usetotality.com/ and /privacy, both fixed text. And public
// profile pages at usetotality.com/@username. A page exists only after its owner pressed Share in
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
.note{margin:22px 0 0;font-size:14px;color:var(--text2)}
main.doc{max-width:680px;text-align:left;padding:36px 28px}
.doc h1{font-size:28px}.doc h2{margin:30px 0 8px;font-size:19px}
.doc p,.doc li{margin:8px 0;color:var(--text)}.doc ul{padding-left:22px;margin:8px 0}
.doc a{color:var(--accent)}.doc .lead{color:var(--text2);margin-top:10px}`

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

function page(title, inner, { kind = '', indexed = false } = {}) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">${indexed ? '' : '<meta name="robots" content="noindex">'}` +
    `<title>${escapeHTML(title)}</title><style>${STYLE}</style></head><body><main${kind ? ` class="${kind}"` : ''}>${inner}</main></body></html>`
}

/** usetotality.com itself. Fixed text, nothing from a request. */
export const homePage = () => page('Totality', `<h1>Totality</h1>
<p class="lead">One app for iPhone, with a website beside it: reading and listening, a calendar, mail, messages, photos, and social.</p>
<p>What you keep privately in Totality is sealed on your own device before it goes anywhere, with a key only your devices hold. Messages are end-to-end encrypted. Social posts you share with Everyone are public. Every account gets its own address at usetotality.com, and you can add Gmail or iCloud beside it.</p>
<p>Totality is in early testing and isn't in the App Store yet.</p>
<p><a href="/privacy">Privacy policy</a></p>`, { kind: 'doc', indexed: true })

/** What Totality keeps and where. Every line has to be literally true of the code. */
export const privacyPage = () => page('Totality privacy policy', `<h1>Privacy policy</h1>
<p class="lead">Last updated 19 November 2026. This covers the Totality app, the website at app.usetotality.com, and Totality's servers at usetotality.com.</p>

<h2>The short version</h2>
<ul>
<li>Your private content is encrypted on your device before it's uploaded. Totality's servers hold it sealed and can't read it.</li>
<li>Social posts you share with Everyone are public. They're stored readable on Totality's server, so other people can see them and For You can rank them. Friends and Close-friends posts are end-to-end encrypted.</li>
<li>There are no ads, no analytics, and no tracking, and nothing is sold or shared for marketing.</li>
<li>Gmail, iCloud, and the Google services you connect are reached from your device straight to Google or Apple. Totality's servers never see that mail. Anything else from them that syncs, your sign-in included, reaches the servers only sealed, where they can't read it.</li>
</ul>

<h2>Your account</h2>
<p>An account is a username and a password. Totality doesn't ask for an email address or a phone number. Your password goes over HTTPS only to the account server, which keeps a one-way hash of it. The app never stores it, and it's never used to encrypt anything.</p>
<p>The account server also keeps your profile (your username, and the name, bio, and photo you choose to add), the people you've added or blocked, and the devices and browsers you've signed in on, with a name like "Safari on Mac" and when each was last used. Other people signed in to Totality can see your username, name, bio, and photo, so they can find you. Your profile photo isn't encrypted, and anyone who has its link can open it.</p>

<h2>What you keep in Totality</h2>
<p>Private things like Reader documents, calendar events, tasks, bookmarks, photos, and mail settings are encrypted on your device before upload. The servers keep the sealed copy and what's needed to sync it: an ID, which kind of thing it is, which account it belongs to, its size, and when it changed. The keys stay on your devices. A backup of them is kept on the server, sealed with a recovery key that only you have.</p>

<h2>Social</h2>
<p>When you post in Social, you choose who it's for: Everyone, Friends (people you follow who follow you back), or Close friends (a list you choose).</p>
<p>Everyone posts are public. They're stored on Totality's server as readable text, not encrypted, so that other people can see them, For You can rank them, and search can find them. The same goes for their tags, the likes and comments on them, and who made each one. Anyone signed in to Totality can see them, unless one of you has blocked the other. If you make your account private, only followers you approve can see your posts. Who you follow and who follows you can also be seen by people signed in to Totality. Public posts aren't on the open web: you need a Totality account to see them.</p>
<p>Friends and Close-friends posts, and the likes and comments on them, go through Totality's Matrix server in end-to-end encrypted rooms, so the server can't read them. It does know who is in each room and when something is posted, because it has to deliver it. It can't tell a Friends room from a Close-friends one.</p>
<p>Your Social settings, such as whether your account is private and who can comment on your posts, can be read by people signed in to Totality, because they decide what others can do on your posts. They hold choices, not content.</p>

<h2>For You</h2>
<p>For You is Totality's own ranking. It looks only at public posts from the last 30 days, and only at what happens inside Social: how new a post is, how many likes and comments it has, whether people you follow follow its author, the tags of posts you've liked, and the tags of posts you said Not interested to. It never shows you your own posts or people you've muted, and each post in it says why it's there. Friends and Close-friends posts are never used for ranking.</p>
<p>To work, For You remembers which posts it has already shown you and which you said Not interested to. That list, the posts you save, and the people you mute are stored on the server unencrypted. Only you can see them in Totality, and nobody else is told.</p>

<h2>Blocking, muting, and reports</h2>
<p>Blocking works across Totality: neither of you sees the other's posts, likes, comments, or follows, it covers Messages too, and they aren't told. Muting hides someone's posts from your feeds without telling them.</p>
<p>You can report a person, a post, or a comment. A report holds who sent it, who it's about, the public post or comment it's about if there is one, the reason you picked, and when. Reports are stored readable on the server and go to Totality's moderator, who for now is the person who runs Totality. The person you report can't see your report. Friends and Close-friends posts are end-to-end encrypted, so a report about one gives the moderator only the person and the reason, never the post. Nothing deletes reports on a timer: each one is kept until the moderator deletes it.</p>

<h2>Keeping and deleting Social posts</h2>
<p>Your posts, comments, likes, and follows are kept until you delete them. Deleting a public post removes it from Totality's database right away, along with its likes and comments. You can delete your own comments, and any comment on your own posts. A report about a post you delete still says who it was about and why, but no longer points to the post. Totality doesn't keep separate backups of its database, so a deleted post is gone from it at once.</p>
<p>Deleting a Friends or Close-friends post tells everyone in that room to remove it, and their apps stop showing it. The encrypted copy stays on the Matrix server, which can't read it, and anyone who already saw the post may have kept a copy.</p>
<h2>Deleting your account, and contact</h2>
<p>The app can't delete a whole account yet. Until it can, email mckay_clemens@usetotality.com, from Totality Mail or from anywhere else, to have your account and its data deleted, or with any question about privacy.</p>

<h2>Messages</h2>
<p>Messages, the photos and videos sent in them, group chats, and shared task lists go through Totality's Matrix server and are end-to-end encrypted, so the server can't read them. It does know which accounts are in a conversation and when messages are sent, because it has to deliver them.</p>

<h2>Totality Mail</h2>
<p>Every account has an address at usetotality.com. Mail between Totality accounts is sealed end to end. Mail from outside Totality arrives readable, as all email does. The mail server checks it for spam and holds it in memory for a moment, then seals it to your key before it's written anywhere. Mail you send to an outside address has to reach the other side readable, so it passes through Cloudflare's email service unsealed. Neither step keeps a log of the mail.</p>

<h2>Gmail and iCloud</h2>
<p>When you add a Gmail or iCloud account, your device connects to it directly. Gmail uses Google sign-in, and iCloud uses an app-specific password. The sign-in is kept in your device's Keychain. So the account works on your other devices too, a copy of the sign-in syncs sealed with your key, which Totality's servers can't open. Mail downloaded from these accounts is stored encrypted on that device only, and isn't uploaded to Totality's servers.</p>
<p>From the device, Totality reads your mail and labels or folders so they show in the app. It also sends back the changes you make in the app: read or unread, starred, archived, spam, and moving to Trash. It never deletes mail for good there. It only sends mail from these accounts after you turn on sending for that account, and then only each message you send. When you remove an account, its mail and sign-in are deleted from your devices, and Totality's access is withdrawn at Google. That also ends that Google account's connection to Calendar, Photos, and Drive in Totality.</p>

<h2>Google Calendar, Google Photos, and Google Drive</h2>
<p>These connect from your device straight to Google, with the same Google sign-in. Totality's servers get only sealed copies of what you bring in from them, and can't read those. Google Calendar events are read on each device and kept there encrypted, and you can add, change, or delete events on calendars you own. From Google Photos, Totality gets only the photos and videos you pick, and they're added to your library like any other photo, encrypted before upload. For Google Drive, Totality asks for full Drive access so you can link folders of your choice and open, edit, and import their files. It shows only the folders you link. The list of linked folders syncs sealed, and a file you import becomes an encrypted Reader file like any other.</p>
<p>Totality's use and transfer of information received from Google APIs follows the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including its Limited Use requirements. Data from Gmail and other Google services is used only to show and manage it in the app. It isn't used for ads, it isn't sold or given to anyone, nobody at Totality reads it, and it isn't used to train AI models.</p>

<h2>The website</h2>
<p>You sign in to the website at app.usetotality.com by scanning a code with your iPhone, which hands your key to that browser sealed so only it can open it. On a computer you say is yours, the browser keeps the key and your sign-in. On a shared computer it keeps nothing once you close the tab or leave it idle for 30 minutes. You can remove any browser from your iPhone, and within five minutes it signs out and wipes what it kept.</p>

<h2>Notifications</h2>
<p>Task and calendar reminders are scheduled on your device by the app. Totality doesn't send push notifications yet.</p>

<h2>Public profile page</h2>
<p>Your profile has a public web page at usetotality.com/@username only after you press Share. The page shows only your name, photo, and bio, and you can take it down at any time. Your posts are never on it.</p>

<h2>Web search</h2>
<p>Searches go through Totality's own search gateway, which passes them to search engines without your account or address attached. Neither the gateway nor the search service logs what you search for.</p>

<h2>Where it's kept</h2>
<p>Totality's servers run on Supabase (the account, profile photos, public Social posts, and sealed sync data), Oracle Cloud (messages, Friends and Close-friends posts, mail, and sealed files), and Cloudflare (the connection to those servers, the website, and email delivery). Each of them holds only what's described above.</p>

<h2>Changes</h2>
<p>If this policy changes, the date at the top changes with it.</p>`, { kind: 'doc', indexed: true })

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

    const fixed = { '/': homePage, '/privacy': privacyPage }[path]
    if (fixed) {
      if (method !== 'GET' && method !== 'HEAD') return json(405, { error: 'method' })
      return { status: 200, body: Buffer.from(fixed()), type: 'text/html; charset=utf-8', headers: pageHeaders("'none'"), cache: 'public, max-age=300' }
    }

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
