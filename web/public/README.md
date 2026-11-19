# usetotality.com

The signed-out public site. The signed-in web app is `web/site` at app.usetotality.com.

- Static files in `site/`, no build step and no dependencies. Fonts (Geist, Geist Mono, OFL) are self-hosted.
- Strict CSP in `site/_headers`: no inline code, no third-party scripts, analytics or trackers.
- `npm test` checks the CSP rules, that nothing loads from another origin, and that every theme meets WCAG AA.
- Preview deploy (free Pages project `totality-public`): `npx -y wrangler@4 pages deploy site --project-name totality-public --branch preview`.
  The apex domain is not attached until the owner approves.
- The main button reads "Coming soon to iPhone" (`#get` in `site/index.html`). Swap it for a TestFlight link once one exists.
