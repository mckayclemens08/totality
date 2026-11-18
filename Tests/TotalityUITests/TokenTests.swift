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

private let everyTheme = ThemeChoice.allCases

@Suite("Design tokens")
struct TokenTests {
    @Test("Body and muted text meet AA on every surface", arguments: everyTheme)
    func textContrast(_ choice: ThemeChoice) {
        let theme = choice.palette
        for background in [theme.bg, theme.surface, theme.surfaceSunken] {
            for text in [theme.textPrimary, theme.textSecondary, theme.accent, theme.danger, theme.success] {
                #expect(contrast(text, background) >= 4.5, "\(choice): \(String(text.hex, radix: 16)) on \(String(background.hex, radix: 16))")
            }
        }
    }

    @Test("Tertiary text is only ever large-text contrast", arguments: everyTheme)
    func tertiaryContrast(_ choice: ThemeChoice) {
        let theme = choice.palette
        #expect(contrast(theme.textTertiary, theme.surface) >= 3)
    }

    @Test("Text on a highlight meets AA", arguments: everyTheme)
    func highlights(_ choice: ThemeChoice) {
        let theme = choice.palette
        for fill in [theme.highlight, theme.highlightStrong] {
            #expect(contrast(theme.textPrimary, fill) >= 4.5)
        }
    }

    @Test("Text on an accent fill meets AA", arguments: everyTheme)
    func accentFill(_ choice: ThemeChoice) {
        let theme = choice.palette
        #expect(contrast(theme.accentOn, theme.accent) >= 4.5)
    }

    @Test("Nothing is pure black", arguments: everyTheme)
    func noPureBlack(_ choice: ThemeChoice) {
        let theme = choice.palette
        #expect(theme.bg.hex != 0 && theme.surface.hex != 0 && theme.surfaceSunken.hex != 0)
    }

    @Test("Background and surface stay close, which is the neumorphic effect", arguments: everyTheme)
    func surfacesStayClose(_ choice: ThemeChoice) {
        let theme = choice.palette
        #expect(contrast(theme.bg, theme.surface) < 1.2)
    }

    @Test("Only Graphite is dark, and its text is light")
    func graphiteIsDark() {
        #expect(ThemeChoice.allCases.filter(\.isDark) == [.graphite])
        #expect(luminance(Theme.graphite.textPrimary) > luminance(Theme.graphite.bg))
    }

    @Test("The choice is kept on the device and read back")
    func choiceIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "TokenTests.theme"))
        defaults.removePersistentDomain(forName: "TokenTests.theme")
        #expect(ThemeStore(defaults: defaults).choice == .light)
        ThemeStore(defaults: defaults).choice = .graphite
        #expect(ThemeStore(defaults: defaults).choice == .graphite)
        defaults.removePersistentDomain(forName: "TokenTests.theme")
    }
}
