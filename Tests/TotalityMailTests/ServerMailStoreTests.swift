import CryptoKit
import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// The mail service as the store meets it: sealed files it can't read, and a key it keeps for good.
private actor FakeMailService: MailServer {
    enum Mode { case online, offline, conflict }

    var mode = Mode.online
    var isFull = false
    private(set) var files: [UUID: (sealed: Data, received: Date)] = [:]
    private(set) var publishedKey: Data?
    private(set) var publishCalls = 0
    private(set) var fetched: [UUID] = []
    private(set) var deleted: [Set<UUID>] = []

    func set(_ mode: Mode) { self.mode = mode }
    func set(full: Bool) { isFull = full }
    func add(_ id: UUID, sealed: Data, received: Date) { files[id] = (sealed, received) }

    func publish(publicKey: Data) async throws -> MailKeyPublication {
        publishCalls += 1
        switch mode {
        case .offline: throw MailServerError.offline
        case .conflict: throw MailServerError.keyConflict
        case .online: break
        }
        if let publishedKey {
            guard publishedKey == publicKey else { throw MailServerError.keyConflict }
            return .alreadyThere
        }
        publishedKey = publicKey
        return .published
    }

    func list() async throws -> MailServerList {
        if mode == .offline { throw MailServerError.offline }
        let entries = files.map { MailServerEntry(id: $0.key, size: $0.value.sealed.count, received: $0.value.received) }
        let used = entries.reduce(0) { $0 + $1.size }
        return MailServerList(messages: entries, used: used, limit: isFull ? used : 1_073_741_824)
    }

    func message(_ id: UUID) async throws -> Data {
        if mode == .offline { throw MailServerError.offline }
        fetched.append(id)
        guard let file = files[id] else { throw MailServerError.unavailable }
        return file.sealed
    }

    func delete(_ ids: Set<UUID>) async throws -> Int {
        if mode == .offline { throw MailServerError.offline }
        deleted.append(ids)
        let count = ids.filter { files[$0] != nil }.count
        for id in ids { files[id] = nil }
        return count
    }

    func recipientKey(_ name: String) async throws -> Data? { nil }
    func deliver(to name: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer { .noSuchAddress }
    func keep(id: UUID, sealed: Data) async throws { files[id] = (sealed, Date()) }
}

/// Whether the device may publish, which a test can change partway.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private(set) var asked = 0
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func check() -> Bool { lock.withLock { asked += 1; return value } }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [MailDownload] = []
    func add(_ download: MailDownload) { lock.withLock { seen.append(download) } }
    var all: [MailDownload] { lock.withLock { seen } }
}

@MainActor @Suite struct ServerMailStoreTests {
    private let account = "3f2b8c1e-7a44-4e0b-9d52-1c6f0a9e8b11"
    private let ferry = UUID(uuidString: "6f1c2a7e-93d4-4b8e-a1f0-2c5d8e9b7a31")!
    private let clinic = UUID(uuidString: "0b9e4d12-5a6f-4c3b-8e7d-1f2a3b4c5d6e")!
    private let broken = UUID(uuidString: "a94c07d2-58e3-4b16-8f70-2de1b4c63a05")!
    private let received = Date(timeIntervalSince1970: 1_793_783_564)

    private let ferryMail = """
    {"version":1,"received":"2026-11-04T09:12:44.512Z","spam":{"score":1.2,"flagged":false}}
    From: Harbour Ferries <tickets@harbourferries.example>
    To: mckay@usetotality.com
    Subject: Your crossing to Brownsea Island on Saturday
    Date: Wed, 04 Nov 2026 09:12:40 +0000
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="crossing"

    --crossing
    Content-Type: text/plain; charset=utf-8

    Two adults on the 10:15 sailing from Poole Quay. Show the attached ticket at the gangway.
    --crossing
    Content-Type: text/plain; name="ticket.txt"
    Content-Disposition: attachment; filename="ticket.txt"

    Booking HF-20914, 2 adults, 10:15 Poole Quay to Brownsea Island.
    --crossing--
    """

    private let clinicMail = """
    {"version":1,"received":"2026-11-04T15:40:02.000Z","spam":{"score":0.4,"flagged":false}}
    From: Pine Hollow Dental <frontdesk@pinehollowdental.example>
    To: mckay@usetotality.com
    Subject: Reminder: cleaning on Thursday at 2:30
    Date: Wed, 04 Nov 2026 15:39:58 +0000

    We'll see you Thursday at 2:30. Reply to this message if you need to move it.
    """

    private func sealed(_ text: String, to root: ContentRootKey, message: UUID) throws -> Data {
        let info = Data("totality/mail/v1".utf8)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: MailKey(root: root).publicKey())
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let mailbox = UUID(uuidString: account)!
        let ids = withUnsafeBytes(of: mailbox.uuid) { Data($0) } + withUnsafeBytes(of: message.uuid) { Data($0) }
        let body = try sender.seal(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8), authenticating: info + ids)
        return Data([1]) + sender.encapsulatedKey + body
    }

    private func setUp(canPublish: Bool = true) async throws -> (ServerMailStore, FakeMailService, MailVault, ContentRootKey, Gate) {
        let root = try ContentRootKey.generate()
        let service = FakeMailService()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: account)
        let gate = Gate(canPublish)
        let store = try ServerMailStore(
            account: account, rootKey: root, vault: vault, server: service,
            canPublish: { gate.check() }, username: { "mckay" }
        )
        return (store, service, vault, root, gate)
    }

    @Test func openDownloadsOpensParsesAndKeeps() async throws {
        let (store, service, vault, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await service.add(clinic, sealed: try sealed(clinicMail, to: root, message: clinic), received: received)
        let progress = Progress()

        let opening = try await store.open { progress.add($0) }
        #expect(!opening.isOffline)
        #expect(opening.mailbox.address == "mckay@usetotality.com")
        #expect(await service.publishedKey == (try MailKey(root: root).publicKey()))
        let subjects = Set(opening.mailbox.messages.map(\.subject))
        #expect(subjects == ["Your crossing to Brownsea Island on Saturday", "Reminder: cleaning on Thursday at 2:30"])
        #expect(opening.mailbox.messages.allSatisfy { $0.marks.isUnread && $0.marks.folder == .inbox })
        #expect(progress.all.first == MailDownload(done: 0, total: 2))
        #expect(progress.all.last == MailDownload(done: 2, total: 2))
        #expect(try await vault.hasMessage(ferry))

        let ticket = try #require(opening.mailbox.messages.first { $0.id == ferry }?.attachments.first)
        #expect(ticket.name == "ticket.txt")
        let bytes = try await store.data(of: ticket.id)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Booking HF-20914"))
    }

    @Test func aSecondOpenDownloadsNothingAgain() async throws {
        let (store, service, _, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        _ = try await store.open { _ in }
        let progress = Progress()
        let again = try await store.open { progress.add($0) }
        #expect(again.mailbox.messages.count == 1)
        #expect(await service.fetched == [ferry])
        #expect(progress.all.isEmpty)
        #expect(await service.publishCalls == 1)
    }

    @Test func aSealThatWontOpenIsKeptAndShownAsUnreadable() async throws {
        let (store, service, vault, _, _) = try await setUp()
        // Sealed to some other key, so this device can't open it.
        await service.add(broken, sealed: try sealed(clinicMail, to: try .generate(), message: broken), received: received)
        let opening = try await store.open { _ in }
        let message = try #require(opening.mailbox.messages.first)
        #expect(message.isUnreadable)
        #expect(message.date == received)
        #expect(try await vault.message(broken)?.raw == nil)
        _ = try await store.open { _ in }
        #expect(await service.fetched == [broken])
    }

    @Test func marksAndSettingsComeBackFromTheVault() async throws {
        let (store, service, _, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await service.add(clinic, sealed: try sealed(clinicMail, to: root, message: clinic), received: received)
        _ = try await store.open { _ in }
        let trips = MailOwnFolder(name: "Trips")
        try await store.save([ferry: MailMarks(folder: .own(trips.id), isUnread: false, isStarred: true)])
        try await store.save(MailSettings(folders: [trips], blockedSenders: ["frontdesk@pinehollowdental.example"]))
        let opening = try await store.open { _ in }
        #expect(opening.mailbox.settings.folders == [trips])
        let ferryMessage = try #require(opening.mailbox.messages.first { $0.id == ferry })
        #expect(ferryMessage.marks.folder == .own(trips.id))
        #expect(ferryMessage.marks.isStarred)
        // A blocked sender's mail with no marks of its own lands in Spam.
        #expect(opening.mailbox.messages.first { $0.id == clinic }?.marks.folder == .spam)
    }

    @Test func offlineReturnsWhatTheVaultHas() async throws {
        let (store, service, _, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        _ = try await store.open { _ in }
        await service.set(.offline)
        let opening = try await store.open { _ in }
        #expect(opening.isOffline)
        #expect(opening.mailbox.messages.map(\.subject) == ["Your crossing to Brownsea Island on Saturday"])
        await #expect(throws: MailStoreError.offline) { try await store.erase([ferry]) }
    }

    @Test func aFullMailboxSaysSo() async throws {
        let (store, service, _, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await service.set(full: true)
        #expect(try await store.open { _ in }.mailbox.isFull)
    }

    @Test func aKeyConflictShowsItsStateAndIsNeverTriedAgain() async throws {
        let (store, service, _, _, _) = try await setUp()
        await service.set(.conflict)
        await #expect(throws: MailStoreError.keyConflict) { try await store.open { _ in } }
        await #expect(throws: MailStoreError.keyConflict) { try await store.open { _ in } }
        #expect(await service.publishCalls == 1)

        let model = MailModel(store: store)
        await model.load()
        await model.load()
        #expect(model.phase == .keyConflict)
        #expect(await service.publishCalls == 1)
    }

    @Test func nothingIsPublishedOrFetchedUntilTheDeviceCanSync() async throws {
        let (store, service, _, root, gate) = try await setUp(canPublish: false)
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await #expect(throws: MailStoreError.waitingForBackup) { try await store.open { _ in } }
        #expect(await service.publishCalls == 0)
        #expect(await service.publishedKey == nil)
        #expect(await service.fetched.isEmpty)

        let model = MailModel(store: store)
        await model.load()
        #expect(model.phase == .waitingForBackup)
        #expect(model.mailbox.address == "mckay@usetotality.com")

        gate.set(true)
        let opening = try await store.open { _ in }
        #expect(opening.mailbox.messages.count == 1)
        #expect(await service.publishCalls == 1)
    }

    @Test func eraseRemovesFromTheServerAndTheVault() async throws {
        let (store, service, vault, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await service.add(clinic, sealed: try sealed(clinicMail, to: root, message: clinic), received: received)
        _ = try await store.open { _ in }
        try await store.save([ferry: MailMarks(folder: .trash, trashedAt: received, trashedFrom: .inbox)])
        try await store.erase([ferry])
        #expect(await service.deleted == [[ferry]])
        #expect(await service.files[ferry] == nil)
        #expect(try await vault.message(ferry) == nil)
        #expect(try await vault.marks()[ferry] == nil)
        let opening = try await store.open { _ in }
        #expect(opening.mailbox.messages.map(\.id) == [clinic])
        #expect(await service.fetched.filter { $0 == ferry }.count == 1)
    }

    @Test func mailDeletedOnAnotherDeviceGoesHereToo() async throws {
        let root = try ContentRootKey.generate()
        let service = FakeMailService()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: account)
        let first = try ServerMailStore(account: account, rootKey: root, vault: vault, server: service, canPublish: { true }, username: { "mckay" })
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        await service.add(clinic, sealed: try sealed(clinicMail, to: root, message: clinic), received: received)
        _ = try await first.open { _ in }
        // Another device deletes the ferry ticket for good, then this app opens again later.
        _ = try await service.delete([ferry])
        let later = try ServerMailStore(account: account, rootKey: root, vault: vault, server: service, canPublish: { true }, username: { "mckay" })
        let opening = try await later.open { _ in }
        #expect(opening.mailbox.messages.map(\.id) == [clinic])
        #expect(try await vault.hasMessage(ferry) == false)
    }

    @Test func aMailboxMadeAfreshKeepsWhatThisDeviceHas() async throws {
        let (store, service, vault, root, _) = try await setUp()
        await service.add(ferry, sealed: try sealed(ferryMail, to: root, message: ferry), received: received)
        _ = try await store.open { _ in }
        // The server lost its disk: a new store finds no key and publishes afresh.
        let rebuilt = FakeMailService()
        let after = try ServerMailStore(account: account, rootKey: root, vault: vault, server: rebuilt, canPublish: { true }, username: { "mckay" })
        let opening = try await after.open { _ in }
        #expect(opening.mailbox.messages.map(\.id) == [ferry])
    }

    @Test func anAccountThatIsntTheVaultsIsRefused() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: account)
        #expect(throws: MailStoreError.noAccount) {
            try ServerMailStore(
                account: "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", rootKey: try .generate(), vault: vault,
                server: FakeMailService(), canPublish: { true }, username: { "dana" }
            )
        }
    }
}
