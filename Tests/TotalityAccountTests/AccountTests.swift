import Auth
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
    var username: String?
    var signInError: AccountError?
    var signUpError: AccountError?
    var deviceError: AccountError?
    var signOutError: AccountError?
    var signOutResult = SignOutResult.complete
    private(set) var signIns: [String] = []
    private(set) var signUps: [String] = []
    private(set) var devices = 0

    init(username: String? = nil) { self.username = username }
    func fail(signIn: AccountError? = nil, signUp: AccountError? = nil, device: AccountError? = nil, signOut: AccountError? = nil) {
        signInError = signIn
        signUpError = signUp
        deviceError = device
        signOutError = signOut
    }

    func currentUsername() async -> String? { username }
    func signUp(username: Username, password: String) async throws {
        if let signUpError { throw signUpError }
        signUps.append(username.value)
        self.username = username.value
    }
    func signIn(username: Username, password: String) async throws {
        if let signInError { throw signInError }
        signIns.append(username.value)
        self.username = username.value
    }
    func registerDevice() async throws {
        if let deviceError { throw deviceError }
        devices += 1
    }
    func signOut() async throws -> SignOutResult {
        if let signOutError { throw signOutError }
        username = nil
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

@Suite struct UsernameTests {
    @Test func tidiesWhatPeopleType() {
        #expect(Username("  McKay_1\n")?.value == "mckay_1")
    }

    @Test(arguments: ["", "ab", String(repeating: "a", count: 25), "a b c", "a.b", "a@b", "ow-ner", "caf\u{e9}", "\u{43e}wner", "owner\u{301}"])
    func refusesWhatTheServerWould(text: String) {
        #expect(Username(text) == nil)
    }

    @Test func acceptsTheEdgesOfTheRule() {
        #expect(Username("abc") != nil)
        #expect(Username(String(repeating: "a", count: 24)) != nil)
    }

    @Test("The address can never reach a real mailbox, and maps back to the name")
    func addressRoundTrips() throws {
        let name = try #require(Username("owner"))
        #expect(name.address == "owner@totality.invalid")
        #expect(Username(address: name.address) == name)
    }

    @Test(arguments: ["owner@gmail.com", "owner", "@totality.invalid", "a b c@totality.invalid"])
    func onlyReservedAddressesAreUsernames(address: String) {
        #expect(Username(address: address) == nil)
    }
}

@Suite struct AccountErrorTests {
    private func api(_ code: ErrorCode) -> AuthError {
        .api(
            message: "raw server text",
            errorCode: code,
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(url: URL(string: "https://abc.supabase.co")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        )
    }

    @Test func mapsTheServerErrorsPeopleCanAct() {
        #expect(SupabaseAccountService.accountError(from: api(.invalidCredentials)) == .wrongPassword)
        #expect(SupabaseAccountService.accountError(from: api(.userAlreadyExists)) == .usernameTaken)
        #expect(SupabaseAccountService.accountError(from: api(.emailExists)) == .usernameTaken)
        #expect(SupabaseAccountService.accountError(from: AuthError.weakPassword(message: "raw", reasons: [])) == .weakPassword)
        #expect(SupabaseAccountService.accountError(from: api(.overRequestRateLimit)) == .rateLimited)
        #expect(SupabaseAccountService.accountError(from: URLError(.notConnectedToInternet)) == .offline)
    }

    @Test func anythingElseIsAPlainFailure() {
        #expect(SupabaseAccountService.accountError(from: api(.unknown)) == .failed)
    }
}

@MainActor
@Suite struct AccountModelTests {
    private let password = "correct horse battery"

    @Test func signsInWithAUsernameAndPassword() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.load()
        #expect(model.phase == .signedOut)
        await model.signIn(username: "  Owner\n", password: password)
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(await service.signIns == ["owner"])
        #expect(await service.devices == 1)
        #expect(model.deviceRegistered)
    }

    @Test func createsAnAccount() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.signUp(username: "Owner", password: password, confirmation: password)
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(await service.signUps == ["owner"])
        #expect(await service.devices == 1)
    }

    @Test func aWrongPasswordSignsNobodyIn() async {
        let service = FakeAccountService()
        await service.fail(signIn: .wrongPassword)
        let model = AccountModel(service: service)
        await model.load()
        await model.signIn(username: "owner", password: password)
        #expect(model.phase == .signedOut)
        #expect(model.notice == AccountError.wrongPassword.message)
        #expect(await service.devices == 0)
    }

    @Test func aTakenUsernameSaysSo() async {
        let service = FakeAccountService()
        await service.fail(signUp: .usernameTaken)
        let model = AccountModel(service: service)
        await model.load()
        await model.signUp(username: "owner", password: password, confirmation: password)
        #expect(model.phase == .signedOut)
        #expect(model.notice == AccountError.usernameTaken.message)
    }

    @Test(arguments: [("", "correct horse battery"), ("owner", ""), ("no", "correct horse battery"), ("not a name", "correct horse battery")])
    func incompleteSignInsAreCaughtBeforeSending(username: String, password: String) async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.signIn(username: username, password: password)
        #expect(model.notice != nil)
        #expect(await service.signIns.isEmpty)
    }

    @Test("Sign-in leaves password rules to the server")
    func signInDoesNotApplyThePasswordRule() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.signIn(username: "owner", password: "short")
        #expect(await service.signIns == ["owner"])
    }

    @Test(arguments: [
        ("bad name", "correct horse battery", "correct horse battery"),
        ("owner", "elevenchars", "elevenchars"),
        ("owner", String(repeating: "a", count: 73), String(repeating: "a", count: 73)),
        ("owner", "correct horse battery", "correct horse batterz"),
    ])
    func badSignUpsAreCaughtBeforeSending(username: String, password: String, confirmation: String) async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.signUp(username: username, password: password, confirmation: confirmation)
        #expect(model.notice != nil)
        #expect(await service.signUps.isEmpty)
    }

    @Test func theShortestAndLongestPasswordsPass() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        let shortest = String(repeating: "a", count: AccountModel.minimumPasswordLength)
        let longest = String(repeating: "a", count: 72)
        await model.signUp(username: "first", password: shortest, confirmation: shortest)
        await model.signUp(username: "second", password: longest, confirmation: longest)
        #expect(await service.signUps == ["first", "second"])
    }

    @Test func aReturningPersonIsAlreadySignedIn() async {
        let model = AccountModel(service: FakeAccountService(username: "owner"))
        await model.load()
        #expect(model.phase == .signedIn(username: "owner"))
    }

    @Test func aRateLimitSaysSo() async {
        let service = FakeAccountService()
        await service.fail(signIn: .rateLimited)
        let model = AccountModel(service: service)
        await model.signIn(username: "owner", password: password)
        #expect(model.phase == .loading)
        #expect(model.notice == AccountError.rateLimited.message)
    }

    @Test("A device that can't register doesn't undo the sign-in, and says so")
    func deviceFailureIsShownNotFatal() async {
        let service = FakeAccountService()
        await service.fail(device: .offline)
        let model = AccountModel(service: service)
        await model.signIn(username: "owner", password: password)
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(!model.deviceRegistered)
    }

    @Test func signingOutReturnsToTheStart() async {
        let model = AccountModel(service: FakeAccountService(username: "owner"))
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(!model.deviceRegistered)
    }

    @Test("If the server can't be told, you're signed out here and the app says what's left")
    func unrevokedSignOutIsHonest() async {
        let service = FakeAccountService(username: "owner")
        await service.setSignOutResult(.serverNotReached)
        let model = AccountModel(service: service)
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(model.notice?.contains("server") == true)
    }

    @Test("Offline, nothing is signed out and the app says so")
    func offlineSignOutStaysSignedIn() async {
        let service = FakeAccountService(username: "owner")
        await service.fail(signOut: .offline)
        let model = AccountModel(service: service)
        await model.load()
        await model.signOut()
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(model.notice == AccountError.offline.message)
    }
}
