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
