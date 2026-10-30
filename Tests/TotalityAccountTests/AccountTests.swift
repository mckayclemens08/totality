import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { secrets[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
    var names: [String] { lock.withLock { Array(secrets.keys) } }
}

actor FakeAccountService: AccountService {
    var email: String?
    var requestError: AccountError?
    var finishError: AccountError?
    var deviceError: AccountError?
    var signOutError: AccountError?
    var signOutResult = SignOutResult.complete
    private(set) var requested: [String] = []
    private(set) var finished: [URL] = []
    private(set) var devices = 0

    init(email: String? = nil) { self.email = email }
    func seedRequest(_ email: String) { requested.append(email) }
    func fail(request: AccountError? = nil, finish: AccountError? = nil, device: AccountError? = nil, signOut: AccountError? = nil) {
        requestError = request
        finishError = finish
        deviceError = device
        signOutError = signOut
    }

    func currentEmail() async -> String? { email }
    func requestLink(email: String) async throws {
        if let requestError { throw requestError }
        requested.append(email)
    }
    func finishSignIn(from url: URL) async throws -> String? {
        if let finishError { throw finishError }
        finished.append(url)
        email = requested.last
        return email
    }
    func registerDevice() async throws {
        if let deviceError { throw deviceError }
        devices += 1
    }
    func signOut() async throws -> SignOutResult {
        if let signOutError { throw signOutError }
        email = nil
        return signOutResult
    }
    func setSignOutResult(_ result: SignOutResult) { signOutResult = result }
}

@Suite struct AccountConfigTests {
    @Test func acceptsAnHTTPSProject() {
        #expect(AccountConfig(url: "https://abc.supabase.co", publishableKey: "key") != nil)
    }

    @Test("Plain HTTP is refused, because tokens would cross the network readable")
    func refusesHTTP() {
        #expect(AccountConfig(url: "http://abc.supabase.co", publishableKey: "key") == nil)
    }

    @Test func missingSettingsMeanNoBackend() {
        #expect(AccountConfig(url: nil, publishableKey: "key") == nil)
        #expect(AccountConfig(url: "https://abc.supabase.co", publishableKey: "") == nil)
        #expect(AccountConfig(url: "", publishableKey: "key") == nil)
        #expect(AccountConfig(url: "not a url", publishableKey: "key") == nil)
    }
}

@Suite struct SessionStorageTests {
    @Test func storesInTheKeyStoreItWasGiven() throws {
        let keys = MemoryKeyStore()
        let storage = SessionStorage(store: keys)
        try storage.store(key: "session", value: Data("token".utf8))
        #expect(try keys.load("session") == Data("token".utf8))
        #expect(try storage.retrieve(key: "session") == Data("token".utf8))
        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
    }
}

@Suite struct DeviceKeyTests {
    @Test func staysTheSameAndIsTheRightSize() throws {
        let keys = MemoryKeyStore()
        let first = try DeviceKey.publicKey(in: keys)
        #expect(first.count == 32)
        #expect(try DeviceKey.publicKey(in: keys) == first)
    }

    @Test func eachDeviceGetsItsOwn() throws {
        #expect(try DeviceKey.publicKey(in: MemoryKeyStore()) != DeviceKey.publicKey(in: MemoryKeyStore()))
    }
}

@MainActor
@Suite struct AccountModelTests {
    private let link = URL(string: "app.totality.client://auth/callback?code=abc")!

    @Test func signsInWithALink() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.load()
        #expect(model.phase == .signedOut)
        await model.sendLink(to: "  Owner@Example.COM\n")
        #expect(model.phase == .awaitingLink(email: "owner@example.com"))
        await model.finishSignIn(from: link)
        #expect(model.phase == .signedIn(email: "owner@example.com"))
        #expect(await service.devices == 1)
        #expect(model.deviceRegistered)
    }

    @Test("A link this device can't redeem signs nobody in, and says so")
    func unredeemableLinkFails() async {
        let service = FakeAccountService()
        await service.fail(finish: .invalidLink)
        let model = AccountModel(service: service)
        await model.load()
        await model.finishSignIn(from: link)
        #expect(model.phase == .signedOut)
        #expect(model.notice == AccountError.invalidLink.message)
    }

    @Test("A link still works if iOS closed the app while you were in Mail")
    func linkWorksAfterRelaunch() async {
        let service = FakeAccountService()
        await service.seedRequest("owner@example.com")
        let model = AccountModel(service: service)
        await model.finishSignIn(from: link)
        #expect(model.phase == .signedIn(email: "owner@example.com"))
    }

    @Test("Reopening the account screen while waiting doesn't lose your place")
    func reloadingKeepsTheWait() async {
        let model = AccountModel(service: FakeAccountService())
        await model.sendLink(to: "owner@example.com")
        await model.load()
        #expect(model.phase == .awaitingLink(email: "owner@example.com"))
    }

    @Test func aLinkIsIgnoredOnceSignedIn() async {
        let service = FakeAccountService(email: "owner@example.com")
        let model = AccountModel(service: service)
        await model.load()
        await model.finishSignIn(from: link)
        #expect(await service.finished.isEmpty)
    }

    @Test(arguments: [
        "https://evil.example/auth/callback?code=abc",
        "app.totality.client://evil/callback?code=abc",
        "app.totality.client://auth/other?code=abc",
        "other.scheme://auth/callback?code=abc",
    ])
    func onlyTheExactCallbackCounts(address: String) async throws {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.sendLink(to: "owner@example.com")
        await model.finishSignIn(from: try #require(URL(string: address)))
        #expect(model.phase == .awaitingLink(email: "owner@example.com"))
        #expect(await service.finished.isEmpty)
    }

    @Test func aReturningPersonIsAlreadySignedIn() async {
        let model = AccountModel(service: FakeAccountService(email: "owner@example.com"))
        await model.load()
        #expect(model.phase == .signedIn(email: "owner@example.com"))
    }

    @Test(arguments: ["", "owner", "@example.com", "owner@", "owner@example", "a b@example.com", "a@b@c.com", "owner@.com"])
    func badEmailsAreCaughtBeforeSending(email: String) async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.sendLink(to: email)
        #expect(model.notice != nil)
        #expect(await service.requested.isEmpty)
    }

    @Test func anExpiredLinkLetsYouAskAgain() async {
        let service = FakeAccountService()
        await service.fail(finish: .invalidLink)
        let model = AccountModel(service: service)
        await model.sendLink(to: "owner@example.com")
        await model.finishSignIn(from: link)
        #expect(model.phase == .awaitingLink(email: "owner@example.com"))
        #expect(model.notice == AccountError.invalidLink.message)
    }

    @Test func aRateLimitSaysSo() async {
        let service = FakeAccountService()
        await service.fail(request: .rateLimited)
        let model = AccountModel(service: service)
        await model.sendLink(to: "owner@example.com")
        #expect(model.phase == .loading)
        #expect(model.notice == AccountError.rateLimited.message)
    }

    @Test("A device that can't register doesn't undo the sign-in, and says so")
    func deviceFailureIsShownNotFatal() async {
        let service = FakeAccountService()
        await service.fail(device: .offline)
        let model = AccountModel(service: service)
        await model.sendLink(to: "owner@example.com")
        await model.finishSignIn(from: link)
        #expect(model.phase == .signedIn(email: "owner@example.com"))
        #expect(!model.deviceRegistered)
    }

    @Test func signingOutReturnsToTheStart() async {
        let model = AccountModel(service: FakeAccountService(email: "owner@example.com"))
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(!model.deviceRegistered)
    }

    @Test("If the server can't be told, you're signed out here and the app says what's left")
    func unrevokedSignOutIsHonest() async {
        let service = FakeAccountService(email: "owner@example.com")
        await service.setSignOutResult(.serverNotReached)
        let model = AccountModel(service: service)
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(model.notice?.contains("server") == true)
    }

    @Test("Offline, nothing is signed out and the app says so")
    func offlineSignOutStaysSignedIn() async {
        let service = FakeAccountService(email: "owner@example.com")
        await service.fail(signOut: .offline)
        let model = AccountModel(service: service)
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedIn(email: "owner@example.com"))
        #expect(model.notice == AccountError.offline.message)
    }
}
