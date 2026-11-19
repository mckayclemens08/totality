import SwiftUI
import TotalityCore
import TotalityUI

// The private Account page (Social canvas, Account board, owner 2026-11-17). Social's profile is the one
// public profile; this page is only ever seen by its owner and holds the settings. Every group and row is
// raised, never pressed in (issue 132). Each setting still works the way it did on the old Settings screen.

/// The signed-in Account page: a way to the public profile, then the settings in groups.
struct AccountPage: View {
    let model: AccountModel

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s5) {
            Label("Only you see this page", systemImage: "lock.fill")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .labelStyle(OnlyYouLabelStyle())

            NavigationLink { ProfileScreen(model: model) } label: { ProfileCard(model: model) }
                .buttonStyle(SoftPress())

            SettingsGroup("Look") {
                NavigationLink { ThemePickerView() } label: {
                    SettingsRow("Theme", value: ThemeStore.shared.choice.name)
                }
                HomeStyleRow()
            }

            SettingsGroup("Keys and devices") {
                if let backup = model.backup {
                    NavigationLink { BackupView(model: backup) } label: {
                        SettingsRow("Recovery key", value: Self.recoveryValue(backup.phase))
                    }
                }
                NavigationLink { DevicesScreen(model: model) } label: {
                    SettingsRow("Devices", value: model.deviceRegistered ? "This device added" : "Not added")
                }
                NavigationLink { SyncScreen(model: model) } label: {
                    SettingsRow("Sync", value: Self.syncValue(model.sync))
                }
            }

            if let storage = model.storage {
                SettingsGroup("Storage") {
                    NavigationLink { StorageScreen(model: storage) } label: {
                        SettingsRow("Used", value: storage.sealed.quota?.line)
                    }
                }
            }

            SignOutButton(isWorking: model.isWorking) { Task { await model.signOut() } }
        }
        .buttonStyle(.plain)
    }

    private static func recoveryValue(_ phase: BackupModel.Phase) -> String? {
        switch phase {
        case .ready: "Saved"
        case .notSetUp: "Not set up"
        case .needsKey: "Needed"
        case .checking, .working: nil
        default: nil
        }
    }

    private static func syncValue(_ sync: SyncModel?) -> String {
        guard let sync, sync.isAvailable else { return "Off" }
        switch sync.status {
        case .syncing: return "Syncing"
        case .failed: return "Didn't finish"
        case .idle:
            guard let last = sync.lastSynced else { return "Not yet" }
            return last.formatted(.relative(presentation: .named))
        }
    }
}

private struct OnlyYouLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s2) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}

/// The raised card that leads to the public profile.
private struct ProfileCard: View {
    let model: AccountModel

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            ProfilePicture(url: model.profile?.avatarURL, diameter: Metric.headerButton)
            VStack(alignment: .leading, spacing: Space.hairline * 2) {
                Text("Your profile")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text(subtitle)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Chevron()
        }
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s4)
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let profile = model.profile { return "@\(profile.username) · what everyone else sees" }
        if case .signedIn(let username) = model.phase { return "@\(username) · what everyone else sees" }
        return "What everyone else sees"
    }
}

/// A titled, raised group of rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title)
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
                .padding(.horizontal, Space.s1)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }
}

/// One row in a group: its name, its current value, and a chevron.
private struct SettingsRow: View {
    let title: String
    let value: String?

    init(_ title: String, value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Text(title)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: Space.s2)
            if let value {
                Text(value)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            Chevron()
        }
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s4)
        .frame(minHeight: Metric.headerButton)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .accessibilityHidden(true)
    }
}

/// Which home page Totality opens on, as a row that opens a menu. It's on this device and needs no account.
private struct HomeStyleRow: View {
    @AppStorage(HomeStyle.defaultKey) private var defaultHome = HomeStyle.tiles

    var body: some View {
        Menu {
            Picker("Home opens to", selection: $defaultHome) {
                ForEach(HomeStyle.allCases) { style in
                    Text(style.name).tag(style)
                }
            }
        } label: {
            SettingsRow("Home opens to", value: defaultHome.name)
        }
    }
}

/// Sign out, raised with danger-coloured words.
private struct SignOutButton: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView()
                } else {
                    Text("Sign out")
                }
            }
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(theme.danger.color)
            .frame(maxWidth: .infinity)
            .padding(Space.s3)
            .frame(minHeight: Metric.headerButton)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .disabled(isWorking)
    }
}

// MARK: - The screens the rows open

/// The public profile's photo, name and bio, with Edit and Share, and a way to see it as others do in Social.
struct ProfileScreen: View {
    let model: AccountModel
    @State private var editing = false
    @State private var sharing = false

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                ProfileSummary(model: model, onEdit: { editing = true }, onShare: { sharing = true })
                if let open = model.onOpenSocialProfile {
                    HeaderPill("See it in Social", systemImage: "person.2", action: open)
                }
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.bg.color)
        .navigationTitle("Your profile")
        .navigationDestination(isPresented: $editing) {
            EditProfileView(model: model) { editing = false }
        }
        .navigationDestination(isPresented: $sharing) {
            ShareProfileView(model: model) { sharing = false }
        }
    }
}

private struct DevicesScreen: View {
    let model: AccountModel

    var body: some View {
        DetailScreen(title: "Devices") {
            if case .signedIn(let username) = model.phase {
                AccountDetail(text: "Signed in as \(username).")
            }
            AccountDetail(text: model.deviceRegistered ? "This device is added to your account." : "This device isn't added to your account yet.")
            if let browsers = model.browsers {
                BrowsersSection(model: browsers)
            }
            if let pairing = model.pairing {
                NavigationLink { PairBrowserScreen(model: pairing) } label: {
                    SettingsRow("Pair a browser", value: nil)
                }
                .buttonStyle(.plain)
            }
        }
        .refreshable { await model.browsers?.load() }
    }
}

/// Devices › Browsers: every browser paired with the website, each with Remove (mockup approved direction, 2026-11-19).
private struct BrowsersSection: View {
    let model: BrowsersModel
    @State private var confirming: WebBrowser?

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Browsers")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, Space.s1)
                .accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(Space.s4)
            case .failed(let text):
                AccountDetail(text: text)
            case .loaded(let list) where list.isEmpty:
                AccountDetail(text: "No browsers are signed in. Pair one to use Totality on a computer.")
            case .loaded(let list):
                VStack(spacing: 0) {
                    ForEach(list) { browser in row(browser) }
                }
                .padding(.horizontal, Space.s4)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                AccountDetail(text: "Every browser you paired. Removing one signs it out of the website and ends Messages there.")
            }
            if let message = model.message { AccountDetail(text: message) }
        }
        .task { await model.load() }
        .confirmationDialog(confirming.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible, presenting: confirming) { browser in
            Button("Remove browser", role: .destructive) { Task { await model.remove(browser) } }
            Button("Cancel", role: .cancel) {}
        } message: { browser in
            Text("\(BrowsersModel.lastActive(browser.lastSeen)). It's signed out of the website and Messages within 5 minutes, or the next time it opens, and its message keys are deleted from your account. To use it again, sign in and pair it with this iPhone. Removing can't make a browser forget what it already opened.")
        }
    }

    private func row(_ browser: WebBrowser) -> some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.label).font(Typeface.body.weight(.semibold)).foregroundStyle(theme.textPrimary.color)
                Text(BrowsersModel.lastActive(browser.lastSeen) + (browser.matrixDevice == nil ? "" : " · Messages on"))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: Space.s2)
            if model.removing == browser.id {
                ProgressView()
            } else {
                Button("Remove") { confirming = browser }
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .neumorphic(.subtle, in: Capsule())
                    .disabled(model.removing != nil)
                    .accessibilityLabel("Remove \(browser.label)")
            }
        }
        .padding(.vertical, Space.s3)
    }
}

private struct SyncScreen: View {
    let model: AccountModel

    var body: some View {
        DetailScreen(title: "Sync") {
            AccountDetail(text: model.sync?.isAvailable == true
                ? "Your notes, files, and events sync between your devices, encrypted. Signing out leaves them on this device, and event reminders keep showing."
                : "Set up your recovery key to sync your notes, files, and events. Signing out leaves them on this device, and event reminders keep showing.")
            if let sync = model.sync, let summary = sync.summary {
                AccountDetail(text: summary)
                AccountButton(title: "Sync now", isWorking: sync.status == .syncing) { Task { await sync.syncNow() } }
                if sync.heldRemovals > 0 {
                    Button("Remove those \(sync.heldRemovals) items here too") { Task { await sync.applyHeldRemovals() } }
                        .font(Typeface.callout)
                        .disabled(sync.status == .syncing)
                }
            }
        }
    }
}

private struct StorageScreen: View {
    let model: StorageModel

    var body: some View {
        DetailScreen(title: "Storage") {
            StorageSection(model: model)
        }
    }
}

private struct DetailScreen<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) { content }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.bg.color)
        .navigationTitle(title)
    }
}
