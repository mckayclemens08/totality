import SwiftUI
import TotalityUI

/// Sign in or create an account with a username and password. There is no email.
public struct AccountView: View {
    private let model: AccountModel
    private let onClose: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
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
            .onSubmit(submit)
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
        .onChange(of: model.phase) {
            password = ""
            confirmation = ""
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .signedOut:
            detail(creating ? "Choose a username and a password of at least \(AccountModel.minimumPasswordLength) characters." : "Sign in with your username and password.")
            usernameField
            passwordField("Password", text: $password)
            if creating {
                passwordField("Confirm password", text: $confirmation)
                detail("Totality has no email for you, so a forgotten password can't be reset here. Keep it somewhere safe. Your username can't be changed later.")
            }
            primary(creating ? "Create account" : "Sign in", action: submit)
            Button(creating ? "I already have an account" : "Create an account") {
                creating.toggle()
                confirmation = ""
                model.notice = nil
            }
            .font(Typeface.callout)
        case .signedIn(let username):
            detail("Signed in as \(username).")
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

    private var usernameField: some View {
        TextField("Username", text: $username)
            .font(Typeface.body)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textContentType(.username)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func passwordField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            .font(Typeface.body)
            .textFieldStyle(.plain)
            #if os(iOS)
            // iOS's strong-password fill needs Associated Domains, which the free Apple plan can't
            // have. On a sign-up form it would cover these fields and drop what's typed, even with
            // .password set, and .oneTimeCode is what keeps it away.
            .textContentType(creating ? .oneTimeCode : .password)
            #else
            .textContentType(.password)
            #endif
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func submit() {
        guard !model.isWorking else { return }
        Task {
            if creating {
                await model.signUp(username: username, password: password, confirmation: confirmation)
            } else {
                await model.signIn(username: username, password: password)
            }
        }
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
