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

/// Provisional until the Figma file arrives. Values and rules are in docs/design-tokens.md.
public struct Theme: Sendable, Equatable {
    public let bg, surface, surfaceSunken: ColorToken
    public let shadowLight, shadowDark: ColorToken
    public let textPrimary, textSecondary, textTertiary: ColorToken
    public let accent, accentOn, danger, success: ColorToken
    public let highlight, highlightStrong: ColorToken

    /// Totality has one look. The owner removed dark mode on 2026-10-31.
    public static let current = Theme(
        bg: .init(0xE8EBEF), surface: .init(0xEDEFF2), surfaceSunken: .init(0xE2E5EA),
        shadowLight: .init(0xFFFFFF, opacity: 0.9), shadowDark: .init(0xC3C9D3, opacity: 0.7),
        textPrimary: .init(0x15181D), textSecondary: .init(0x555C68), textTertiary: .init(0x7D8592),
        accent: .init(0x1F5FBF), accentOn: .init(0xFFFFFF), danger: .init(0xB3261E), success: .init(0x1E6F4C),
        highlight: .init(0xD3E0F4), highlightStrong: .init(0xA9C5EE)
    )
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
    /// Keys and codes, where every character has to be told apart.
    public static let code = Font.body.monospaced()
}

public enum Motion {
    public static let instant = Animation.easeOut(duration: 0.12)
    public static let quick = Animation.spring(response: 0.3, dampingFraction: 0.8)
    public static let standard = Animation.spring(response: 0.4, dampingFraction: 0.82)
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

    func body(content: Content) -> some View {
        let theme = Theme.current
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
