import Foundation
import TotalityAccount
import TotalityCalendar
import TotalityCore
import TotalityMail
import TotalityPhotos
import TotalityReader
import TotalityWeb

/// Connects the modules that seal content to this device's key and storage. They share one key, so
/// they're set up together.
@MainActor
enum ContentSetup {
    private static func base() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality", isDirectory: true)
    }

    private static func stores() throws -> (
        reader: FileBlobStore, calendar: FileBlobStore, web: FileBlobStore, mail: FileBlobStore, photos: FileBlobStore
    ) {
        let base = try base()
        return (
            try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Calendar", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Web", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Mail", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Photos", isDirectory: true))
        )
    }

    static func keyRing() throws -> ContentKeyRing {
        let stores = try stores()
        return ContentKeyRing(keys: KeychainKeyStore(), areas: [
            SealedArea(store: stores.reader, purposes: ReaderVault.sealedPurposes),
            SealedArea(store: stores.calendar, purposes: CalendarVault.sealedPurposes),
            SealedArea(store: stores.web, purposes: WebVault.sealedPurposes),
            SealedArea(store: stores.mail, purposes: MailVault.sealedPurposes),
            SealedArea(files: stores.photos, purposes: PhotoLibrary.sealedPurposes, chunked: PhotoLibrary.chunkedPurposes),
        ])
    }

    static func syncStateFile() throws -> URL {
        let directory = try base().appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    /// The key step finishes any move that was interrupted, so this always opens with the right key.
    static func makeModels() throws -> (
        reader: ReaderModel, calendar: CalendarModel, web: WebModel, areas: [any SyncArea], registry: ModuleRegistry,
        mail: MailContent, photos: PhotosContent
    ) {
        let stores = try stores()
        let rootKey = try keyRing().current()

        let readerVault = ReaderVault(store: stores.reader, rootKey: rootKey)
        let calendarVault = CalendarVault(store: stores.calendar, rootKey: rootKey)
        let webVault = WebVault(store: stores.web, rootKey: rootKey)
        let devices = SystemCalendarSource()
        let registry = try ModuleRegistry(handlers: [
            ReaderModule(vault: readerVault),
            CalendarModule(vault: calendarVault, devices: devices, hidden: { CalendarModel.hiddenCalendars(in: .standard) }),
            WebModule(),
            MailModule(),
            PhotosModule(),
        ])
        return (
            ReaderModel(vault: readerVault, listen: ListenController(engine: ListenVoices())),
            CalendarModel(
                vault: calendarVault,
                devices: devices, reminders: SystemReminders(),
                registry: registry
            ),
            WebModel(
                client: AccountSetup.searchToken.map { WebSearchClient(token: $0) }, vault: webVault, blocker: WebBlocker(),
                downloads: try base().appendingPathComponent("Downloads", isDirectory: true),
                receiver: registry.receiver(for: .web)
            ),
            [readerVault, calendarVault, webVault],
            registry,
            MailContent(rootKey: rootKey, store: stores.mail),
            PhotosContent(rootKey: rootKey, store: stores.photos)
        )
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
        vault = MailVault(store: content.store, rootKey: content.rootKey, account: account, secrets: OutsideSecrets.keychain())
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
                    connections: KeychainKeyStore(service: GoogleAccounts.service)
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

    func rootKey() async throws -> ContentRootKey {
        let ring = try ContentSetup.keyRing()
        return try await Task.detached { try ring.current() }.value
    }

    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport {
        isMoving = true
        defer {
            isMoving = false
            didMove()
        }
        await willMove()
        let ring = try ContentSetup.keyRing()
        return try await Task.detached { try ring.adopt(key) }.value
    }

    func keyOwner() async throws -> String? {
        try ContentSetup.keyRing().owner()
    }

    func claim(for account: String) async throws {
        try ContentSetup.keyRing().claim(for: account)
    }

    func settleExistingInstall(signedInAccount: String?) async throws {
        try ContentSetup.keyRing().settleExistingInstall(signedInAccount: signedInAccount)
    }

    func hasSealedContent() async throws -> Bool {
        try ContentSetup.keyRing().hasSealedContent()
    }

    func reassign(to account: String, provenBy key: ContentRootKey) async throws {
        try ContentSetup.keyRing().reassign(to: account, provenBy: key)
    }

    func release(by account: String) async throws {
        try ContentSetup.keyRing().release(by: account)
        OutsideSecrets.forgetAll()
        GoogleAccounts.forgetAll()
    }

    /// The old key goes, so any open module has to go with it.
    func resetEmptyDevice() async throws {
        await willMove()
        defer { didMove() }
        try ContentSetup.keyRing().resetEmptyDevice()
        OutsideSecrets.forgetAll()
        GoogleAccounts.forgetAll()
        // What the last account agreed with its server means nothing to the next one.
        try? FileManager.default.removeItem(at: ContentSetup.syncStateFile())
    }

    func joinedBackup() async throws -> String? {
        try ContentSetup.keyRing().joinedBackup()
    }

    func markJoined(_ fingerprint: String) async throws {
        try ContentSetup.keyRing().markJoined(fingerprint)
    }
}
