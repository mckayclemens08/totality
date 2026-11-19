# Website architecture proposal

Draft for the owner to agree. Document only; no code until it is agreed and security-reviewed. Spec: issue 150. Canvas: the approved website canvas. Rules: `docs/standing-rules.md`.

## 1. Stack and $0 hosting

- **Hosting:** Cloudflare Pages, free tier, static files only. `usetotality.com` is the signed-out public site; `app.usetotality.com` is the signed-in app (owner, 2026-11-17).
- **Backends:** the same ones the app uses (Supabase, the Matrix server, the sealed blob store on Oracle). No new server.
- **Code:** TypeScript, Vite, a small framework (Preact or Svelte; open to the owner's taste). Output is plain static files with no runtime server rendering.
- **Public pages** (home, later articles) are pre-built at deploy time from public data only. Nothing sealed is ever rendered by a server.
- **Headers** (CSP, HSTS, COOP/COEP) come from a Pages `_headers` file, free.
- **Workers Paid ($5/mo, already allowed)** is held back unless free limits bite: Pages Functions have a daily request cap. Plan: none needed, since the app talks straight to the existing backends.
- Cross-origin calls to Supabase, Matrix and Oracle need CORS allowances on those servers. Free.

## 2. Sign-in

Passwords sign you in and nothing else (rule 3).
- Same flow as the app: username + password over HTTPS to the account server, which returns a session. No email, no sign-in email.
- The browser keeps only the session token, in memory plus an HttpOnly, Secure, SameSite=Strict cookie if the account server can issue one (preferred over `localStorage`, which any script can read). The password is never stored or logged, and never touches key code.
- A signed-in browser with no content key is **locked**: it can show nothing private. Unlocking is section 3.

## 3. How the browser gets the content key

The app's content key (`ContentRootKey`, 32 bytes) must reach the browser without the password, the server, or Totality ever holding it.

| Option | How | Risks |
|---|---|---|
| **A. Pair from the iPhone (QR)** | Browser makes an ephemeral X25519 pair and shows a QR of its public key plus a short code. The phone scans it, checks the code, seals the root key to that public key and sends it through a one-time relay slot (ciphertext only, expires in 2 minutes, one use). | Relay sees only ciphertext. A hostile page showing a fake QR is the main risk: the phone shows the browser's name and a confirm-code to match on screen. Needs the phone at hand. |
| **B. Type the recovery key** | The owner types the existing recovery key. | The recovery key lands in a page that could be tampered with, on a computer that may be shared. Fine as a fallback, bad as the everyday path. Phishing lookalike sites would train people to type it. |
| **C. Matrix-style device verification** | Emoji or QR compare, then secrets are shared by cross-signing. | Right answer for Matrix keys, but it does not carry the Totality root key unless we build it ourselves. It reduces to A. |

**Recommendation: A for everyday use, B kept as a fallback with a warning** ("only type it at app.usetotality.com").

**Holding the key.** The browser keeps the root key as a **non-extractable WebCrypto HKDF key** in IndexedDB. Honest limit: XChaCha20-Poly1305 is not in WebCrypto, so each per-object key is derived with `deriveBits` and used in JS memory briefly. The root never leaves the non-extractable handle, but any script running on our page can still use it (section 7).

**Session policy (to decide):** by default the key is kept only until the tab closes or after 30 minutes idle, then the browser re-locks and needs re-pairing. A "trusted computer" toggle stores the handle in IndexedDB across restarts. Label it literally: "Anyone who can use this computer while you are signed in can read your Totality" (rule 5).

## 4. Sealing and opening in the browser

Matching `ContentCipher.swift` exactly:
- Blob: version byte `1` · 24-byte nonce · ciphertext+tag, **XChaCha20-Poly1305**, associated data `"totality/blob/v1"` + the object's 16 raw UUID bytes.
- Object key: HKDF-SHA256, empty salt, info `"totality/<purpose>/v1"` + UUID bytes, 32 bytes out. Also `derivedID` and `matrixRecoverySecret` use HKDF with their own info strings.
- Chunked files (`ChunkedCipher`: Photos, Reader pieces) must match too.

Note: the spec said ChaCha is only for Mail's sent copies. It is the format of **every** blob, so the library question matters for everything.

| Option | For | Against |
|---|---|---|
| **WebCrypto + `@noble/ciphers`** | Small (~10 KB), audited, pure JS, easy CSP. HKDF/X25519/Ed25519 from WebCrypto where available, `@noble/curves` otherwise. | JS speed on large photos and videos, a few times slower than native. |
| **libsodium.js (WASM)** | The same libsodium the Swift side uses (swift-sodium), so byte-identical behaviour. Faster. | Larger (~200 KB), needs `wasm-unsafe-eval` in the CSP. |

**Recommendation:** noble for everything, and libsodium WASM only if a speed test on a large video chunk fails. A shared **test-vector file** (key, id, plaintext → sealed bytes) is checked by both the Swift and TypeScript suites in CI, so a mismatch fails a build. Large files stream chunk by chunk in a Worker so the page stays responsive.

## 5. Matrix end-to-end on the web

- Use **matrix-js-sdk with the Rust crypto WASM** (`matrix-sdk-crypto-wasm`), the same engine Element Web uses. CSP needs `wasm-unsafe-eval`.
- The browser is a new Matrix device with its own device keys, kept in IndexedDB by the SDK.
- **Verification:** the phone verifies the browser (emoji or QR) through Matrix's standard flow, which cross-signs it. This can ride on the same scan as section 3A, so there is one gesture.
- **Key backup:** the app already stores a Matrix key backup in secret storage, locked by `matrixRecoverySecret()` (HKDF of the root key, never the password). Once the browser has the root key it derives the same secret and restores old room keys. No Matrix passphrase prompt is shown.
- Risks: IndexedDB holds Matrix session keys in a form the SDK controls, so it inherits section 7's XSS risk. Calls (WebRTC) need a separate look and can follow later.
- Messages ships late (section 6), so this has time for its own security review.

## 6. Order of modules

Per the owner (2026-11-17). Each is its own PR with mockup, tests and two-user test:
1. Frame: hosting, build, CSP, tokens, signed-out home.
2. Sign-in, pairing, settings, storage. (Nothing private works before this.)
3. Reader, with Michael's voice. **First check:** can the voice model run fast enough in the page (WASM/WebGPU)? If not, Listen falls back to the browser's built-in voices and the owner is told.
4. Mail. 5. Calendar. 6. Messages. 7. Tasks. 8. Photos. Web module left out.

Google (Drive, Gmail) is called directly from the browser with its own sign-in; Totality's server never sees it. Google OAuth redirect URIs for the new origin are added in the existing Google project (Testing mode; free).

## 7. Web-specific security risks

- **XSS is the whole game.** Script on our page can use the key handle and read decrypted content. Controls: strict CSP (`default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; connect-src` only our backends and Google; `frame-ancestors 'none'`; `object-src 'none'`), no inline scripts, **Trusted Types** required, no third-party scripts, fonts or analytics ever, subresource integrity, hashed filenames, pinned and audited dependencies with a lockfile and a small count.
- **Untrusted content:** mail HTML and Reader documents render only in a sandboxed iframe with no script, no network, and a separate origin where possible. Markdown is sanitised. This is the likeliest XSS route.
- **Supply chain:** one malicious npm update is a key theft. Mitigate with exact versions, `npm ci`, review of each upgrade, and a deploy that builds from a signed, tagged commit.
- **Extensions** can read the page. We cannot stop this; the app says so plainly and recommends a clean browser profile on shared machines.
- **Key storage:** non-extractable handles, idle lock, "sign out clears keys" that wipes IndexedDB, no key in `localStorage`, logs or URLs.
- **Server-delivered code risk:** unlike the app, the host can change the code the browser runs. Cloudflare account and repo get 2FA; releases are tagged; a published file hash list lets anyone compare.
- **Phishing:** lookalike domains. Pairing (3A) shows the real origin and never asks for the recovery key in the common path.

## 8. Costs

- Cloudflare Pages free tier: **$0**. Domain already counted (~$10/yr). Workers Paid ($5/mo) **not needed** unless we add a Function.
- Supabase, Matrix, Oracle: unchanged, $0. The relay slot for pairing is a tiny table or Matrix to-device message: $0.
- The one possible cost: a hosted Michael's-voice model file, size permitting free-tier static hosting (Pages allows 25 MB per file). A bigger model would need R2 storage (free tier 10 GB, but flag if it would pass it). **Flagged, not decided.**
- Watch Cloudflare billing whenever it is touched.

## 9. Open decisions for the owner

1. Pairing from the iPhone (QR) as the everyday way to unlock the browser, with the recovery key only as a fallback. Yes?
2. Should the browser keep the key after the tab closes? Re-lock after 30 minutes idle by default, with a "trusted computer" toggle?
3. Is noble (pure JS) acceptable for sealing, with libsodium WASM only if videos prove too slow?
4. If Michael's voice is too slow in the browser, may Listen fall back to the browser's built-in voices?
5. If Michael's voice model is too large for free hosting, is R2 (still free tier) acceptable, or should the model be left out?
6. Is a signed-in browser also a Matrix device that verifies with the phone, with Messages and calls last?
7. Mail HTML and documents shown in a sandboxed no-script frame, so some rich mail may look plainer than on the phone. OK?
