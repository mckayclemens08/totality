import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// Plays iCloud's or Google's servers: each connection gets a fresh script, chosen by where it's going,
/// and anywhere else stops the test.
final class ProviderMaker: OutsideWireMaker, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [OutsideEndpoint] = []
    private let acceptsReading: Bool
    private let acceptsSending: Bool

    init(acceptsReading: Bool = true, acceptsSending: Bool = true) {
        self.acceptsReading = acceptsReading
        self.acceptsSending = acceptsSending
    }

    var connections: [OutsideEndpoint] { lock.withLock { opened } }

    func open(_ endpoint: OutsideEndpoint) -> any OutsideWire {
        lock.withLock { opened.append(endpoint) }
        let reading = OutsideProvider.allCases.contains { $0.reading == endpoint }
        let sending = OutsideProvider.allCases.contains { $0.sending == endpoint }
        precondition(reading || sending, "connected somewhere that isn't a provider's server")
        if reading {
            let ok = acceptsReading
            return ScriptedWire(greeting: "* OK ready\r\n") { line in
                if line.hasPrefix("t1 AUTHENTICATE PLAIN ") {
                    return ok ? "t1 OK authenticated\r\n" : "t1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"
                }
                return line == "t2 LOGOUT" ? "* BYE\r\nt2 OK bye\r\n" : nil
            }
        }
        let ok = acceptsSending
        return ScriptedWire(greeting: "220 ready\r\n") { line in
            switch line {
            case "EHLO [127.0.0.1]": "250-hello\r\n250-STARTTLS\r\n250 AUTH PLAIN LOGIN\r\n"
            case "STARTTLS": "220 go ahead\r\n"
            case "QUIT": "221 bye\r\n"
            default: line.hasPrefix("AUTH PLAIN ") ? (ok ? "235 accepted\r\n" : "535 5.7.8 not accepted\r\n") : "500 what\r\n"
            }
        }
    }
}

/// Mail's own server, which outside accounts never reach.
private struct UntouchedMailServer: MailServer {
    func publish(publicKey: Data) async throws -> MailKeyPublication { Issue.record("reached Totality's mail server"); throw MailServerError.unavailable }
    func list() async throws -> MailServerList { Issue.record("reached Totality's mail server"); throw MailServerError.unavailable }
    func message(_ id: UUID) async throws -> Data { throw MailServerError.unavailable }
    func delete(_ ids: Set<UUID>) async throws -> Int { throw MailServerError.unavailable }
    func recipientKey(_ name: String) async throws -> Data? { throw MailServerError.unavailable }
    func deliver(to name: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer { throw MailServerError.unavailable }
    func keep(id: UUID, sealed: Data) async throws { throw MailServerError.unavailable }
    func sendOutside(_ message: MailOutsideMessage) async throws -> MailOutsideAnswer { throw MailServerError.unavailable }
}

@Suite struct OutsideVaultTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"
    private let bruno = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private let added = Date(timeIntervalSince1970: 1_793_870_000)
    private let icloud = OutsideAccount(provider: .icloud, address: "mckay.clemens@icloud.com", addedAt: Date(timeIntervalSince1970: 1_793_870_000))

    @Test func anAccountIsKeptSealedWithItsSignInInTheKeychain() async throws {
        let blobs = MailMemoryStore()
        let keys = MailMemoryKeys()
        let vault = MailVault(store: blobs, rootKey: try .generate(), account: alice, secrets: keys)
        try await vault.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        #expect(try await vault.outsideAccounts() == [icloud])
        let signIn = try #require(try await vault.signIn(for: icloud.id))
        #expect(signIn.address == "mckay.clemens@icloud.com")
        #expect(signIn.appPassword == "hjkl-qwer-tyui-asdf")
        #expect(try keys.load(MailVault.secretName(icloud.id, account: alice)).map { try OutsideCredential(keychainData: $0) } == .appPassword("hjkl-qwer-tyui-asdf"))
        // Nothing readable on the disk: not the password, the address, or the provider.
        for name in try blobs.names() {
            let bytes = try #require(try blobs.read(name))
            for readable in ["hjkl-qwer", "mckay.clemens", "icloud"] {
                #expect(bytes.range(of: Data(readable.utf8)) == nil)
                #expect(!name.contains(readable))
            }
        }
    }

    @Test func removingTakesTheSignInAndTellsSync() async throws {
        let keys = MailMemoryKeys()
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice, secrets: keys)
        try await vault.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        try await vault.removeOutside(icloud.id)
        #expect(try await vault.outsideAccounts().isEmpty)
        #expect(try keys.load(MailVault.secretName(icloud.id, account: alice)) == nil)
        #expect(try await vault.deletedObjectIDs() == [MailVault.outsideID(icloud.id, account: alice)])
    }

    @Test func aVaultWithNoKeychainKeepsNoSignIns() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice)
        await #expect(throws: OutsideAccountError.unavailable) { try await vault.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf")) }
    }

    @Test("Two-user: on one device, the next account gets none of the last one's outside accounts")
    func anotherAccountOnTheDeviceSeesNothing() async throws {
        let blobs = MailMemoryStore()
        let keys = MailMemoryKeys()
        let key = try ContentRootKey.generate()
        let mine = MailVault(store: blobs, rootKey: key, account: alice, secrets: keys)
        try await mine.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        let theirs = MailVault(store: blobs, rootKey: key, account: bruno, secrets: keys)
        #expect(try await theirs.outsideAccounts().isEmpty)
        #expect(try await theirs.signIn(for: icloud.id) == nil)
        #expect(try await theirs.sealedObjectIDs().isEmpty)
        // Even handed alice's record under bruno's ID, bruno's vault won't take it.
        let record = try #require(try await mine.sealedObject(MailVault.outsideID(icloud.id, account: alice)))
        let moved = SealedObject(id: MailVault.outsideID(icloud.id, account: bruno), kind: .mailOutside, meta: record.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await theirs.store(moved, ifLocalHash: nil) }
        #expect(try keys.load(MailVault.secretName(icloud.id, account: bruno)) == nil)
    }

    @Test("Two-user: the sync server holds only ciphertext it can't open")
    func syncRowsShowNothing() async throws {
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice, secrets: MailMemoryKeys())
        try await vault.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        let remote = MailMemoryRemote()
        _ = try await SyncEngine(areas: [vault], remote: remote, state: MailMemorySyncState()).sync()
        let rows = await remote.all()
        #expect(rows.map(\.kind) == [.mailOutside])
        for row in rows {
            #expect(row.body == nil)
            for readable in ["hjkl-qwer", "mckay.clemens", "icloud"] { #expect(row.meta.range(of: Data(readable.utf8)) == nil) }
        }
        // Someone else's key opens none of it.
        let stranger = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice, secrets: MailMemoryKeys())
        for row in rows { await #expect(throws: CryptoError.self) { try await stranger.store(row, ifLocalHash: nil) } }
    }

    @Test func anAccountAddedOnOneDeviceArrivesOnTheOtherWithItsSignIn() async throws {
        let key = try ContentRootKey.generate()
        let macKeys = MailMemoryKeys()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice, secrets: MailMemoryKeys())
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice, secrets: macKeys)
        let remote = MailMemoryRemote()
        let phoneSync = SyncEngine(areas: [phone], remote: remote, state: MailMemorySyncState())
        let macSync = SyncEngine(areas: [mac], remote: remote, state: MailMemorySyncState())
        try await phone.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try await mac.outsideAccounts() == [icloud])
        #expect(try macKeys.load(MailVault.secretName(icloud.id, account: alice)).map { try OutsideCredential(keychainData: $0) } == .appPassword("hjkl-qwer-tyui-asdf"))

        // Turning sending on reaches the phone too.
        var sending = icloud
        sending.canSend = true
        try await mac.update(sending, at: added.addingTimeInterval(60))
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()
        #expect(try await phone.outsideAccounts() == [sending])

        // Removing on the Mac takes it, and its sign-in, off the phone, with nothing left in a trash.
        try await mac.removeOutside(icloud.id)
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()
        #expect(try await phone.outsideAccounts().isEmpty)
        #expect(try await phone.signIn(for: icloud.id) == nil)
        #expect(try await phone.sealedObjectIDs().isEmpty)
    }

    @Test func aLostKeychainCopyComesBackFromTheSealedRecord() async throws {
        let keys = MailMemoryKeys()
        let vault = MailVault(store: MailMemoryStore(), rootKey: try .generate(), account: alice, secrets: keys)
        try await vault.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        try keys.delete(MailVault.secretName(icloud.id, account: alice))
        #expect(try await vault.signIn(for: icloud.id)?.appPassword == "hjkl-qwer-tyui-asdf")
        #expect(try keys.load(MailVault.secretName(icloud.id, account: alice)) != nil)
    }

    @Test func theNewerChangeWinsAConflict() async throws {
        let key = try ContentRootKey.generate()
        let phone = MailVault(store: MailMemoryStore(), rootKey: key, account: alice, secrets: MailMemoryKeys())
        let mac = MailVault(store: MailMemoryStore(), rootKey: key, account: alice, secrets: MailMemoryKeys())
        var on = icloud
        on.canSend = true
        try await phone.save(icloud, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added)
        try await mac.save(on, credential: .appPassword("hjkl-qwer-tyui-asdf"), at: added.addingTimeInterval(5))
        let id = MailVault.outsideID(icloud.id, account: alice)
        let older = try #require(try await phone.sealedObject(id))
        let newer = try #require(try await mac.sealedObject(id))
        #expect(try await phone.resolveConflict(local: older, remote: newer) == .keepRemote)
        #expect(try await mac.resolveConflict(local: newer, remote: older) == .keepLocal)
    }
}

@Suite struct OutsideAccountStoreTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"

    private func store(_ maker: ProviderMaker, keys: MailMemoryKeys = MailMemoryKeys()) throws -> (ServerMailStore, MailVault) {
        let root = try ContentRootKey.generate()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: alice, secrets: keys)
        let store = try ServerMailStore(
            account: alice, rootKey: root, vault: vault, server: UntouchedMailServer(), canPublish: { false },
            username: { "mckay" }, outsideCheck: OutsideSignInCheck(maker: maker)
        )
        return (store, vault)
    }

    private func icloud(_ address: String = "mckay.clemens@icloud.com") -> OutsideSignIn {
        OutsideSignIn(provider: .icloud, address: address, appPassword: "wxyz abcd efgh ijkl")!
    }

    @Test func addingChecksWithTheProviderFirstAndStartsWithSendingOff() async throws {
        let maker = ProviderMaker()
        let (store, _) = try store(maker)
        let added = try await store.addOutside(icloud())
        #expect(added.provider == .icloud && !added.canSend)
        #expect(maker.connections == [OutsideProvider.icloud.reading])
        #expect(try await store.outsideAccounts() == [added])
    }

    @Test func aRefusedSignInKeepsNothing() async throws {
        let keys = MailMemoryKeys()
        let (store, vault) = try store(ProviderMaker(acceptsReading: false), keys: keys)
        await #expect(throws: OutsideAccountError.problem(.wrongPassword)) { try await store.addOutside(icloud()) }
        #expect(try await vault.outsideAccounts().isEmpty)
        #expect(try await vault.sealedObjectIDs().isEmpty)
    }

    @Test func theSameMailboxTwiceIsRefusedWithoutConnecting() async throws {
        let maker = ProviderMaker()
        let (store, _) = try store(maker)
        _ = try await store.addOutside(icloud())
        await #expect(throws: OutsideAccountError.alreadyAdded) { try await store.addOutside(icloud("McKay.Clemens@iCloud.com")) }
        #expect(maker.connections.count == 1)
    }

    @Test func threeIsTheMost() async throws {
        let (store, _) = try store(ProviderMaker())
        for name in ["mckay.clemens", "clemens.family", "mckay.receipts"] { _ = try await store.addOutside(icloud("\(name)@icloud.com")) }
        await #expect(throws: OutsideAccountError.tooMany) { try await store.addOutside(icloud("one.more@icloud.com")) }
    }

    @Test func turningSendingOnChecksSendingFirst() async throws {
        let maker = ProviderMaker()
        let (store, _) = try store(maker)
        let added = try await store.addOutside(icloud())
        try await store.setOutsideSending(added.id, on: true)
        #expect(try await store.outsideAccounts().first?.canSend == true)
        #expect(maker.connections.last == OutsideProvider.icloud.sending)
        // Turning it off needs no check.
        try await store.setOutsideSending(added.id, on: false)
        #expect(try await store.outsideAccounts().first?.canSend == false)
        #expect(maker.connections.count == 2)
    }

    @Test func sendingThatFailsItsCheckStaysOff() async throws {
        let (store, _) = try store(ProviderMaker(acceptsSending: false))
        let added = try await store.addOutside(icloud())
        await #expect(throws: OutsideAccountError.problem(.wrongPassword)) { try await store.setOutsideSending(added.id, on: true) }
        #expect(try await store.outsideAccounts().first?.canSend == false)
    }

    @Test func removingLeavesNoSignIn() async throws {
        let keys = MailMemoryKeys()
        let (store, vault) = try store(ProviderMaker(), keys: keys)
        let added = try await store.addOutside(icloud())
        try await store.removeOutside(added.id)
        #expect(try await store.outsideAccounts().isEmpty)
        #expect(try await vault.signIn(for: added.id) == nil)
        #expect(try keys.load(MailVault.secretName(added.id, account: alice)) == nil)
    }
}

/// A sign-in page that should never open.
@MainActor
let neverOpened: OutsideWebSignIn = { _, _ in
    Issue.record("opened a sign-in page")
    throw CancellationError()
}

@MainActor
@Suite struct OutsideAccountsModelTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"

    private func model(_ maker: ProviderMaker = ProviderMaker()) throws -> OutsideAccountsModel {
        let root = try ContentRootKey.generate()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: alice, secrets: MailMemoryKeys())
        let store = try ServerMailStore(
            account: alice, rootKey: root, vault: vault, server: UntouchedMailServer(), canPublish: { false },
            username: { "mckay" }, outsideCheck: OutsideSignInCheck(maker: maker)
        )
        return try #require(MailModel(store: store).outside)
    }

    @Test func startsEmptyAndAddsOnlyOnceChecked() async throws {
        let model = try model()
        await model.load()
        #expect(model.phase == .ready && model.accounts.isEmpty && model.canAddMore)
        #expect(await model.add(.icloud, address: "mckay.clemens@icloud.com", appPassword: "hjkl-qwer-tyui-asdf") == nil)
        #expect(model.accounts.map(\.address) == ["mckay.clemens@icloud.com"])
        #expect(!model.isAdding)
    }

    @Test func aWrongPasswordSaysWhatToDo() async throws {
        let model = try model(ProviderMaker(acceptsReading: false))
        let said = await model.add(.icloud, address: "mckay.clemens@icloud.com", appPassword: "wxyz abcd efgh ijkl")
        #expect(said == "iCloud didn't accept that address and app password. Check both, or make a new app password.")
        #expect(model.accounts.isEmpty)
    }

    @Test func aHalfTypedAccountNeverConnects() async throws {
        let maker = ProviderMaker()
        let model = try model(maker)
        #expect(await model.add(.icloud, address: "mckay.clemens", appPassword: "wxyz") == "Enter the full address and the app password.")
        #expect(maker.connections.isEmpty)
    }

    @Test func aFailedSendSwitchSaysWhyAndStaysOff() async throws {
        let model = try model(ProviderMaker(acceptsSending: false))
        _ = await model.add(.icloud, address: "mckay.clemens@icloud.com", appPassword: "wxyz abcd efgh ijkl")
        let account = try #require(model.accounts.first)
        await model.setSending(account, on: true, signingIn: neverOpened)
        #expect(model.accounts.first?.canSend == false)
        #expect(model.notice?.hasPrefix("iCloud didn't accept") == true)
        #expect(model.busy.isEmpty)
    }

    @Test func gmailNeedsGoogleSignInAndNeverTakesAPassword() async throws {
        let maker = ProviderMaker()
        let model = try model(maker)
        #expect(await model.add(.gmail, address: "mckay.clemens@gmail.com", appPassword: "wxyz abcd efgh ijkl") == "Enter the full address and the app password.")
        #expect(maker.connections.isEmpty)
        // This build has no Google client, so it says so rather than opening a page.
        #expect(await model.addGoogle(signingIn: neverOpened) == .failed("Google sign-in isn't set up in this version of Totality yet."))
    }

    @Test func aSampleStoreOffersNoOutsideAccounts() {
        #expect(MailModel(store: UnavailableMailStore(.noKey)).outside == nil)
    }
}

@Suite struct OutsideWordingTests {
    @Test func theLabelsNeverCallAProvidersCopySealed() {
        for provider in OutsideProvider.allCases {
            let kept = OutsideWording.kept(by: provider)
            #expect(kept.contains("\(provider.keeper), who can read it"))
            #expect(kept.contains("Totality doesn't seal it there"))
            #expect(!kept.lowercased().contains("end-to-end encrypted"))
            #expect(OutsideWording.sent(through: provider).contains("isn't end-to-end encrypted"))
        }
    }

    @Test func everyProblemSaysSomething() {
        let problems: [OutsideMailProblem] = [.offline, .unreachable, .insecure, .wrongPassword, .needsAppPassword, .notAllowed, .expired, .refused(""), .refused("Too many sign-ins"), .unexpected]
        for problem in problems {
            for provider in OutsideProvider.allCases { #expect(!OutsideWording.problem(problem, provider: provider).isEmpty) }
        }
        for error: OutsideAccountError in [.tooMany, .alreadyAdded, .notFound, .unavailable, .notSetUp, .differentAccount] {
            #expect(!OutsideWording.problem(error, provider: .icloud).isEmpty)
        }
    }
}
