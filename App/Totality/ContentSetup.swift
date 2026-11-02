import Foundation
import TotalityAccount
import TotalityCalendar
import TotalityCore
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

    private static func stores() throws -> (reader: FileBlobStore, calendar: FileBlobStore, web: FileBlobStore) {
        let base = try base()
        return (
            try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Calendar", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Web", isDirectory: true))
        )
    }

    static func keyRing() throws -> ContentKeyRing {
        let stores = try stores()
        return ContentKeyRing(keys: KeychainKeyStore(), areas: [
            SealedArea(store: stores.reader, purposes: ReaderVault.sealedPurposes),
            SealedArea(store: stores.calendar, purposes: CalendarVault.sealedPurposes),
            SealedArea(store: stores.web, purposes: WebVault.sealedPurposes),
        ])
    }

    static func syncStateFile() throws -> URL {
        let directory = try base().appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    /// The key step finishes any move that was interrupted, so this always opens with the right key.
    static func makeModels() throws -> (reader: ReaderModel, calendar: CalendarModel, web: WebModel, areas: [any SyncArea], registry: ModuleRegistry) {
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
            registry
        )
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
    }

    /// The old key goes, so any open module has to go with it.
    func resetEmptyDevice() async throws {
        await willMove()
        defer { didMove() }
        try ContentSetup.keyRing().resetEmptyDevice()
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
