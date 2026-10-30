import Foundation
import Testing
@testable import TotalityUI

private func luminance(_ token: ColorToken) -> Double {
    func channel(_ shift: UInt32) -> Double {
        let value = Double((token.hex >> shift) & 0xFF) / 255
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

private func contrast(_ a: ColorToken, _ b: ColorToken) -> Double {
    let high = max(luminance(a), luminance(b))
    let low = min(luminance(a), luminance(b))
    return (high + 0.05) / (low + 0.05)
}

@Suite("Design tokens")
struct TokenTests {
    @Test("Body text meets AA on every surface, in both themes", arguments: [Theme.light, Theme.dark])
    func textContrast(theme: Theme) {
        for background in [theme.bg, theme.surface, theme.surfaceSunken] {
            for text in [theme.textPrimary, theme.textSecondary, theme.accent, theme.danger, theme.success] {
                #expect(contrast(text, background) >= 4.5, "\(String(text.hex, radix: 16)) on \(String(background.hex, radix: 16))")
            }
        }
    }

    @Test("Tertiary text is only ever large-text contrast", arguments: [Theme.light, Theme.dark])
    func tertiaryContrast(theme: Theme) {
        #expect(contrast(theme.textTertiary, theme.surface) >= 3)
    }

    @Test("Text on an accent fill meets AA", arguments: [Theme.light, Theme.dark])
    func accentFill(theme: Theme) {
        #expect(contrast(theme.accentOn, theme.accent) >= 4.5)
    }

    @Test("Nothing is pure black", arguments: [Theme.light, Theme.dark])
    func noPureBlack(theme: Theme) {
        #expect(theme.bg.hex != 0 && theme.surface.hex != 0 && theme.surfaceSunken.hex != 0)
    }

    @Test("Background and surface stay close, which is the neumorphic effect", arguments: [Theme.light, Theme.dark])
    func surfacesStayClose(theme: Theme) {
        #expect(contrast(theme.bg, theme.surface) < 1.2)
    }
}
