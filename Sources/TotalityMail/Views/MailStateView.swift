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
    /// The person's own address, shown so they can hand it out before mail starts.
    var address: String = ""

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.title)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s8 + Space.s4, height: Space.s8 + Space.s4)
                .neumorphic(.raised, in: Circle())
                .padding(.bottom, Space.s3)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !address.isEmpty {
                AddressLine("Your address", address: address)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, Space.s3)
            }
            if let action {
                Button(action: action.run) {
                    Text(action.label)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, Space.s5)
                        .padding(.vertical, Space.s3)
                        .neumorphic(.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, Space.s3)
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
