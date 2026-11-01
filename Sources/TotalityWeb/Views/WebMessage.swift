import SwiftUI
import TotalityUI

/// A button on a message, with a quiet line under it when it needs explaining.
struct WebMessageAction {
    let label: String
    var note: String?
    let run: () -> Void
}

/// A full-page message, with the one thing that can be done about it.
struct WebMessage: View {
    let systemImage: String
    let title: String
    let detail: String
    var action: WebMessageAction?
    var alternative: WebMessageAction?

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.run)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
                    .padding(.top, Space.s3)
            }
            if let alternative {
                Button(alternative.label, action: alternative.run)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
                    .padding(.top, Space.s2)
                if let note = alternative.note {
                    Text(note)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
