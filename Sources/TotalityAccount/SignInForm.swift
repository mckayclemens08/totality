import SwiftUI
import TotalityUI

/// Sign in, or create an account, with a username and password. The full-screen sign-in page and the
/// Account sheet both use it. The password lives only in this view's state while it's typed, goes only to
/// the account server through `AccountModel`, and is cleared as soon as the account changes or the form
/// leaves the screen (non-negotiable 3).
struct SignInForm: View {
    let model: AccountModel
    @Binding var creating: Bool
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            SignInModePicker(creating: $creating) {
                confirmation = ""
                model.notice = nil
            }
            usernameField
            passwordField("Password", text: $password)
            if creating {
                passwordField("Confirm password", text: $confirmation)
                AccountDetail(text: "Totality has no email for you, so a forgotten password can't be reset here. Keep it somewhere safe. Your username can't be changed later.")
            }
            AccountButton(title: creating ? "Create account" : "Sign in", isWorking: model.isWorking, action: submit)
            if let notice = model.notice {
                Text(notice)
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(SignInForm.noticeID)
            }
        }
        .onSubmit(submit)
        .onChange(of: model.phase) { forgetPasswords() }
        .onDisappear(perform: forgetPasswords)
    }

    static let noticeID = "notice"

    private var usernameField: some View {
        TextField("Username", text: $username)
            .font(Typeface.body)
            .autocorrectionDisabled()
            // At sign-up iOS would offer an email address or Hide My Email, and neither is a username.
            .textContentType(creating ? nil : .username)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .raisedField()
    }

    private func passwordField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            .font(Typeface.body)
            #if os(iOS)
            // iOS's strong-password fill needs Associated Domains, which the free Apple plan can't
            // have. On a sign-up form it would cover these fields and drop what's typed, even with
            // .password set, and .oneTimeCode is what keeps it away.
            .textContentType(creating ? .oneTimeCode : .password)
            #else
            .textContentType(.password)
            #endif
            .raisedField()
    }

    private func forgetPasswords() {
        password = ""
        confirmation = ""
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
}

/// Sign in or Create account. The chosen side is an accent fill on a raised track, never pressed in.
struct SignInModePicker: View {
    @Binding var creating: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: Space.s1) {
            side("Sign in", isOn: !creating) { set(false) }
            side("Create account", isOn: creating) { set(true) }
        }
        .padding(Space.s1)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func side(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(isOn ? theme.accentOn.color : theme.textSecondary.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s2)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.accent.color)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func set(_ value: Bool) {
        guard creating != value else { return }
        withMotion(Motion.snappy) { creating = value }
        onChange()
    }
}

/// The page a device opens to before anyone has signed in on it, or after signing out (owner,
/// 2026-11-25). Once someone signs in here, the app opens straight to Home from then on.
public struct SignInPage: View {
    private let model: AccountModel
    @State private var creating = false

    public init(model: AccountModel) {
        self.model = model
    }

    public var body: some View {
        let theme = Theme.current
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Space.s5) {
                    VStack(spacing: Space.s3) {
                        BrandMark(size: Space.s8)
                        Text(creating ? "Make your account" : "Welcome to Totality")
                            .font(Typeface.title)
                            .foregroundStyle(theme.textPrimary.color)
                            .multilineTextAlignment(.center)
                        Text(creating
                             ? "Choose a username and a password of at least \(AccountModel.minimumPasswordLength) characters."
                             : "Your notes, mail, messages and plans in one place.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.s7)
                    SignInForm(model: model, creating: $creating)
                    Text("Your password goes only to Totality's account server, over an encrypted connection, and is never kept on this device.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.s5)
                .frame(maxWidth: Metric.formWidth)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: model.notice) {
                guard model.notice != nil else { return }
                withMotion(Motion.snappy) { proxy.scrollTo(SignInForm.noticeID, anchor: .bottom) }
            }
        }
        .background(theme.bg.color.ignoresSafeArea())
        .tint(theme.accent.color)
    }
}
