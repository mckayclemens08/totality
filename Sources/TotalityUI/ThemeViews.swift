import SwiftUI

// The theme setting (Social canvas, ThemePicker board). Each row is raised, and the chosen one carries an
// accent check, never a pressed-in look (issue 132).

extension View {
    /// Follows the theme chosen on this device: Graphite asks the system for dark controls.
    public func followsTheme() -> some View {
        modifier(FollowsTheme())
    }
}

private struct FollowsTheme: ViewModifier {
    func body(content: Content) -> some View {
        let choice = ThemeStore.shared.choice
        content
            .tint(choice.palette.accent.color)
            .preferredColorScheme(choice.isDark ? .dark : .light)
    }
}

/// Picks the whole app's theme. The choice stays on this device.
public struct ThemePickerView: View {
    private let store: ThemeStore

    public init(store: ThemeStore = .shared) {
        self.store = store
    }

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Tints the whole app. Every theme keeps text easy to read.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.bottom, Space.s1)
                ForEach(ThemeChoice.allCases) { choice in
                    ThemeRow(choice: choice, isChosen: store.choice == choice) {
                        withMotion(Motion.smooth) { store.choice = choice }
                    }
                }
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.bg.color)
        .navigationTitle("Theme")
    }
}

private struct ThemeRow: View {
    let choice: ThemeChoice
    let isChosen: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        let palette = choice.palette
        Button(action: action) {
            HStack(spacing: Space.s3) {
                let swatch = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                Color.clear
                    .frame(width: Metric.headerButton, height: Metric.headerButton)
                    .neumorphic(.subtle, in: swatch)
                    .overlay { swatch.fill(palette.bg.color) }
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(palette.accent.color)
                            .frame(width: Metric.swatchDot, height: Metric.swatchDot)
                            .padding(Space.s2)
                    }
                VStack(alignment: .leading, spacing: Space.hairline * 2) {
                    Text(choice.name)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    Text(choice.detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(Typeface.micro.weight(.heavy))
                        .foregroundStyle(theme.accentOn.color)
                        .frame(width: Metric.choiceMark, height: Metric.choiceMark)
                        .background(Circle().fill(theme.accent.color))
                } else {
                    Circle()
                        .strokeBorder(theme.textTertiary.color, lineWidth: Space.hairline * 2)
                        .frame(width: Metric.choiceMark, height: Metric.choiceMark)
                }
            }
            .padding(.vertical, Space.s3)
            .padding(.horizontal, Space.s4)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("\(choice.name), \(choice.detail)")
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}
