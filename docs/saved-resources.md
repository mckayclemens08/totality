# Saved Resources & Tooling Triage (2026-11-27)

Curated from *GitHub Repositories & Resources List V3* (22 links) against Totality's architecture (native SwiftUI iOS modules + `web/` static/web app + AI agent workflow + `$0` cost rule).

## Implemented Now
- **`SamuelZ12/research-sources` (`rsrc`)** — <https://github.com/SamuelZ12/research-sources>
  - **What it is:** Zero-dependency read-only Python CLI (`>=3.11`, MIT) that fetches structured JSON from X, Reddit, Hacker News, YouTube transcripts, LinkedIn posts, and Apple App Store listings/reviews.
  - **Setup:** Installed `uv` + `rsrc` at `~/.local/bin/rsrc`, plus the `research-sources` skill at `~/.gemini/config/skills/research-sources/` and `~/.codex/skills/research-sources/`.
  - **Optional extras when needed:** `yt-dlp` + `deno` for YouTube transcripts (`rsrc youtube`), your X session for `x search`, and Ego Lite for live Reddit search.

## Worth Keeping (Saved for Upcoming Work)
1. **`uizze.com`** — *UI/UX & anti-slop sweep (`next-up.md`)*
   - Agent UI skills (`uizze-ui`, `image-to-ui`, anti-slop PR finish gates) and real iOS/web screen references (live 800k-screen MCP retrieval has paid tiers; skills are open).
   - Saved directly under **Website review** and **Security audit + polish/uniformity sweeps** in `.claude/next-up.md`. Always keep Totality's `docs/design-tokens.md` and `docs/standing-rules.md` (`Theme.current`, light/dark tokens, no sunken look) authoritative over external presets.
2. **`thinkui.xyz`** — *UI reference MCP alongside Uizze*
   - Hosted MCP (`https://thinkui.xyz/mcp`, requires API bearer token `tk_...`) supplying real-product UI examples (`find_ui_references`, `find_ui_elements`, animated icons/materials) for empty states, paywalls, onboarding, and `app.usetotality.com`.
3. **`ripienaar/free-for-dev`** — <https://github.com/ripienaar/free-for-dev>
   - Directory of free SaaS/PaaS/IaaS and monitoring tiers. Useful reference whenever checking infrastructure under Totality's `$0` cost rule.
4. **`motiondivision/motion`** — <https://github.com/motiondivision/motion>
   - React/JS UI motion library. **Web-only** (`web/` / `app.usetotality.com`), not iOS native. Must honor Reduce Motion.
5. **`airbnb/lottie-web`** — <https://github.com/airbnb/lottie-web>
   - Vector After Effects animations for **web only** (`web/` / marketing). On native iOS, prefer SwiftUI animations / `.symbolEffect` first, or `airbnb/lottie-ios` if a custom vector animation is truly needed.
6. **`remotion-dev/skills`** — <https://github.com/remotion-dev/skills>
   - Optional keep solely for generating programmatic promo / App Store preview videos in React later — not for app runtime code.

## Skipped (Not Needed for Totality)
- `franciscop/ola`, `juliangarnier/anime`, `jeremyckahn/shifty`, `CreateJS/TweenJS` — Overlapping JS tween/interpolation libraries; native SwiftUI springs/keyframes handle iOS motion, and CSS + `motiondivision/motion` cover `web/`.
- `jonobr1/two.js`, `konvajs/konva` — HTML5 2D Canvas/drawing libraries; unnecessary unless building a web whiteboard/vector editor.
- `mattdesl/gifenc` — Low-level JS GIF encoder; unneeded alongside iOS `ImageIO`/video tooling.
- `drawcall/Proton` — JS particle library; out of place for Totality's calm UI.
- `lume/lume`, `mrdoob/three.js`, `BabylonJS/Babylon.js` — Overlapping WebGL/3D engines; overkill unless building a 3D marketing page.
- `godotengine/godot`, `blender/blender` — 2D/3D game engine and 3D creation suite; outside Totality's scope.
- `motion-canvas/motion-canvas`, `ManimCommunity/manim` — Code-driven video/math animation frameworks superseded here by `remotion-dev/skills` if promo videos are ever scripted.
