import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

final class MailMemoryStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
}

/// The sync server, as rows of ciphertext it can't read.
actor MailMemoryRemote: SyncRemote {
    private var rows: [UUID: SealedObject] = [:]
    private var tombstones: [UUID: ContentKind] = [:]

    nonisolated func forCurrentAccount() async throws -> any SyncRemote { self }

    func list() async throws -> [RemoteRecord] {
        rows.values.map { RemoteRecord(id: $0.id, kind: $0.kind, hash: $0.hash, byteCount: $0.meta.count) }
            + tombstones.map { RemoteRecord(id: $0.key, kind: $0.value, hash: nil, byteCount: 0) }
    }

    func fetch(_ id: UUID, reusing local: SealedObject?) async throws -> SealedObject? { rows[id] }

    func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws {
        guard rows[object.id]?.hash == expected else { throw SyncError.changedOnServer }
        rows[object.id] = object
        tombstones[object.id] = nil
    }

    func delete(_ id: UUID, expected: String) async throws {
        guard let row = rows[id], row.hash == expected else { throw SyncError.changedOnServer }
        rows[id] = nil
        tombstones[id] = row.kind
    }

    func all() -> [SealedObject] { Array(rows.values) }
}

final class MailMemoryKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { secrets[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}

final class MailMemorySyncState: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [UUID: String] = [:]
    func load() throws -> [UUID: String] { lock.withLock { state } }
    func save(_ state: [UUID: String]) throws { lock.withLock { self.state = state } }
}

@Suite struct MailVaultTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"
    private let bruno = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private let invoice = UUID(uuidString: "6f1c2a7e-93d4-4b8e-a1f0-2c5d8e9b7a31")!
    private let ferry = UUID(uuidString: "0b9e4d12-5a6f-4c3b-8e7d-1f2a3b4c5d6e")!
    private let received = Date(timeIntervalSince1970: 1_793_783_564)

    private var invoiceMessage: MailStoredMessage {
        let raw = """
        {"version":1,"received":"2026-11-04T09:12:44.512Z","spam":{"score":1.2,"action":"no action"}}
        From: Harbour Ferries <tickets@harbourferries.example>
        To: alice@usetotality.com
        Subject: Your crossing to Brownsea Island on Saturday
        Date: Wed, 04 Nov 2026 09:12:40 +0000

        Two adults on the 10:15 sailing from Poole Quay. Show this at the gangway.
        """
        return MailStoredMessage(id: invoice, received: received, raw: Data(raw.utf8))
    }

    @Test func aMessageComesBack() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        try await vault.keep(invoiceMessage)
        try await vault.keep(MailStoredMessage(id: ferry, received: received, raw: nil))
        #expect(try await vault.message(invoice) == invoiceMessage)
        #expect(try await vault.hasMessage(ferry))
        #expect(Set(try await vault.messages().map(\.id)) == [invoice, ferry])
        try await vault.erase([invoice])
        #expect(try await vault.message(invoice) == nil)
        #expect(try await vault.messages().map(\.id) == [ferry])
    }

    @Test("Nothing readable reaches the disk: not the subject, the sender, a folder name, or a blocked address")
    func nothingReadableOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = MailVault(store: try FileBlobStore(directory: folder), rootKey: try .generate(), account: alice)
        try await vault.keep(invoiceMessage)
        try await vault.save([invoice: MailMarks(folder: .archive, isUnread: false, isStarred: true)])
        try await vault.save(MailSettings(
            folders: [MailOwnFolder(name: "Brownsea trip")],
            blockedSenders: ["offers@cheapflights.example"],
            alwaysLoadImages: ["tickets@harbourferries.example"]
        ))

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 3)
        let secrets = ["Brownsea", "harbourferries", "Poole", "cheapflights", "alice@", "crossing", "archive", alice, invoice.uuidString.lowercased()]
        for file in files {
            let bytes = try Data(contentsOf: folder.appendingPathComponent(file))
            for secret in secrets {
                #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is readable in \(file)")
                #expect(!file.contains(secret))
            }
        }
    }

    @Test("Another key opens nothing")
    func anotherKey() async throws {
        let store = MailMemoryStore()
        let mine = MailVault(store: store, rootKey: try .generate(), account: alice)
        try await mine.keep(invoiceMessage)
        try await mine.save([invoice: MailMarks(isStarred: true)])
        try await mine.save(MailSettings(blockedSenders: ["offers@cheapflights.example"]))

        let other = MailVault(store: store, rootKey: try .generate(), account: alice)
        await #expect(throws: CryptoError.self) { try await other.message(invoice) }
        #expect(try await other.messages().isEmpty)
        #expect(try await other.marks().isEmpty)
        await #expect(throws: CryptoError.self) { try await other.settings() }
        #expect(try await other.sealedObjectIDs().count == 1, "Only the settings, whose ID is known without opening")
    }

    @Test("Two accounts on one device never see each other's mail, marks, or settings")
    func twoUsersStayApart() async throws {
        let store = MailMemoryStore()
        let key = try ContentRootKey.generate()
        let first = MailVault(store: store, rootKey: key, account: alice)
        let second = MailVault(store: store, rootKey: key, account: bruno)
        try await first.keep(invoiceMessage)
        try await first.save([invoice: MailMarks(folder: .archive)])
        try await first.save(MailSettings(folders: [MailOwnFolder(name: "Brownsea trip")]))

        #expect(try await second.message(invoice) == nil)
        #expect(try await second.messages().isEmpty)
        #expect(try await second.marks().isEmpty)
        #expect(try await second.settings() == nil)
        #expect(try await second.sealedObjectIDs().isEmpty)

        // Even moved under the other account's name, one account's file won't open as the other's.
        let moved = try #require(try await first.sealedObject(MailVault.settingsID(account: alice)))
        let planted = SealedObject(id: MailVault.settingsID(account: bruno), kind: .mailSettings, meta: moved.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await second.store(planted, ifLocalHash: nil) }
    }

    @Test("Sync sees marks, settings, and drafts, never messages")
    func onlyMarksAndSettingsSync() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        #expect(vault.kinds == [.mailMarks, .mailSettings, .mailDraft])
        try await vault.keep(invoiceMessage)
        #expect(try await vault.sealedObjectIDs().isEmpty)
        try await vault.save([invoice: MailMarks(isStarred: true)])
        try await vault.save(MailSettings())
        let ids = try await vault.sealedObjectIDs()
        #expect(Set(ids) == [MailVault.marksID(invoice, account: alice), MailVault.settingsID(account: alice)])
        #expect(!ids.contains(invoice), "The sync server never sees the mail server's ID")
        for id in ids {
            let object = try #require(try await vault.verifiedObject(id))
            #expect(object.body == nil)
        }
    }

    @Test("Marks and settings round-trip between two devices with the same key")
    func roundTrip() async throws {
        let key = try ContentRootKey.generate()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let starred = MailMarks(folder: .own(UUID()), isUnread: false, isStarred: true)
        let settings = MailSettings(folders: [MailOwnFolder(name: "Brownsea trip")], blockedSenders: ["offers@cheapflights.example"])
        try await phone.save([invoice: starred])
        try await phone.save(settings)
        for id in try await phone.sealedObjectIDs() {
            try await mac.store(try #require(try await phone.sealedObject(id)), ifLocalHash: nil)
        }
        #expect(try await mac.marks() == [invoice: starred])
        #expect(try await mac.settings() == settings)
    }

    @Test("What sync brings must open under this key")
    func refusesAForeignKey() async throws {
        let mine = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        let theirs = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        try await theirs.save([invoice: MailMarks(folder: .spam)])
        try await theirs.save(MailSettings(blockedSenders: ["tickets@harbourferries.example"]))
        for id in try await theirs.sealedObjectIDs() {
            let object = try #require(try await theirs.sealedObject(id))
            await #expect(throws: CryptoError.self) { try await mine.store(object, ifLocalHash: nil) }
        }
        #expect(try await mine.marks().isEmpty)
        #expect(try await mine.settings() == nil)
    }

    @Test("One message's marks can't be passed off as another's")
    func marksStayWithTheirMessage() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        try await vault.save([invoice: MailMarks(folder: .trash, trashedAt: received, trashedFrom: .inbox)])
        let real = try #require(try await vault.sealedObject(MailVault.marksID(invoice, account: alice)))
        let moved = SealedObject(id: MailVault.marksID(ferry, account: alice), kind: .mailMarks, meta: real.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await vault.store(moved, ifLocalHash: nil) }
        let relabelled = SealedObject(id: real.id, kind: .mailSettings, meta: real.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await vault.store(relabelled, ifLocalHash: real.hash) }
    }

    @Test("Two devices changing different messages through real sync both keep their change")
    func twoDevicesDifferentMessages() async throws {
        let key = try ContentRootKey.generate()
        let remote = MailMemoryRemote()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let phoneSync = SyncEngine(areas: [phone], remote: remote, state: MailMemorySyncState())
        let macSync = SyncEngine(areas: [mac], remote: remote, state: MailMemorySyncState())

        try await phone.save([invoice: MailMarks(folder: .archive)])
        try await mac.save([ferry: MailMarks(isStarred: true)])
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        let both: [UUID: MailMarks] = [invoice: MailMarks(folder: .archive), ferry: MailMarks(isStarred: true)]
        #expect(try await phone.marks() == both)
        #expect(try await mac.marks() == both)
        #expect(await remote.all().count == 2)
    }

    @Test("When both change one message, the newer marks win")
    func newerWins() async throws {
        let key = try ContentRootKey.generate()
        let remote = MailMemoryRemote()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let phoneSync = SyncEngine(areas: [phone], remote: remote, state: MailMemorySyncState())
        let macSync = SyncEngine(areas: [mac], remote: remote, state: MailMemorySyncState())

        try await phone.save([invoice: MailMarks(isUnread: true)], at: received)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        try await phone.save([invoice: MailMarks(folder: .archive)], at: received.addingTimeInterval(60))
        try await mac.save([invoice: MailMarks(isStarred: true)], at: received.addingTimeInterval(120))
        _ = try await phoneSync.sync()
        let report = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(report.conflicts == 1)
        #expect(try await phone.marks() == [invoice: MailMarks(isStarred: true)])
        #expect(try await mac.marks() == [invoice: MailMarks(isStarred: true)])
    }

    @Test("Erasing a message removes its marks on the other device too")
    func eraseReachesOtherDevices() async throws {
        let key = try ContentRootKey.generate()
        let remote = MailMemoryRemote()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice)
        let phoneSync = SyncEngine(areas: [phone], remote: remote, state: MailMemorySyncState())
        let macSync = SyncEngine(areas: [mac], remote: remote, state: MailMemorySyncState())

        try await phone.keep(invoiceMessage)
        try await phone.save([invoice: MailMarks(folder: .trash, trashedAt: received, trashedFrom: .inbox)])
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try await mac.marks().count == 1)

        try await phone.erase([invoice])
        #expect(try await phone.message(invoice) == nil)
        _ = try await phoneSync.sync()
        let report = try await macSync.sync()
        #expect(report.removedHere == 1)
        #expect(try await mac.marks().isEmpty)
        #expect(try await phone.deletedObjectIDs().isEmpty)
    }

    @Test("A key move reaches every mail file, and they open under the new key")
    func keyMoveReachesMail() async throws {
        let store = MailMemoryStore()
        let ring = ContentKeyRing(keys: MailMemoryKeys(), areas: [SealedArea(store: store, purposes: MailVault.sealedPurposes)])
        let settings = MailSettings(folders: [MailOwnFolder(name: "Brownsea trip")])
        let vault = MailVault(store: store, rootKey: try ring.current(), account: alice)
        try await vault.keep(invoiceMessage)
        try await vault.save([invoice: MailMarks(isStarred: true)])
        try await vault.save(settings)

        let new = try ContentRootKey.generate()
        let report = try ring.adopt(new)
        #expect(report.moved == 3)
        #expect(report.unreadable == 0)
        let moved = MailVault(store: store, rootKey: new, account: alice)
        #expect(try await moved.message(invoice) == invoiceMessage)
        #expect(try await moved.marks() == [invoice: MailMarks(isStarred: true)])
        #expect(try await moved.settings() == settings)
    }

    @Test func aClosedVaultWritesNothing() async throws {
        let store = MailMemoryStore()
        let vault = MailVault(store: store, rootKey: try .generate(), account: alice)
        await vault.close()
        await #expect(throws: MailVaultError.closed) { try await vault.keep(invoiceMessage) }
        await #expect(throws: MailVaultError.closed) { try await vault.save([invoice: MailMarks()]) }
        await #expect(throws: MailVaultError.closed) { try await vault.save(MailSettings()) }
        #expect(try store.names().isEmpty)
    }
}
