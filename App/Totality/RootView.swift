import os
import SwiftUI
import TotalityAccount
import TotalityAI
import TotalityCalendar
import TotalityClock
import TotalityContacts
import TotalityCore
import TotalityMail
import TotalityMessages
import TotalityMusic
import TotalityPhotos
import TotalityReader
import TotalitySocial
import TotalityTasks
import TotalityUI
import TotalityHiking
import TotalityNews
import TotalityWeather
import TotalityWeb

/// Home and whichever module is open. The Reader's model stays alive here, so Listen keeps playing
/// after the person goes back to the home screen.
struct RootView: View {
    @State private var open: ModuleID?
    /// A module asked for from search, opened once the search sheet is gone.
    @State private var pendingOpen: ModuleID?
    /// Where a module zooms out of: its tile on Home.
    // Only which module was last open, on this device. It holds no content.
    @AppStorage("home.recentModule") private var recentModule = ModuleID.reader
    @State private var reader: ReaderModel?
    @State private var calendar: CalendarModel?
    @State private var web: WebModel?
    @State private var tasks: TasksModel?
    @State private var weather: WeatherModel?
    @State private var clock: ClockModel?
    @State private var contacts: ContactsModel?
    @State private var hiking: HikingModel?
    @State private var ai: AIModel?
    @State private var music: MusicModel?
    @State private var news: NewsModel?
    /// A .gpx file opened in Totality, waiting for Hiking to be ready to take it.
    @State private var pendingGPX: URL?
    /// Shared task lists, over Messages' Matrix connection (step 6).
    @State private var sharedLists: SharedListsModel?
    /// Social, made the first time it's opened (issue 149). It needs the sign-in, not the content key.
    @State private var social: SocialModel?
    /// A post Social asked to send to a chat, which Messages' picker takes over (share to chat, 2026-11-26).
    @State private var shareRequest: ShareRequest?
    /// Quick add from the Tasks tile, over the home page.
    @State private var quickAddingTask = false
    @State private var messages: MessagesModel
    #if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
    @State private var voiceCalls = VoiceCalls()

    private var voiceChats: [ChatSummary] {
        messages.chats.filter { !$0.isRequest && !$0.isGroup && $0.otherPerson != nil }
    }

    private func dialVoiceChat(_ id: String) {
        guard let chat = voiceChats.first(where: { $0.id == id }) else { return }
        Task { await voiceCalls.dial(chat) }
    }

    private var voiceService: MatrixMessagesService? {
        messages.connectedService as? MatrixMessagesService
    }
    #endif
    // The real mailbox, for whoever owns this device's key. `mailWiring` holds that account's vault.
    @State private var mail: MailAccountModel
    @State private var mailWiring: MailWiring
    // The photos of whoever owns this device's key, once it has joined the key backup.
    @State private var photos = PhotosModel(library: nil)
    @State private var photosWiring = PhotosWiring()
    /// Counts each change of who Photos is for, so an older one that finishes late is ignored.
    @State private var photosTurn = 0
    /// Whichever Photos is current, for settings' storage bars.
    @State private var currentPhotos = CurrentPhotos()
    /// Modules taken off Home, which also skip refresh, reminders and search.
    @State private var homeChoices = HomeChoicesModel(defaults: ContentSetup.defaults())
    /// The account whose space is open, and its own settings.
    @State private var followedAccount: String?
    @State private var accountDefaults = ContentSetup.defaults()
    /// Each module's refresher, which `AppRefresh` reaches through the registry.
    @State private var refreshers = ModuleRefreshers()
    @State private var registry: ModuleRegistry?
    @State private var syncAreas: [any SyncArea] = []
    @State private var contentProblem: ContentProblem?
    @State private var contentKeys: DeviceContentKeys
    @State private var account: AccountModel?
    @State private var showingAccount = false
    @State private var showingSearch = false
    /// Someone's profile, opened from their link.
    @State private var linkedProfile: LinkedProfile?
    /// Ask Totality sheet triggered from inside a module (or focused on one item).
    @State private var askTarget: AskTotalityTarget?
    // What the home page's button chose, until the app restarts or the default changes.
    @Environment(\.scenePhase) private var scenePhase
    /// The branded screen while the session is restored and each module opens what it has saved.
    @State private var launching = true
    /// Counts each launch screen, so a later launch overrides an earlier one.
    @State private var launchTurn = 0
    /// Incremented when a sign-in-linked layout arrives from the server so Home reloads immediately.
    @State private var homeLayoutRevision = 0
    private static let launchLog = Logger(subsystem: "app.totality.client", category: "launch")

    init() {
        let keys = DeviceContentKeys()
        _contentKeys = State(initialValue: keys)
        let account = AccountSetup.makeModel(content: keys)
        _account = State(initialValue: account)
        let current = CurrentPhotos()
        _currentPhotos = State(initialValue: current)
        if let storage = StorageSetup.makeModel(photos: { current.model }) {
            account?.storage = storage
            AppRefresh.shared.extras["storage"] = { await storage.refresh() }
        }
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

    private var launchAndSignIn: some View {
        ZStack {
            if account?.showsSignInPage == true {
                if let account { SignInPage(model: account).transition(.opacity) }
            } else {
                screens
            }
            if launching {
                LaunchView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .motion(Motion.smooth, value: account?.showsSignInPage)
        .task {
            connectSharedContent()
            contentKeys.willMove = { await closeContent() }
            contentKeys.didMove = { account?.sync?.resume() }
            watchAccountChanges()
            // A push or a background refresh can start Totality while the phone is locked, when the saved
            // sign-in and the content key can't be read. Opening then would find nobody here and leave
            // Home empty, so launch waits for the unlock (owner, 2026-11-26).
            await ProtectedDataGate.system.waitUntilAvailable()
            await account?.restoreIfNeeded()
            await launch()
            await refreshAhead()
            await account?.sync?.syncNow()
        }
        // Signing in on the sign-in page opens Home already filled in, as launching does. Signing in from
        // the Account sheet is followed when the sheet closes.
        .onChange(of: isSignedIn) { wasSignedIn, signedIn in
            guard signedIn, !wasSignedIn, !showingAccount, !launching else { return }
            Task { await openAfterSignIn() }
        }
        .onChange(of: account?.syncedHomeLayout) { _, remote in
            guard let remote else { return }
            Task { await applySyncedHomeLayout(remote) }
        }
        // Signing out brings the sign-in page back, with nothing of the account left open over it.
        .onChange(of: account?.showsSignInPage) {
            guard account?.showsSignInPage == true else { return }
            showingAccount = false
            showingSearch = false
            quickAddingTask = false
            linkedProfile = nil
            open = nil
        }
    }

    /// `body` is split in two so the compiler can type-check each half in reasonable time.
    var body: some View {
        launchAndSignIn
        #if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
        .environment(\.startVoiceCall, voiceService == nil ? nil : dialVoiceChat)
        .task(id: VoiceWatchKey(service: voiceService.map(ObjectIdentifier.init), rooms: Set(voiceChats.map(\.id)))) {
            await voiceCalls.watch(voiceService, chats: voiceChats)
        }
        .modifier(VoiceCallPresentation(calls: voiceCalls, showingCalls: open == .calls))
        #endif
        // Every minute while Totality is in front, the modules fetch what's new, so opening one never waits.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: AppRefresh.every)
                guard !Task.isCancelled else { return }
                await refreshAhead()
            }
        }
        // Every module's photo chooser shows the Photos library first. Modules only see `PhotoChoosing`.
        .environment(\.photoChooser, photos)
        .onChange(of: ObjectIdentifier(photos), initial: true) {
            refreshers[.photos] = photos.refresher
            currentPhotos.model = photos
        }
        .onChange(of: homeChoices.removed, initial: true) { old, removed in
            AppRefresh.shared.removed = removed
            // Calendar coming off Home clears the reminders already waiting.
            if removed.contains(.calendar), !old.contains(.calendar) || old == removed {
                Task { await SystemReminders().replace(with: []) }
            }
            // Tasks coming off Home clears its reminders; coming back plans them again.
            if removed.contains(.tasks) != old.contains(.tasks) || old == removed {
                Task { await tasks?.planReminders() }
            }
        }
        .onChange(of: showingAccount) {
            if !showingAccount {
                Task {
                    await followAccount()
                    if needsHomeAgain { await warmUp() }
                    await messages.checkAccount()
                    // The recovery key may have just been set up or entered.
                    await messages.settleKeys()
                    await account?.sync?.syncNow()
                }
            }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                Task {
                    await account?.restoreIfNeeded()
                    // Home is never left empty: content that couldn't open before opens now.
                    if needsHomeAgain { await warmUp() }
                    await refreshAhead()
                    await syncHomeLayoutFromAccount()
                    await account?.sync?.syncNow()
                    // An account whose Matrix address couldn't be made at sign-up gets another try.
                    await account?.setUpMessagesIfNeeded()
                }
            case .background:
                AppRefresh.shared.scheduleBackground()
                // Drive files opened lately wait to sync, so the server can't time each open.
                Task {
                    await reader?.drive?.publishOpened()
                    await reader?.publishPlaces()
                }
            default:
                break
            }
        }
        .onChange(of: open) {
            guard open == nil else { return }
            Task {
                await account?.restoreIfNeeded()
                await followAccount()
                await openContentForHome()
                if social == nil { await openSocialForHome() }
                await account?.sync?.syncNow()
                logLaunchState("closedModule")
            }
        }
        #if os(iOS)
        // A tap on an alert asks for its module; the module was already told which item (issue 232).
        .onChange(of: NotificationHub.shared.requestedModule, initial: true) { _, module in
            guard let module else { return }
            NotificationHub.shared.requestedModule = nil
            if module == .social, social == nil { social = makeSocial() }
            bringUp(module)
        }
        #endif
        #if os(iOS)
        // Mail seen, going in or out, is what the icon's badge counts from.
        .onChange(of: open) { old, new in
            guard old == .mail || new == .mail else { return }
            MailBadge.shared.markSeen()
            Task { await NotificationHub.shared.updateBadge() }
        }
        #endif
        .onChange(of: hiking != nil) { deliverGPX() }
        .onChange(of: isSignedIn) { deliverGPX() }
        .onChange(of: ObjectIdentifier(mail.current)) { Task { await warmMailForHome() } }
        .onOpenURL(perform: openURL)
    }

    /// A GPX file goes to Hiking; a profile link opens that profile.
    private func openURL(_ url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "gpx" {
            pendingGPX = url
            deliverGPX()
            return
        }
        if let username = ProfileLink.username(in: url) { linkedProfile = LinkedProfile(username: username) }
    }

    /// Signed in, done launching, and still missing open content: something stopped it opening, such as
    /// a locked phone or interrupted load, so coming to the front tries again, as closing a module would.
    private var needsHomeAgain: Bool {
        isSignedIn && !launching && (reader == nil || hasUnloadedHomeContent) && !contentKeys.isMoving && ProtectedDataGate.system.canRead
    }

    private var hasUnloadedHomeContent: Bool {
        reader?.phase == .loading
            || calendar?.phase == .loading
            || tasks?.phase == .loading
            || weather?.phase == .loading
            || clock?.phase == .loading
            || contacts?.phase == .loading
            || hiking?.phase == .loading
            || (social == nil && !homeChoices.removed.contains(.social))
    }

    private var isSignedIn: Bool {
        if case .signedIn = account?.phase { true } else { false }
    }

    /// Shows the launch screen while the signed-in account's space opens and each module reads what it
    /// has saved on this device, so Home's tiles are filled in when it appears (owner, 2026-11-25). Network
    /// tiles wait up to `LaunchView.limit`, while sign-in and local saved content always finish first.
    private func launch(after first: () async -> Void = {}) async {
        launchTurn += 1
        let turn = launchTurn
        launching = true
        await ProtectedDataGate.system.waitUntilAvailable()
        await first()
        // Never hold the launch screen past `LaunchView.limit`, even if account setup or a module stalls.
        await FirstContent.wait(
            for: [{
                await account?.restoreIfNeeded()
                // Signed out this is quick: each module finds no account and opens nothing.
                await warmUp()
            }],
            cap: LaunchView.limit
        )
        if turn == launchTurn { endLaunch() }
    }

    /// After signing in on the sign-in page: the launch screen while the account's space opens, then
    /// Home. A new account, or a device whose key isn't this account's yet, still needs the recovery key
    /// step, which lives on the Account page, so that opens over Home, as it did when signing in there.
    private func openAfterSignIn() async {
        // The device is claimed for the account before it's settled, never the other way round.
        await launch(after: { await account?.waitForSignIn() })
        await messages.checkAccount()
        await messages.settleKeys()
        if let backup = account?.backup {
            await backup.load()
            switch backup.phase {
            case .notSetUp, .needsKey, .confirmingOwnership, .otherAccount:
                if isSignedIn { showingAccount = true }
            default:
                break
            }
        }
        await refreshAhead()
        await account?.sync?.syncNow()
    }

    private func endLaunch() {
        guard launching else { return }
        withMotion(Motion.smooth) { launching = false }
    }

    /// Opens each module from its cache, then waits up to `LaunchView.limit` for network tiles.
    private func warmUp() async {
        // Prepare the signed-in account's space immediately without serializing module loads ahead of the cap.
        await followAccount(loadPhotos: false, loadContent: false)
        guard isSignedIn else {
            logLaunchState("warmUp.signedOut")
            return
        }
        connectSync()
        // All local & network warm-ups race together under `LaunchView.limit` so nothing hangs launch.
        var jobs: [@MainActor () async -> Void] = []
        var needsMessages = !homeChoices.removed.contains(.messages)
        #if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
        needsMessages = needsMessages || !homeChoices.removed.contains(.calls)
        #endif
        jobs.append { await openContentForHome(loadPhotos: false) }
        jobs.append { await syncHomeLayoutFromAccount() }
        if needsMessages { jobs.append { await messages.connect() } }
        jobs.append { await warmMailForHome() }
        jobs.append { await openSocialForHome() }
        if photos.phase == .loading { jobs.append { await photos.load() } }
        await FirstContent.wait(for: jobs, cap: LaunchView.limit)
        logLaunchState("warmUp.done")
    }

    private func logLaunchState(_ stage: String) {
        let accountPhase = switch account?.phase {
        case .loading: "loading"
        case .signedOut: "signedOut"
        case .signedIn: "signedIn"
        case nil: "nil"
        }
        let problem = contentProblem.map { "\($0)" } ?? "none"
        let hasReader = reader != nil
        let hasFollowed = followedAccount != nil
        let hasSocial = social != nil
        let mailReady = mail.current.phase == .ready
        let messagesReady = messages.phase == .ready
        let photosReady = photos.phase == .ready
        Self.launchLog.notice(
            "\(stage, privacy: .public): account=\(accountPhase, privacy: .public) followed=\(hasFollowed, privacy: .public) reader=\(hasReader, privacy: .public) problem=\(problem, privacy: .public) social=\(hasSocial, privacy: .public) mailReady=\(mailReady, privacy: .public) messagesReady=\(messagesReady, privacy: .public) photosReady=\(photosReady, privacy: .public)"
        )
    }

    /// Home, with the open module over it. On iPhone the module slides up as a cover and Home stays
    /// alive underneath, so going back lands where the person left it. The tile zoom was dropped
    /// (owner, 2026-11-18): iOS left stale snapshots of the module in Home's tiles after it closed.
    @ViewBuilder
    private var screens: some View {
        #if os(iOS)
        rootSheets(home, isTop: open == nil)
            .fullScreenCover(item: Binding(get: { open.map(OpenModule.init) }, set: { open = $0?.id })) { item in
                rootSheets(module(item.id), isTop: true)
            }
        #else
        rootSheets(
            ZStack {
                if let open {
                    module(open).transition(.opacity)
                } else {
                    home.transition(.opacity)
                }
            }
            .motion(Motion.smooth, value: open),
            isTop: true
        )
        #endif
    }

    private var home: some View {
        HomeView(
            glances: glances, bigTile: bigTile, lineLink: lineLink,
            removed: homeChoices.removed,
            onRemove: { module in
                Task {
                    await homeChoices.remove(module)
                    await pushLocalHomeLayout()
                }
            },
            onRestore: { module in
                Task {
                    await homeChoices.restore(module)
                    await pushLocalHomeLayout()
                }
            },
            onLayoutChanged: { data in
                Task { await pushLocalHomeLayout(data) }
            }
        ) { module in
            if [.reader, .calendar, .web, .mail, .photos, .tasks, .weather, .clock, .contacts, .hiking, .ai, .player, .news].contains(module) { prepareContent() }
            bringUp(module)
        } onSearch: {
            prepareContent()
            showingSearch = true
        } onAccount: {
            showingAccount = true
        }
        // Home's layout is the signed-in account's own, and a new account's Home starts fresh.
        .defaultAppStorage(accountDefaults)
        .id("\(followedAccount ?? "")-\(homeLayoutRevision)")
    }

    private static let homeLayoutStampKey = "home.layoutUpdatedAt"

    private func syncHomeLayoutFromAccount() async {
        guard isSignedIn else { return }
        await account?.loadHomeLayout()
        if let remote = account?.syncedHomeLayout {
            await applySyncedHomeLayout(remote)
        } else if accountDefaults.data(forKey: "home.layout") != nil || !homeChoices.removed.isEmpty {
            await pushLocalHomeLayout()
        }
    }

    private func applySyncedHomeLayout(_ remote: SyncedHomeLayout) async {
        let localData = accountDefaults.data(forKey: "home.layout")
        let localStamp = accountDefaults.object(forKey: Self.homeLayoutStampKey) as? Date
        let shouldApplyTiles = localData == nil || (localStamp.map { remote.updatedAt > $0 } ?? true)
        if shouldApplyTiles, let data = HomeLayout.savedData(from: remote.tiles), data != localData {
            accountDefaults.set(data, forKey: "home.layout")
            accountDefaults.set(remote.updatedAt, forKey: Self.homeLayoutStampKey)
            homeLayoutRevision += 1
        }
        await homeChoices.applySynced(remote.choices)
    }

    private func pushLocalHomeLayout(_ layoutData: Data? = nil) async {
        guard isSignedIn else { return }
        let now = Date()
        accountDefaults.set(now, forKey: Self.homeLayoutStampKey)
        let data = layoutData ?? accountDefaults.data(forKey: "home.layout") ?? Data()
        let tiles = HomeLayout.syncedTiles(from: data)
        await account?.saveHomeLayout(SyncedHomeLayout(tiles: tiles, choices: homeChoices.choices, updatedAt: now))
    }

    @ViewBuilder
    private func module(_ id: ModuleID) -> some View {
        switch id {
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
        case .tasks:
            if let tasks {
                TasksHomeView(model: tasks, shared: sharedLists) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .clock:
            if let clock {
                ClockHomeView(model: clock) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .weather:
            if let weather {
                WeatherHomeView(model: weather) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .contacts:
            if let contacts {
                ContactsHomeView(model: contacts) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .news:
            if let news { NewsHomeView(model: news, onClose: { open = nil }, onOpen: show) }
            else { contentMessage { open = nil } }
        case .hiking:
            if let hiking {
                HikingHomeView(model: hiking) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .ai:
            if let ai {
                AIHomeView(model: ai) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .player:
            if let music {
                MusicHomeView(model: music) { open = nil }
            } else {
                contentMessage { open = nil }
            }
        case .mail:
            MailHomeView(model: mail.current, onClose: { open = nil }, onOpenLink: openInWeb)
                .id(ObjectIdentifier(mail.current))
                .task(id: ObjectIdentifier(mail.current)) { mail.current.people = registry?.people }
        #if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
        case .calls:
            VoiceCallsHome(calls: voiceCalls, chats: voiceChats, ready: voiceService != nil) { open = nil }
        #endif
        case .messages:
            MessagesHomeView(model: messages, onClose: { open = nil }, onOpenAccount: { showingAccount = true })
        case .photos:
            PhotosHomeView(model: photos, onClose: { open = nil }, onOpenAccount: { showingAccount = true })
                .id(ObjectIdentifier(photos))
        case .social:
            if let social = social ?? makeSocial() {
                SocialHomeView(model: social) { open = nil }
                    .onAppear { if self.social == nil { self.social = social } }
            } else {
                ModuleMessage(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Sign-in isn't set up",
                    detail: "This build has no backend settings, so Social can't open."
                ) { open = nil }
            }
        default:
            ModuleMessage(
                systemImage: "hammer",
                title: ModuleEntry.all.first { $0.id == id }?.name ?? "This module",
                detail: "This isn't built yet. The Reader, Calendar, and Web are ready to use."
            ) { open = nil }
        }
    }

    /// The sheets that can come up anywhere. Only the top screen presents them, since a screen under a
    /// cover can't. Search opens only from Home.
    private func rootSheets(_ content: some View, isTop: Bool) -> some View {
        func gate(_ value: Binding<Bool>) -> Binding<Bool> {
            Binding(get: { isTop && value.wrappedValue }, set: { value.wrappedValue = $0 })
        }
        return content
            .sheet(isPresented: gate($showingAccount)) {
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
            .sheet(item: Binding(get: { isTop ? linkedProfile : nil }, set: { linkedProfile = $0 })) { linked in
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
            .sheet(item: $shareRequest) { request in
                ShareToChatSheet(model: messages, request: request) { shareRequest = nil }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: gate($quickAddingTask)) {
                if let tasks {
                    QuickAddView(model: tasks, bucket: .today) { quickAddingTask = false }
                }
            }
            .sheet(isPresented: gate($showingSearch), onDismiss: openPending) {
                if let registry {
                    SearchView(search: UniversalSearch(searchers: homeSearchers(registry)), onOpen: show) { showingSearch = false }
                } else {
                    contentMessage { showingSearch = false }
                }
            }
            .sheet(item: Binding(get: { isTop ? askTarget : nil }, set: { askTarget = $0 })) { target in
                if let ai {
                    AIHomeView(model: ai, about: target.context.map(AIContextItem.init)) { askTarget = nil }
                } else {
                    contentMessage { askTarget = nil }
                }
            }
            .environment(\.askTotality, AskTotalityAction { context in
                if reader == nil { prepareContent() }
                askTarget = AskTotalityTarget(context: context)
            })
    }

    /// Opens what search asked for, now its sheet is down. A cover can't come up while a sheet leaves.
    private func openPending() {
        guard let pendingOpen else { return }
        self.pendingOpen = nil
        open = pendingOpen
    }

    /// Modules without a screen yet say so. A module that can't open shows no lines at all, because
    /// the home page is no place to report a key problem. Opening the module does that.
    private var glances: [ModuleID: ModuleGlance] {
        var glances = Dictionary(uniqueKeysWithValues: ModuleEntry.all.map { ($0.id, ModuleGlance(lines: ["Not built yet"], isQuiet: true)) })
        glances[.reader] = reader?.glance
        glances[.calendar] = calendar?.glance
        glances[.web] = web?.glance
        glances[.tasks] = tasks?.glance
        glances[.weather] = weather?.glance
        glances[.clock] = clock?.glance
        glances[.contacts] = contacts?.glance
        glances[.hiking] = hiking?.glance
        glances[.ai] = ai?.glance
        glances[.player] = music?.glance
        glances[.social] = social?.glance
        glances[.mail] = mail.current.glance
        glances[.messages] = messages.glance
        glances[.photos] = photos.glance
        return glances
    }

    /// A module's own view for a big tile. Nil falls back to the lines, which say why it's quiet.
    private func bigTile(_ module: ModuleID, size: TileSize) -> AnyView? {
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
        case .tasks:
            guard let tasks, tasks.phase == .ready else { return nil }
            return AnyView(TasksHomeTile(model: tasks, size: size, onOpen: { bringUp(.tasks) }, onQuickAdd: { quickAddingTask = true }))
        case .clock:
            guard let clock, clock.phase == .ready else { return nil }
            return AnyView(ClockHomeTile(model: clock, size: size) { bringUp(.clock) })
        case .weather:
            guard let weather, weather.phase == .ready else { return nil }
            return AnyView(WeatherHomeTile(model: weather, size: size) { bringUp(.weather) })
        case .contacts:
            guard let contacts, contacts.phase == .ready else { return nil }
            return AnyView(ContactsHomeTile(model: contacts, size: size) { bringUp(.contacts) })
        case .news:
            guard let news else { return nil }
            return AnyView(NewsHomeTile(model: news, size: size))
        case .hiking:
            guard let hiking, hiking.phase == .ready else { return nil }
            return AnyView(HikingHomeTile(model: hiking, size: size) { bringUp(.hiking) })
        case .ai:
            guard let ai, ai.phase == .ready || ai.phase == .thinking else { return nil }
            return AnyView(AIHomeTile(model: ai, size: size) { bringUp(.ai) })
        case .player:
            guard let music, music.phase == .ready else { return nil }
            return AnyView(MusicHomeTile(model: music, size: size) { bringUp(.player) })
        case .mail:
            guard mail.current.phase == .ready else { return nil }
            return AnyView(MailHomeTile(model: mail.current, size: size) { bringUp(.mail) })
        case .messages:
            guard messages.phase == .ready else { return nil }
            return AnyView(MessagesHomeTile(model: messages, size: size) { bringUp(.messages) })
        case .photos:
            // Signing out shows nothing at once, before the library is closed. Only signing out: the
            // account's phase stays loading after a launch until the Account screen is opened, and the
            // library here already belongs to the device's owner. While the library opens, the tile says so.
            if case .signedOut = account?.phase { return nil }
            return AnyView(PhotosHomeTile(model: photos, size: size) { bringUp(.photos) })
        case .social:
            guard let social, case .signedIn = account?.phase else { return nil }
            return AnyView(SocialHomeTile(model: social, size: size) { bringUp(.social) })
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

    /// Hands a .gpx file to Hiking, which opens its import preview. Nothing is saved until the person saves.
    private func deliverGPX() {
        guard let url = pendingGPX else { return }
        guard isSignedIn else { return }
        prepareContent()
        guard let hiking else { return }
        pendingGPX = nil
        hiking.pendingImport = url
        bringUp(.hiking)
    }

    private func bringUp(_ module: ModuleID) {
        recentModule = module
        if showingSearch {
            pendingOpen = module
            showingSearch = false
        } else {
            open = module
        }
    }

    private func contentMessage(onClose: @escaping () -> Void) -> some View {
        let problem = contentProblem ?? .keyUnavailable
        return ModuleMessage(
            systemImage: problem == .signedOut ? "person.crop.circle" : "lock.slash", title: problem.title, detail: problem.detail,
            onSignIn: problem == .signedOut ? { showingAccount = true } : nil, onClose: onClose
        )
    }

    private func prepareContent(tellOwner: Bool = true) {
        guard reader == nil else { return }
        guard !contentKeys.isMoving else {
            contentProblem = .keyUnavailable
            return
        }
        do {
            let content = try ContentSetup.makeModels(
                mailRefresh: { @MainActor [mail] in await mail.current.refresh() },
                refresh: { [refreshers] module in await refreshers.refresh(module) }
            )
            reader = content.reader
            calendar = content.calendar
            web = content.web
            tasks = content.tasks
            weather = content.weather
            clock = content.clock
            refreshers[.weather] = content.weather.refresher
            contacts = content.contacts
            refreshers[.contacts] = content.contacts.refresher
            connectContacts(content.contacts, registry: content.registry)
            hiking = content.hiking
            news = content.news
            // A hike shared from Hiking opens Social's composer with it. Nothing posts until Post is pressed.
            content.hiking.onShare = { draft in shareToSocial(draft) }
            content.ai.bridge = AppAIToolBridge(
                calendar: content.calendar, mail: mail, tasks: content.tasks, reader: content.reader,
                weather: content.weather, messages: messages, contacts: content.contacts, hiking: content.hiking,
                music: content.music
            )
            ai = content.ai
            music = content.music
            sharedLists = makeSharedLists(directory: content.registry.profiles)
            content.reader.shared = makeSharedDocs(directory: content.registry.profiles)
            // Shared docs answer asks for a copy on the refresh beat, at launch, on coming back and in
            // the background, so someone who joined later isn't left waiting for the Reader to be opened.
            // Only while Messages is connected: this never signs in to it.
            AppRefresh.shared.extras["sharedDocs"] = { @MainActor [weak reader = content.reader, messages] in
                guard messages.phase == .ready else { return }
                await reader?.shared?.refresh()
            }
            refreshers[.reader] = content.reader.refresher
            refreshers[.tasks] = content.tasks.refresher
            refreshers[.calendar] = content.calendar.refresher
            refreshers[.web] = content.web.refresher
            refreshers[.messages] = messages.refresher
            #if os(iOS)
            // Instant Gmail sync: a push fetches and notifies, and the watches renew on the refresh beat.
            PushSetup.shared.onWake = { [mail] in
                await mail.current.refreshForPush(details: GmailPushSettings.shared.showsDetails)
            }
            PushSetup.shared.keepWatching = { [mail] in
                if let plan = PushSetup.plan() { await mail.current.keepGmailWatching(plan) }
            }
            AppRefresh.shared.extras["gmailPush"] = { await PushSetup.shared.renew() }
            PushSetup.shared.start()
            NotificationsSetup.connect(messages: messages, mail: mail)
            NotificationsSetup.connect(calendar: content.calendar)
            #endif
            // A pull also brings in the person's other devices. The app already syncs with them on
            // opening and on coming back, so the minute-by-minute refresh leaves it out.
            for refresher in [content.reader.refresher, content.calendar.refresher, content.web.refresher, content.tasks.refresher] {
                refresher.add("other devices", limit: .seconds(120), onlyWhenPulled: true) { [account] in
                    guard let sync = account?.sync else { return .done }
                    await sync.syncNow()
                    return sync.isAvailable && sync.status == .failed ? .failed(Refresher.syncLine) : .done
                }
            }
            web?.onSentToReader = { Task { await reader?.load() } }
            web?.onOpenInReader = { show($0) }
            mailWiring.connect(content.mail)
            photosWiring.connect(content.photos)
            mail.receiver = content.registry.receiver(for: .mail)
            mail.onSentToReader = { Task { await reader?.load() } }
            registry = content.registry
            messages.people.directory = content.registry.profiles
            messages.people.followers = makeFollowerDirectory()
            connectTasks(content.registry)
            AppRefresh.shared.registry = content.registry
            syncAreas = content.areas
            Task { await homeChoices.open(content.home) }
            refreshRecoveryLabels()
            contentProblem = nil
            if tellOwner { Task { await tellWhoIsHere() } }
        } catch is ContentSetup.SignedOut {
            contentProblem = .signedOut
        } catch KeyStoreError.keyMissing {
            contentProblem = .keyMissing
        } catch {
            contentProblem = .keyUnavailable
        }
    }

    /// The tiles show live content, so it opens with the home page. This has to come after the device
    /// is settled, and it follows the same rules as opening a module.
    private func openContentForHome(loadPhotos: Bool = true) async {
        if reader == nil { prepareContent(tellOwner: false) }
        guard reader != nil else { return }
        let needsReader = reader?.phase == .loading
        let needsCalendar = calendar?.phase == .loading
        let needsTasks = tasks?.phase == .loading
        let needsWeather = weather?.phase == .loading
        let needsClock = clock?.phase == .loading
        let needsContacts = contacts?.phase == .loading
        let needsHiking = hiking?.phase == .loading
        let needsAI = ai?.phase == .idle
        let needsMusic = music?.phase == .idle
        async let ownerReady: Void = tellWhoIsHere(loadPhotos: loadPhotos)
        async let readerLoad: Void = { @MainActor in if needsReader { await reader?.load() } }()
        async let calendarLoad: Void = { @MainActor in if needsCalendar { await calendar?.load() } }()
        async let tasksLoad: Void = { @MainActor in if needsTasks { await tasks?.load() } }()
        async let weatherLoad: Void = { @MainActor in if needsWeather { await weather?.load() } }()
        async let clockLoad: Void = { @MainActor in if needsClock { await clock?.load() } }()
        async let contactsLoad: Void = { @MainActor in if needsContacts { await contacts?.load() } }()
        async let hikingLoad: Void = { @MainActor in if needsHiking { await hiking?.load() } }()
        async let aiLoad: Void = { @MainActor in if needsAI { await ai?.load() } }()
        async let musicLoad: Void = { @MainActor in if needsMusic { await music?.load() } }()
        async let newsLoad: Void = self.news?.load() ?? ()
        _ = await (ownerReady, readerLoad, calendarLoad, tasksLoad, weatherLoad, clockLoad, contactsLoad, hikingLoad, aiLoad, musicLoad, newsLoad)
        await warmMailForHome(waitForCheck: false)
    }

    /// So the Mail tile has something to show before Mail is opened. A new mailbox model (another account,
    /// a new key) needs this too, so it isn't only done when content first opens.
    private func warmMailForHome(waitForCheck: Bool = true) async {
        guard reader != nil, !homeChoices.removed.contains(.mail) else { return }
        let mail = mail.current
        await mail.showStored()
        // The check behind it isn't waited for past what's saved, unless nothing is.
        if mail.phase == .ready || !waitForCheck { Task { await mail.warmForHome() } } else { await mail.warmForHome() }
    }

    /// Each module that keeps itself up to date fetches what's new, quietly.
    private func refreshAhead() async {
        await AppRefresh.shared.refresh()
        // A sync may have brought another device's choices.
        await homeChoices.reload()
    }

    /// Web keeps things only for the key's owner, and Mail shows only the owner's mailbox.
    private func tellWhoIsHere(loadPhotos: Bool = true) async {
        photosTurn += 1
        let turn = photosTurn
        let owner = await account?.backup?.deviceOwner()
        // Drive files open in memory only, and go whenever who's here changes, signing out included.
        let isSignedIn = if case .signedIn = account?.phase { true } else { false }
        await reader?.drive?.use(owner: isSignedIn ? owner : nil)
        let newVault = await mailWiring.use(account: owner)
        mail.use(account: owner, restart: newVault)
        // Photos go to the server as they're added, so only a device that can sync gets a library.
        let canSync = await account?.backup?.deviceCanSync() ?? false
        if turn == photosTurn, await photosWiring.use(account: canSync ? owner : nil), turn == photosTurn {
            let model = PhotosModel(library: photosWiring.library, unavailable: photosReason())
            model.sender = photosSender()
            model.taskMaker = registry?.taskMaker
            model.googleAccounts = ContentSetup.googleAccounts()
            photos = model
            if loadPhotos { await model.load() }
        } else if turn == photosTurn, photos.account != photosWiring.library?.account
                    || (photosWiring.library == nil && photos.phase != .unavailable(title: photosReason().title, detail: photosReason().detail)) {
            // The model on screen must always be the current library's, or none.
            let model = PhotosModel(library: photosWiring.library, unavailable: photosReason())
            model.sender = photosSender()
            model.taskMaker = registry?.taskMaker
            model.googleAccounts = ContentSetup.googleAccounts()
            photos = model
            if loadPhotos { await model.load() }
        }
        await web?.use(account: owner)
    }

    /// Shared lists travel in Matrix rooms, which run only where the Matrix SDK is linked.
    /// So the Social tile shows the newest posts without opening Social first. Not while it's off Home.
    /// Opens Social's composer with a post another module started (issue 240). The person checks it, picks
    /// who sees it and presses Post; nothing is sent before that.
    private func shareToSocial(_ draft: PostDraft) {
        if social == nil { social = makeSocial() }
        guard let social else {
            hiking?.notice = "Sign in to share to Social"
            return
        }
        social.draft = draft
        social.homeRequest = .compose
        bringUp(.social)
    }

    private func openSocialForHome() async {
        guard !homeChoices.removed.contains(.social), case .signedIn = account?.phase else { return }
        if social == nil { social = makeSocial() }
        await social?.load()
    }

    /// Who follows the signed-in person, for Messages' broadcast channels, which invite only followers.
    /// Messages never imports Social: it only sees Core's `FollowerDirectory`.
    private func makeFollowerDirectory() -> (any FollowerDirectory)? {
        guard let config = AccountSetup.config, let token = AccountSetup.searchToken, let username = AccountSetup.username else { return nil }
        let server = RestSocialServer(base: config.url, publishableKey: config.publishableKey, token: token, username: username)
        return SocialFollowerDirectory(server: server, username: username)
    }

    /// Social for whoever is signed in. Friends and Close-friends posts ride Messages' Matrix connection,
    /// in their own encrypted rooms, which only the iPhone build has.
    private func makeSocial() -> SocialModel? {
        guard let config = AccountSetup.config, let token = AccountSetup.searchToken, let username = AccountSetup.username else { return nil }
        let server = RestSocialServer(base: config.url, publishableKey: config.publishableKey, token: token, username: username)
        #if canImport(MatrixRustSDK)
        let rooms: (any SharedRooms)? = MatrixTaskRooms(messages: messages, marker: SharedRoomMarker.social)
        #else
        let rooms: (any SharedRooms)? = nil
        #endif
        let model = SocialModel(server: server, privateRooms: rooms, profiles: AccountSetup.profiles, remembered: .standard)
        model.taskMaker = registry?.taskMaker
        model.receiver = registry?.receiver(for: .social)
        model.contactMaker = registry?.contactMaker
        model.backgroundStore = account?.backgroundStore
        model.onMessage = { name in
            Task {
                guard let chat = await messages.startChat(with: name) else { return }
                messages.requestedChat = chat
                bringUp(.messages)
            }
        }
        model.onShare = { request in shareRequest = request }
        #if os(iOS)
        NotificationsSetup.connect(social: model)
        #endif
        return model
    }

    /// Closes every module's content, for a key change or an account leaving. Nothing is deleted.
    private func closeContent() async {
        #if os(iOS)
        NotificationsSetup.disconnect()
        #endif
        // Photos first, before any wait, so the home tile can't show the old key's photos meanwhile.
        photosTurn += 1
        photos = PhotosModel(library: nil)
        await account?.sync?.pause()
        await reader?.stopForKeyChange()
        await calendar?.stopForKeyChange()
        await web?.stopForKeyChange()
        await tasks?.stopForKeyChange()
        await weather?.stopForKeyChange()
        weather = nil
        clock = nil
        await contacts?.stopForKeyChange()
        contacts = nil
        messages.people.lookup = nil
        await news?.close()
        news = nil
        await hiking?.stopForKeyChange()
        hiking = nil
        await ai?.close()
        ai = nil
        await music?.close()
        music = nil
        reader = nil
        AppRefresh.shared.extras["sharedDocs"] = nil
        calendar = nil
        web = nil
        tasks = nil
        sharedLists = nil
        social = nil
        await mailWiring.disconnect()
        mail.keyChanged()
        photosTurn += 1
        await photosWiring.disconnect()
        photos = PhotosModel(library: nil)
        registry = nil
        homeChoices.close()
        messages.people.directory = nil
        messages.people.followers = nil
        messages.taskMaker = nil
        AppRefresh.shared.registry = nil
        syncAreas = []
        contentProblem = nil
    }

    /// Opens the signed-in account's own space, after anyone else's has closed. Each account on this
    /// device sees only its own notes, calendar, tasks and Home; signed out, the modules ask to sign in.
    private func followAccount(loadPhotos: Bool = true, loadContent: Bool = true) async {
        let now = await AccountSetup.accountID?()
        guard now != followedAccount || (now != nil && SignedInAccount.shared.id == nil) else { return }
        if reader != nil || registry != nil {
            await closeContent()
            account?.sync?.resume()
        }
        ContentSetup.follow(account: now)
        followedAccount = now
        homeChoices = HomeChoicesModel(defaults: ContentSetup.defaults())
        accountDefaults = ContentSetup.defaults()
        guard now != nil else { return }
        await account?.backup?.settleDevice()
        if reader == nil { prepareContent(tellOwner: false) }
        if loadContent { await openContentForHome(loadPhotos: loadPhotos) }
    }

    /// Signing out, or in as someone else, leaves nothing of the last account's behind: Social and shared
    /// lists are made again for whoever is next, and Messages stops the last account's connection. The
    /// content key and Messages' stores stay on the device, as the standing rules say.
    private func watchAccountChanges() {
        account?.onAccountLeft = { _ in
            social = nil
            if sharedLists != nil, let registry { sharedLists = makeSharedLists(directory: registry.profiles) }
            if reader?.shared != nil, let registry { reader?.shared = makeSharedDocs(directory: registry.profiles) }
            if open == .social { open = nil }
            Task {
                #if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
                await voiceCalls.watch(nil, chats: [])
                #endif
                await messages.checkAccount()
                // The last account's reminders stop ringing here. They come back when it signs in again.
                await SystemTaskReminders.shared.replace(with: [], places: [])
                await SystemReminders().replace(with: [])
                await followAccount()
                await tellWhoIsHere()
            }
        }
        // Always the Social of whoever is signed in now, never a model made for someone before them.
        account?.onOpenSocialProfile = {
            showingAccount = false
            if social == nil { social = makeSocial() }
            Task { social?.requestedProfile = await AccountSetup.username?() }
            bringUp(.social)
        }
    }

    private func makeSharedLists(directory: (any ProfileDirectory)?) -> SharedListsModel? {
        #if canImport(MatrixRustSDK)
        let model = SharedListsModel(rooms: MatrixTaskRooms(messages: messages))
        model.directory = directory
        return model
        #else
        return nil
        #endif
    }

    /// The Reader's shared docs (issue 228), in their own encrypted rooms over Messages' connection.
    private func makeSharedDocs(directory: (any ProfileDirectory)?) -> SharedDocsModel? {
        #if canImport(MatrixRustSDK)
        let model = SharedDocsModel(rooms: MatrixTaskRooms(messages: messages, marker: SharedRoomMarker.reader))
        model.directory = directory
        return model
        #else
        return nil
        #endif
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
        sync.onFinished = {
            refreshRecoveryLabels()
            Task { await homeChoices.reload() }
        }
        sync.onChanged = {
            await reader?.load()
            await calendar?.load()
            await web?.load()
            await tasks?.load()
            await weather?.reload()
            await clock?.reload()
            await contacts?.load()
            await ai?.load()
            // Marks from another device, so Mail is already up to date when it's opened.
            await mail.current.showStored()
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

    /// Step 4 of issue 123: every module can hand Tasks a task through the registry, Mail tells it about
    /// replies, and a task's link opens its source the way a search result does. Only the app sees every
    /// module, so the wiring lives here.
    private func connectTasks(_ registry: ModuleRegistry) {
        let maker = registry.taskMaker
        mail.taskMaker = maker
        messages.taskMaker = maker
        photos.taskMaker = maker
        reader?.taskMaker = maker
        web?.taskMaker = maker
        social?.taskMaker = maker
        social?.receiver = registry.receiver(for: .social)
        tasks?.replyWatchers = [MailReplyWatcher(model: mail)]
        // Tasks and the Calendar set alarms through the registry, never by importing the Clock (issue 204).
        tasks?.alarmMaker = registry.alarmMaker
        tasks?.onOpenSource = { source in show(source.hit) }
        tasks?.sourceGone = { source in
            switch source.module {
            case .mail: mail.current.hasConversation(source.itemID) == false
            case .photos: photos.hasItem(source.itemID) == false
            case .reader: reader?.hasItem(source.itemID) == false
            case .messages: !messages.chats.isEmpty && !messages.chats.contains { $0.id == source.itemID }
            default: false
            }
        }
        calendar?.onOpenLinked = { item in
            guard item.module == .tasks || item.module == .contacts, let module = item.module else { return }
            show(SearchHit(module: module, itemID: item.id, title: item.title))
        }
    }

    /// Messages draws and opens a post shared in a chat without importing Social: the app asks the owning module,
    /// by the ref's module, what the recipient may see.
    private func connectSharedContent() {
        messages.sharedContent = SharedContentHooks(
            resolve: { ref, author in
                guard ref.module == .social else { return .unavailable(author: author) }
                if social == nil { social = makeSocial() }
                guard let social else { return .failed }
                return await social.sharedCard(ref, author: author)
            },
            open: { ref in show(ref) },
            openAuthor: { name in
                if social == nil { social = makeSocial() }
                social?.requestedProfile = name
                bringUp(.social)
            }
        )
    }

    /// A ref opens in its own module: the Reader's items, and Contacts' cards.
    private func show(_ ref: ContentRef) {
        switch ref.module {
        case .news:
            guard let provider = registry?.handler(for: ref) as? any ArticleLinkProvider,
                  let currentNews = news else { return }
            Task {
                guard let url = await provider.articleURL(for: ref), news === currentNews, let web else { return }
                web.newTab(isPrivate: true)
                web.open(url)
                bringUp(.web)
            }
        case .social:
            if social == nil { social = makeSocial() }
            social?.requestedPost = ref.id
            bringUp(.social)
        case .reader:
            reader?.requestedItem = ref.id
            bringUp(.reader)
        case .contacts:
            contacts?.requestedCard = ref.id
            bringUp(.contacts)
        default:
            return
        }
    }

    /// Contacts hands people over to Messages, Mail and Social, and lends Mail and Messages its names, all
    /// through the registry or the app. Nothing is sent without the person's press in that module.
    private func connectContacts(_ model: ContactsModel, registry: ModuleRegistry) {
        messages.people.lookup = registry.people
        mail.current.people = registry.people
        model.onMessage = { name in
            Task {
                guard let chat = await messages.startChat(with: name) else { return }
                messages.requestedChat = chat
                bringUp(.messages)
            }
        }
        model.onMail = { addresses in
            mail.current.people = registry.people
            mail.current.requestedRecipients = addresses
            bringUp(.mail)
        }
        model.onProfile = { name in
            if social == nil { social = makeSocial() }
            social?.requestedProfile = name
            bringUp(.social)
        }
    }

    /// Every module the home search looks in. Each reads only what's already open on this device.
    private func homeSearchers(_ registry: ModuleRegistry) -> [any ModuleSearcher] {
        var searchers = registry.searchers + [MessagesSearcher(model: messages), MailSearcher(model: mail), PhotosSearcher(model: photos)]
        if let web { searchers.append(WebSearcher(model: web)) }
        // Linked Google Drive folders, in the Reader's group.
        if let drive = reader?.drive { searchers += drive.searchers }
        return searchers.onHome(removed: homeChoices.removed)
    }

    /// Only the module that found a result knows what its ID means, so it goes back there to open.
    private func show(_ hit: SearchHit) {
        // After bringUp, which waits for the sheet to go when it's still up.
        defer { showingSearch = false }
        switch hit.module {
        case .reader:
            if DriveSearcher.parse(hit.itemID) != nil {
                reader?.requestedDriveHit = hit.itemID
            } else {
                reader?.requestedItem = UUID(uuidString: hit.itemID)
            }
        case .calendar: calendar?.requestedHit = hit
        case .messages: messages.requestedChat = hit.itemID
        case .mail:
            guard let id = UUID(uuidString: hit.itemID) else { return }
            mail.current.requestFromSearch(id)
        case .photos: photos.requestedItem = UUID(uuidString: hit.itemID)
        case .tasks: tasks?.requestedTask = UUID(uuidString: hit.itemID)
        case .clock: clock?.requestedTab = hit.itemID.hasPrefix("city:") ? .world : .alarms
        case .weather: weather?.requestedPlace = UUID(uuidString: hit.itemID)
        case .contacts: contacts?.requestedCard = UUID(uuidString: hit.itemID)
        case .hiking: hiking?.requestedItem = hit.itemID
        case .player: music?.requestedItemID = hit.itemID
        case .news:
            guard let id = UUID(uuidString: hit.itemID) else { return }
            show(ContentRef(module: .news, kind: .newsArticle, id: id, keyRef: .plain, preview: .init(title: hit.title)))
            return
        case .social:
            if social == nil { social = makeSocial() }
            social?.requestedPost = UUID(uuidString: hit.itemID)
        case .web:
            guard let url = URL(string: hit.itemID) else { return }
            web?.open(url)
        default: return
        }
        bringUp(hit.module)
    }
}

private enum ContentProblem {
    case keyMissing, keyUnavailable, signedOut

    var title: String {
        switch self {
        case .keyMissing: "Your key isn't on this device"
        case .keyUnavailable: "This didn't open"
        case .signedOut: "Sign in to see yours"
        }
    }

    var detail: String {
        switch self {
        case .keyMissing:
            "Your items are here, still encrypted, but the key that opens them isn't. Totality has left them untouched and won't make a new key over them."
        case .keyUnavailable:
            "Totality couldn't reach this device's key, and it won't replace one it can't read. Go back and try again."
        case .signedOut:
            "Each account on this iPhone has its own notes, calendar and tasks. Sign in to open yours."
        }
    }
}

/// A module's full-screen message, with the way back home.
private struct ModuleMessage: View {
    let systemImage: String
    let title: String
    let detail: String
    var onSignIn: (() -> Void)?
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
            if let onSignIn {
                Button("Sign in", action: onSignIn)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.accent.color)
                    .padding(.top, Space.s3)
            }
            Button("Home", action: onClose)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .padding(.top, onSignIn == nil ? Space.s3 : 0)
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

/// The open module, as a cover's item.
private struct OpenModule: Identifiable {
    let id: ModuleID
}

private struct AskTotalityTarget: Identifiable {
    let id = UUID()
    let context: AIAskContext?
}

#if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
private struct VoiceWatchKey: Equatable {
    let service: ObjectIdentifier?
    let rooms: Set<String>
}
#endif
