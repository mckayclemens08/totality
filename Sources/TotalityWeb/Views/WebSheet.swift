import SwiftUI
import TotalityUI

/// The frame every Web sheet shares: a title, a way out, and the sheet's own content.
struct WebSheet<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                Button("Done", action: onClose)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Space.s4)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.bg.color)
        #if os(macOS)
        .frame(minWidth: Space.s8 * 8, minHeight: Space.s8 * 8)
        #endif
    }
}
