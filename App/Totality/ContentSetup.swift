import Foundation
import TotalityAccount
import TotalityCalendar
import TotalityClock
import TotalityCore
import TotalityMail
import TotalityMessages
import TotalityPhotos
import TotalityReader
import TotalityTasks
import TotalityWeather
import TotalityWeb

/// Connects the modules that seal content to this device's key and storage. They share one key, so
/// they're set up together.
@MainActor
enum ContentSetup {
    /// Nobody is signed in, so there's no one's content to open.
    struct SignedOut: Error {}

    /// The folder every account's content sits under. Before content was per account, it sat right here.
    nonisolated static func sharedBase() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality", isDirectory: true)
    }

    nonisolated static func sharedCaches() throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality", isDirectory: true)
    }

    /// The signed-in account's own folder. Each account on a device sees only what's in its own.
    private static func base() throws -> URL {
        guard let account = SignedInAccount.shared.id else { throw SignedOut() }
        return AccountDataMigration.folder(for: account, in: try sharedBase())
    }

    /// The signed-in account's corner of one of the device's Keychain services.
    nonisolated static func keys(_ store: KeychainKeyStore) throws -> AccountKeyStore {
        guard let account = SignedInAccount.shared.id else { throw SignedOut() }
        return AccountKeyStore(store, account: account)
    }

    /// The signed-in account's own settings, such as Home's layout and hidden calendars. Signed out, an
    /// empty set of its own, so nothing of anyone's shows.
    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: defaultsName()) ?? .standard
    }

    nonisolated static func defaultsName() -> String {
        SignedInAccount.shared.id.map { "app.totality.account.\($0)" } ?? "app.totality.signed-out"
    }

    /// Moves an install from before content was per account to its owner, then opens `account`'s space.
    /// Runs before anything reads content, so an account's key is never made beside data still waiting
    /// to move. The owner is whoever the device's key was claimed for, never simply whoever is here.
    static func follow(account: String?) {
        let migration = AccountDataMigration(
            contentKeys: KeychainKeyStore(),
            otherKeys: [KeychainKeyStore(service: GoogleAccounts.service), KeychainKeyStore(service: OutsideSecrets.service)],
            folders: [try? sharedBase(), try? sharedCaches()].compactMap { $0 }
        )
        // A failure is left as it was, to try again next time. Its contents never reach the log.
        if let owner = try? migration.run(signedInAccount: account) { moveSettings(to: owner) }
        // Until the content key has moved, no one's space opens: a new key there could split the owner's
        // content. Anything else still waiting is retried later and never keeps anyone out.
        SignedInAccount.shared.id = (try? migration.blocksOpening()) == false ? account : nil
    }

    /// The settings that are an account's own, copied once to the owner's set. The device's copies stay.
    private static func moveSettings(to owner: String) {
        let mine = UserDefaults(suiteName: "app.totality.account.\(owner)")
        for key in ["home.layout", HomeChoicesModel.cacheKey, "calendar.hiddenDeviceCalendars", "tasks.splitToday"]
        where mine?.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) { mine?.set(value, forKey: key) }
        }
    }

    /// Forgets the signed-in account's outside sign-ins on this device, and nobody else's, along with any
    /// left under the names from before accounts had their own (an older build may have written some).
    nonisolated static func forgetSecrets() {
        guard let account = SignedInAccount.shared.id else { return }
        for service in [GoogleAccounts.service, OutsideSecrets.service] {
            let store = KeychainKeyStore(service: service)
            for name in AccountKeyStore.toForget(in: (try? store.names()) ?? [], account: account) { try? store.delete(name) }
        }
    }

    private static func stores() throws -> (
        reader: FileBlobStore, calendar: FileBlobStore, web: FileBlobStore, mail: FileBlobStore, photos: FileBlobStore,
        googleCalendar: FileBlobStore, googleDrive: FileBlobStore, tasks: FileBlobStore, home: FileBlobStore,
        weather: FileBlobStore, weatherCache: FileBlobStore, clock: FileBlobStore
    ) {
        let base = try base()
        return (
            try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Calendar", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Web", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Mail", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Photos", isDirectory: true)),
            // Apart from the Calendar's own, because this never syncs.
            try FileBlobStore(directory: base.appendingPathComponent("GoogleCalendar", isDirectory: true)),
            // The Reader's linked Drive folders. Never synced: each device reads Google itself.
            try FileBlobStore(directory: base.appendingPathComponent("GoogleDrive", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Tasks", isDirectory: true)),
            // Which modules are off Home, as one sealed record that syncs.
            try FileBlobStore(directory: base.appendingPathComponent("Home", isDirectory: true)),
            // Weather's saved places, as one sealed record that syncs.
            try FileBlobStore(directory: base.appendingPathComponent("Weather", isDirectory: true)),
            // The last forecast for each place. Apart from the places, because this never syncs.
            try FileBlobStore(directory: base.appendingPathComponent("WeatherCache", isDirectory: true)),
            // The Clock's synced record and its device-only one (issue 204).
            try FileBlobStore(directory: base.appendingPathComponent("Clock", isDirectory: true))
        )
    }

    /// This build's Google sign-in, shared by every module, or nil when it has no Google client.
    static func googleAccounts() -> GoogleAccounts? {
        guard let keychain = try? keys(KeychainKeyStore(service: GoogleAccounts.service)) else { return nil }
        return GoogleSignIn(clientID: Bundle.main.object(forInfoDictionaryKey: "TotalityGoogleClientID") as? String)
            .map { GoogleAccounts(signIn: $0, keychain: keychain) }
    }

    /// Opened Drive files, sealed. In Caches, so they stay out of backups and the system may clear them
    /// when space runs low: they come back from Google on the next open.
    private static func driveCache() throws -> FileBlobStore {
        guard let account = SignedInAccount.shared.id else { throw SignedOut() }
        return try FileBlobStore(directory: AccountDataMigration.folder(for: account, in: try sharedCaches())
            .appendingPathComponent("GoogleDrive", isDirectory: true))
    }

    static func keyRing() throws -> ContentKeyRing {
        let stores = try stores()
        return ContentKeyRing(keys: try keys(KeychainKeyStore()), areas: [
            SealedArea(files: stores.reader, purposes: ReaderVault.sealedPurposes, chunked: ReaderVault.chunkedPurposes),
            SealedArea(store: stores.calendar, purposes: CalendarVault.sealedPurposes),
            SealedArea(store: stores.web, purposes: WebVault.sealedPurposes),
            SealedArea(store: stores.mail, purposes: MailVault.sealedPurposes),
            SealedArea(files: stores.photos, purposes: PhotoLibrary.sealedPurposes, chunked: PhotoLibrary.chunkedPurposes),
            SealedArea(store: stores.googleCalendar, purposes: GoogleCalendars.sealedPurposes),
            SealedArea(store: stores.googleDrive, purposes: GoogleDrive.sealedPurposes),
            SealedArea(store: stores.tasks, purposes: TaskVault.sealedPurposes),
            SealedArea(store: stores.home, purposes: HomeChoicesBook.sealedPurposes),
            SealedArea(store: stores.weather, purposes: WeatherPlaceBook.sealedPurposes),
            SealedArea(store: stores.weatherCache, purposes: ForecastCache.sealedPurposes),
            SealedArea(store: stores.clock, purposes: ClockBook.sealedPurposes),
        ])
    }

    static func syncStateFile() throws -> URL {
        let directory = try base().appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    /// The key step finishes any move that was interrupted, so this always opens with the right key.
    /// `mailRefresh` brings the signed-in account's mailbox up to date, for Mail's registry entry, and
    /// `refresh` brings any other module up to date through its own `Refresher`.
    static func makeModels(
        mailRefresh: @escaping @Sendable () async -> Void, refresh: @escaping @Sendable (ModuleID) async -> Void
    ) throws -> (
        reader: ReaderModel, calendar: CalendarModel, web: WebModel, tasks: TasksModel, areas: [any SyncArea],
        registry: ModuleRegistry, mail: MailContent, photos: PhotosContent, home: HomeChoicesBook, weather: WeatherModel, clock: ClockModel
    ) {
        let stores = try stores()
        let rootKey = try keyRing().current()

        let readerVault = ReaderVault(store: stores.reader, rootKey: rootKey)
        let calendarVault = CalendarVault(store: stores.calendar, rootKey: rootKey)
        let webVault = WebVault(store: stores.web, rootKey: rootKey)
        let taskVault = TaskVault(store: stores.tasks, rootKey: rootKey)
        let devices = SystemCalendarSource()
        let google = GoogleCalendars(accounts: googleAccounts(), store: stores.googleCalendar, rootKey: rootKey)
        let home = HomeChoicesBook(store: stores.home, rootKey: rootKey)
        let reader = ReaderModel(vault: readerVault, listen: ListenController(engine: ListenVoices()))
        // Read when an import asks, since sign-in may come after the Reader opens.
        reader.storageLeft = {
            guard let usage = await MainActor.run(body: { AccountSetup.storageUsage }) else { return nil }
            return try? await usage().left
        }
        // Beside the Reader's items, under its own key purpose, and sealed the same way.
        let places = ReadingPlaceBook(store: stores.reader, rootKey: rootKey)
        reader.places = places
        let drive = GoogleDrive(
            accounts: googleAccounts(), store: stores.googleDrive,
            cache: try driveCache(), rootKey: rootKey
        )
        if drive.isAvailable {
            let model = DriveModel(drive: drive, vault: readerVault)
            model.attach(to: reader.refresher)
            reader.drive = model
        }
        let tasks = TasksModel(vault: taskVault)
        let weatherBook = WeatherPlaceBook(store: stores.weather, rootKey: rootKey)
        let weatherCache = ForecastCache(store: stores.weatherCache, rootKey: rootKey)
        let weather = makeWeather(book: weatherBook, cache: weatherCache)
        let clockBook = ClockBook(store: stores.clock, rootKey: rootKey)
        let clock = ClockModel(book: clockBook)
        let registry = try ModuleRegistry(handlers: [
            ReaderModule(vault: readerVault, refresh: { await refresh(.reader) }),
            CalendarModule(
                vault: calendarVault, devices: devices, google: google, hidden: { [suite = defaultsName()] in CalendarModel.hiddenCalendars(in: UserDefaults(suiteName: suite) ?? .standard) },
                refresh: { await refresh(.calendar) }
            ),
            WebModule(refresh: { await refresh(.web) }),
            MailModule(refresh: mailRefresh),
            PhotosModule(refresh: { await refresh(.photos) }),
            MessagesRefresher(refresh: { await refresh(.messages) }),
            // A task made or planned from another module is read in at once (step 4).
            TasksModule(vault: taskVault, refresh: { await refresh(.tasks) }, changed: { @MainActor [weak tasks] in await tasks?.load() }),
            WeatherModule(
                book: weatherBook, cache: weatherCache,
                units: { [suite = defaultsName()] in WeatherUnits.stored(in: UserDefaults(suiteName: suite) ?? .standard) },
                refresh: { await refresh(.weather) }
            ),
            // Alarms other modules ask for go through the Clock's model, so its screens show them at once.
            ClockModule(book: clockBook) { @MainActor [weak clock] draft in
                guard let clock else { throw AlarmSchedulingError.failed }
                return try await clock.make(draft)
            },
        ], profiles: AccountSetup.profiles)
        // Reminders ring from this iPhone alone: local notifications and places iOS watches.
        tasks.reminderCenter = HomeGatedTaskReminders(SystemTaskReminders.shared)
        tasks.actionQueue = .shared
        SystemTaskReminders.shared.onAction = { [weak tasks] _ in await tasks?.applyQueuedActions() }
        // Upcoming's events come through the registry, so Tasks never reaches into the Calendar.
        // Tasks is on the calendar too now, so it leaves itself out.
        tasks.agenda = { [registry] start, end in await registry.agenda(from: start, to: end, except: .tasks) }
        return (
            reader,
            CalendarModel(
                vault: calendarVault,
                devices: devices, reminders: HomeGatedReminders(SystemReminders()),
                registry: registry, google: google, defaults: defaults()
            ),
            WebModel(
                client: AccountSetup.searchToken.map { WebSearchClient(token: $0) }, vault: webVault, blocker: WebBlocker(),
                downloads: try base().appendingPathComponent("Downloads", isDirectory: true),
                receiver: registry.receiver(for: .web)
            ),
            tasks,
            // The Drive record syncs whether or not this build can sign in to Google, so links made on
            // another device aren't lost here.
            [readerVault, calendarVault, webVault, drive, places, taskVault, home, weatherBook, clockBook],
            registry,
            MailContent(rootKey: rootKey, store: stores.mail),
            PhotosContent(rootKey: rootKey, store: stores.photos),
            home,
            weather,
            clock
        )
    }

    /// Weather, with Apple Weather as its source when this build has the WeatherKit entitlement
    /// (`TotalityWeatherKit` in Info.plist), and Open-Meteo otherwise. Both are free (issue 203).
    private static func makeWeather(book: WeatherPlaceBook, cache: ForecastCache) -> WeatherModel {
        let source: any ForecastSource
        #if canImport(WeatherKit)
        if (Bundle.main.object(forInfoDictionaryKey: "TotalityWeatherKit") as? Bool) == true {
            source = WeatherKitSource()
        } else {
            source = OpenMeteoSource()
        }
        #else
        source = OpenMeteoSource()
        #endif
        #if os(iOS)
        let location: (any WeatherLocating)? = SystemWeatherLocation()
        let notices: (any WeatherAlertNotifying)? = SystemWeatherAlertNotices()
        #else
        let location: (any WeatherLocating)? = nil
        let notices: (any WeatherAlertNotifying)? = nil
        #endif
        return WeatherModel(
            book: book, cache: cache,
            service: WeatherService(source: source, air: AirQualitySource(), alerts: NWSAlerts()),
            searcher: OpenMeteoPlaces(), location: location, notices: notices, defaults: defaults()
        )
    }
}

/// Who is signed in, for the folders and Keychain names content is kept under. Read from any thread.
final class SignedInAccount: @unchecked Sendable {
    static let shared = SignedInAccount()
    private let lock = NSLock()
    private var value: String?

    var id: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What a Photos library is made from. Like Mail's, a library belongs to one account, so it's made once
/// the device's owner is known.
struct PhotosContent {
    let rootKey: ContentRootKey
    let store: FileBlobStore
}

/// Makes the Photos library for whoever owns this device's key. A change of account or key closes the
/// old one, so nothing of the last person's photos can be read or added through it.
@MainActor
final class PhotosWiring {
    private(set) var library: PhotoLibrary?
    private var content: PhotosContent?

    func connect(_ content: PhotosContent) {
        self.content = content
    }

    /// Forgets the library before waiting for it to close, so nothing can pick it up meanwhile.
    func disconnect() async {
        let old = library
        library = nil
        content = nil
        await old?.close()
    }

    /// Opens the library for this account. True when it's a different library from before.
    /// The new library is in place before anything waits, so two calls that overlap can't leave a stale one.
    func use(account: String?) async -> Bool {
        let old = library
        if let account, let content, let makeRows = AccountSetup.photoRows {
            guard old?.account != account else { return false }
            let rows = makeRows(account)
            library = PhotoLibrary(
                account: account, rootKey: content.rootKey, cache: content.store, rows: rows,
                store: SealedStoreClient(token: { try await rows.accessToken() })
            )
        } else {
            guard old != nil else { return false }
            library = nil
        }
        await old?.close()
        return true
    }
}

/// What Mail's vault is made from. Mail's vault belongs to one account, which is only known once the
/// device's owner is, so it's made later than the other modules'.
struct MailContent {
    let rootKey: ContentRootKey
    let store: FileBlobStore
}

/// Makes Mail's store for whoever owns this device's key. One vault per account and key: a change of
/// either closes the old one, so nothing of the last person's mail can be read or saved through it.
@MainActor
final class MailWiring {
    private(set) var vault: MailVault?
    private var content: MailContent?
    /// Whether this device may publish this account's mailbox key. Set from the account, if there is one.
    /// It names the account, so a sign-in that changes mid-open can't publish one person's key for another.
    var canPublish: @Sendable (String) async -> Bool = { _ in false }

    /// The content key is open.
    func connect(_ content: MailContent) {
        self.content = content
    }

    /// The content key is about to move, or has gone.
    func disconnect() async {
        await vault?.close()
        vault = nil
        content = nil
    }

    /// Opens the vault for this account. True when it's a different vault from before, so Mail has to
    /// start over on it.
    func use(account: String?) async -> Bool {
        guard let account, let content else {
            guard let old = vault else { return false }
            await old.close()
            vault = nil
            return true
        }
        guard vault?.account != account else { return false }
        await vault?.close()
        vault = MailVault(store: content.store, rootKey: content.rootKey, account: account, secrets: AccountKeyStore(OutsideSecrets.keychain(), account: account))
        return true
    }

    func makeStore(account: String?) -> any MailStore {
        guard let account else { return UnavailableMailStore(.noAccount) }
        guard let vault, vault.account == account, let content else { return UnavailableMailStore(.noKey) }
        guard let token = AccountSetup.searchToken, let username = AccountSetup.username else {
            return UnavailableMailStore(.noAccount)
        }
        do {
            return try ServerMailStore(
                account: account, rootKey: content.rootKey, vault: vault, server: MailServerClient(token: token),
                canPublish: { [canPublish] in await canPublish(account) }, username: username,
                google: GoogleOAuth(
                    clientID: Bundle.main.object(forInfoDictionaryKey: "TotalityGoogleClientID") as? String,
                    connections: AccountKeyStore(KeychainKeyStore(service: GoogleAccounts.service), account: account)
                )
            )
        } catch {
            return UnavailableMailStore(.noKey)
        }
    }
}

/// The content key as the account screens reach it. Moving keys rewrites every sealed blob, so the
/// open modules are stopped first and rebuilt afterwards.
@MainActor
final class DeviceContentKeys: ContentKeyAccess {
    var willMove: () async -> Void = {}
    var didMove: () -> Void = {}
    /// True while blobs are being rewritten, so nothing opens them halfway through.
    private(set) var isMoving = false

    /// The signed-in account's own key ring. Someone may have signed in or out since the app last
    /// looked, and the account screens must never act on the last person's key.
    private func ring() async throws -> ContentKeyRing {
        let now = await AccountSetup.accountID?()
        if now != SignedInAccount.shared.id { ContentSetup.follow(account: now) }
        return try ContentSetup.keyRing()
    }

    func rootKey() async throws -> ContentRootKey {
        let keyRing = try await ring()
        return try await Task.detached { try keyRing.current() }.value
    }

    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport {
        isMoving = true
        defer {
            isMoving = false
            didMove()
        }
        await willMove()
        let keyRing = try await ring()
        return try await Task.detached { try keyRing.adopt(key) }.value
    }

    func keyOwner() async throws -> String? {
        try await ring().owner()
    }

    func claim(for account: String) async throws {
        try await ring().claim(for: account)
    }

    func settleExistingInstall(signedInAccount: String?) async throws {
        try await ring().settleExistingInstall(signedInAccount: signedInAccount)
    }

    func hasSealedContent() async throws -> Bool {
        try await ring().hasSealedContent()
    }

    func reassign(to account: String, provenBy key: ContentRootKey) async throws {
        try await ring().reassign(to: account, provenBy: key)
    }

    func release(by account: String) async throws {
        try await ring().release(by: account)
        ContentSetup.forgetSecrets()
    }

    /// The old key goes, so any open module has to go with it.
    func resetEmptyDevice() async throws {
        await willMove()
        defer { didMove() }
        try await ring().resetEmptyDevice()
        ContentSetup.forgetSecrets()
        // What the last account agreed with its server means nothing to the next one.
        try? FileManager.default.removeItem(at: ContentSetup.syncStateFile())
    }

    func joinedBackup() async throws -> String? {
        try await ring().joinedBackup()
    }

    func markJoined(_ fingerprint: String) async throws {
        try await ring().markJoined(fingerprint)
    }
}

/// Which `Refresher` keeps each module fresh, so the registry's entries can reach a model made after
/// them, or replaced, like Photos' when the account changes.
@MainActor
final class ModuleRefreshers {
    private var refreshers: [ModuleID: Refresher] = [:]

    subscript(module: ModuleID) -> Refresher? {
        get { refreshers[module] }
        set { refreshers[module] = newValue }
    }

    /// An automatic refresh, which shows nothing unless a problem lasts.
    func refresh(_ module: ModuleID) async {
        await refreshers[module]?.refresh(.automatic)
    }
}

/// Tasks' reminders, held back while Tasks is off Home, like Calendar's.
struct HomeGatedTaskReminders: TaskReminderScheduling {
    private let inner: any TaskReminderScheduling

    init(_ inner: any TaskReminderScheduling) {
        self.inner = inner
    }

    func replace(with notifications: [PlannedTaskNotification], places: [PlannedPlace]) async {
        let removed = await MainActor.run { AppRefresh.shared.removed.contains(.tasks) }
        await inner.replace(with: removed ? [] : notifications, places: removed ? [] : places)
    }

    func access() async -> ReminderAccess { await inner.access() }
    func requestNotifications() async -> Bool { await inner.requestNotifications() }
    func requestAlwaysLocation() async { await inner.requestAlwaysLocation() }
}

/// Calendar's reminders, held back while Calendar is off Home. Removing Calendar clears what's waiting, and
/// adding it back lets the next refresh plan them again.
struct HomeGatedReminders: ReminderScheduler {
    private let inner: any ReminderScheduler

    init(_ inner: any ReminderScheduler) {
        self.inner = inner
    }

    func requestPermission() async -> Bool {
        await inner.requestPermission()
    }

    func replace(with reminders: [PlannedReminder]) async {
        let removed = await MainActor.run { AppRefresh.shared.removed.contains(.calendar) }
        await inner.replace(with: removed ? [] : reminders)
    }
}
