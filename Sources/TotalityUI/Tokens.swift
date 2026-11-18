import Observation
import SwiftUI

/// One colour value. Kept as hex so contrast can be tested without a renderer.
public struct ColorToken: Sendable, Equatable {
    public let hex: UInt32
    public let opacity: Double

    public init(_ hex: UInt32, opacity: Double = 1) {
        self.hex = hex
        self.opacity = opacity
    }

    public var color: Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

#if canImport(UIKit)
import UIKit

extension ColorToken {
    /// For views that SwiftUI doesn't draw itself.
    public var platformColor: UIColor { UIColor(color) }
}
#elseif canImport(AppKit)
import AppKit

extension ColorToken {
    /// For views that SwiftUI doesn't draw itself.
    public var platformColor: NSColor { NSColor(color) }
}
#endif

/// One theme's palette. Values and rules are in docs/design-tokens.md.
public struct Theme: Sendable, Equatable {
    public let bg, surface, surfaceSunken: ColorToken
    public let shadowLight, shadowDark: ColorToken
    public let textPrimary, textSecondary, textTertiary: ColorToken
    public let accent, accentOn, danger, success: ColorToken
    public let highlight, highlightStrong: ColorToken

    /// The palette of the theme chosen on this device. A view that reads it while drawing redraws when
    /// the choice changes.
    public static var current: Theme { ThemeStore.shared.choice.palette }

    /// White and pale grey with a blue accent: the default.
    public static let light = Theme(
        bg: .init(0xE8EBEF), surface: .init(0xEDEFF2), surfaceSunken: .init(0xE2E5EA),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xC3C9D3, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x555C68), textTertiary: .init(0x7D8592),
        accent: .init(0x1F5FBF), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xD3E0F4), highlightStrong: .init(0xA9C5EE)
    )

    public static let blush = Theme(
        bg: .init(0xF2E6E6), surface: .init(0xF7ECEC), surfaceSunken: .init(0xEADCDC),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xD6BEBE, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x6A5555), textTertiary: .init(0x8A7272),
        accent: .init(0xA83636), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xF3D3D3), highlightStrong: .init(0xE8B4B4)
    )

    public static let sky = Theme(
        bg: .init(0xE3ECF5), surface: .init(0xEAF1F8), surfaceSunken: .init(0xD9E3EE),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xBAC8DA, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x4F5D6E), textTertiary: .init(0x707D8D),
        accent: .init(0x1F5FBF), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xCFE0F2), highlightStrong: .init(0xA9C5EE)
    )

    public static let sage = Theme(
        bg: .init(0xE5EEE7), surface: .init(0xECF3EE), surfaceSunken: .init(0xDAE5DD),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xBCCEC2, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x52625A), textTertiary: .init(0x728279),
        accent: .init(0x2E6B47), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xD2E6D8), highlightStrong: .init(0xAFD2B9)
    )

    public static let lilac = Theme(
        bg: .init(0xECE8F3), surface: .init(0xF1EEF7), surfaceSunken: .init(0xE1DCEB),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xCBC4DB, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x5C5870), textTertiary: .init(0x7C7790),
        accent: .init(0x5B45A8), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xE0D8F0), highlightStrong: .init(0xC7B8E6)
    )

    /// Dark grey, for dark mode. The shadow pair is a faint light edge and a deep dark one, and text on
    /// an accent fill is dark.
    public static let graphite = Theme(
        bg: .init(0x2A2E34), surface: .init(0x30353C), surfaceSunken: .init(0x25292E),
        shadowLight: .init(0xFFFFFF, opacity: 0.06), shadowDark: .init(0x000000, opacity: 0.45),
        textPrimary: .init(0xE7E9ED), textSecondary: .init(0xA7AEB9), textTertiary: .init(0x8C939E),
        accent: .init(0x8DB2EE), accentOn: .init(0x16191E), danger: .init(0xF2A39B), success: .init(0x7FCFA6),
        highlight: .init(0x33405A), highlightStrong: .init(0x44577D)
    )
}

/// The themes a person can pick. The owner asked for "not just a white background, but red, blue, green,
/// etc as well" and to "add a gray theme for dark mode" (2026-11-17).
public enum ThemeChoice: String, CaseIterable, Sendable, Identifiable {
    case light = "default", blush, sky, sage, lilac, graphite

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .light: "Light"
        case .blush: "Blush"
        case .sky: "Sky"
        case .sage: "Sage"
        case .lilac: "Lilac"
        case .graphite: "Graphite"
        }
    }

    public var detail: String {
        switch self {
        case .light: "White and grey"
        case .blush: "Red"
        case .sky: "Blue"
        case .sage: "Green"
        case .lilac: "Purple"
        case .graphite: "Dark grey"
        }
    }

    public var palette: Theme {
        switch self {
        case .light: .light
        case .blush: .blush
        case .sky: .sky
        case .sage: .sage
        case .lilac: .lilac
        case .graphite: .graphite
        }
    }

    public var isDark: Bool { self == .graphite }
}

/// Which theme this device uses. Only the choice is kept, in this device's settings; it holds no content.
@Observable
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()
    public static let defaultsKey = "app.theme"

    @ObservationIgnored private let defaults: UserDefaults

    public var choice: ThemeChoice {
        didSet { defaults.set(choice.rawValue, forKey: Self.defaultsKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: Self.defaultsKey).flatMap(ThemeChoice.init(rawValue:)) ?? .light
    }
}

/// The writing page's type. The editor's stylesheet and a printed export read the same numbers, so an
/// exported doc looks like the page it was written on.
public enum WritingType {
    /// Body text, as a multiple of the system's body size.
    public static let bodyScale: CGFloat = 1.0625
    public static let lineHeight: CGFloat = 1.6
    public static let headingLineHeight: CGFloat = 1.3
    /// Headings 1 to 6, as multiples of body text.
    public static let headingScales: [CGFloat] = [1.75, 1.4, 1.2, 1.05, 1, 1]
    /// Space above headings 1 to 6.
    public static let headingSpace: [CGFloat] = [Space.s4, Space.s3, Space.s2, 0, 0, 0]
    /// Body text on paper, in points, where the page's own size would print too large.
    public static let printSize: CGFloat = 11
}

public enum Radius {
    public static let sm: CGFloat = 10
    public static let md: CGFloat = 18
    public static let lg: CGFloat = 28
    /// Home's tiles, as on the approved canvas.
    public static let tile: CGFloat = 20
    /// Text boxes and the composer: a capsule at one line, softly rounded as the text grows.
    public static let field: CGFloat = 24
}

public enum Space {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32
    public static let s7: CGFloat = 48
    public static let s8: CGFloat = 64
    /// Rules on a timeline, which sit in the surface rather than on it.
    public static let hairline: CGFloat = 1
}

/// Text styles, so every size scales with Dynamic Type.
public enum Typeface {
    public static let display = Font.largeTitle.weight(.bold)
    public static let title = Font.title2.weight(.semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.callout.weight(.medium)
    public static let caption = Font.footnote
    public static let micro = Font.caption2.weight(.medium)
    /// A tile's label row, like "Mail · 3 new" (12 pt semibold on the canvas).
    public static let tileLabel = Font.caption.weight(.semibold)
    /// A tile's second line under a name or title (12 pt on the canvas).
    public static let tileDetail = Font.caption
    /// A task or other one-line item on a tile (14 pt on the canvas, the nearest Dynamic Type size).
    public static let tileRow = Font.subheadline
    /// Keys and codes, where every character has to be told apart.
    public static let code = Font.body.monospaced()
}

/// Muted colours for a book or document with no cover of its own, so a shelf isn't a row of blanks. The
/// same item always gets the same one. Each carries a white icon at WCAG AA for graphics (3:1).
public enum CoverTone {
    public static let all: [ColorToken] = [
        .init(0x4E6B80), .init(0xA83636), .init(0x2E6B47), .init(0x5B45A8), .init(0x8A5A2B), .init(0x3F5F8A),
    ]

    /// A stable pick from `all` for a key such as an item's ID.
    public static func tone(for key: String) -> ColorToken {
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return all[sum % all.count]
    }
}

/// Fixed sizes of the shared controls in the redesign (owner approved the canvas on 2026-11-17).
public enum Metric {
    /// A round header button: the flower and search buttons on Home, and each screen's header.
    public static let headerButton: CGFloat = 44
    /// The accent round + at the bottom right of a screen.
    public static let addButton: CGFloat = 56
    /// The remove button on a tile while Home is being edited.
    public static let removeButton: CGFloat = 26
    /// A progress ring's stroke.
    public static let ringStroke: CGFloat = 7
    /// How far the chosen tile's outline stands off the tile while Home is being edited.
    public static let selectionOutline: CGFloat = 2
    /// The gap between Home's tiles, and how far a tile's content stands in from its edge.
    public static let tileGap: CGFloat = 14
    /// The space between rows inside a tile, and between its label row and the first one.
    public static let tileRowGap: CGFloat = 11
    /// The space between a row's picture or dot and its words inside a tile.
    public static let tileItemGap: CGFloat = 10
    /// How far a full-bleed tile's pictures stand in from its edge.
    public static let tileBleed: CGFloat = 6
    /// The accent dot on a theme's swatch in the theme setting.
    public static let swatchDot: CGFloat = 14
    /// The round check, or empty ring, that marks the chosen one of a list.
    public static let choiceMark: CGFloat = 22
}

/// Every animation in the app is one of these springs, so things move alike everywhere. Springs carry a
/// finger's speed and never stop with a jolt, which is what made the old fixed curves feel abrupt.
public enum Motion {
    /// A press and its release: quick, with no overshoot.
    public static let press = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// Small controls: pills, ticks, switches and segments.
    public static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Things that change place or size: screens, sheets' contents, rows coming and going.
    public static let smooth = Animation.spring(response: 0.42, dampingFraction: 1)
    /// Something the person picked up or resized, which settles with a small give.
    public static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.72)

    /// A placeholder's slow breathing while something loads. It only fades, so it stays under Reduce Motion.
    public static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// How small a pressed control gets, and how faint. Nothing sinks in (issue 132).
    public static let pressScale: CGFloat = 0.97
    public static let pressOpacity: Double = 0.82

    /// The animation to use, or a plain fade-speed one when Reduce Motion is on, so nothing slides or
    /// springs for someone who's asked it not to.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : animation
    }

    /// Whether the person has asked for less motion, for code outside a view.
    @MainActor public static var isReduced: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }
}

/// `withAnimation` with one of the `Motion` springs, which turns to a short fade under Reduce Motion.
@MainActor
@discardableResult
public func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolved(animation, reduceMotion: Motion.isReduced), body)
}

extension View {
    /// `animation(_:value:)` with one of the `Motion` springs, honouring Reduce Motion.
    public func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// How far a surface stands off the page. There is no pressed or inset elevation: the owner doesn't want
/// a sunken look anywhere ("I just don't like the sunken-in look", "anywhere", 2026-11-15, issue 132).
/// A selected thing gets `selectionWash`, and a press gets a little scale or opacity.
public enum Elevation: Sendable {
    case flat, subtle, raised

    var offset: CGFloat {
        switch self {
        case .flat: 0
        case .subtle: 3
        case .raised: 6
        }
    }
}

extension View {
    /// A soft surface in the given shape. Elevation comes from the shadow pair, never a border.
    public func neumorphic<S: Shape>(_ elevation: Elevation = .raised, in shape: S) -> some View {
        modifier(NeumorphicSurface(elevation: elevation, shape: shape))
    }

    /// The chosen one of several: a flat, soft wash of the accent behind it, never pressed in.
    @ViewBuilder
    public func selectionWash<S: Shape>(_ isOn: Bool, in shape: S) -> some View {
        background {
            if isOn { shape.fill(Theme.current.highlight.color) }
        }
    }

    /// A toggle's surface: raised a little when off, and a flat accent wash when on.
    @ViewBuilder
    public func toggleSurface<S: Shape>(_ isOn: Bool, in shape: S) -> some View {
        if isOn { selectionWash(true, in: shape) } else { neumorphic(.subtle, in: shape) }
    }
}

private struct NeumorphicSurface<S: Shape>: ViewModifier {
    let elevation: Elevation
    let shape: S

    func body(content: Content) -> some View {
        let theme = Theme.current
        let offset = elevation.offset
        let radius = offset * 2
        content.background {
            shape.fill(theme.surface.color)
                .shadow(color: theme.shadowDark.color, radius: radius, x: offset, y: offset)
                .shadow(color: theme.shadowLight.color, radius: radius, x: -offset, y: -offset)
        }
    }
}
