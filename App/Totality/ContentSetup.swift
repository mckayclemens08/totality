import Foundation
import TotalityAccount
import TotalityCalendar
import TotalityCore
import TotalityReader

/// Connects the modules that seal content to this device's key and storage. They share one key, so
/// they're set up together.
@MainActor
enum ContentSetup {
    private static func stores() throws -> (reader: FileBlobStore, calendar: FileBlobStore) {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality", isDirectory: true)
        return (
            try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true)),
            try FileBlobStore(directory: base.appendingPathComponent("Calendar", isDirectory: true))
        )
    }

    static func keyRing() throws -> ContentKeyRing {
        let stores = try stores()
        return ContentKeyRing(keys: KeychainKeyStore(), areas: [
            SealedArea(store: stores.reader, purposes: ReaderVault.sealedPurposes),
            SealedArea(store: stores.calendar, purposes: CalendarVault.sealedPurposes),
        ])
    }

    /// The key step finishes any move that was interrupted, so this always opens with the right key.
    static func makeModels() throws -> (reader: ReaderModel, calendar: CalendarModel) {
        let stores = try stores()
        let rootKey = try keyRing().current()

        let readerVault = ReaderVault(store: stores.reader, rootKey: rootKey)
        let registry = try ModuleRegistry(handlers: [ReaderModule(vault: readerVault), CalendarModule()])
        #if os(iOS)
        let startingMode = CalendarModel.Mode.agenda
        #else
        let startingMode = CalendarModel.Mode.month
        #endif
        return (
            ReaderModel(vault: readerVault, listen: ListenController(engine: SystemSpeechEngine())),
            CalendarModel(
                vault: CalendarVault(store: stores.calendar, rootKey: rootKey),
                devices: SystemCalendarSource(), reminders: SystemReminders(),
                registry: registry, startingMode: startingMode
            )
        )
    }
}

/// The content key as the account screens reach it. Moving keys rewrites every sealed blob, so the
/// open modules are stopped first and rebuilt afterwards.
@MainActor
final class DeviceContentKeys: ContentKeyAccess {
    var willMove: () async -> Void = {}

    func rootKey() async throws -> ContentRootKey {
        let ring = try ContentSetup.keyRing()
        return try await Task.detached { try ring.current() }.value
    }

    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport {
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

    func joinedBackup() async throws -> String? {
        try ContentSetup.keyRing().joinedBackup()
    }

    func markJoined(_ fingerprint: String) async throws {
        try ContentSetup.keyRing().markJoined(fingerprint)
    }
}
