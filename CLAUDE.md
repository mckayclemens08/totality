# Totality — standing instructions (short form)

iPhone super app, with a website planned in place of a Mac app. Owner: McKay Clemens. Full rules, owner quotes and dates: `docs/standing-rules.md`. Read the matching section there before touching auth, keys, mail, Google, the server or the gates. Architecture: `docs/phase-0-architecture-proposal.md`. Contracts: `docs/module-contracts.md`.

## Non-negotiables (each fails review)
1. Every user-data table has `owner_id`, `visibility`, RLS on and a mutation policy. Run `scripts/check-schema-invariants.sql` before adding a table.
2. Private content, filenames and captions included, is encrypted on the device before upload. Outside email is the one exception (see the full rules).
3. Passwords sign you in and do nothing else. They go only to the account server over HTTPS. The app never stores or logs them, and they never unlock or derive a key. Totality sends no sign-in email.
4. No secrets in the repo, ever: not in code, tests, history or comments.
5. Encryption labels must be literally true.
6. The AI starts with access to nothing. Send, post, pay and delete always stop for approval.
7. Modules never import each other. Cross-module work goes through `ContentRef` and `ModuleRegistry`.
8. Plaid is read-only, and Google scopes are minimal, except Gmail `gmail.modify` and full Drive access for the Reader (see the full rules).

## Gates
Phases 0 and 1 are both being built, and Phase 2 is open starting with Messages. Phase 4 is closed. A module is done only when:
- its spec is agreed
- **a UI mockup the owner has seen comes before building** (owner, 2026-11-17)
- it builds and the owner has run it on a real device
- its unit tests and the two-user test pass, with its case in `TotalityTests/TwoUserTests`
- its empty, loading and error states were looked at
- anything touching auth, keys or user data had a security review
- it's committed

Never start the next module on a broken one.

## Design
- Neumorphic, with soft dual shadows and no hard borders.
- No sunken look anywhere, enforced by `NoSunkenLookTests`.
- One accent colour, and text meets WCAG AA.
- Use the tokens in `Sources/TotalityUI/Tokens.swift`, never hard-coded values.
- Real content, never lorem ipsum.
- The visual target is the approved canvases:
  - redesign: https://claude.ai/artifact/TfyX6ksdt2RDkDRd3k94fd
  - Social: https://claude.ai/artifact/8LBGndLQUGzYYSVrU1TeSi
  - website: https://claude.ai/artifact/EPDH71EqdT2cz34HJxv1Dr
- Tinted themes and a Graphite dark theme are approved but not built. Update `docs/design-tokens.md` before building them.

## Cost
Stages A and B cost $0. Flag anything that would cost money; don't decide it. The only exceptions are the domain (about $10 a year) and Cloudflare Workers Paid ($5 a month). Never upgrade Oracle to paid.

## Working
- Work lands through PRs, and `main` is treated as protected. Merge by hand only when every check passes.
- Small conventional commits. Issues hold open decisions and specs.
- Run one build at a time on this machine, with `-j 2`.
- Build with `-quiet` and show only errors (`2>&1 | grep -E "error:|warning: unre|BUILD"`), never the full log.
- For the app at `App/Totality.xcodeproj`, see the "Running the app" and "The server" sections of the full rules.
- **Open decisions: ask, don't guess.**
