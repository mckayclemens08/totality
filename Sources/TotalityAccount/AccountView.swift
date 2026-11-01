import SwiftUI
import TotalityUI

/// Sign in or create an account with a username and password, and your profile once you have. There is no email.
public struct AccountView: View {
    private let model: AccountModel
    private let onClose: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var editing = false
    @State private var showingSettings = false

    private static let noticeID = "notice"

    public init(model: AccountModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            Group {
                #if os(iOS)
                // The keyboard leaves too little room for the form, which slid under the title
                // when it couldn't scroll. A notice would land behind the keyboard, so it's brought up.
                ScrollViewReader { proxy in
                    ScrollView { form }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: model.notice) {
                            guard model.notice != nil else { return }
                            withAnimation(Motion.quick) { proxy.scrollTo(Self.noticeID, anchor: .bottom) }
                        }
                }
                #else
                form.frame(maxHeight: .infinity, alignment: .top)
                #endif
            }
            .background(theme.bg.color)
            .navigationTitle(isSignedIn ? "Profile" : "Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                if isSignedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .navigationDestination(isPresented: $editing) {
                EditProfileView(model: model) { editing = false }
            }
            .navigationDestination(isPresented: $showingSettings) {
                AccountSettingsView(model: model)
            }
        }
        .tint(theme.accent.color)
        .task { await model.load() }
        .onChange(of: model.phase) {
            password = ""
            confirmation = ""
            editing = false
            showingSettings = false
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = model.phase { true } else { false }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            content
            if let notice = model.notice {
                Text(notice)
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.danger.color)
                    .id(Self.noticeID)
            }
        }
        .onSubmit(submit)
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            HomeStyleSetting()
                .padding(.top, Space.s4)
        case .signedIn:
            ProfileSummary(model: model) { editing = true }
        }
    }

    private func detail(_ text: String) -> some View {
        AccountDetail(text: text)
    }

    private var usernameField: some View {
        TextField("Username", text: $username)
            .font(Typeface.body)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            // At sign-up iOS would offer an email address or Hide My Email, and neither is a username.
            .textContentType(creating ? nil : .username)
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
        AccountButton(title: title, isWorking: model.isWorking, action: action)
    }
}
