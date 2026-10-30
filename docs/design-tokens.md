# Totality — Design Tokens (PROVISIONAL)

**Status:** placeholders, not brand decisions. The owner's Figma file is the visual source of truth and
overrides everything here when it arrives (Brief §16, §17). Until then these exist so that no module is
ever written against hard-coded values.

These ship as `Sources/TotalityUI/Tokens.swift`, and `Tests/TotalityUITests/TokenTests.swift` checks the contrast rules on every surface in both themes.

## Principle

Neumorphic, white / dark grey. **Background and surface stay close in value — that closeness is the
effect.** Elevation and grouping come from the soft shadow pair, never from borders or hard drop
shadows. Content contrast is carried by type weight, the single accent, and imagery.

The failure mode of neumorphism is unreadable text. Guardrail: **body text meets WCAG AA (4.5:1),
large text 3:1.** Every ratio below was computed, not estimated. The look never wins over legibility.

## Colour — light

| Token | Hex | Use | Contrast vs `surface` |
|---|---|---|---|
| `bg` | `#E8EBEF` | app background, the plane bubbles sit on | — |
| `surface` | `#EDEFF2` | raised cards, controls, bubbles | — |
| `surfaceSunken` | `#E2E5EA` | pressed / inset state | — |
| `shadowLight` | `#FFFFFF` @ 90% | top-left highlight of the shadow pair | — |
| `shadowDark` | `#C3C9D3` @ 70% | bottom-right depth of the shadow pair | — |
| `textPrimary` | `#15181D` | body, titles | **15.5:1** ✓ AA/AAA |
| `textSecondary` | `#555C68` | captions, metadata | **5.9:1** ✓ AA |
| `textTertiary` | `#7D8592` | disabled, placeholder | 3.2:1 — large text / non-text only |
| `accent` | `#A84A16` | the one saturated colour, used sparingly | **5.0:1** ✓ AA |
| `accentOn` | `#FFFFFF` | text on an accent fill | **5.7:1** vs accent ✓ AA |
| `danger` | `#B3261E` | destructive, key-loss warnings | 5.7:1 ✓ AA |
| `success` | `#1E6F4C` | verified contact, synced | 5.3:1 ✓ AA |

## Colour — dark

| Token | Hex | Use | Contrast vs `surface` |
|---|---|---|---|
| `bg` | `#191C21` | app background — **not pure black** | — |
| `surface` | `#20242A` | raised cards, controls, bubbles | — |
| `surfaceSunken` | `#171A1F` | pressed / inset state | — |
| `shadowLight` | `#2C3138` @ 80% | top-left highlight | — |
| `shadowDark` | `#101317` @ 80% | bottom-right depth | — |
| `textPrimary` | `#EFF1F4` | body, titles | **13.8:1** ✓ AA/AAA |
| `textSecondary` | `#A3ABB7` | captions, metadata | **6.7:1** ✓ AA |
| `textTertiary` | `#737B87` | disabled, placeholder | 3.7:1 — large text / non-text only |
| `accent` | `#E8833F` | lightened for dark surfaces | **5.8:1** ✓ AA |
| `accentOn` | `#1A1207` | text on an accent fill | **6.8:1** vs accent ✓ AA |
| `danger` | `#F2645A` | destructive | 5.0:1 ✓ AA |
| `success` | `#4FC08D` | verified, synced | 6.9:1 ✓ AA |

> **Accent is the most provisional token here.** `#A84A16` (burnt ochre) is chosen to be
> *deliberately not* the default blue/violet every AI-built app lands on, and to sit warm against
> cool grey. Expect the Figma file to replace it. Changing it is one line in two places.

## Shadow pair

Neumorphism is two shadows, always offset in opposite directions, always soft.

| Token | Light | Dark |
|---|---|---|
| `elevationRaised` | `+6,+6 blur 12 shadowDark` · `−6,−6 blur 12 shadowLight` | same offsets, dark values |
| `elevationSubtle` | `+3,+3 blur 6` · `−3,−3 blur 6` | same |
| `elevationPressed` | inner `+4,+4 blur 8 shadowDark` · inner `−4,−4 blur 8 shadowLight` | same |
| `elevationFlat` | none | none |

Nothing else. No `elevationXL`, no coloured shadows, no border as a substitute.

## Radius

| Token | Value | Use |
|---|---|---|
| `radiusSm` | 10 | chips, badges, inline controls |
| `radiusMd` | 18 | cards, fields, sheets |
| `radiusLg` | 28 | large cards, feed cover cards |
| `radiusFull` | ∞ | module bubbles, avatars |

Generous radii are part of the neumorphic read. Nothing in the app is square-cornered.

## Spacing — 4pt base

`space1` 4 · `space2` 8 · `space3` 12 · `space4` 16 · `space5` 24 · `space6` 32 · `space7` 48 · `space8` 64

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

## Motion

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motionInstant` | 120 ms | easeOut | press feedback, toggles |
| `motionQuick` | 220 ms | spring(response 0.3, damping 0.8) | sheets, chips, list inserts |
| `motionStandard` | 320 ms | spring(response 0.4, damping 0.82) | navigation, bubble open |
| `motionDrift` | 600 ms | easeInOut | home-screen bubble-cloud settling |

One motion vocabulary. `matchedGeometryEffect` for bubble → module transitions. Honour
`accessibilityReduceMotion`: `motionDrift` becomes a crossfade, bubble panning becomes a static grid.

## Icons

SF Symbols for system chrome; Lucide for the module bubbles — **pending the owner's decision**
(architecture proposal §11-E). One stroke weight either way. No emoji as icons, ever.

## Rules for every module

1. Never hard-code a colour, radius, spacing value, duration, or font size. If a token is missing,
   propose adding one — do not inline a value.
2. All UI composes from `TotalityUI` components. Bespoke one-off styling is a review failure.
3. Empty, loading, and error states are designed, not left to default. They are checked before commit.
4. Both themes are checked on both platforms before a module is called done.
