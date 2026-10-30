# Totality — standing instructions

Native iPhone + Mac super app. Owner: McKay Clemens. Spec: `docs/founding-brief-v6.pdf`.
Architecture: `docs/phase-0-architecture-proposal.md`. Contracts: `docs/module-contracts.md` (created in Phase 0).

**Read this file every session. Read the architecture proposal before touching anything structural.**

## The gate

The owner waived the independent model review on 2026-10-30 ("Waive it, start building"), so Phase 0
work may proceed against the proposal. The waiver covers that one review, nothing else: the build order,
the two-user test, and security review of anything touching auth, keys, or user data all still apply.

The owner overrode the Phase 1 gate on 2026-10-30 ("Override, start Phase 1"), so Phase 1 is being built
before Phase 0 passes the two-user test. The override covers starting Phase 1 modules, nothing else:
Phase 2 stays closed, the remaining Phase 0 work still has to land, and no module is done until it meets
the definition of done below, which needs the app target, a real device, and a real backend.

## Non-negotiables

These fail review, full stop. There is no "just for now" version of any of them.

1. **Every user-data table has `owner_id`, `visibility`, RLS enabled, and a mutation policy.**
   `scripts/check-schema-invariants.sql` is written at Phase 0 step 0.3 and then runs in CI. Do not add
   a table without running it. Account and infrastructure tables are on an owner-approved allowlist.
2. **Private content is encrypted client-side before upload.** A plaintext content column on a
   private entity is an automatic rejection. Filenames and captions count as content.
3. **No passwords, ever.** Email magic link now, passkeys later. Nothing stores or transmits a password.
4. **No secrets in the repo.** Not in code, not in tests, not in history, not in a commented-out line.
   Environment and GitHub Secrets only. Assume anything committed is permanent and public.
5. **Encryption labels must be literally true.** "End-to-end encrypted" in the UI only where the
   server genuinely cannot read it. Group calls through an SFU without E2EE enabled are
   "encrypted in transit." PSTN calls and outbound email are neither — label them honestly.
6. **The AI starts with access to nothing.** Access comes from revocable per-module grants.
   Outward-facing actions (send, post, pay, delete) always stop for explicit approval regardless
   of grant scope.
7. **Modules never import each other.** Cross-module anything goes through `ContentRef` and
   `ModuleRegistry` in `TotalityCore`.
8. **Plaid is read-only. Google scopes are minimal.** Gmail read is not Gmail send.

## Definition of done (every module)

A module is done when all of these are true — not when it compiles, not when it works for the owner:

- [ ] Spec written in plain English and agreed before building
- [ ] Builds for **both** iPhone and Mac
- [ ] Owner has run it on a real device
- [ ] Unit tests pass
- [ ] **Two-user test passes**: User 2 cannot see User 1's private content, can accept an invite,
      can receive a message, can open something User 1 shared. A module that only works with one
      account in the world is an A-only hack — reject it.
- [ ] The module's own case is added to `TotalityTests/TwoUserTests`
- [ ] Empty, loading, and error states exist and were looked at
- [ ] Anything touching auth, keys, or user data went through security review
- [ ] Committed

Never start the next module on a broken previous one.

## Build order

Phase 0 foundation → Phase 1 solo modules (Reader+Listen, calendar, email, player, photos, money,
AI basic) → Phase 2 network modules (Messages, calls, unified social) → Phase 3 hardening →
Phase 4 commerce. Brief §7. One module at a time.

## Architecture in one paragraph

SwiftUI multiplatform client, three server planes. **Supabase** holds the account, the public handle
directory, solo-module data, and ciphertext blobs. **Matrix** (Conduit) carries every private
interpersonal thing — DMs, communities/channels, call signalling, device keys, private posts, shared
docs — all E2E. **atproto** (Phase 2) carries public social posts only. A record's transport is chosen
by its **visibility**, not by its module. Keys live on devices, backed up in Matrix SSSS under one
recovery key. Large binaries go to Supabase Storage as ciphertext; Matrix holds the key and the
membership.

## Design

- **Neumorphic, white / dark grey.** Soft dual shadows; background and surface close in value.
  No rainbow palette, no pure black, no hard borders or harsh drop shadows as the default treatment.
  Elevation comes from the shadow pair, not from lines.
- **One accent colour, used sparingly.**
- Body text meets WCAG AA contrast. The look never wins over legibility.
- Tokens in `Sources/TotalityUI/Tokens.swift` + `docs/design-tokens.md`. Read them before writing UI.
  Never hard-code a colour, radius, spacing value, or duration.
- **Figma is the visual source of truth once it arrives** and overrides these words where they conflict.
  Until then the tokens are provisional placeholders, not brand decisions.
- Real content in every mock and test. Never lorem ipsum — slop hides in fake content.
- Note: brief §16's UI library list (shadcn, Radix, Origin UI, Magic UI, 21st.dev, Framer Motion,
  Playwright screenshots) is from the superseded web-app plan and does not apply to SwiftUI.
  Components are first-party in `TotalityUI`; visual verification is swift-snapshot-testing + XCUITest.

## Cost rule

Stages A and B cost nothing. Free tiers, open source, hardware already owned. If a feature cannot be
done at $0, it waits or gets redesigned — it does not quietly start a subscription. Flag it, don't
decide it.

## Running the app

The app target is `App/Totality.xcodeproj`, one target for iPhone and Mac. Set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at Command Line Tools.
The project signs with the owner's free Personal Team, and command-line builds need
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`. An ad-hoc Mac build gets `-34018` from
the Keychain, so the Reader shows its key error by design: never fall back to a weaker keychain to get
around that. `keychain-access-groups` is pinned in the entitlements so a team change cannot hide the key.

## Working discipline

- Work lands through pull requests; the PR is the review surface. GitHub may not enforce this on a
  free private repo (proposal §11-J), so treat `main` as protected whether or not it is enforced.
- Small conventional commits, one module-step each.
- GitHub Issues hold the OPEN decisions and each module's spec.
- Tags mark completed phases.
- Red build blocks merge — for you exactly as for a human.

## Decisions that are locked (do not relitigate)

Name: Totality. Identity: handle + email, phone optional. v1 is a native iPhone app with a connected
Mac app. Groups are Discord-shaped; DMs are Snapchat-shaped minus the clutter. Social is ONE module
with a Lemon8-style discovery homepage. Docs are a content type inside the Reader — there is no Docs
module. Listen is a button inside the Reader — there is no Speechify module. Shopping is
Amazon-*like*, never an Amazon wrapper. Home screen is an Apple Watch-style bubble cloud.
Federation and E2E are principles, not features. Pi self-hosting is the hosting direction.

## Decisions that are OPEN — ask, do not guess

Brief §17 plus the items in §11–12 of the architecture proposal. When you hit one: stop and ask.
A guess here costs more than a question.
