# Messages on the website: spec (2026-11-18)

Brings Messages to app.usetotality.com. Builds on `docs/website-architecture-proposal.md` section 5 and the review in `docs/website-security-review.md` (rows 4 and 10 said Matrix gets its own review; it is at the end of this file). No app code in this PR.

## 1. What the server is

The Matrix server is **Tuwunel** (`server/tuwunel.toml`, behind Cloudflare Tunnel at `matrix.usetotality.com`), not Synapse. Federation and registration are off. Sign-in is by a 60-second ES256 JWT (`org.matrix.login.jwt`) signed by the Supabase function `matrix-login`, the same pass the iPhone uses.

## 2. Library

| | |
|---|---|
| Client | `matrix-js-sdk` **45.0.0**, exact (released 2026-10-27; 45.1.0 is from 2026-11-11, under two weeks old) |
| Crypto | `@matrix-org/matrix-sdk-crypto-wasm` **18.9.0**, exact, the version 45.0.0 pins. The same Rust crypto engine the iPhone SDK uses, compiled to WASM. |
| Extra packages | 16 runtime packages in all (`npm ls`), none with install scripts. Installed with `npm ci`, lockfile integrity hashes checked. |
| Size, measured | JS 1.10 MB minified (274 KB gzip). WASM 7.8 MB (2.0 MB gzip), under Pages' 25 MB per-file limit. |

- Messages is its own esbuild chunk (`splitting: true`), loaded only when Messages is opened. Other modules don't get bigger. The WASM file is served from our own origin with a hashed name and `immutable` caching, so it downloads once.
- I checked the bundle: no `eval`, `new Function`, `innerHTML`, workers or `importScripts`. It does contain `localStorage` code (old stores we don't use). Our own code writes only two per-browser choices there, the same ones the iPhone keeps in its settings (share read receipts, and how far each chat was read); a test holds it to those.
- Not used: calls (WebRTC), widgets, threads UI, the legacy Olm crypto. Calls need their own review later.
- Upgrades follow review row 8: exact versions, reviewed one at a time, never newer than two weeks.
- Alternatives: none real. Olm-in-JS is retired, and other clients use this same crypto crate.

## 3. CSP change

Two tokens in `web/site/public/_headers` (and `build.mjs`):

- `script-src 'self' 'wasm-unsafe-eval'`. This lets the page compile WebAssembly. It doesn't allow JS `eval` or any script from elsewhere. The only WASM the page can fetch is our own, since `connect-src` decides where `fetch` may go.
- `connect-src` gains `https://matrix.usetotality.com`.
- `media-src blob:`, so a video this page decrypted can play. Like images, every `blob:` URL is made in one file (`messages/media.ts`), tracked and revoked.
- Chunks the app loads at start get `modulepreload` with integrity; Messages' own chunks and the WASM are fetched later from this site only.

Everything else stays: `default-src 'none'`, Trusted Types with the one `mail-frame` policy, `img-src 'self' blob: data:`, `frame-ancestors 'none'`. A test checks `script-src` is exactly `'self' 'wasm-unsafe-eval'`.

## 4. Signing in and becoming a verified device

No recovery key typing, no emoji compare, and the phone doesn't need to be on. The QR pairing the browser already did is the one gesture. It gave the browser the root key, and the root key is what unlocks Matrix.

1. The page asks `matrix-login` for a pass with its Supabase access token, then logs in with `org.matrix.login.jwt`. The device name is `Totality web` (see open question 3). The Matrix access token is kept like the Supabase refresh token: sealed under a non-extractable key on "my computer", memory only otherwise.
2. `initRustCrypto` starts the crypto engine (store in section 5).
3. The page derives `matrixRecoverySecret` from the root key (HKDF, info `totality/matrix-recovery/v1`, base64), the same value the iPhone gives `enableRecovery(passphrase:)`.
4. It reads the account's default secret-storage key description. That is PBKDF2 settings (salt, iterations) because the iPhone set it up from a passphrase. It derives the key with `deriveRecoveryKeyFromPassphrase`, checks it against the key's MAC, and hands it to the SDK through `getSecretStorageKey`.
5. From secret storage it takes the self-signing key and signs its own device (`bootstrapCrossSigning` with no reset), so the iPhone and contacts see it as verified by the account. It takes the backup key and restores history (`restoreKeyBackup`), and from then on it backs up the new room keys it makes.

Rules:
- **Never resets.** If secret storage is missing ("Open Messages on your iPhone once to set up history backup") or the secret doesn't open it, the browser stops and says so. It never makes new cross-signing keys or a new backup, which would cut the iPhone off. This matches `settleKeys` on the iPhone.
- **Proof before build.** Step 3 starts with a test against the owner's real account: the page must open the secret storage the iPhone made. If the Rust SDK turned out to store the secret another way, this stops and comes back for a decision.
- **Fallback, not in v1.** An account whose iPhone has never set up recovery could verify by emoji from the phone. Pairing already needs the recovery key (review notes), so every paired browser can use the path above. Emoji is left out.

## 5. Where things are stored

| What | My computer | Shared computer |
|---|---|---|
| Crypto store (device keys, room keys) | IndexedDB, `totality-matrix-<account>` prefix, encrypted by the SDK's store cipher under a 32-byte `storageKey` = HKDF(root key, `totality/web-matrix-store/v1`) | Memory only |
| Matrix access token | Sealed under the non-extractable session key | Memory only |
| Chats, messages, names | **Memory only.** No sync store on disk, so no plaintext ever touches the disk. Each visit does one sync with lazy-loaded members and 30 events per chat. | Memory only |
| Decrypted photos | `blob:` URLs from bytes the page opened, revoked when the chat closes (the Photos rule) | same |

- `storageKey` bytes come from `deriveBits` on the non-extractable root key. They live in the WASM memory while the page is open, like the object keys the other modules derive. Keys inside the Rust store are not WebCrypto keys and can't be non-extractable; the store cipher is what protects them at rest.
- A copied browser profile alone opens nothing without the root key, and the root key is non-extractable.

## 6. Shared computer, locking and signing out

- **Shared computer, 30 idle minutes** (`idle.ts`): stop sync, log the Matrix device out (`POST /logout`, which deletes it and its keys on the server), drop everything from memory. Next time the page pairs again and is a new device.
- A tab closed without locking can't log out (no beacon can carry the token). The device is left signed in on the server with no keys anywhere on the computer. The iPhone's Devices list shows it to remove, and the next sign-in from any browser removes `Totality web` devices older than 30 days with no activity. Open question 2 asks whether to skip this by not offering Messages on shared computers.
- **Sign out (my computer):** log the device out, `clearStores()`, delete the `totality-matrix-*` databases, then the usual site sign-out.
- **Removing the browser on the iPhone** (Devices) must also delete its Matrix device. That's an iPhone change in the build PR.

## 7. Scope (owner, 2026-11-18: "as functional as the iphone app messages module")

The same as the iPhone Messages module: chat list with requests (accept, decline, block), new chats by username, groups (start with names, a name and a photo; rename; change photo; leave), read and send text, reply, react, send and see photos and short videos, retry, delete your own messages, typing and read receipts (with the same share-read setting), disappearing messages, load earlier, blocked people (block, list, unblock). Both sides use the same Matrix events, so a chat looks the same on the iPhone and the website. Calls aren't in the iPhone module either. Sending is the user's own action from their own keyboard; it isn't an AI action, so rule 6 doesn't come into it.

Photos and videos sent from the browser are sealed in the page by the SDK (AES-CTR attachment encryption, as on the iPhone) before upload. Photos: JPEG/PNG/GIF/WebP, re-encoded in a canvas to strip metadata and resized like the iPhone. Videos: MP4 as picked, size-limited like the iPhone.

Rendering: plain `body` text with `textContent`, never `formatted_body` HTML. `http(s)` links only, `noopener noreferrer nofollow`. Photos only as JPEG/PNG/GIF/WebP up to 10 MB, videos up to 40 MB, the rest "opens on the iPhone".

## 8. Server changes

- **Tuwunel CORS: none needed.** I checked: `matrix.usetotality.com/_matrix/client/*` already answers preflights with `Access-Control-Allow-Origin: *`, all methods, `authorization` allowed. That's the Matrix spec's rule and safe here, because Matrix uses bearer tokens, not cookies. No container restart.
- **`matrix-login` CORS: needed.** The function has no `OPTIONS` answer today. Add one for `https://app.usetotality.com` only (`POST`, `authorization, content-type, apikey`), plus the same `Access-Control-Allow-Origin` on replies. Deploy with `supabase functions deploy matrix-login`. Free. Asked for before deploying.
- `cloudflared.yml` already routes `/_matrix/client` and `/_matrix/media`. Nothing else.

## 9. What the server sees

Same as with the iPhone: who is in which chat, when messages are sent and their sizes, read receipts and typing, group names and photos (not encrypted in Matrix, which the screens already say), device names and IP addresses (through Cloudflare). It sees no message text, photos or videos, and no keys except encrypted backups it can't open. One new thing: a second device, `Totality web`, in the account's device list, which contacts also see.

Cost: $0. Pages hosts the bigger files on the free plan; nothing else changes.

---

# Security review: Messages on the website (2026-11-18)

Follows `docs/website-security-review.md`.

| # | Threat | Mitigation / change |
|---|---|---|
| M1 | **XSS now can send as the user,** not only read. | Same controls as review row 4: `script-src 'self'`, Trusted Types, no HTML from messages. Message text is only ever `textContent`. Residual: script running in the page could send messages and read open chats. Stated plainly. |
| M2 | **`wasm-unsafe-eval` weakens the CSP.** | It only allows compiling WASM, and WASM can only come from our own origin (`connect-src`, `script-src 'self'`). It doesn't enable JS eval. Accepted. |
| M3 | **Supply chain: 16 packages and a 7.8 MB binary.** | Exact pins, lockfile hashes, `npm ci`, no install scripts, two-week age rule, the WASM built by matrix.org's release CI (the same artifact Element Web ships). Residual: we can't audit the binary ourselves. |
| M4 | **The browser resets the account's Matrix keys** by mistake and cuts off the iPhone. | It never calls a reset or creates secret storage, cross-signing or backup. Missing or unopenable storage stops with a message. Tested with a fake server in step 3. |
| M5 | **Malicious server adds a device** or swaps keys to read new messages. | The same as on the iPhone: the Rust crypto engine checks signatures, and cross-signed identity changes show a warning. No change from today. |
| M6 | **Copied browser profile** (disk theft). | The crypto store is encrypted under a key derived from the non-extractable root key; no plaintext chats on disk. Same residual as review row 3 for someone with the unlocked browser itself. |
| M7 | **Shared computer leaves a live device.** | Lock logs the device out; nothing written to disk; stale web devices are removed after 30 days; the iPhone lists them. See open question 2. |
| M8 | **The Matrix token leaks.** | Never in `localStorage`, URLs or logs; sealed or memory only; `Referrer-Policy: no-referrer`. The JWT pass lasts 60 seconds and is used once. |
| M9 | **Untrusted media and links.** | Decrypted in the page, shown as `blob:` images or `<video>` only for listed types and sizes, revoked on close. No `formatted_body`, no remote images, links with `noopener noreferrer`. |
| M10 | **Device name leaks the browser and OS to contacts.** | Name is plain `Totality web`. |
| M12 | **Uploads.** Only files the user picks are sent. | No drag-anywhere or paste auto-send; a picked file is shown before Send. Photos are redrawn in a canvas, which drops location and camera details, as the iPhone does. Bytes are sealed by the SDK before upload. |
| M11 | **Rule check.** | 1: no new tables. 2: messages are sealed by Megolm on the device before upload. 3: the password isn't involved; the secret comes from the root key. 4: no secrets; the JWT key stays in Supabase. 5: "verified" is shown only once the device is really cross-signed. 6: no AI on the web. 7: Messages on the web is its own folder, importing no other module. 8: unchanged. |

**Result.** No blocker. Changes: the never-reset rule (M4), memory-only chats (M6), lock = log out (M7), plain device name (M10), the proof test before building (section 4). Decisions below.

## Decisions (owner, 2026-11-18)

1. **Scope:** full parity with the iPhone Messages module (section 7).
2. **Shared computers:** Messages is off there. Section 6's shared-computer lock path stays as a backstop only.
3. **Device name:** `Totality web`.
4. **Size:** about 2.3 MB gzip on first open is fine.
