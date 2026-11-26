import Foundation
import Observation
import TotalityCore

/// What the account screens show. Signing in and out never touches notes or their keys.
@MainActor
@Observable
public final class AccountModel {
    public enum Phase: Equatable {
        case loading
        case signedOut
        case signedIn(username: String)
    }

    /// Matches `minimum_password_length` in supabase/config.toml.
    public static let minimumPasswordLength = 12
    /// The server's hash only reads this many bytes, and it refuses anything longer.
    private static let maximumPasswordBytes = 72

    public private(set) var phase = Phase.loading {
        didSet {
            if case .signedIn = phase, !hasSignedInHere { rememberSignedInHere(true) }
            guard case .signedIn(let old) = oldValue, phase != oldValue else { return }
            onAccountLeft?(old)
        }
    }
    /// Whether someone has signed in on this device and not signed out since. The sign-in page shows
    /// only when this is false (owner, 2026-11-25), so a session that lapses or a Keychain read that fails
    /// just after launch opens Home, where Account still offers to sign in, rather than the sign-in page.
    /// It's a flag on this device and holds no username, token or password.
    public private(set) var hasSignedInHere: Bool
    /// Called once the signed-in account signs out or is replaced, with the username that left. Anything
    /// the app keeps per account (Social, shared lists, Messages' connection) must drop it here, so the
    /// next account never sees or acts as this one.
    public var onAccountLeft: (@MainActor (String) -> Void)?
    public private(set) var isWorking = false
    /// False after sign-in if this device could not be added. Signing in still counts.
    public private(set) var deviceRegistered = false
    public private(set) var profile: Profile?
    /// True when the profile couldn't be read, so the screen can offer another try.
    public private(set) var profileFailed = false
    public var notice: String?
    /// Whether the public web page is up. Nil until the server has said.
    public private(set) var webPage: Bool?
    public private(set) var isChangingWebPage = false
    /// Why the last change to the web page didn't happen, if it didn't.
    public private(set) var webPageProblem: String?

    /// Nil when this build has nothing to back up with.
    public let backup: BackupModel?
    /// Nil when this build has nothing to sync with.
    public let sync: SyncModel?
    public let syncRemote: (any SyncRemote)?
    /// Settings' storage bars. The app sets it, since it reads what other modules hold.
    public var storage: StorageModel?
    /// Adds a browser to the account. The app sets it, since it holds the content key.
    public var pairing: PairBrowserModel?
    /// Opens your profile in Social, the one public profile. The app sets it, so Account never imports Social.
    public var onOpenSocialProfile: (@MainActor () -> Void)?
    /// Browsers paired with the website, listed under Devices with Remove.
    public var browsers: BrowsersModel?
    private let service: any AccountService
    /// Usernames whose Matrix address is known to exist, so it's set up once and not on every launch.
    private let marks: UserDefaults
    private static let messagesReadyKey = "account.messagesAccountReady"
    static let signedInHereKey = "account.signedInHere"
    private var settingUpMessages = false
    private var finishing: Task<Void, Never>?

    public init(
        service: any AccountService, backup: BackupModel? = nil, sync: SyncModel? = nil, syncRemote: (any SyncRemote)? = nil,
        marks: UserDefaults = .standard
    ) {
        self.service = service
        self.marks = marks
        self.backup = backup
        self.sync = sync
        self.syncRemote = syncRemote
        hasSignedInHere = marks.bool(forKey: Self.signedInHereKey)
    }

    /// The full-screen sign-in page, rather than Home: only on a device that has never signed in, or
    /// since someone signed out here. Nothing is decided while the session is still being read.
    public var showsSignInPage: Bool {
        phase == .signedOut && !hasSignedInHere
    }

    /// Reads who is signed in from this device's saved session, and nothing else, so launch can decide
    /// between Home and the sign-in page at once. It makes no network call: the Account page's `load()`
    /// still registers the device and reads the profile when it opens.
    public func restore() async {
        guard phase == .loading else { return }
        let username = await service.currentUsername()
        guard phase == .loading else { return }
        phase = username.map { .signedIn(username: $0) } ?? .signedOut
    }

    public func load() async {
        if let username = await service.currentUsername() {
            phase = .signedIn(username: username)
            await finishSigningIn()
        } else {
            forgetProfile()
            phase = .signedOut
        }
    }

    public func signIn(username: String, password: String) async {
        guard let name = Username(username), !password.isEmpty else {
            notice = "Enter your username and password."
            return
        }
        await run {
            try await service.signIn(username: name, password: password)
            signedIn(as: name.value)
        }
        await waitForSignIn()
    }

    /// Passwords stay out of the model. A typo here can't be fixed later, so it's typed twice.
    public func signUp(username: String, password: String, confirmation: String) async {
        guard let name = Username(username) else {
            notice = "Use 3 to 24 letters, numbers, or underscores for your username."
            return
        }
        guard !name.isReserved else {
            notice = AccountError.usernameTaken.message
            return
        }
        guard password.unicodeScalars.count >= Self.minimumPasswordLength else {
            notice = "Use at least \(Self.minimumPasswordLength) characters for your password."
            return
        }
        guard password.utf8.count <= Self.maximumPasswordBytes else {
            notice = "That password is too long. Use \(Self.maximumPasswordBytes) characters or fewer."
            return
        }
        guard password == confirmation else {
            notice = "Those passwords don't match."
            return
        }
        await run {
            try await service.signUp(username: name, password: password)
            signedIn(as: name.value)
        }
        await waitForSignIn()
    }

    public func signOut() async {
        await sync?.stopForSignOut()
        await run {
            let result = try await service.signOut()
            rememberSignedInHere(false)
            phase = .signedOut
            deviceRegistered = false
            forgetProfile()
            sync?.forget()
            if result == .serverNotReached {
                notice = "You're signed out on this device, but the server couldn't be reached to end the session."
            }
        }
        await backup?.accountSignedOut()
        sync?.resume()
    }

    /// The account can change while this waits, and an answer for the old one must not land.
    public func loadProfile() async {
        let requestedFor = phase
        do {
            let loaded = try await service.loadProfile()
            guard phase == requestedFor else { return }
            profile = loaded
            profileFailed = false
        } catch {
            guard phase == requestedFor else { return }
            profileFailed = profile == nil
        }
    }

    /// Returns whether it saved, so the edit screen knows to close. Blank fields clear what was there.
    public func saveProfile(displayName: String, bio: String, links typed: [String] = []) async -> Bool {
        let name = Self.cleaned(displayName)
        let about = Self.cleaned(bio)
        guard (name?.unicodeScalars.count ?? 0) <= Profile.maximumNameLength else {
            notice = "Use \(Profile.maximumNameLength) characters or fewer for your name."
            return false
        }
        guard (about?.unicodeScalars.count ?? 0) <= Profile.maximumBioLength else {
            notice = "Use \(Profile.maximumBioLength) characters or fewer for your bio."
            return false
        }
        let links: [String]
        do {
            links = try ProfileLinks.normalize(all: typed)
        } catch let problem as ProfileLinks.Problem {
            notice = ProfileLinks.message(for: problem)
            return false
        } catch {
            notice = ProfileLinks.message(for: .malformed)
            return false
        }
        var saved = false
        await run {
            try await service.saveProfile(displayName: name, bio: about, links: links)
            profile?.displayName = name
            profile?.bio = about
            profile?.links = links
            saved = true
        }
        if saved { await refreshWebPage() }
        return saved
    }

    public func setPhoto(_ picture: Data) async {
        guard let jpeg = await Task.detached(operation: { ProfilePhoto.prepare(picture) }).value else {
            notice = "That picture can't be used. Try another."
            return
        }
        await run { profile?.avatarURL = try await service.updatePhoto(jpeg) }
        await refreshWebPage()
    }

    public func removePhoto() async {
        await run { profile?.avatarURL = try await service.updatePhoto(nil) }
        await refreshWebPage()
    }

    /// Asks the server whether the page is up. Not knowing changes nothing.
    public func loadWebPage() async {
        let requestedFor = phase
        guard let published = try? await service.webPageIsPublished(), phase == requestedFor else { return }
        webPage = published
    }

    /// Puts the page up or takes it down. Returns whether that happened.
    @discardableResult
    public func setWebPage(published: Bool) async -> Bool {
        let requestedFor = phase
        isChangingWebPage = true
        defer { isChangingWebPage = false }
        do {
            try await service.setWebPage(published: published)
            guard phase == requestedFor else { return false }
            webPage = published
            webPageProblem = nil
            return true
        } catch {
            guard phase == requestedFor else { return false }
            webPageProblem = (error as? AccountError ?? .failed).message
            return false
        }
    }

    /// Someone else's public profile, or nil if there isn't one this account can see.
    public func lookUp(_ username: String) async throws -> PublicProfile? {
        guard let name = Username(username) else { return nil }
        return try await service.lookUpProfile(name)
    }

    /// A page that's up shows the profile as it was when it was published, so a change goes up too.
    private func refreshWebPage() async {
        guard webPage == true else { return }
        try? await service.setWebPage(published: true)
    }

    private func forgetProfile() {
        profile = nil
        profileFailed = false
        webPage = nil
        webPageProblem = nil
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Waits for the steps after a sign-in or sign-up (claiming an empty device, adding it to the account,
    /// reading the profile) to finish. The app waits on this before opening the account's space, so the
    /// device is claimed before it's settled, as when signing in from the Account page.
    public func waitForSignIn() async {
        await finishing?.value
    }

    /// The account is in from this moment. What follows starts at once, in the same step, so anyone
    /// watching the phase change can wait for it with `waitForSignIn`.
    private func signedIn(as username: String) {
        forgetProfile()
        phase = .signedIn(username: username)
        finishing = Task { await finishSigningIn() }
    }

    private func finishSigningIn() async {
        await backup?.accountSignedIn()
        await registerDevice()
        await loadProfile()
        await loadWebPage()
        await setUpMessagesIfNeeded()
    }

    /// Owner, 2026-11-20 ("Yes, at sign-up"): a new account can be found in Messages straight away, not
    /// only once it first opens Messages. This runs after the profile, since the Matrix pass is made from
    /// its handle. It's quiet: if the Matrix server is down, signing up or in still works and nothing shows,
    /// and the next sign-in or return to the app tries again.
    public func setUpMessagesIfNeeded() async {
        guard case .signedIn(let username) = phase, !settingUpMessages, !messagesReady.contains(username) else { return }
        settingUpMessages = true
        defer { settingUpMessages = false }
        do {
            // The account can change while this waits, so the name marked is the one the server set up.
            let done = try await service.setUpMessagesAccount()
            marks.set(Array(messagesReady.union([done])).sorted(), forKey: Self.messagesReadyKey)
        } catch {}
    }

    /// Whether this username's Matrix address is known to exist.
    func messagesIsReady(_ username: String) -> Bool { messagesReady.contains(username) }

    private var messagesReady: Set<String> {
        Set(marks.stringArray(forKey: Self.messagesReadyKey) ?? [])
    }

    private func rememberSignedInHere(_ value: Bool) {
        hasSignedInHere = value
        marks.set(value, forKey: Self.signedInHereKey)
    }

    private func registerDevice() async {
        do {
            try await service.registerDevice()
            deviceRegistered = true
        } catch {
            deviceRegistered = false
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            notice = nil
            try await work()
        } catch let error as AccountError {
            notice = error.message
        } catch {
            notice = AccountError.failed.message
        }
    }
}
