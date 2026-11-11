import SwiftUI

/// The look of every toolbar icon: a filled dark-grey glyph on a small raised disc. The owner chose it on
/// 2026-11-10 over thin outlined accent icons. Use it as a menu's label too, so menus match buttons.
public struct ToolbarGlyph: View {
    /// Big enough to hit, small enough that a row of them stays a row.
    public static let diameter: CGFloat = Space.s6 + Space.s1

    let systemImage: String
    var isEnabled = true

    public nonisolated init(systemImage: String, isEnabled: Bool = true) {
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }

    public var body: some View {
        let theme = Theme.current
        // Filled symbols wherever one exists. Ones made only of lines, like + or a chevron, get a heavier
        // weight so they don't read as thin outlines beside the filled ones.
        Image(systemName: systemImage)
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? theme.textSecondary.color : theme.textTertiary.color)
            .frame(width: Self.diameter, height: Self.diameter)
            .neumorphic(isEnabled ? .subtle : .flat, in: Circle())
            .contentShape(Circle())
    }
}

/// A toolbar button in that look. Its title is what VoiceOver says.
public struct ToolbarIcon: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    public init(_ title: String, systemImage: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ToolbarGlyph(systemImage: systemImage, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}
