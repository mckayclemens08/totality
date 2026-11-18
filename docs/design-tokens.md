# Totality — Design Tokens (PROVISIONAL)

**Status:** placeholders, not brand decisions. The owner's Figma file is the visual source of truth and
overrides everything here when it arrives (Brief §16, §17). Until then these exist so that no module is
ever written against hard-coded values.

These ship as `Sources/TotalityUI/Tokens.swift`, and `Tests/TotalityUITests/TokenTests.swift` checks the contrast rules on every surface in every theme.

## Principle

Neumorphic, in six themes (below). The owner removed dark mode on 2026-10-31 and brought it back as Graphite on 2026-11-17. **Background and surface stay close in value — that closeness is the
effect.** Elevation and grouping come from the soft shadow pair, never from borders or hard drop
shadows. Content contrast is carried by type weight, the single accent, and imagery.

The failure mode of neumorphism is unreadable text. Guardrail: **body text meets WCAG AA (4.5:1),
large text 3:1.** Every ratio below was computed, not estimated. The look never wins over legibility.

## Colour

The table is the Light theme, the default. The other themes change the same tokens; see **Themes**.

| Token | Hex | Use | Contrast vs `surface` |
|---|---|---|---|
| `bg` | `#E8EBEF` | app background, the plane bubbles sit on | — |
| `surface` | `#EDEFF2` | raised cards, controls, bubbles | — |
| `surfaceSunken` | `#E2E5EA` | a flat tone with no inner shadow: progress tracks, image placeholders, timeline rules, a send button with nothing to send. Never an inset or pressed-in surface. | — |
| `shadowLight` | `#FFFFFF` @ 90% | top-left highlight of the shadow pair | — |
| `shadowDark` | `#C3C9D3` @ 70% | bottom-right depth of the shadow pair | — |
| `textPrimary` | `#15181D` | body, titles | **15.5:1** ✓ AA/AAA |
| `textSecondary` | `#555C68` | captions, metadata | **5.9:1** ✓ AA |
| `textTertiary` | `#7D8592` | disabled, placeholder | 3.2:1 — large text / non-text only |
| `accent` | `#1F5FBF` | the one saturated colour, used sparingly | **5.3:1** ✓ AA |
| `accentOn` | `#FFFFFF` | text on an accent fill | **6.1:1** vs accent ✓ AA |
| `highlight` | `#D3E0F4` | the sentence Listen is reading, and the selection wash: the chosen row, chip, folder or day | `textPrimary` on it **13.3:1** ✓ AA |
| `highlightStrong` | `#A9C5EE` | the word Listen is reading | `textPrimary` on it **10.1:1** ✓ AA |
| `danger` | `#B3261E` | destructive, key-loss warnings | 5.7:1 ✓ AA |
| `success` | `#1E6F4C` | verified contact, synced | 5.3:1 ✓ AA |

> **Accent is the most provisional token here.** The owner chose blue on 2026-10-30, replacing the
> original burnt ochre. The exact shades are placeholders until the Figma file arrives. Changing them
> is one line in two places.

**Cover tones** (`CoverTone` in `Tokens.swift`): `#4E6B80`, `#A83636`, `#2E6B47`, `#5B45A8`, `#8A5A2B`,
`#3F5F8A`. A book or document with no cover of its own gets one, picked from its ID so it never changes,
with a white icon on it. They're content, like a photo, not UI, so the one-accent rule doesn't cover
them (owner, 2026-11-18: "randomize a color if there isn't a book cover").

## Themes

The owner, 2026-11-17: "not just a white background, but red, blue, green, etc as well", and "add a gray
theme for dark mode", which reverses the 2026-10-31 dark-mode removal. Colours are from the Social
canvas's Theme boards. A person picks one in Settings → Theme (`ThemePickerView`); `ThemeStore` keeps the
choice on the device under `app.theme`, and `Theme.current` returns its palette, so every view that reads
it redraws when it changes. The tinted themes stay pale and light with one matching accent; Graphite is
dark grey and asks the system for dark controls. `danger` and `success` keep Light's values in the tinted
themes.

| Token | Blush | Sky | Sage | Lilac | Graphite |
|---|---|---|---|---|---|
| `bg` | `#F2E6E6` | `#E3ECF5` | `#E5EEE7` | `#ECE8F3` | `#2A2E34` |
| `surface` | `#F7ECEC` | `#EAF1F8` | `#ECF3EE` | `#F1EEF7` | `#30353C` |
| `surfaceSunken` (flat) | `#EADCDC` | `#D9E3EE` | `#DAE5DD` | `#E1DCEB` | `#25292E` |
| `shadowLight` | `#FFFFFF` @ 90% | same | same | same | `#FFFFFF` @ 6% |
| `shadowDark` | `#D6BEBE` @ 70% | `#BAC8DA` @ 70% | `#BCCEC2` @ 70% | `#CBC4DB` @ 70% | `#000000` @ 45% |
| `textPrimary` | `#15181D` | `#15181D` | `#15181D` | `#15181D` | `#E7E9ED` |
| `textSecondary` | `#6A5555` | `#4F5D6E` | `#52625A` | `#5C5870` | `#A7AEB9` |
| `textTertiary` | `#8A7272` | `#707D8D` | `#728279` | `#7C7790` | `#8C939E` |
| `accent` | `#A83636` | `#1F5FBF` | `#2E6B47` | `#5B45A8` | `#8DB2EE` |
| `accentOn` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#16191E` |
| `highlight` | `#F3D3D3` | `#CFE0F2` | `#D2E6D8` | `#E0D8F0` | `#33405A` |
| `highlightStrong` | `#E8B4B4` | `#A9C5EE` | `#AFD2B9` | `#C7B8E6` | `#44577D` |
| `danger` | Light's | Light's | Light's | Light's | `#F2A39B` |
| `success` | Light's | Light's | Light's | Light's | `#7FCFA6` |
| lowest body/muted contrast | 4.6:1 | 4.7:1 | 4.7:1 | 4.6:1 | 5.5:1 |

All computed by `TokenTests`, which runs every rule above against every theme.

## Shadow pair

Neumorphism is two shadows, always offset in opposite directions, always soft.

| Token | Value |
|---|---|
| `elevationRaised` | `+6,+6 blur 12 shadowDark` · `−6,−6 blur 12 shadowLight` |
| `elevationSubtle` | `+3,+3 blur 6` · `−3,−3 blur 6` |
| `elevationFlat` | none |

Nothing else. No `elevationXL`, no coloured shadows, no border as a substitute.

### No sunken look, anywhere

`elevationPressed` is retired. The owner, 2026-11-15: "I just don't like the sunken-in look", then
"anywhere" (issue 132). Nothing in the app is inset, inner-shadowed or pressed in: not at rest, not as a
selected state, not as press feedback. Neumorphism in Totality means raised surfaces only.

- **Selected or on:** accent-tinted icon or text, with `selectionWash` (a flat `highlight` fill) behind
  the chosen one. A toggle that's raised when off uses `toggleSurface`, which turns into the wash when on.
- **Pressed:** a slight scale and opacity change (`TilePress`), never a sink.
- **Tick boxes:** fill with `accent` and a check.
- **Text boxes:** `raisedField()`.
- **Flat fills:** progress tracks and image placeholders keep a flat `surfaceSunken` tone, with no inner shadow.

`NoSunkenLookTests` fails the build on `neumorphic(.pressed`, `elevationPressed` or an inner shadow in
any source file.

## Radius

| Token | Value | Use |
|---|---|---|
| `radiusSm` | 10 | chips, badges, inline controls |
| `radiusMd` | 18 | cards, fields, sheets |
| `radiusLg` | 28 | large cards, feed cover cards |
| `radiusField` | 24 | text boxes and the composer: a capsule at one line, rounded as text grows |
| `radiusFull` | ∞ | module bubbles, avatars |

Generous radii are part of the neumorphic read. Nothing in the app is square-cornered.

## Control sizes

`Metric` in `Tokens.swift`. Fixed sizes of the shared controls from the 2026-11-17 redesign.

| Token | Value | Use |
|---|---|---|
| `headerButton` | 44 | the raised round header button (`HeaderButton`) |
| `addButton` | 56 | the accent round + at the bottom right (`AddButton`) |
| `removeButton` | 26 | the minus on a tile while Home is edited |
| `ringStroke` | 7 | a `ProgressRing`'s track (`highlight`) and its accent arc |
| `selectionOutline` | 2 | the accent outline around the chosen tile while Home is edited |
| `tileGap` | 14 | the gap between Home's tiles, and a tile's inner padding |
| `tileBleed` | 6 | the inset of a full-bleed tile's pictures (Photos) |

## Spacing — 4pt base

`space1` 4 · `space2` 8 · `space3` 12 · `space4` 16 · `space5` 24 · `space6` 32 · `space7` 48 · `space8` 64 · `hairline` 1

`hairline` is for rules on a timeline, which sit in the surface in `surfaceSunken`. It isn't a border.

Default screen gutter is `space4` (16). Default stack gap is `space3` (12).

## Type

System font (SF Pro) with Dynamic Type. The code uses system text styles, so real sizes follow Apple's scale and differ slightly from the base sizes below. A custom display face is a Figma-stage decision; shipping one
now would be a brand decision made by the wrong person.

| Token | Size / weight | Use |
|---|---|---|
| `display` | 34 / bold, tight | module titles, the home screen |
| `title` | 24 / semibold | screen titles |
| `headline` | 18 / semibold | card titles, section heads |
| `body` | 16 / regular | body text |
| `callout` | 15 / medium | emphasised body, buttons |
| `caption` | 13 / regular | metadata, timestamps |
| `micro` | 11 / medium | badges, counts |

**Every size scales with Dynamic Type.** Fixed-size text is a review failure. Hierarchy is carried by
weight more than by size — on low-contrast neumorphic surfaces, weight reads better than scale.

### Writing type

`WritingType` sets the Reader's writing page, and a doc exported as a PDF in the Doc layout uses the
same numbers, so the printout matches the page. The editor's stylesheet gets them as `--tl-*` variables.

| Token | Value | Use |
|---|---|---|
| `bodyScale` | 1.0625 × body | the page's body text |
| `lineHeight` | 1.6 | body lines |
| `headingLineHeight` | 1.3 | heading lines |
| `headingScales` | 1.75, 1.4, 1.2, 1.05, 1, 1 | headings 1 to 6, as multiples of body text |
| `headingSpace` | s4, s3, s2, 0, 0, 0 | space above headings 1 to 6 |
| `printSize` | 11 pt | body text on paper |

The essay, manuscript and thesis layouts follow their style guides instead: 12 point Times, double
spaced, with headings at the body's size.

## Motion

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motionInstant` | 120 ms | easeOut | press feedback, toggles |
| `motionQuick` | 220 ms | spring(response 0.3, damping 0.8) | sheets, chips, list inserts |
| `motionStandard` | 320 ms | spring(response 0.4, damping 0.82) | navigation, bubble open |

One motion vocabulary. `matchedGeometryEffect` for bubble → module transitions. Honour
`accessibilityReduceMotion`: the home flower swaps its centre module without animating.

## Icons

SF Symbols for system chrome; Lucide for the module bubbles — **pending the owner's decision**
(architecture proposal §11-E). One stroke weight either way. No emoji as icons, ever.

## Text boxes and toolbar icons

The owner chose one look for both on 2026-11-10 ("Yes, every module"): option A, the raised capsule.

- **Text boxes** use `raisedField()` from TotalityUI: `elevationRaised` on `surface`, `radiusField`
  corners, `space4` across and `space3` down, at least `space7` tall, no line around it. Paragraph
  boxes (a signature, a mail body, event notes) use `raisedField(.block)`, which has `radiusMd` corners.
  In a Form it clears the row's own background. Put it on the row when a field shares it with icons.
- **The chat composer** is one raised capsule (`radiusField`): a single + attach button on
  `surfaceSunken`, the message, and send, which fills with `accent` once there's text.
- **Toolbar icons** use `ToolbarIcon` (a button) or `ToolbarGlyph` (a menu's label): a filled SF Symbol
  in `textSecondary`, `callout` size, on a raised disc (`elevationSubtle`) `space6 + space1` across.
  Disabled ones are `textTertiary` on a flat disc. Text buttons such as Close and Done stay text.
- Search above a list is `SearchBox`, a raised field with a magnifying glass and a clear button, in
  place of the system search bar.
- System alerts keep the system's text field, which can't take this style.

## Rules for every module

1. Never hard-code a colour, radius, spacing value, duration, or font size. If a token is missing,
   propose adding one — do not inline a value.
2. All UI composes from `TotalityUI` components. Bespoke one-off styling is a review failure.
3. Empty, loading, and error states are designed, not left to default. They are checked before commit.
4. Every screen is checked on both platforms before a module is called done.
