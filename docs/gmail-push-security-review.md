# Instant Gmail sync: security review (issue 164, step 3)

Reviewed on 2026-11-19 against non-negotiables 2, 4 and 8. Code: `server/push/push.mjs`, tests in
`server/push/push.test.mjs`.

## What crosses the server

| Thing | Seen by the server | Kept |
|---|---|---|
| Mail, subjects, senders | Never. The phone fetches mail from Gmail itself | Never |
| Google access or refresh token | Never | Never |
| Google ID token (when a phone links an address) | Yes, once, to check Google's signature | Never |
| Gmail address | In memory, while it's hashed, on link, unlink and each Pub/Sub note | Only `HMAC-SHA256(PUSH_ADDRESS_KEY, address)` |
| Gmail history number | In the Pub/Sub note | Never |
| Phone push token | Yes | Per account, until removed, gone at Apple, or unseen for 60 days |
| Totality account ID | From the sign-in | Next to its phones and its linked hashes |

Nothing is logged: the container has `logging: driver: none` and the code has no console calls.

## Threats and answers

1. **A forged "you've got mail" note.** `/push/gmail/notify` takes only an OIDC token that Google signed (RS256,
   checked against Google's published keys). It must also carry this endpoint's audience, be from the one
   Pub/Sub service account (`PUBSUB_SENDER`, verified) and fall inside its times, with 5 minutes of skew. `alg`
   must be RS256 and a `kid` is required, so `none` and algorithm-confusion tricks fail. Tests cover each of these.
2. **Someone linking another person's Gmail address to learn when they get mail.** Linking needs a Totality
   sign-in and a Google ID token for that address, issued to Totality's own client ID with `email_verified`.
   Only the address's owner can get one. The ID token opens nothing in Gmail and is dropped after the check.
3. **A replayed note or a burst of mail.** Each push says only "wake up". Notes for one address that arrive within 10 seconds
   of each other become one push, plus one at the end of that gap. A replay can't flood a phone or use up its
   push budget at Apple.
4. **Reading the stored file.** It holds keyed hashes, not addresses. Matching it against a list of addresses
   needs `PUSH_ADDRESS_KEY` too, which is only in `~/totality/.env`.
5. **Telling who's linked.** Any signed, well-formed note gets 204, whether or not its address is linked, so the
   answer says nothing. Unlinking takes the plain address, because the Google sign-in may already be
   gone, and it only ever removes the caller's own link.
6. **Apple's key.** It's read from `~/totality/secrets/push/apns.p8` (git ignores `secrets/` and `*.p8`), mounted read-only. It's
   never in the repo, an image or an environment variable.
7. **Resource use.** Bodies are capped (1 KB, 8 KB and 16 KB). Google's keys are re-fetched at most once a minute.
   The quiet-gap map is pruned past 10,000 entries. The container is read-only, uid 1000, with no
   capabilities and 128 MB.

## Residual risks (accepted or for later)

- **Cloudflare sees the traffic.** The tunnel ends TLS at Cloudflare, as for every other path. So Cloudflare can see the
  Pub/Sub note (the address and a history number) and the ID token on link. That's no more than Cloudflare
  already sees for Totality mail.
- **The account link.** The store maps a hash to the Totality account ID, which the server already knows from the
  sign-in. Someone holding both the file and the key could tell which Totality account has which Gmail.
- **A leaked ID token.** It lasts about an hour. Someone holding one could link that address to their own account
  and learn when it gets mail, but nothing else.
- **No per-IP rate limit** on `/push/gmail/notify`. Each forged request costs one RSA check and is refused. This
  is part of the whole-system audit planned after Social (rate limits, bots).
- **iOS rations background pushes.** It may delay or drop them, and doesn't deliver to an app the person
  force-quit. A Notification Service Extension would make delivery dependable. It's a follow-up, not a security issue.
