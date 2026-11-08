import AuthenticationServices
import SwiftUI
import TotalityUI

/// Google's own sign-in page, in the system's sign-in sheet. It shares Safari's sign-ins, so someone
/// already signed in to Google there just picks their account.
@MainActor
private func webSignIn(_ session: WebAuthenticationSession) -> OutsideWebSignIn {
    { page, scheme in
        try await session.authenticate(using: page, callbackURLScheme: scheme, preferredBrowserSession: .shared)
    }
}

/// iCloud and Gmail accounts beside the Totality address: each one's honest label, its Send switch,
/// and Remove. Adding one opens `OutsideAddAccountView`.
struct OutsideAccountsView: View {
    let model: OutsideAccountsModel
    let onDone: () -> Void

    @State private var adding = false
    @State private var removing: OutsideAccount?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    content
                    if let notice = model.notice {
                        Text(notice)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                    if model.phase == .ready, model.canAddMore {
                        Button {
                            adding = true
                        } label: {
                            Label("Add Account", systemImage: "plus")
                                .font(Typeface.callout)
                                .foregroundStyle(theme.accent.color)
                                .padding(Space.s3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if model.phase == .ready {
                        Text(OutsideWording.problem(.tooMany, provider: .icloud))
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Outside Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .tint(theme.accent.color)
        .task { await model.load() }
        .sheet(isPresented: $adding) {
            OutsideAddAccountView(model: model) { adding = false }
                #if os(macOS)
                .frame(minWidth: Space.s8 * 7, minHeight: Space.s8 * 7)
                #endif
        }
        .confirmationDialog("Remove \(removing?.address ?? "this account")?", isPresented: isRemoving, titleVisibility: .visible, presenting: removing) { account in
            Button("Remove Account", role: .destructive) {
                Task { await model.remove(account) }
            }
        } message: { account in
            Text(OutsideWording.removing(account))
        }
    }

    @ViewBuilder
    private var content: some View {
        let theme = Theme.current
        switch model.phase {
        case .loading:
            HStack(spacing: Space.s2) {
                ProgressView()
                Text("Opening your accounts…")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
        case .failed:
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Your outside accounts couldn't be opened on this device.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                Button("Try Again") { Task { await model.load() } }
                    .font(Typeface.callout)
            }
        case .ready:
            if model.accounts.isEmpty {
                Text(OutsideWording.none)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
            }
            ForEach(model.accounts) { account in
                row(account)
            }
        }
    }

    private func row(_ account: OutsideAccount) -> some View {
        let theme = Theme.current
        let isBusy = model.busy.contains(account.id)
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(account.provider.name)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                    Text(account.address)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text(OutsideWording.kept(by: account.provider))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(OutsideWording.sendSwitch, isOn: Binding(
                get: { account.canSend },
                set: { on in
                    let signIn = webSignIn(webAuthenticationSession)
                    Task { await model.setSending(account, on: on, signingIn: signIn) }
                }
            ))
            .font(Typeface.callout)
            .foregroundStyle(theme.textPrimary.color)
            .disabled(isBusy)
            Text(account.canSend ? OutsideWording.sent(through: account.provider) : OutsideWording.sendSwitchOff(account.provider))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove Account", role: .destructive) { removing = account }
                .font(Typeface.callout)
                .foregroundStyle(theme.danger.color)
                .buttonStyle(.plain)
                .disabled(isBusy)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

/// Gmail signs in on Google's own page. iCloud asks for the address and an app password. Either way the
/// provider checks it before anything is kept.
struct OutsideAddAccountView: View {
    let model: OutsideAccountsModel
    let onDone: () -> Void

    @State private var provider = OutsideProvider.gmail
    @State private var address = ""
    @State private var password = ""
    @State private var problem: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Picker("Provider", selection: $provider) {
                        ForEach(OutsideProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isAdding)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ForEach(OutsideWording.howToAdd(provider), id: \.self) { line in
                            Text(line)
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if provider.signsInWithGoogle {
                            Text(OutsideWording.googleUnverified)
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if provider.signsInWithGoogle {
                        googleButton
                    } else {
                        appPasswordFields
                    }
                    if let problem {
                        Text(problem)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.isAdding {
                        HStack(spacing: Space.s2) {
                            ProgressView()
                            Text("Checking with \(provider.name)…")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Add Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close).disabled(model.isAdding)
                }
                if !provider.signsInWithGoogle {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", action: add)
                            .disabled(model.isAdding || address.isEmpty || password.isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onChange(of: provider) { problem = nil }
    }

    private var googleButton: some View {
        let theme = Theme.current
        return Button(action: addGoogle) {
            Label("Sign in with Google", systemImage: "person.crop.circle")
                .font(Typeface.headline)
                .foregroundStyle(theme.accent.color)
                .padding(Space.s3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
        .disabled(model.isAdding)
    }

    @ViewBuilder
    private var appPasswordFields: some View {
        if let page = provider.appPasswordPage {
            Link(destination: page) {
                Label("Make an App Password", systemImage: "key")
                    .font(Typeface.callout)
                    .padding(Space.s3)
                    .frame(maxWidth: .infinity)
            }
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        if let help = provider.appPasswordHelp {
            Link("Apple's help on app passwords", destination: help)
                .font(Typeface.caption)
        }
        field {
            TextField("Address", text: $address)
                .textContentType(.emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }
        field {
            SecureField("App password", text: $password)
                .autocorrectionDisabled()
        }
    }

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(Typeface.body)
            .foregroundStyle(Theme.current.textPrimary.color)
            .padding(Space.s3)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
            .disabled(model.isAdding)
    }

    private func addGoogle() {
        problem = nil
        let signIn = webSignIn(webAuthenticationSession)
        Task {
            switch await model.addGoogle(signingIn: signIn) {
            case .added: close()
            case .cancelled: break
            case .failed(let said): problem = said
            }
        }
    }

    private func add() {
        let chosen = provider, typed = address, secret = password
        problem = nil
        Task {
            problem = await model.add(chosen, address: typed, appPassword: secret)
            if problem == nil { close() }
        }
    }

    /// The password leaves the screen's memory with the screen.
    private func close() {
        password = ""
        onDone()
    }
}
