import Auth
import CoreGraphics
import Foundation
import ImageIO
import Testing
import TotalityCore
import UniformTypeIdentifiers
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
    var profileError: AccountError?
    var saveError: AccountError?
    var photoError: AccountError?
    private var holding = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private(set) var stored: Profile?
    private(set) var photos: [Data?] = []
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
    func failProfile(load: AccountError? = nil, save: AccountError? = nil, photo: AccountError? = nil) {
        profileError = load
        saveError = save
        photoError = photo
    }

    func endSession() { username = nil }
    func holdProfile() { holding = true }
    func waitForHeldLoad() async {
        while heldLoad == nil { await Task.yield() }
    }
    func releaseProfile() {
        holding = false
        heldLoad?.resume()
        heldLoad = nil
    }

    func loadProfile() async throws -> Profile {
        if holding {
            let current = Profile(username: username ?? "")
            await withCheckedContinuation { heldLoad = $0 }
            return current
        }
        if let profileError { throw profileError }
        if let stored { return stored }
        let made = Profile(username: username ?? "")
        stored = made
        return made
    }
    func saveProfile(displayName: String?, bio: String?) async throws {
        if let saveError { throw saveError }
        stored?.displayName = displayName
        stored?.bio = bio
    }
    func updatePhoto(_ jpeg: Data?) async throws -> URL? {
        if let photoError { throw photoError }
        photos.append(jpeg)
        return jpeg == nil ? nil : URL(string: "https://abc.supabase.co/photo.jpg")
    }
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

@Suite struct ReservedUsernameTests {
    @Test("The app's list matches the one the server enforces")
    func matchesTheMigration() throws {
        let migration = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "supabase/migrations/20261102000001_reserved_usernames.sql")
        let sql = try String(contentsOf: migration, encoding: .utf8)
        let names = sql.split(separator: "\n").filter { !$0.hasPrefix("--") }.joined()
            .matches(of: /\('([a-z0-9_]+)'\)/).map { String($0.1) }
        #expect(Set(names) == Username.reserved)
    }

    @Test(arguments: Username.reserved)
    func everyNameCouldHaveBeenAUsername(name: String) {
        #expect(Username(name)?.isReserved == true)
    }

    @Test func aNameCloseToOneIsFree() {
        #expect(Username("admin_fan")?.isReserved == false)
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

    @Test("A reserved name gets the plain answer and never reaches the server", arguments: ["Admin", "postmaster", "mckayclemens"])
    func aReservedNameIsTaken(name: String) async {
        let service = FakeAccountService()
        let model = AccountModel(service: service)
        await model.signUp(username: name, password: password, confirmation: password)
        #expect(model.notice == AccountError.usernameTaken.message)
        #expect(await service.signUps.isEmpty)
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

    @Test("Signing in fetches the profile")
    func signingInLoadsTheProfile() async {
        let model = AccountModel(service: FakeAccountService())
        await model.signIn(username: "owner", password: password)
        #expect(model.profile == Profile(username: "owner"))
        #expect(!model.profileFailed)
    }

    @Test("A profile that won't load doesn't undo the sign-in, and can be tried again")
    func profileFailureIsRecoverable() async {
        let service = FakeAccountService()
        await service.failProfile(load: .offline)
        let model = AccountModel(service: service)
        await model.signIn(username: "owner", password: password)
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(model.profile == nil)
        #expect(model.profileFailed)
        await service.failProfile()
        await model.loadProfile()
        #expect(model.profile != nil)
        #expect(!model.profileFailed)
    }

    @Test("A failed refresh keeps showing the profile you already have")
    func failedRefreshKeepsTheProfile() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        await service.failProfile(load: .offline)
        await model.loadProfile()
        #expect(model.profile != nil)
        #expect(!model.profileFailed)
    }

    @Test func savingTidiesAndBlankClears() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        #expect(await model.saveProfile(displayName: "  McKay Clemens\n", bio: "Building Totality."))
        #expect(model.profile?.displayName == "McKay Clemens")
        #expect(await model.saveProfile(displayName: "   ", bio: ""))
        #expect(model.profile?.displayName == nil)
        #expect(model.profile?.bio == nil)
        #expect(await service.stored?.bio == nil)
    }

    @Test(arguments: [(String(repeating: "n", count: 51), ""), ("", String(repeating: "b", count: 161))])
    func overlongProfilesAreCaughtBeforeSending(name: String, bio: String) async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        #expect(await model.saveProfile(displayName: name, bio: bio) == false)
        #expect(model.notice != nil)
        #expect(model.profile?.displayName == nil)
    }

    @Test func theLongestProfileFits() async {
        let model = AccountModel(service: FakeAccountService(username: "owner"))
        await model.load()
        let saved = await model.saveProfile(displayName: String(repeating: "n", count: 50), bio: String(repeating: "b", count: 160))
        #expect(saved)
    }

    @Test("A save that fails keeps what was there and says so")
    func failedSaveChangesNothing() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        await service.failProfile(save: .offline)
        #expect(await model.saveProfile(displayName: "New name", bio: "") == false)
        #expect(model.profile?.displayName == nil)
        #expect(model.notice == AccountError.offline.message)
    }

    @Test func aPhotoIsRebuiltBeforeItLeaves() async throws {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        let original = try Picture.jpeg(width: 1200, height: 800, withMetadata: true)
        await model.setPhoto(original)
        let sent = try #require(await service.photos.first ?? nil)
        #expect(sent != original)
        #expect(model.profile?.avatarURL != nil)
    }

    @Test("Something that isn't a picture never reaches the server")
    func nonPicturesStayHere() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        await model.setPhoto(Data("not a picture".utf8))
        #expect(model.notice != nil)
        #expect(await service.photos.isEmpty)
    }

    @Test func removingAPhotoClearsIt() async throws {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        await model.setPhoto(try Picture.jpeg(width: 600, height: 600))
        await model.removePhoto()
        #expect(model.profile?.avatarURL == nil)
        #expect(await service.photos.last == .some(nil))
    }

    @Test("A session that's gone takes its profile with it")
    func anEndedSessionForgetsTheProfile() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await model.load()
        #expect(model.profile != nil)
        await service.endSession()
        await model.load()
        #expect(model.phase == .signedOut)
        #expect(model.profile == nil)
    }

    @Test("The next account never shows the last one's profile, even if its own won't load")
    func nextAccountStartsClean() async {
        let service = FakeAccountService(username: "first_user")
        let model = AccountModel(service: service)
        await model.load()
        await service.failProfile(load: .offline)
        await model.signIn(username: "second_user", password: password)
        #expect(model.phase == .signedIn(username: "second_user"))
        #expect(model.profile == nil)
        #expect(model.profileFailed)
    }

    @Test("A profile that arrives after signing out is dropped")
    func lateProfileIsDropped() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service)
        await service.holdProfile()
        let loading = Task { await model.load() }
        await service.waitForHeldLoad()
        await model.signOut()
        await service.releaseProfile()
        await loading.value
        #expect(model.phase == .signedOut)
        #expect(model.profile == nil)
    }

    @Test func signingOutForgetsTheProfile() async {
        let model = AccountModel(service: FakeAccountService(username: "owner"))
        await model.load()
        await model.signOut()
        #expect(model.profile == nil)
    }
}

enum Picture {
    static func jpeg(width: Int, height: Int, withMetadata: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 40.2338, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 111.6585, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:30 15:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 14"],
        ]
        CGImageDestinationAddImage(destination, image, withMetadata ? metadata as CFDictionary : nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}

@Suite struct ProfilePhotoTests {
    @Test("Location, time, and camera details don't survive")
    func metadataIsGone() throws {
        let original = try Picture.jpeg(width: 1200, height: 800, withMetadata: true)
        #expect(try Picture.properties(of: original)[kCGImagePropertyGPSDictionary] != nil)
        let prepared = try #require(ProfilePhoto.prepare(original))
        let properties = try Picture.properties(of: prepared)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
    }

    @Test(arguments: [(1200, 800), (800, 1200), (2000, 2000)])
    func comesOutSquareAndSmall(width: Int, height: Int) throws {
        let prepared = try #require(ProfilePhoto.prepare(try Picture.jpeg(width: width, height: height)))
        let properties = try Picture.properties(of: prepared)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == ProfilePhoto.side)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == ProfilePhoto.side)
        #expect(prepared.count < 1_048_576)
    }

    @Test func aSmallPictureIsNotBlownUp() throws {
        let prepared = try #require(ProfilePhoto.prepare(try Picture.jpeg(width: 100, height: 60)))
        let properties = try Picture.properties(of: prepared)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 60)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 60)
    }

    @Test func refusesWhatIsNotAPicture() {
        #expect(ProfilePhoto.prepare(Data("<svg onload=alert(1)>".utf8)) == nil)
        #expect(ProfilePhoto.prepare(Data()) == nil)
    }
}
