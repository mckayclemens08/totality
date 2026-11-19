# usetotality.com

The signed-out public site. The signed-in web app is `web/site` at app.usetotality.com.

- Static files in `site/`, no build step and no dependencies. Fonts (Geist, Geist Mono, OFL) are self-hosted.
- Strict CSP in `site/_headers`: no inline code, no third-party scripts, analytics or trackers.
- `npm test` checks the CSP rules, that nothing loads from another origin, and that every theme meets WCAG AA.
- Preview deploy (free Pages project `totality-public`): `npx -y wrangler@4 pages deploy site --project-name totality-public --branch preview`.
- Live at usetotality.com since 2026-11-19 (owner approved). The apex also carries Matrix discovery, mail arrival,
  search, blobs, profiles and /privacy through the server tunnel, so the domain is NOT attached to Pages. Instead the
  Worker in `worker/` runs only on the homepage routes in `worker/wrangler.toml` and serves those files from
  totality-public.pages.dev. Production: `npx -y wrangler@4 pages deploy site --project-name totality-public --branch main`.
  Worker: `cd worker && npx -y wrangler@4 deploy`. A new top-level file needs a route and a PATHS entry.
- The main button reads "Coming soon to iPhone" (`#get` in `site/index.html`). Swap it for a TestFlight link once one exists.
