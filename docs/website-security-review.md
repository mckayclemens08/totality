# Website proposal: security review (2026-11-18)

Reviews `docs/website-architecture-proposal.md`. Design changes below are folded into the proposal's intent and bind step 3 (pairing) and step 1 (headers).

## Threats and mitigations

| # | Threat | Mitigation / change |
|---|---|---|
| 1 | **Pairing relay swap.** The relay could swap the browser's public key for its own and receive the root key. | The QR carries a random slot secret and a hash of the browser's public key. The phone checks the hash and shows a short code that must match the browser's screen. The relay stores ciphertext only, one use, 2-minute expiry, rate limited. |
| 2 | **Fake pairing page.** A lookalike site shows a QR; the user scans it with the app. | The app only scans while the owner has tapped "Add a device", shows the browser's name and city, and requires the code match. Residual risk is social engineering; stated in the UI. Devices lists every browser with one-tap remove. |
| 3 | **Stolen or removed browser still has the key.** Removing a device ends its session but cannot make it forget a root key it already holds. | Residual and the same as a phone. "Remove" must say so. Root key rotation is a later feature; recommend it be scheduled. Not blocking. |
| 4 | **XSS reads decrypted content or uses the key handle.** | Proposal section 7 controls stand. Added: Trusted Types enforced, no `eval`, no service worker caching decrypted data, no `postMessage` without exact origin checks. |
| 5 | **Session cookie.** `SameSite=Strict` HttpOnly only works if the account server is on `*.usetotality.com`. | If it isn't, keep the token in memory and refresh it through a short-lived endpoint. No token in `localStorage`. Decide at step 3. |
| 6 | **Untrusted mail and documents.** | Sandboxed iframe, `sandbox` without `allow-same-origin` or `allow-scripts`, with its own CSP in the document (`default-src 'none'`; images only as allowed). Remote images off by default; they leak IP and open times. Links open with `noopener noreferrer`. |
| 7 | **Google tokens in the browser.** | OAuth with PKCE, no client secret anywhere in the repo (rule 4). Tokens stored sealed under the content key, never plaintext. Scopes unchanged. |
| 8 | **Supply chain.** | Exact versions, lockfile, `npm ci`, upgrade review, few dependencies, deploys from tagged commits, 2FA on Cloudflare and GitHub. |
| 9 | **Clickjacking, framing, MIME sniffing, referrer leaks.** | `frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Permissions-Policy` denying camera, mic, geolocation until a module needs them, COOP same-origin. |
| 10 | **Matrix crypto state in IndexedDB.** | Inherits XSS risk (4). Shared-computer mode wipes it on lock. Reviewed again before Messages. |
| 11 | **Extensions and malware.** | Cannot be stopped. Documented plainly. |
| 12 | **Rule check.** | 1 and 2 hold (same schema, same sealing). 3 holds (password never reaches key code). 4: no secrets in the repo, Pages env vars hold none that matter. 5: shared-computer and trusted-computer labels must be literal. 6: no AI on the web in v1. 7: modules do not import each other. 8: Google and Plaid scopes unchanged. |

## Result

No finding needs an owner decision. Changes: slot secret and key-hash commitment in pairing (1), phone-side "Add a device" gating (2), remove-device wording (3), cookie-or-memory choice at step 3 (5), no `allow-same-origin` for mail frames (6). Step 1 carries the headers in (4) and (9).

Further review is required for pairing code (step 3), the mail renderer (step 5) and Matrix (step 7).

## Pairing implementation notes (PR for issue 150, step 3)

- Protocol, in order: sign in; the browser makes a one-time X25519 key and slot secret, and creates a `pairing_slots` row (public key and a browser name only); the QR holds the slot ID, the slot secret and a hash of the browser's public key; the iPhone reads the row, refuses unless the hash matches, seals the content key (XChaCha20-Poly1305, key from X25519 + HKDF salted with the slot secret, bound to the slot ID) and fills the slot once; the browser opens it, deletes the slot and keeps the key non-extractable.
- The six-digit code is derived from the slot ID and the browser's public key, so it shows the person the iPhone scanned this screen's code. It is not a secret.
- The iPhone sends nothing unless the recovery key is set up, so a browser is only ever given a key the recovery key can also restore.
- Slots: 2-minute server-set expiry, one fill, at most five open, owner-only rows, no client-set expiry. Row policies are tested in `backend-tests/pairing.test.js`.
- Not in the mockup: the "Near Provo, Utah" line is left out, because a location needs an IP lookup service. The iPhone shows the website and browser name instead.
- Session storage (review #5): the account server isn't on `usetotality.com`, so no cookie. The access token stays in memory; on "my computer" the refresh token is kept sealed under a non-extractable key; on a shared computer nothing is written.
- Shared-computer lock after 30 idle minutes drops the key from memory. Residual: a page script could have copied derived object keys while open (review #4).
- Still open for later steps: removing a browser from Devices on the iPhone (the list and remove button), and root-key rotation (review #3).

## Reader on the web, first slice (issue 150, step 4)

- **Reads only.** The website lists the account's docs and files and opens notes. It writes nothing, so it can't corrupt a sealed copy. Files, PDFs, EPUBs, Journal, Drive, Listen and editing come in later PRs.
- **Same formats, proven.** `docs/reader-vectors.json` is made by the real `ReaderVault` (`WebVectorsTests.makeVectors`). `web/site/test/reader.test.mjs` opens it with the website's code, so what the iPhone seals is what the browser reads. If the Swift format changes, the Swift test fails until the vector is remade, which fails the website test unless it still opens.
- **Untrusted content.** A note is Markdown text, turned into a tree and drawn with `textContent` only. Nothing in a note is parsed as HTML. It is drawn in a frame with `sandbox="allow-same-origin"` and no `allow-scripts`, so it can't run script or reach the page's key or session. Only `http(s)` links are kept, with `noopener noreferrer nofollow`. Mail (HTML) will need its own review before it ships (review #6).
- **Blob store from a browser.** `server/blobs/blobs.mjs` now answers CORS for `https://app.usetotality.com` only (`ALLOWED_ORIGINS` changes it). It still needs a sign-in for every blob, and answers other origins' preflights with 403. This is a change to the Oracle server, which the owner has to redeploy.
- **Keys.** Object keys are derived from the non-extractable root key with `deriveBits`. The page holds each derived key only while it opens one blob.
- **Residual:** every opened note is decrypted text in page memory. XSS in the page could read it (review #4); the CSP and Trusted Types are what stand in the way.

## Photos and Mail on the web (issue 150, web-next-2)

**Photos (read-only).**
- The page CSP gains one thing: `img-src 'self' blob:`. Every `blob:` URL is made in `photos/view.ts` from bytes this page decrypted, is tracked in one set, and is revoked when the view closes or reloads. A test checks that nothing else makes blob URLs and that `blob:` appears once in the CSP.
- Details that name another account or another photo are never shown (the same rule as `PhotoSealer`). Thumbnails are limited to 2 MB and originals to 40 MB, and only JPEG/PNG/GIF/WebP originals are shown. HEIC and video show the thumbnail and say the full file opens on the iPhone.
- Vectors: `docs/photos-vectors.json` is made by the real `PhotoSealer`.

**Mail (read-only).**
- Opening: HPKE (RFC 9180) in `mail/hpke.ts`, tested against messages made by the server's own `seal()` (`docs/mail-vectors.json`, made by `server/mail/make-web-vectors.mjs`). The mailbox and message IDs are authenticated, so a moved or swapped message fails. The mail key is derived from the non-extractable root key like the others.
- Rendering HTML: `<iframe sandbox="" srcdoc>` with `default-src 'none'; img-src data:; style-src 'unsafe-inline'` as the first thing in the document. An empty `sandbox` gives no scripts, no same-origin (opaque origin, so no way to the page's key or session), no forms, no popups, no top navigation. The single sink is `srcdoc`, assigned through a Trusted Types policy named `mail-frame`, and the page CSP now says `trusted-types mail-frame`, so no other policy can be made. Remote images, fonts and styles never load, so there are no tracking pixels. Inline (`cid:`) images up to 2 MB become `data:` images.
- Links: a frame with no scripts can't be clicked, so the page lists the message's `http(s)` links itself (from an inert parsed document, de-duplicated, at most 20) as `target=_blank rel="noopener noreferrer nofollow"` anchors with the host shown. `javascript:`, `data:` and relative links are dropped. This replaces the "sanitised click handler" in the brief, which can't exist for a frame that runs nothing.
- Plain text is drawn with `textContent`. Attachments are listed, never opened. Messages over 5 MB, Sent copies (their own seal) and mail from other Totality accounts (sealed again inside) show a note that they open on the iPhone for now. Messages flagged as spam are hidden.
- The MIME reader never throws, caps depth (24) and parts (1,000), and returns text that is never parsed as markup.
- **Decided (owner via the founding session, 2026-11-18): option A.** The page CSP is now `style-src 'self' 'unsafe-inline'` and `img-src 'self' blob: data:`; `script-src` stays `'self'` and Trusted Types stays. Checked in a browser: with this CSP a sandboxed `srcdoc` frame shows its inline-styled text. Finding: a `srcdoc` frame inherits the page's CSP, and the stricter of the two wins. The page says `style-src 'self'` and `img-src 'self' blob:`, so the frame's inline styles and `data:` images are blocked, and mail renders unstyled. I confirmed this in a browser. The frame's own CSP can only tighten. Two ways to get styled mail: (A) change the page CSP to `style-src 'self' 'unsafe-inline'` and `img-src 'self' blob: data:`. Script stays strict, nothing untrusted is ever put into the page's own DOM, so style injection has no way in; this keeps the sandbox exactly as specified. (B) show mail from a separate static page with its own CSP header, which needs `sandbox="allow-scripts"` for a bootstrap script. I recommend A. It is a two-token change in `web/site/public/_headers`.
- Server: `server/mail/mail.mjs` answers CORS for GET only, for the listed origins. Preflights for POST or DELETE are refused, so a page can't delete, send or keep mail.
