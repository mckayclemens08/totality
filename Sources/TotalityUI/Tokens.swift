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

/// Provisional until the Figma file arrives. Values and rules are in docs/design-tokens.md.
public struct Theme: Sendable, Equatable {
    public let bg, surface, surfaceSunken: ColorToken
    public let shadowLight, shadowDark: ColorToken
    public let textPrimary, textSecondary, textTertiary: ColorToken
    public let accent, accentOn, danger, success: ColorToken

    public static let light = Theme(
        bg: .init(0xE8EBEF), surface: .init(0xEDEFF2), surfaceSunken: .init(0xE2E5EA),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xC3C9D3, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x555C68), textTertiary: .init(0x7D8592),
        accent: .init(0xA84A16), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C)
    )

    public static let dark = Theme(
        bg: .init(0x191C21), surface: .init(0x20242A), surfaceSunken: .init(0x171A1F),
        shadowLight: .init(0x2C3138, opacity: 0.8), shadowDark: .init(0x101317, opacity: 0.8),
        textPrimary: .init(0xEFF1F4), textSecondary: .init(0xA3ABB7), textTertiary: .init(0x737B87),
        accent: .init(0xE8833F), accentOn: .init(0x1A1207), danger: .init(0xF2645A), success: .init(0x4FC08D)
    )

    public static func current(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

public enum Radius {
    public static let sm: CGFloat = 10
    public static let md: CGFloat = 18
    public static let lg: CGFloat = 28
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
}

public enum Motion {
    public static let instant = Animation.easeOut(duration: 0.12)
    public static let quick = Animation.spring(response: 0.3, dampingFraction: 0.8)
    public static let standard = Animation.spring(response: 0.4, dampingFraction: 0.82)
    public static let drift = Animation.easeInOut(duration: 0.6)
}

public enum Elevation: Sendable {
    case flat, subtle, raised, pressed

    var offset: CGFloat {
        switch self {
        case .flat: 0
        case .subtle: 3
        case .raised: 6
        case .pressed: 4
        }
    }
}

extension View {
    /// A soft surface in the given shape. Elevation comes from the shadow pair, never a border.
    public func neumorphic<S: Shape>(_ elevation: Elevation = .raised, in shape: S) -> some View {
        modifier(NeumorphicSurface(elevation: elevation, shape: shape))
    }
}

private struct NeumorphicSurface<S: Shape>: ViewModifier {
    let elevation: Elevation
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = Theme.current(scheme)
        let offset = elevation.offset
        let radius = offset * 2
        content.background {
            if elevation == .pressed {
                shape.fill(
                    theme.surfaceSunken.color
                        .shadow(.inner(color: theme.shadowDark.color, radius: radius, x: offset, y: offset))
                        .shadow(.inner(color: theme.shadowLight.color, radius: radius, x: -offset, y: -offset))
                )
            } else {
                shape.fill(theme.surface.color)
                    .shadow(color: theme.shadowDark.color, radius: radius, x: offset, y: offset)
                    .shadow(color: theme.shadowLight.color, radius: radius, x: -offset, y: -offset)
            }
        }
    }
}
