import SwiftUI
import TotalityUI

/// Sign in or create an account with a username and password, and the private Account page once you have.
/// There is no email.
public struct AccountView: View {
    private let model: AccountModel
    private let onClose: () -> Void
    @State private var creating = false

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
                            withMotion(Motion.snappy) { proxy.scrollTo(SignInForm.noticeID, anchor: .bottom) }
                        }
                }
                #else
                form.frame(maxHeight: .infinity, alignment: .top)
                #endif
            }
            .background(theme.bg.color)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        // Signing in or out drops whatever was opened from the Account page, as it did from Settings.
        .id(isSignedIn)
        .tint(theme.accent.color)
        .task { await model.load() }
    }

    private var isSignedIn: Bool {
        if case .signedIn = model.phase { true } else { false }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            content
            // The sign-in form shows its own notice. Signed in, the Account page's land here.
            if isSignedIn, let notice = model.notice {
                Text(notice)
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.danger.color)
                    .id(SignInForm.noticeID)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .signedOut:
            if creating {
                AccountDetail(text: "Choose a username and a password of at least \(AccountModel.minimumPasswordLength) characters.")
            }
            SignInForm(model: model, creating: $creating)
        case .signedIn:
            AccountPage(model: model)
        }
    }
}
