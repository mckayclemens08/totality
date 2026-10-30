import SwiftUI
import TotalityUI

/// Sign in with a link from your email. There are no passwords.
public struct AccountView: View {
    private let model: AccountModel
    private let onClose: () -> Void
    @State private var email = ""
    @Environment(\.colorScheme) private var scheme

    public init(model: AccountModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current(scheme)
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                content
                if let notice = model.notice {
                    Text(notice)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.bg.color)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .tint(theme.accent.color)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .signedOut:
            detail("Enter your email and we'll send you a sign-in link. There's no password.")
            field("you@example.com", text: $email)
            primary("Send link") { Task { await model.sendLink(to: email) } }
        case .awaitingLink(let email):
            detail("We sent a link to \(email). Open it on this device to finish signing in. It can take a minute to arrive, and it expires after 10 minutes.")
            Button("Use a different email") { model.startOver() }
                .font(Typeface.callout)
        case .signedIn(let email):
            detail("Signed in as \(email).")
            detail(model.deviceRegistered ? "This device is added to your account." : "This device isn't added to your account yet.")
            detail("Your notes aren't synced yet. They stay on this device, and signing out leaves them here.")
            primary("Sign out") { Task { await model.signOut() } }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(Typeface.body)
            .foregroundStyle(Theme.current(scheme).textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(Typeface.body)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        let theme = Theme.current(scheme)
        return Button(action: action) {
            Group {
                if model.isWorking {
                    ProgressView().tint(theme.accentOn.color)
                } else {
                    Text(title)
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accentOn.color)
            .frame(maxWidth: .infinity)
            .padding(Space.s4)
            .background(theme.accent.color, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }
}
