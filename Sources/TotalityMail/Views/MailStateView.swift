import SwiftUI
import TotalityUI

struct MailStateAction {
    let label: String
    let run: () -> Void
}

/// A full-page message, with the one thing that can be done about it.
struct MailStateView: View {
    let systemImage: String
    let title: String
    let detail: String
    var action: MailStateAction?

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
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The first download, and how far along it is.
struct MailDownloadView: View {
    let download: MailDownload?

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: "envelope")
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(download == nil ? "Opening your mail" : "Downloading your mail")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            if let download {
                ProgressView(value: download.fraction)
                    .tint(theme.accent.color)
                Text("\(download.done.formatted()) of \(download.total.formatted()) messages. It's opened here, on this device.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// For rows a swipe can cross. A Button also fires when a swipe ends on it.
    func tappable(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
