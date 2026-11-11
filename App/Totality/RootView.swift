import SwiftUI
import TotalityAccount
import TotalityCalendar
import TotalityCore
import TotalityMail
import TotalityMessages
import TotalityPhotos
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
    @State private var messages: MessagesModel
    // The real mailbox, for whoever owns this device's key. `mailWiring` holds that account's vault.
    @State private var mail: MailAccountModel
    @State private var mailWiring: MailWiring
    // The photos of whoever owns this device's key, once it has joined the key backup.
    @State private var photos = PhotosModel(library: nil)
    @State private var photosWiring = PhotosWiring()
    /// Counts each change of who Photos is for, so an older one that finishes late is ignored.
    @State private var photosTurn = 0
    @State private var registry: ModuleRegistry?
    @State private var syncAreas: [any SyncArea] = []
    @State private var contentProblem: ContentProblem?
    @State private var contentKeys: DeviceContentKeys
    @State private var account: AccountModel?
    @State private var showingAccount = false
    @State private var showingSearch = false
    /// Someone's profile, opened from their link.
    @State private var linkedProfile: LinkedProfile?
    @AppStorage(HomeStyle.defaultKey) private var defaultHomeStyle = HomeStyle.tiles
    // What the home page's button chose, until the app restarts or the default changes.
    @State private var chosenHomeStyle: HomeStyle?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let keys = DeviceContentKeys()
        _contentKeys = State(initialValue: keys)
        let account = AccountSetup.makeModel(content: keys)
        _account = State(initialValue: account)
        let wiring = MailWiring()
        // A mailbox's key can never be replaced, so it's published only from a device whose key is the
        // signed-in account's and has joined the key backup.
        wiring.canPublish = { [backup = account?.backup] account in
            guard let backup, await backup.deviceCanSync() else { return false }
            return await backup.deviceOwner() == account
        }
        _mailWiring = State(initialValue: wiring)
        _messages = State(initialValue: AccountSetup.makeMessages())
        _mail = State(initialValue: MailAccountModel { wiring.makeStore(account: $0) })
    }

    var body: some View {
        Group {
            switch open {
            case nil:
                HomeView(center: recentModule, glances: glances, bigTile: bigTile, lineLink: lineLink, style: homeStyle) { module in
                    if [.reader, .calendar, .web, .mail, .photos].contains(module) { prepareContent() }
                    bringUp(module)
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
            case .mail:
                MailHomeView(model: mail.current, onClose: { open = nil }, onOpenLink: openInWeb)
                    .id(ObjectIdentifier(mail.current))
            case .messages:
                MessagesHomeView(model: messages) { open = nil }
            case .photos:
                PhotosHomeView(model: photos, onClose: { open = nil }, onOpenAccount: { showingAccount = true })
                    .id(ObjectIdentifier(photos))
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
                // Photos first, before any wait, so the home tile can't show the old key's photos meanwhile.
                photosTurn += 1
                photos = PhotosModel(library: nil)
                await account?.sync?.pause()
                await reader?.stopForKeyChange()
                await calendar?.stopForKeyChange()
                await web?.stopForKeyChange()
                reader = nil
                calendar = nil
                web = nil
                await mailWiring.disconnect()
                mail.keyChanged()
                photosTurn += 1
                await photosWiring.disconnect()
                photos = PhotosModel(library: nil)
                registry = nil
                AppRefresh.shared.registry = nil
                syncAreas = []
                contentProblem = nil
            }
            contentKeys.didMove = { account?.sync?.resume() }
            await account?.backup?.settleDevice()
            connectSync()
            await openContentForHome()
            // So the Messages tile shows who's written without opening Messages first.
            Task { await messages.connect() }
            await refreshAhead()
            await account?.sync?.syncNow()
        }
        // Every minute while Totality is in front, the modules fetch what's new, so opening one never waits.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: AppRefresh.every)
                guard !Task.isCancelled else { return }
                await refreshAhead()
            }
        }
        .onChange(of: defaultHomeStyle) { chosenHomeStyle = nil }
        .onChange(of: showingAccount) {
            if !showingAccount { Task { await messages.checkAccount() } }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                Task {
                    await refreshAhead()
                    await account?.sync?.syncNow()
                }
            case .background:
                AppRefresh.shared.scheduleBackground()
            default:
                break
            }
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
        .onOpenURL { url in
            if let username = ProfileLink.username(in: url) { linkedProfile = LinkedProfile(username: username) }
        }
        .sheet(item: $linkedProfile) { linked in
            if let account {
                OtherProfileView(model: account, username: linked.username) { linkedProfile = nil }
            } else {
                ModuleMessage(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Sign-in isn't set up",
                    detail: "This build has no backend settings, so profiles can't open."
                ) { linkedProfile = nil }
            }
        }
        .sheet(isPresented: $showingSearch) {
            if let registry {
                SearchView(search: UniversalSearch(searchers: registry.searchers + [MessagesSearcher(model: messages)]), onOpen: show) { showingSearch = false }
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
        glances[.web] = web?.glance
        glances[.mail] = mail.current.glance
        glances[.messages] = messages.glance
        glances[.photos] = photos.glance
        return glances
    }

    /// A module's own view for a big tile. Nil falls back to the lines, which say why it's quiet.
    private func bigTile(_ module: ModuleID, size: BigTileSize) -> AnyView? {
        switch module {
        case .reader:
            guard let reader, reader.glance?.isQuiet == false else { return nil }
            return AnyView(ReaderHomeTile(model: reader, size: size) { bringUp(.reader) })
        case .calendar:
            guard let calendar, calendar.glance != nil else { return nil }
            return AnyView(CalendarHomeTile(model: calendar, size: size) { bringUp(.calendar) })
        case .web:
            guard let web, web.glance != nil else { return nil }
            return AnyView(WebHomeTile(model: web, size: size) { bringUp(.web) })
        case .mail:
            guard mail.current.phase == .ready else { return nil }
            return AnyView(MailHomeTile(model: mail.current, size: size) { bringUp(.mail) })
        case .photos:
            // Signing out shows nothing at once, before the library is closed.
            guard photos.phase == .ready, let account, case .signedIn = account.phase else { return nil }
            return AnyView(PhotosHomeTile(model: photos, size: size) { bringUp(.photos) })
        default:
            return nil
        }
    }

    /// What a line of a tile opens. A tile can only show these once its module is open, so nothing here
    /// has to prepare content.
    private func lineLink(_ module: ModuleID, _ line: Int) -> (@MainActor () -> Void)? {
        switch module {
        case .reader:
            guard let id = reader?.glanceItem(at: line) else { return nil }
            return {
                reader?.requestedItem = id
                bringUp(.reader)
            }
        case .calendar:
            guard let target = calendar?.glanceTarget(at: line) else { return nil }
            return {
                calendar?.request(target)
                bringUp(.calendar)
            }
        case .web:
            guard let bookmark = web?.glanceBookmark(at: line) else { return nil }
            return {
                web?.openFromHome(bookmark)
                bringUp(.web)
            }
        case .messages:
            guard let chat = messages.glanceChat(at: line) else { return nil }
            return {
                messages.requestedChat = chat
                bringUp(.messages)
            }
        case .mail:
            guard let id = mail.current.glanceConversation(at: line) else { return nil }
            return {
                mail.current.requestFromHome(id)
                bringUp(.mail)
            }
        default:
            return nil
        }
    }

    private func bringUp(_ module: ModuleID) {
        recentModule = module
        open = module
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
            let content = try ContentSetup.makeModels(mailRefresh: { @MainActor [mail] in await mail.current.refresh() })
            reader = content.reader
            calendar = content.calendar
            web = content.web
            web?.onSentToReader = { Task { await reader?.load() } }
            web?.onOpenInReader = { show($0) }
            mailWiring.connect(content.mail)
            photosWiring.connect(content.photos)
            mail.receiver = content.registry.receiver(for: .mail)
            mail.onSentToReader = { Task { await reader?.load() } }
            registry = content.registry
            AppRefresh.shared.registry = content.registry
            syncAreas = content.areas
            refreshRecoveryLabels()
            Task { await tellWhoIsHere() }
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
        await tellWhoIsHere()
        // So the Mail tile has something to show before Mail is opened.
        if mail.current.phase != .ready { await mail.current.refresh() }
    }

    /// Each module that keeps itself up to date fetches what's new, quietly.
    private func refreshAhead() async {
        await AppRefresh.shared.refresh()
    }

    /// Web keeps things only for the key's owner, and Mail shows only the owner's mailbox.
    private func tellWhoIsHere() async {
        photosTurn += 1
        let turn = photosTurn
        let owner = await account?.backup?.deviceOwner()
        let newVault = await mailWiring.use(account: owner)
        mail.use(account: owner, restart: newVault)
        // Photos go to the server as they're added, so only a device that can sync gets a library.
        let canSync = await account?.backup?.deviceCanSync() ?? false
        if turn == photosTurn, await photosWiring.use(account: canSync ? owner : nil), turn == photosTurn {
            let model = PhotosModel(library: photosWiring.library, unavailable: photosReason())
            model.sender = photosSender()
            photos = model
            await model.load()
        } else if turn == photosTurn, photos.account != photosWiring.library?.account
                    || (photosWiring.library == nil && photos.phase != .unavailable(title: photosReason().title, detail: photosReason().detail)) {
            // The model on screen must always be the current library's, or none.
            let model = PhotosModel(library: photosWiring.library, unavailable: photosReason())
            model.sender = photosSender()
            photos = model
            await model.load()
        }
        await web?.use(account: owner)
    }

    /// Photos shares through Messages, which runs only where the Matrix SDK is linked.
    private func photosSender() -> (any PersonSender)? {
        #if canImport(MatrixRustSDK)
        return MessagesSender(messages: messages)
        #else
        return nil
        #endif
    }

    /// Why Photos can't open on this device, in the words its screen shows.
    private func photosReason() -> (title: String, detail: String) {
        guard let account, case .signedIn = account.phase else { return PhotosModel.signedOut }
        if account.backup?.phase == .otherAccount { return PhotosModel.otherAccountsKey }
        return PhotosModel.needsRecoveryKey
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
            // Mail's vault joins only when it's the syncing account's, which `deviceCanSync` just proved
            // is the owner's. One opened for someone else would be left out.
            var areas = syncAreas
            let owner = await backup.deviceOwner()
            if let vault = mailWiring.vault, vault.account == owner { areas.append(vault) }
            let bound = try await remote.forCurrentAccount()
            let engine = SyncEngine(areas: areas, remote: bound, state: FileSyncState(file: try ContentSetup.syncStateFile()))
            let report = try await engine.sync(allowLargeRemoval: allowLargeRemoval)
            // Older files move from Supabase Storage to the sealed store a few at a time (issue 54). It
            // stops safely wherever it fails, so it never fails the sync.
            if let movable = bound as? any MovesBodies { _ = try? await movable.moveBodies() }
            return report
        }
        sync.onFinished = { refreshRecoveryLabels() }
        sync.onChanged = {
            await reader?.load()
            await calendar?.load()
            await web?.load()
            // Marks from another device, so Mail is already up to date when it's opened.
            if mail.current.phase == .ready { await mail.current.refresh() }
        }
        backup.onJoined = {
            await sync.syncNow()
            await tellWhoIsHere()
        }
        backup.onOwnerChanged = { await tellWhoIsHere() }
    }

    /// Mail's links leave for Web, which opens them like any other address. If Web can't open, that's
    /// where the person hears why.
    private func openInWeb(_ url: URL) {
        prepareContent()
        web?.open(url)
        bringUp(.web)
    }

    /// Only the Reader's content can be attached so far, so that's where a ref opens.
    private func show(_ ref: ContentRef) {
        guard ref.module == .reader else { return }
        reader?.requestedItem = ref.id
        bringUp(.reader)
    }

    /// Only the module that found a result knows what its ID means, so it goes back there to open.
    private func show(_ hit: SearchHit) {
        showingSearch = false
        switch hit.module {
        case .reader: reader?.requestedItem = UUID(uuidString: hit.itemID)
        case .calendar: calendar?.requestedHit = hit
        case .messages: messages.requestedChat = hit.itemID
        default: return
        }
        bringUp(hit.module)
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

private struct LinkedProfile: Identifiable {
    let username: String
    var id: String { username }
}
