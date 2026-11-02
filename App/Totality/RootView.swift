import SwiftUI
import TotalityAccount
import TotalityCalendar
import TotalityCore
import TotalityReader
import TotalityUI
import TotalityWeb

/// Home and whichever module is open. The Reader's model stays alive here, so Listen keeps playing
/// after the person goes back to the home screen.
struct RootView: View {
    @State private var open: ModuleID?
    // Only which module was last open, on this device. It holds no content.
    @AppStorage("home.recentModule") private var recentModule = ModuleID.reader
    @State private var reader: ReaderModel?
    @State private var calendar: CalendarModel?
    @State private var web: WebModel?
    @State private var registry: ModuleRegistry?
    @State private var syncAreas: [any SyncArea] = []
    @State private var contentProblem: ContentProblem?
    @State private var contentKeys: DeviceContentKeys
    @State private var account: AccountModel?
    @State private var showingAccount = false
    @State private var showingSearch = false
    @AppStorage(HomeStyle.defaultKey) private var defaultHomeStyle = HomeStyle.tiles
    // What the home page's button chose, until the app restarts or the default changes.
    @State private var chosenHomeStyle: HomeStyle?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let keys = DeviceContentKeys()
        _contentKeys = State(initialValue: keys)
        _account = State(initialValue: AccountSetup.makeModel(content: keys))
    }

    var body: some View {
        Group {
            switch open {
            case nil:
                HomeView(center: recentModule, glances: glances, bigTile: bigTile, style: homeStyle) { module in
                    if module == .reader || module == .calendar || module == .web { prepareContent() }
                    recentModule = module
                    open = module
                } onSearch: {
                    prepareContent()
                    showingSearch = true
                }
                .overlay(alignment: .topLeading) { accountButton }
            case .reader:
                if let reader {
                    ReaderHomeView(model: reader) { open = nil }
                } else {
                    contentMessage { open = nil }
                }
            case .calendar:
                if let calendar {
                    CalendarHomeView(model: calendar, onClose: { open = nil }, onOpen: show)
                } else {
                    contentMessage { open = nil }
                }
            case .web:
                if let web {
                    WebHomeView(model: web) { open = nil }
                } else {
                    contentMessage { open = nil }
                }
            case .some(let module):
                ModuleMessage(
                    systemImage: "hammer",
                    title: ModuleEntry.all.first { $0.id == module }?.name ?? "This module",
                    detail: "This isn't built yet. The Reader, Calendar, and Web are ready to use."
                ) { open = nil }
            }
        }
        .animation(Motion.standard, value: open)
        .task {
            contentKeys.willMove = {
                await account?.sync?.pause()
                await reader?.stopForKeyChange()
                await calendar?.stopForKeyChange()
                reader = nil
                calendar = nil
                web = nil
                registry = nil
                syncAreas = []
                contentProblem = nil
            }
            contentKeys.didMove = { account?.sync?.resume() }
            await account?.backup?.settleDevice()
            connectSync()
            await openContentForHome()
            await account?.sync?.syncNow()
        }
        .onChange(of: defaultHomeStyle) { chosenHomeStyle = nil }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await account?.sync?.syncNow() } }
        }
        .onChange(of: open) {
            guard open == nil else { return }
            Task {
                await openContentForHome()
                await account?.sync?.syncNow()
            }
        }
        .sheet(isPresented: $showingAccount) {
            if let account {
                AccountView(model: account) { showingAccount = false }
            } else {
                ModuleMessage(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Sign-in isn't set up",
                    detail: "This build has no backend settings. Your notes aren't affected."
                ) { showingAccount = false }
            }
        }
        .sheet(isPresented: $showingSearch) {
            if let registry {
                SearchView(search: UniversalSearch(searchers: registry.searchers), onOpen: show) { showingSearch = false }
            } else {
                contentMessage { showingSearch = false }
            }
        }
    }

    private var homeStyle: Binding<HomeStyle> {
        Binding {
            chosenHomeStyle ?? defaultHomeStyle
        } set: {
            chosenHomeStyle = $0
        }
    }

    /// Modules without a screen yet say so. A module that can't open shows no lines at all, because
    /// the home page is no place to report a key problem. Opening the module does that.
    private var glances: [ModuleID: ModuleGlance] {
        var glances = Dictionary(uniqueKeysWithValues: ModuleEntry.all.map { ($0.id, ModuleGlance(lines: ["Not built yet"], isQuiet: true)) })
        glances[.reader] = reader?.glance
        glances[.calendar] = calendar?.glance
        return glances
    }

    /// A module's own view for a big tile. Nil falls back to the lines, which say why it's quiet.
    private func bigTile(_ module: ModuleID, size: BigTileSize) -> AnyView? {
        switch module {
        case .reader:
            guard let reader, reader.glance?.isQuiet == false else { return nil }
            return AnyView(ReaderHomeTile(model: reader, size: size))
        case .calendar:
            guard let calendar, calendar.glance != nil else { return nil }
            return AnyView(CalendarHomeTile(model: calendar, size: size))
        default:
            return nil
        }
    }

    private var accountButton: some View {
        Button {
            showingAccount = true
        } label: {
            Image(systemName: "person")
                .font(Typeface.body)
                .foregroundStyle(Theme.current.textPrimary.color)
                .frame(width: Space.s7, height: Space.s7)
                .neumorphic(.subtle, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(Space.s4)
        .accessibilityLabel("Account")
    }

    private func contentMessage(onClose: @escaping () -> Void) -> some View {
        let problem = contentProblem ?? .keyUnavailable
        return ModuleMessage(systemImage: "lock.slash", title: problem.title, detail: problem.detail, onClose: onClose)
    }

    private func prepareContent() {
        guard reader == nil else { return }
        guard !contentKeys.isMoving else {
            contentProblem = .keyUnavailable
            return
        }
        do {
            let content = try ContentSetup.makeModels()
            reader = content.reader
            calendar = content.calendar
            web = content.web
            registry = content.registry
            syncAreas = content.areas
            refreshRecoveryLabels()
        } catch KeyStoreError.keyMissing {
            contentProblem = .keyMissing
        } catch {
            contentProblem = .keyUnavailable
        }
    }

    /// The tiles show live content, so it opens with the home page. This has to come after the device
    /// is settled, and it follows the same rules as opening a module.
    private func openContentForHome() async {
        guard reader == nil else { return }
        prepareContent()
        await reader?.load()
        await calendar?.load()
    }

    /// Only a sync that really finished counts, so the screens can't claim safety too early.
    private func refreshRecoveryLabels() {
        let isProtected = account?.sync?.isProtected ?? false
        reader?.isSynced = isProtected
        calendar?.isSynced = isProtected
    }

    /// Sync runs on the same vaults the modules use, so it opens them if nothing has yet.
    private func connectSync() {
        guard let account, let sync = account.sync, let remote = account.syncRemote, let backup = account.backup else { return }
        sync.run = { allowLargeRemoval in
            guard await backup.deviceCanSync() else { return nil }
            prepareContent()
            guard !syncAreas.isEmpty else { return nil }
            let engine = SyncEngine(areas: syncAreas, remote: try await remote.forCurrentAccount(), state: FileSyncState(file: try ContentSetup.syncStateFile()))
            return try await engine.sync(allowLargeRemoval: allowLargeRemoval)
        }
        sync.onFinished = { refreshRecoveryLabels() }
        sync.onChanged = {
            await reader?.load()
            await calendar?.load()
        }
        backup.onJoined = { await sync.syncNow() }
    }

    /// Only the Reader's content can be attached so far, so that's where a ref opens.
    private func show(_ ref: ContentRef) {
        guard ref.module == .reader else { return }
        reader?.requestedItem = ref.id
        recentModule = .reader
        open = .reader
    }

    /// Only the module that found a result knows what its ID means, so it goes back there to open.
    private func show(_ hit: SearchHit) {
        showingSearch = false
        switch hit.module {
        case .reader: reader?.requestedItem = UUID(uuidString: hit.itemID)
        case .calendar: calendar?.requestedHit = hit
        default: return
        }
        recentModule = hit.module
        open = hit.module
    }
}

private enum ContentProblem {
    case keyMissing, keyUnavailable

    var title: String {
        switch self {
        case .keyMissing: "Your key isn't on this device"
        case .keyUnavailable: "This didn't open"
        }
    }

    var detail: String {
        switch self {
        case .keyMissing:
            "Your items are here, still encrypted, but the key that opens them isn't. Totality has left them untouched and won't make a new key over them."
        case .keyUnavailable:
            "Totality couldn't reach this device's key, and it won't replace one it can't read. Go back and try again."
        }
    }
}

/// A module's full-screen message, with the way back home.
private struct ModuleMessage: View {
    let systemImage: String
    let title: String
    let detail: String
    let onClose: () -> Void

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
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            Button("Home", action: onClose)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .padding(.top, Space.s3)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
    }
}
