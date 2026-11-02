# Totality — Phase 0 Architecture Proposal

**Status:** Building. The owner waived the independent-model audit on 2026-10-30 ("Waive it, start building"), so the design has had no second-model review. Open decisions in §12 still stand.
**Author:** Claude Code (builder) · **Date:** 2026-10-30 · **Source spec:** `docs/founding-brief-v6.pdf` (v6, 2026-10-28)
**Rule:** Brief §18 required approval before feature code. The owner waived the independent review above.

---

## 0. What this document decides

| # | Question the brief left to Phase 0 | This proposal's answer |
|---|---|---|
| 1 | The Supabase ↔ protocol-server seam (§5 "tension Claude Code must resolve") | Three-plane split: **Supabase = account + private ciphertext + solo modules**, **Matrix = all private interpersonal traffic**, **atproto = public social only**. §3 below. |
| 2 | Federation protocol for social: ActivityPub vs AT Protocol (§14, §17) | **AT Protocol**, with public-only scope. Private/contacts posts do *not* go on atproto — they ride Matrix. §4. |
| 3 | E2E key recovery design (§14, §17) | **Matrix SSSS as the single key-backup substrate** for Matrix keys *and* Totality content keys. One recovery key for everything. §6. |
| 4 | AI inference + permission design (§15) | Capability-grant table + client-side decryption + hosted-inference disclosure gate. Default local. §7. |
| 5 | Data model with `owner_id` + `visibility` on every entity, RLS sketch (§6) | §5. |
| 6 | Module-boundary contracts (§6) | One `ContentRef` envelope; modules never import each other. §8. |
| 7 | Federated identity / contacts / invites (§6) | One Totality identity binding four names (handle, email, DID, MXID). §4.3, §9. |

Plus, in §11, **twelve conflicts and blockers** that need owner decisions. A blocks all building; K blocks stage B.

---

## 1. Architectural thesis

The brief locks two things that pull in opposite directions:

- **§5:** one modular monolith, one Supabase backend, because a solo builder drowns in microservices.
- **§14:** everything federated, everything E2E, which means protocol servers and client-held keys.

These are reconcilable, but only if the seam is drawn by **data sensitivity**, not by module. The wrong seam is "Messages module → Matrix, Social module → atproto, everything else → Supabase," because then a private post and a public post live in different modules' storage and the one-post-model rule (§13) breaks.

The right seam: **a record's transport is chosen by its visibility, not by the module it came from.**

```
                       ┌───────────────────────────────────────────┐
                       │  SwiftUI client (iPhone + Mac)            │
                       │  modules · crypto core · key store        │
                       └───────┬──────────┬──────────────┬─────────┘
             private, interpersonal │     │ private, solo │ public
                       ┌───────────▼──┐ ┌─▼────────────┐ ┌▼──────────────┐
                       │ MATRIX       │ │ SUPABASE     │ │ ATPROTO PDS   │
                       │ homeserver   │ │ (Postgres,   │ │ (public       │
                       │ (Synapse/    │ │  Storage,    │ │  records,     │
                       │  Tuwunel)    │ │  Auth, RT)   │ │  signed)      │
                       ├──────────────┤ ├──────────────┤ ├───────────────┤
                       │ DMs          │ │ account      │ │ public posts  │
                       │ communities  │ │ handle dir   │ │ follows       │
                       │ channels     │ │ ciphertext   │ │ likes/reposts │
                       │ call signal  │ │  blobs       │ │ public profile│
                       │ device keys  │ │ calendar     │ │ feed gens     │
                       │ private posts│ │ money view   │ └───────────────┘
                       │ shared docs  │ │              │
                       │ SSSS backup  │ │ audit log    │
                       └──────────────┘ │ push routing │
                                        └──────────────┘
```

**Everything in the Matrix column and every blob in Supabase is ciphertext the server cannot read.** Supabase holds plaintext for exactly four things: the account row, the public handle directory, the audit log, and push-notification routing metadata. That list is the thing the owner approves line by line (§14 bullet 7); it is reproduced as an explicit table in §5.4 and nothing may be added to it without owner sign-off.

### Why Matrix carries private *posts* and *docs*, not just chat

This is the non-obvious move in the proposal, so it gets its own justification.

A Matrix room is a replicated, E2E-encrypted, federated, append-only event log with per-room membership and key rotation. That is exactly the primitive a followers-only post, a shared document, or a private photo album needs. Building a second one on top of Supabase would mean hand-writing group key agreement — which §3 forbids for chat ("never write a chat protocol from scratch") and which is no safer when it's called "sharing."

So:

- A **private/contacts-only post** is an event in the author's `app.totality.timeline` room, whose members are the author's contacts. Same `Post` struct in the client as a public post; different transport.
- A **shared document** is a room whose state holds the Yjs doc's encrypted updates; collaborators are room members. Yjs updates are small binary deltas and map cleanly onto timeline events.
- A **private album** is a room; the media is a Supabase Storage blob, the *key* to that blob is an event in the room.

Large binaries never go through Matrix (its media repo on a Pi is a bad idea). Pattern throughout: **Supabase Storage holds the ciphertext, Matrix holds the key and the membership.**

---

## 2. Component inventory (A/B, $0)

| Plane | Software | Where it runs (A/B) | Where it runs (post-Pi) | Cost |
|---|---|---|---|---|
| Account/data | Supabase | Supabase free tier | self-hosted on Pi (Docker) | $0 |
| Private traffic | Matrix **Tuwunel** (not Synapse) | Oracle Cloud Always-Free ARM, behind a Cloudflare tunnel | Pi | $0 |
| Public social | atproto PDS (`bluesky-social/pds`) | **deferred to Phase 2** | Pi | $0 |
| Calls | LiveKit Cloud free tier | cloud | self-host on Pi (later) | $0 |
| AI inference | Ollama on the owner's Mac | Mac (LAN + Tailscale) | Pi or Mac | $0 |
| Private network | Tailscale free tier | — | — | $0 |

**Tuwunel, not Conduit or Synapse.** This proposal first chose Conduit, a single Rust binary that fits small hardware better than Synapse. On 2026-10-30 the server was built on Tuwunel instead, from the same family: it documents JWT login with ES256 public keys, which is how Supabase signs tokens on this project and which was never confirmed for Conduit. It's actively released, has arm64 builds, and is Apache-2.0. Its own docs list a Conduit migration path, but not a route to Synapse yet.

The server runs with registration and federation off. Cloudflare's tunnel means no inbound ports, but Cloudflare ends TLS, so it handles traffic in the clear. Matrix's E2E content and the key backup stay ciphertext there. Sign-in tokens don't.

**atproto is deferred, not dropped.** Phase 1 ships no social module (§7), so running a PDS in Phase 0/1 buys nothing but a second identity system to keep alive. What Phase 0 *does* do is reserve the DID in the identity model (§4.3) so adding it in Phase 2 is additive.

---

## 3. The three planes in detail

### 3.1 Supabase plane

Postgres + Auth + Storage + Realtime. RLS on from the first migration, no exceptions. Realtime is used only for solo-module sync across the owner's own devices (calendar changed, money refreshed) — never for interpersonal messaging, which is Matrix's job.

Supabase Storage holds all large binaries as ciphertext: photos, Reader files, audio, post media. Object keys are opaque UUIDs that leak nothing (no filenames, no dates in paths).

**Free-tier ceilings that will be hit** (per Supabase's pricing page, checked 2026-10-30): 500 MB Postgres, 1 GB Storage, 5 GB egress/mo, 2 active projects, and pausing after 1 week of inactivity. The Photos module alone exceeds 1 GB on import. See §11-C.

### 3.2 Matrix plane

One homeserver, domain `totality.<owner-domain>`. Room types:

| Room type | Purpose | State |
|---|---|---|
| `m.room` (DM) | 1:1 chat | standard, E2E via Megolm |
| `m.space` + child rooms | a community and its channels | Discord-shaped, §13 |
| `app.totality.timeline` | one per user: their private/contacts posts | members = contacts with `canSeePrivatePosts` |
| `app.totality.doc` | one per shared document | Yjs update events |
| `app.totality.album` | one per shared album/collection | media key events |
| `app.totality.keystore` | the user's own SSSS account data | not a room — `account_data`, §6 |

Calls: Matrix carries signalling (`m.call.*`); LiveKit carries media. 1:1 calls use WebRTC's DTLS-SRTP with the key fingerprint exchanged over the E2E Matrix channel — that is genuinely E2E and may be labelled so. **Group calls through a LiveKit SFU are not E2E** unless LiveKit's E2EE insertable-streams mode is enabled; if it isn't, the UI says "encrypted in transit" (§11, encryption-claims rule).

### 3.3 atproto plane (Phase 2)

Self-hosted PDS. Holds only `visibility == .public` posts, the follow graph, likes, reposts, and the public profile. Lexicon: start from `app.bsky.*` rather than inventing `app.totality.*`, so the owner's posts are visible to the existing Bluesky network from day one — which is the entire point of federating. Totality-specific fields go in a sidecar record type that Bluesky clients ignore.

---

## 4. Identity

### 4.1 Basis (DECIDED in brief §17)

Handle + email. Phone optional, never identity, never required.

### 4.2 Credential

Supabase Auth with **username and password**, decided by the owner on 2026-10-30 so Totality sends nobody an outside email. This replaces the email magic link planned here and departs from the brief's no-password rule. Each username maps to a reserved `name@totality.invalid` address, because Supabase Auth needs one. See §11-N for what this gives up. Passkeys need a domain and the paid Apple program, so they are not available yet.

Passkeys are not primary because Supabase's support is an experimental beta (announced May 2026) and its Swift API is gated as experimental. Native passkeys also need Associated Domains, which could not be confirmed on a free Apple team (§11-K).

> **Owner decision needed:** is Sign in with Apple also offered? It is near-mandatory for App Store review *if* the app ever lists publicly (C-stage), and harmless now. Recommendation: build the identity layer so it can be added, don't add it in Phase 0.

### 4.3 One identity, four names

```swift
struct TotalityIdentity {
    let userID: UUID          // Supabase auth.users.id — the join key, never shown
    let handle: String        // "mckay" — the public identity, unique, immutable after 30 days
    let email: String         // credential + recovery anchor
    let mxid: String          // "@mckay:totality.example" — derived from handle
    let did: String?          // "did:plc:..." — nil until Phase 2
    let phone: String?        // optional, never identity
}
```

Binding rules:

- `mxid` is **derived** from `handle`, not independently chosen. Handle changes rename the Matrix account (Matrix does not support rename → this is why handles are immutable after a 30-day grace window; see §11-F).
- `did` is `did:plc` with the handle verified via `_atproto` DNS TXT or `/.well-known/atproto-did` on the owner's domain. DID is the durable identifier; handle is a human-readable alias that can be re-pointed.
- The binding is published at `https://totality.<domain>/.well-known/totality-identity/<handle>` as a JSON document signed by the user's identity key, so another server can verify that the MXID and the DID belong to the same person. **This is the one piece of this design with no upstream precedent** and should get specific attention in the independent review.

### 4.4 Single sign-on across planes

The user signs in once to Supabase. The client then:

1. Gets a Supabase JWT.
2. Exchanges it at the Matrix homeserver via JWT login. **Unverified:** the only documentation found describes statically configured keys, not a JWKS URL, so expect to configure Supabase's public signing key by hand. Spike this at step 0.4 before depending on it.
3. (Phase 2) Signs atproto records with a device-held signing key registered to the DID; no session exchange needed because atproto auth is key-based.

One sign-in, three planes. The password reaches the account server and nothing else.

---

## 5. Data model

### 5.1 Invariants (enforced by migration lint, not by discipline)

Every **content** table has:

- `id uuid primary key default gen_random_uuid()`
- `owner_id uuid not null references auth.users(id) on delete cascade`
- `visibility visibility_t not null default 'private'`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`
- RLS enabled, with at least a SELECT and a mutation policy
- If it holds private content: a `ciphertext bytea` / `storage_key text` column and **no plaintext content column**

A CI check (`scripts/check-schema-invariants.sql`, written at step 0.3) fails the build if any table in the `public` schema violates these. Account and infrastructure tables (`profiles`, `identity_keys`, `devices`, `contacts`, `invites`, `notifications`, `push_tokens`, `audit_log`) are on an explicit allowlist: they have no `visibility` column, and some key on `id`, `user_id`, or `actor_id` instead of `owner_id`. They still need RLS. Adding to the allowlist needs owner sign-off. This is how §6 stops being a good intention.

```sql
create type visibility_t as enum ('private', 'contacts', 'public');
```

Three values, created in the first migration, present on every entity from day one even while only `private` is used — §6.

### 5.2 Core tables (Phase 0)

```sql
-- identity ------------------------------------------------------------
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  handle      citext unique not null check (handle ~ '^[a-z0-9_]{3,24}$'),
  handle_locked_at timestamptz,            -- immutable after grace window
  display_name text,
  bio         text,
  avatar_key  text,                        -- Storage key; public avatars are plaintext
  mxid        text unique not null,
  did         text unique,                 -- null until Phase 2
  visibility  visibility_t not null default 'public',   -- the directory entry itself
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- the public key bundle others need to send this user encrypted content
create table identity_keys (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  signing_pub bytea not null,              -- Ed25519, long-term identity
  kex_pub     bytea not null,              -- X25519, for wrapping content keys
  signed_at   timestamptz not null default now(),
  self_sig    bytea not null               -- signing_pub signs the whole bundle
);

create table devices (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null,               -- "McKay's iPhone"
  platform    text not null check (platform in ('ios','macos')),
  device_pub  bytea not null,              -- X25519, wraps the content root key
  mx_device_id text,                       -- Matrix device, for cross-signing
  verified_at timestamptz,                 -- null = unverified, UI must say so
  last_seen_at timestamptz,
  created_at  timestamptz not null default now()
);

-- contacts ------------------------------------------------------------
create type contact_state_t as enum ('pending_out','pending_in','accepted','blocked');

create table contacts (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  peer_id     uuid references auth.users(id) on delete cascade,  -- null if remote-only
  peer_mxid   text,                        -- set for federated peers on other servers
  peer_did    text,
  state       contact_state_t not null default 'pending_out',
  can_see_private_posts boolean not null default false,
  key_verified_at timestamptz,             -- SAS/QR verification, §6.4
  created_at  timestamptz not null default now(),
  unique (owner_id, peer_id),
  check (peer_id is not null or peer_mxid is not null)
);

create table invites (
  code        text primary key default encode(gen_random_bytes(9),'base64'),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  email       text,                        -- optional: pre-addressed invite
  redeemed_by uuid references auth.users(id),
  redeemed_at timestamptz,
  expires_at  timestamptz not null default now() + interval '14 days',
  created_at  timestamptz not null default now()
);

-- content envelope ----------------------------------------------------
-- Every private object in every module is a row here. Modules add their own
-- metadata tables that reference it; none of them store plaintext content.
create type content_kind_t as enum
  ('file','note','doc','photo','video','audio','post','event','transaction','ai_memory');

create table content_objects (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  kind        content_kind_t not null,
  visibility  visibility_t not null default 'private',
  storage_key text,                        -- Supabase Storage object, ciphertext
  byte_size   bigint,
  content_hash bytea,                      -- hash of CIPHERTEXT (plaintext hash leaks)
  key_ref     text not null,               -- where the content key lives, §6.3
  meta_cipher bytea,                       -- encrypted metadata: filename, caption, EXIF
  meta_plain  jsonb not null default '{}', -- ONLY non-sensitive: mime type, dimensions
  room_id     text,                        -- Matrix room, if shared
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on content_objects (owner_id, kind, created_at desc);

-- shared services -----------------------------------------------------
create table notifications (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  module      text not null,
  title_cipher bytea,                      -- notification text is private too
  content_ref jsonb,                       -- a ContentRef, §8
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create table push_tokens (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  device_id   uuid not null references devices(id) on delete cascade,
  apns_token  text not null,               -- needs a paid Apple team, §11-K
  created_at  timestamptz not null default now()
);

create table audit_log (
  id          bigserial primary key,
  actor_id    uuid references auth.users(id) on delete set null,
  action      text not null,               -- 'ai.grant.create', 'contact.block', ...
  subject     jsonb not null default '{}', -- IDs only, never content
  at          timestamptz not null default now()
);
```

**Filenames are encrypted.** `meta_cipher`, not a `filename text` column. A server that can read "2026-tax-return.pdf" and "Dr Patel referral.pdf" knows most of what it needs to; §14's promise is not kept by encrypting only the bytes.

### 5.3 RLS policy sketch

The shipped schema and policies are in `supabase/migrations/`, and they replace §5.2 and this sketch where they differ. Additions: `instance_config` (the Matrix server name, unset until the domain is decided), `content_shares` (one-to-one sharing with a key sealed to the grantee, which works before Matrix exists), and `reports` (brief §6 safety hook).

The pattern, applied to every table:

```sql
alter table content_objects enable row level security;

create policy co_select_own on content_objects
  for select using (owner_id = auth.uid());

-- is_visible_contact is SECURITY DEFINER. A plain subquery on contacts runs as the caller,
-- cannot see the owner's row, and silently denies every contact. Found by the two-user tests.
create policy co_select_contacts on content_objects
  for select using (visibility = 'contacts' and is_visible_contact(owner_id));

create policy co_select_public on content_objects
  for select using (visibility = 'public');

create policy co_insert_own on content_objects
  for insert with check (owner_id = auth.uid());

create policy co_update_own on content_objects
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy co_delete_own on content_objects
  for delete using (owner_id = auth.uid());
```

Three notes that matter more than the SQL:

1. **RLS is defence in depth here, not the primary control.** The primary control is that the server holds ciphertext. If RLS has a hole, an attacker gets encrypted bytes. That is the correct order of reliance — and it is why the "server stores plaintext" list in §5.4 is kept so short.
2. **Storage buckets need their own policies.** Supabase Storage RLS is separate from table RLS and is the most commonly missed hole in Supabase apps. Every bucket gets explicit policies in the same migration as its table, and the two-user test checks object access directly, not just through the app.
3. **`service_role` never appears in client code.** Edge functions that need it get it from the secret store, and any edge function using it is on the mandatory-review list (§11).

### 5.4 The plaintext-on-server list (owner approves line by line)

| What | Table | Why it can't be encrypted | Leak if server compromised |
|---|---|---|---|
| Email, auth metadata | `auth.users` | Supabase Auth needs it to authenticate | who has an account |
| Handle, display name, avatar, bio | `profiles` | it's the public directory; that's its job | nothing — public by design |
| MXID, DID | `profiles` | must be resolvable by other servers | the federation addresses |
| Contact graph (who ↔ who, state) | `contacts` | RLS needs it to evaluate `contacts` visibility | **the social graph** |
| Device names, platform, last-seen | `devices` | key management UI needs it | device inventory, activity times |
| Object size, mime, dimensions, timestamps | `content_objects` | needed for sync, quota, thumbnails | volume + timing metadata |
| Audit actions and timestamps | `audit_log` | it's the audit log | behaviour pattern |
| Push routing tokens | `push_tokens` | APNs needs them | which devices to notify |

**The contact graph is the significant one.** Metadata-private messaging (hiding who talks to whom) is a research-grade problem that Signal only partly solves and Matrix does not solve at all. This proposal does not solve it either. §14 should be read as "content-private, not metadata-private," and the UI must not imply otherwise.

---

## 6. Keys and recovery

### 6.1 Key hierarchy

```
Recovery Key (48 chars, shown once at signup, user stores offline)
        │  Matrix SSSS format
        ▼
    SSSS Key ──────────────────────────────────────────┐
        │ encrypts (stored in Matrix account_data)     │
        ├── Matrix cross-signing master key            │
        ├── Matrix megolm session backup key           │
        └── Totality Content Root Key (CRK)  ◄─── the addition
                    │ HKDF(CRK, object_id)
                    ▼
            per-object content key → XChaCha20-Poly1305 over the blob
```

Per device, the CRK is also wrapped to `devices.device_pub`, so an already-verified device gets it without the recovery key. The recovery key is only needed when every device is lost.

### 6.2 Why reuse SSSS instead of designing one

Matrix's Secure Secret Storage and Sharing already solves the exact problem — a passphrase-or-key-derived secret store, replicated by the homeserver as opaque ciphertext, with a working cross-signing and device-verification UX in production clients (the brief already names `element-hq/element-web` as the messaging reference, §16). Putting the Totality Content Root Key in it as one more SSSS secret means:

- One recovery key for messages, files, photos, docs, and AI memory — not two.
- Device verification (QR / emoji SAS) is implemented once and covers everything.
- No new cryptographic design to audit. The brief's own rule — "never write a chat protocol from scratch" — generalises.

Cost: the content-key system is now coupled to the Matrix plane. If Matrix is ever swapped out, SSSS has to be reimplemented. Accepted: the client's `KeyStore` protocol abstracts it, and SSSS is a well-specified format that can be reimplemented standalone if needed.

### 6.3 `key_ref`

`content_objects.key_ref` is a URI naming where the object's key lives:

- `crk:<object_id>` — derived from the owner's CRK. Solo content.
- `mxroom:<room_id>:<event_id>` — the key was shared into a Matrix room. Shared content.
- `plain:` — not encrypted (public posts, avatars). Must match `visibility = 'public'`; a CI check enforces it.

### 6.4 Verification and the honest warnings

- Contacts are **unverified until SAS/QR verified**, and the UI says "Unverified" rather than nothing. An unverified contact is a possible MITM by the homeserver.
- At signup the recovery key is shown once, and the user must re-enter it before continuing. No "remind me later."
- At signup the UI states plainly: **lose the recovery key and all devices, and your private history is gone — nobody can recover it, including you.** This is the honest consequence of §14 and must not be softened.

> **Owner decision needed (§17 item):** optional secondary wrap of the CRK to an iCloud Keychain–backed passkey. Pro: a realistic recovery path for a normal B user who will lose a 48-character string. Con: Apple becomes part of the trust boundary for key *availability* (not key *access* — the wrap is to a key only the Secure Enclave can use). Recommendation: **offer it, off by default, labelled exactly.**

---

## 7. AI section design (§15)

### 7.1 Permission model

```sql
create type ai_scope_t as enum ('read','propose','act');

create table ai_grants (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  module      text not null,               -- 'reader','calendar','money','messages','social'
  scope       ai_scope_t not null,
  expires_at  timestamptz,                 -- null = until revoked
  granted_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  unique (owner_id, module, scope)
);
```

Default state is **no rows** — the assistant starts with access to nothing, per §6. Every grant, use, and revocation writes to `audit_log`. One settings screen lists all grants with a revoke button each, and shows last-used time per grant.

`act` scope **never** covers outward-facing actions. Sending a message, posting, paying, or deleting always stops for explicit per-action approval regardless of grants (§15 bullet 2.3). `act` means "create a note," "add a calendar event," "start playback" — reversible, inward-facing.

### 7.2 Where decryption happens

Tool calls run **on the client**, against already-decrypted local data. The inference server — even a self-hosted one — never gets a key. For local inference, the loop never leaves the device or the LAN. For hosted inference, the context that leaves is assembled on-device and shown before it leaves.

### 7.3 The hosted-inference gate

Before the first hosted-model turn in a conversation, a sheet lists: the provider by name, the model, and **each content object that will be included, by title**. The user confirms. The conversation then carries a persistent banner naming where inference runs. After the fact is too late — §15's privacy rule says "before it happens, not after."

Conversations are tagged `local` or `hosted:<provider>` and cannot be switched mid-conversation; switching forks a new conversation. This prevents the failure where three private turns of local context get replayed to a hosted model on turn four.

### 7.4 Memory

AI memory is `content_objects` rows of kind `ai_memory`, `crk:`-encrypted like everything else, listed and editable in the AI section, included in export.

### 7.5 Inference hosting recommendation (§17 OPEN)

**Local default, hosted opt-in**, and specifically: Ollama on the owner's Mac, reached from the iPhone over Tailscale, with a small on-device MLX model as the offline fallback. The Mac is already owned, already on, and already the Xcode machine; it has far more headroom than any Pi for a 14B-class Qwen. The Pi gets the *backend*, not the inference — Brief §12 lists Pi inference as a "possibly," and it should stay a possibly.

---

## 8. Module contracts (§6)

One envelope type crosses every module boundary:

```swift
/// The only type modules use to refer to each other's content.
struct ContentRef: Codable, Hashable {
    let module: ModuleID        // .reader, .photos, .money, .messages, ...
    let kind: ContentKind
    let id: UUID                // content_objects.id
    let keyRef: KeyRef          // how to open it, §6.3
    let preview: Preview        // title + thumbnail, enough to render a chip
}
```

Rules, enforced in review and by a package-boundary lint:

1. **Modules never import each other.** `Reader` does not `import Messages`. Both import `TotalityCore`.
2. Cross-module actions go through a `ModuleRegistry` that resolves a `ContentRef` to a renderer and an opener. Attaching a document to a message means the Messages module renders a `ContentRef` chip it does not understand the contents of.
3. **A module may not reach into another module's tables.** Supabase access is per-module through a repository type; the registry is the only cross-module channel.
4. New contracts are recorded in `docs/module-contracts.md` *before* implementation, per §6.

Phase 0 ships the registry and these contracts, with Reader and Messages as the two named participants even though neither exists yet:

| From | To | Contract |
|---|---|---|
| any | Messages | attach a `ContentRef` to a message |
| Reader | Player | `Listen` hands an audio `ContentRef` to the shared player |
| Calendar | Reader, Calls | an event may attach a doc ref and a call ref |
| AI | Reader, Calendar, Money | read `ContentRef` lists under a grant (§7) |
| Social | Messages | social DMs **are** Messages; social opens a Messages thread, it does not have an inbox |

---

## 9. Invites and the two-user test

### 9.1 Invite flow

1. Owner creates an invite → row in `invites`, link `https://totality.<domain>/i/<code>`.
2. Invitee opens it, signs up with a username and password. The username is their handle.
3. On signup the server creates: Supabase user, Matrix account (JWT-provisioned), `profiles` row, `identity_keys` bundle (generated client-side, public halves uploaded).
4. Invitee is shown the recovery key and must confirm it.
5. A `contacts` row pair is created in `accepted` state on both sides (the invite *is* the consent), `key_verified_at` null.
6. Both are prompted to verify keys by QR — skippable, but the contact shows "Unverified" until done.

### 9.2 The two-user test, as CI

`TotalityTests/TwoUserTests` runs against a local Supabase stack and a Matrix server, with two real accounts. Both need Docker, which is not installed and needs disk space (§11-A). Phase 0 is done when these pass with zero feature modules present:

- `test_user2_cannot_select_user1_private_rows` — direct PostgREST call with User 2's JWT
- `test_user2_cannot_fetch_user1_storage_object` — direct Storage call, not through the app
- `test_user2_can_redeem_invite_and_appears_in_contacts`
- `test_user2_can_send_and_user1_receives` — one Matrix message end to end
- `test_shared_object_opens_for_user2_and_not_for_user3`
- `test_revoked_contact_loses_access_to_new_content`
- `test_export_contains_all_user1_content_and_no_user2_content`
- `test_account_deletion_removes_all_rows_and_storage_objects`

Every later module adds its own case to this suite. A module that cannot add one is not done (§6).

---

## 10. Phase 0 work plan

| Step | Deliverable | Gate |
|---|---|---|
| 0.1 | Repo, CLAUDE.md, tokens, brief committed | owner |
| 0.2 | **This document approved** by owner + independent model | **hard gate — no app code before this** |
| 0.3 | Supabase project, migration 1 (types + core tables + RLS), schema-invariant CI check | invariant check green |
| 0.4 | Tuwunel in Docker, JWT login wired to Supabase | owner signs in once, lands in both planes |
| 0.5 | `TotalityCore`: crypto (XChaCha20-Poly1305, HKDF via swift-sodium), `KeyStore` over SSSS, `ContentRef`, `ModuleRegistry` | unit tests + known-answer vectors |
| 0.6 | SwiftUI shell: sign-up/sign-in, recovery-key ceremony, device verification, contacts, invites, settings | runs on owner's iPhone **and** Mac |
| 0.7 | Shared services: search shell, notifications, storage client, audit log, export, account deletion | — |
| 0.8 | Bubble-cloud home screen with zero modules + list-view accessible alternative | VoiceOver pass |
| 0.9 | Two-user test suite green in CI | **hard gate — Phase 1 does not start otherwise** |

Rough estimate, assuming ~15 h/week: **10–14 weeks.** The hours are my assumption, since the brief gives no build hours, and the range is judgment rather than measurement. Phase 0 is not a warm-up; it is the hardest cryptographic and architectural work in the project, done before any of it is fun. That is the right order, and the brief is right to insist on it, but the schedule should be honest.

---

## 11. Conflicts and blockers found in the brief

These need owner decisions. A blocks all building; K blocks stage B.

### A. **BLOCKER — Disk space.** `/` has **about 1.6 GB free of 228 GB.**
The disk is effectively full; the 87% that `df` prints counts only the system volume. Xcode 16.2 and the iOS 17.2 and 18.2 simulators are already installed (12 GB in `~/Library/Developer`). Still needed, by rough estimate: DerivedData 5–20 GB and Docker with Conduit and local Supabase ~10 GB. Plan on freeing **30–40 GB**. This is the most immediate obstacle and the brief does not mention it.

### B. **Not a blocker — `xcode-select` points at Command Line Tools.**
Xcode works without changing it: setting `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command ran `xcodebuild` and `simctl` successfully. This optional command makes it permanent and needs the owner's password:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### C. **Decision needed — "CI from day one at $0" (§8) does not hold for a private repo.**
Third-party sources put private-repo macOS usage at a **10× multiplier** on 2,000 free minutes, so about 200 macOS minutes/month (one source says 8×). Confirm on GitHub's billing page. At an estimated 8–15 minutes per build and test cycle, that is roughly **15–25 CI runs per month**, against a brief that requires CI on every pull request. Three ways out:
1. **Self-hosted runner on the owner's Mac** — $0, unlimited minutes, works today. *Recommended.*
2. Make the repo public — free unlimited Actions, but §8 says private during A/B and §11's secrets discipline becomes load-bearing rather than advisory.
3. Accept a reduced CI policy (run on merge to `main` only, not every PR) — weakens the §8 rule.

### D. **§16 is still the web-app section.** v4 made the app native; §16 was not updated.
shadcn/ui, Radix, Origin UI, Magic UI, Aceternity, React Bits, 21st.dev, tweakcn, and Framer Motion are all React/web and have **no role in a SwiftUI codebase**. Likewise "every module is screenshotted via Playwright" (§16, visual verification) cannot work on native UI. Native equivalents:

| §16 says | Native replacement |
|---|---|
| shadcn/ui + Radix | a first-party SwiftUI component package, `TotalityUI` — there is no substrate to adopt, it gets built |
| tweakcn | the design-token Swift file + Figma variables |
| Origin UI / Magic UI / 21st.dev | no equivalent; SwiftUI's own controls, restyled |
| Framer Motion | SwiftUI animation + `matchedGeometryEffect`, with named duration/easing constants |
| Lucide | `lucide-icons/lucide` ships SVGs; vend them as an asset catalogue, **or** use SF Symbols. See §11-E |
| Playwright screenshots | `pointfreeco/swift-snapshot-testing` + XCUITest |

The real consequence: **the "compose, don't invent" rule in §16 is not available.** It depends on a curated component library that does not exist for SwiftUI. The anti-slop defence has to come from tokens + a first-party component package + the Figma file instead — which is more work, and worth knowing before the design phase starts.

### E. **Lucide vs SF Symbols.** §16 says "Lucide only, one stroke weight."
Lucide on iOS means shipping SVGs as assets and losing dynamic type scaling, optical sizing, SF Symbol animations, and automatic weight matching with system UI. SF Symbols gets all of that free and is what makes an iOS app feel native. Against: SF Symbols can't ship to a web surface later, and Lucide is in the brief as a decision. **Recommendation: SF Symbols for system-level chrome, Lucide for the module bubbles** (the home screen is the project's signature surface and deserves its own icon language). Owner's call.

### F. **Handle immutability is implied but not stated.** Matrix MXIDs cannot be renamed.
If handles derive from MXIDs (§4.3), handle changes mean account migration. Proposal: handles are freely changeable for 30 days after signup, then fixed. Alternative: decouple MXID from handle entirely (MXID = opaque UUID), which allows free renames but makes the federated address unreadable (`@a7f3...:totality.example`). Recommendation: the 30-day window.

### G. **Phase 1 is six modules.** (§7: Reader+Listen, calendar, email, player, photos, money, AI.)
Each is a real product. At ~15 h/week after a 10–14 week Phase 0, Phase 1 as specified is realistically 9–15 months. Recommendation: **Phase 1a = Reader (with Listen) + Calendar + AI basic** — the three that compound (the AI is only interesting once it has the Reader and calendar to work over), ship it as the daily driver, then Phase 1b for email/photos/money. This is a sequencing change, not a scope cut.

### H. **Supabase free tier vs the Photos module.** 1 GB Storage total.
A phone photo library is 20–200 GB. The Photos module cannot run on the Supabase free tier at any scale, which makes the Pi a *prerequisite* for Photos, not an eventual direction. Either Photos moves after the Pi exists, or Photos stores blobs on the Mac/Pi from the start with Supabase holding only metadata. Recommendation: the latter — design `content_objects.storage_key` as a pluggable backend URI from day one so the storage target is configuration.

### I. **§9 and §10 model and pricing claims are not verified here.**
The brief states specific benchmark numbers, plan prices, and Fable inclusion rules as of October 2026. I have not independently verified any of them and they should be checked against Anthropic's current published pricing before the §10 subscription decision is acted on. Nothing in this architecture depends on them.

### J. **"`main` is protected" (§8) conflicts with a private repo at $0.**
GitHub's docs list rulesets on private repositories only for paid plans; GitHub Free gets them on public repositories. Options: pay for GitHub Pro, make the repo public, or keep the PR discipline by convention with nothing enforcing it. Recommendation: convention during stage A, and revisit before anyone else commits.

### K. **BLOCKER FOR STAGE B — free Apple provisioning does not reach the inner circle.**
§12 defaults to free provisioning, but a free Personal Team installs on devices the owner builds to, expires after 7 days, and per Apple's forums does not support Push Notifications, iCloud, or Sign in with Apple. Stage B therefore has no $0 path on iPhone: invitees cannot install the app without TestFlight, and Messages cannot send push notifications. Associated Domains could not be confirmed either way. **The $99/year Apple Developer Program is effectively required for stage B**, or stage B must wait. This is the owner's call under the no-money rule.

### L. **The domain is not free.**
The proposal needs a domain for handles, MXIDs, and `.well-known`, and it is hard to change later. A purchased domain breaks the literal A/B no-money rule (roughly $10–15/year by rough estimate). A free subdomain is a dependency on someone else's service, which undercuts §14's portability. Recommendation: buy one, as a named exception.

**Resolved.** The owner bought `usetotality.com` through Cloudflare on 2026-10-30, as the one named exception to the no-money rule. It renews yearly at roughly $10, with auto-renew on, and it expires in October 2027 if renewal ever fails. `matrix_server_name` is `usetotality.com`, so addresses read `@handle:usetotality.com`. The server itself can sit on another host and be pointed to with `.well-known`, which keeps Pi self-hosting open. The name cannot change once set, and setting it fills in `mxid` on existing rows.

### M. **Decision needed — the brief's editor is web-only.** §3 names TipTap + Yjs for documents.
TipTap runs in a browser, so it has no place in SwiftUI short of hosting a web view inside the Reader. Yjs matters only for documents edited by several people, which arrive with Matrix. The Reader therefore ships plain-text notes first and treats documents as unbuilt. Options when rich documents are next: a native editor on `AttributedString` with Y-CRDT bindings (not yet evaluated), or a web view hosting TipTap. Recommendation: stay native and decide after the Figma file, because the editor's design drives the choice. Owner's call.

**Partly resolved.** The owner approved the Reader upgrade on 2026-10-31, which merged notes into docs on a native editor: `UITextView` and `NSTextView` over a small Markdown body. There is no web view. Yjs stays undecided, because it only matters when several people edit one doc, which needs Matrix and so waits for Phase 2.

### N. **Sign-in is a username and password, with no recovery.**
The owner chose this on 2026-10-30. It removes the outside email, the custom URL scheme, and the pre-registered password risk that came with email links. The database refuses any account that isn't a valid username at `totality.invalid`, and refuses to change one. What it gives up:

1. **A forgotten password has no self-service reset.** The owner can set a new one from the Supabase dashboard. That works for a small circle and does not scale, and at scale it means whoever runs the server can take over an account's login. Private content stays sealed either way, because keys are not tied to the login.
2. **The server receives the password.** It travels over HTTPS and is stored as a hash, but Supabase handles it in the clear in between. So a password must never unlock or derive a content key.
3. **Guessing is limited per IP address, not per account.** Supabase's leaked-password check needs the paid plan. The 12-character minimum is the main defence.
4. **Public sign-up is open.** Anyone holding the app's public key can create an account. Row-level rules still keep them out of other people's data. Close it or add a captcha before the app leaves the owner's circle.

### O. **Mail is its own system, on the Oracle server.**
The owner agreed the Mail spec, issue 37, on 2026-11-02. It changes this proposal in four ways, and replaces the "mail cache" that §2 first put in Supabase:

1. **Mail is Totality's own email.** Every account gets `username@usetotality.com`. There's no connected outside account. Sign-up still asks for no email address, so §11-N stands.
2. **Mailboxes live on the Oracle server, not Supabase.** They're sealed files. Supabase's free tier has 1 GB of storage already shared with the Reader, and the server has about 41 GB free. The owner accepted that this one server has no backup yet.
3. **Mail between accounts doesn't use Matrix.** Email is its own system, and Phase 2 is closed.
4. **Outside mail is the one exception to client-side sealing.** It arrives readable, so the server handles it for a moment, in memory only and out of logs, then seals it to the recipient's public key. `CLAUDE.md` records this under non-negotiable 2.

Cloudflare Email Routing receives outside mail and Cloudflare Email Service sends it, on Workers Paid at $5 a month plus usage. Cloudflare's own logs keep the subject and addresses of that mail, which the owner accepted on 2026-11-02 on the condition that the spec and the app say so. Mail between accounts never goes through those logs.

## 12. What I need from the owner to proceed

**Blocking (Phase 0 cannot start):**
1. Free 30–40 GB of disk, or decide on external storage (§11-A)
2. Pick a CI approach (§11-C) — recommendation: self-hosted runner on the Mac
3. **Approve or reject this document** — and get it reviewed by the independent model per §18, or waive that review
4. Create the Supabase project yourself; I cannot create accounts

**Blocking Phase 0 design, answerable in a sentence each:**
5. ~~Domain name for the homeserver and handles~~ Resolved: `usetotality.com` (§11-L).
6. SF Symbols vs Lucide (§11-E)
7. 30-day handle window, or opaque MXIDs (§11-F)
8. Secure Enclave recovery wrap offered or not (§6.4)

**Non-blocking, wanted before Phase 1:**
9. Phase 1a/1b split (§11-G)
10. Photos storage direction (§11-H)
11. Whether stage B justifies the $99 Apple Developer Program (§11-K)
12. How `main` is protected (§11-J)

---

*End of proposal.*
