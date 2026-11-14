import AuthenticationServices
import Foundation
import Observation
import TotalityCore

/// What the Reader's Google Drive screens show. All the work happens in `GoogleDrive`.
@MainActor
@Observable
public final class DriveModel {
    /// Shows Google's page and hands back where it returned to. The view supplies it, because only a view
    /// can present Google's sign-in sheet.
    public typealias SignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

    /// The honest label for anything from Drive (rule 5): Google holds it, and can read it.
    public nonisolated static let label = "Stored in Google Drive, not end-to-end encrypted"
    public nonisolated static let explanation =
        "Linked folders stay in Google Drive. Google can read them, so they aren't end-to-end encrypted. "
        + "Totality asks Google for your whole Drive but shows only the folders you link. This device talks to Google "
        + "directly, and Totality's server never sees your files, their names, or your Google sign-in."

    public private(set) var accounts: [DriveAccount] = []
    public private(set) var links: [DriveLink] = []
    /// True while Google's page is open or its answer is being checked.
    public private(set) var isConnecting = false
    /// A problem to show on the Drive screens, cleared when it's dismissed or the next try starts.
    public var problem: String?
    /// What's shown of each folder, by `"account/folderID"`: kept first, then fresh from Google.
    public private(set) var listings: [String: DriveListing] = [:]
    /// Folders that couldn't be read last time, by `"account/folderID"`.
    public private(set) var folderProblems: [String: DriveProblem] = [:]
    /// Accounts with linked folders that no longer allow Drive.
    public private(set) var needsAllowing: Set<String> = []

    let drive: GoogleDrive
    /// Where an opened file is held, so the Reader's viewers and Listen can read it.
    private let vault: ReaderVault?
    private let settings: UserDefaults

    /// Holds only a number, and stays with the device.
    static let cacheLimitKey = "reader.drive.cacheLimit"

    public init(drive: GoogleDrive, vault: ReaderVault? = nil, settings: UserDefaults = .standard) {
        self.drive = drive
        self.vault = vault
        self.settings = settings
        let stored = settings.integer(forKey: Self.cacheLimitKey)
        cacheLimit = DriveCacheLimit.choices.contains(stored) ? stored : DriveCacheLimit.standard
    }

    // MARK: Opening files

    /// How much opened files may take on this device.
    public private(set) var cacheLimit: Int
    /// How much they take now, once it's been read.
    public private(set) var cachedBytes: Int?

    public func setCacheLimit(_ limit: Int) async {
        guard DriveCacheLimit.choices.contains(limit) else { return }
        cacheLimit = limit
        settings.set(limit, forKey: Self.cacheLimitKey)
        try? await drive.trimCache(to: limit)
        await readCacheSize()
    }

    public func readCacheSize() async {
        cachedBytes = try? await drive.cachedBytes()
    }

    public func clearCache() async {
        do {
            try await drive.clearCache()
        } catch {
            problem = "Downloaded files couldn't be cleared."
        }
        await readCacheSize()
    }

    /// The ID a Drive file opens under in the Reader. The same file gets the same one, so Listen picks up
    /// where it was in this run. It's never stored.
    static func readerID(account: String, fileID: String) -> UUID {
        UUID(derivedFrom: "totality.reader.drive.file.\(GoogleDrive.key(account, fileID))")
    }

    /// Opens a file, from what's kept or from Google, and hands it to the Reader as an item held in
    /// memory only. Drive files open read-only for now.
    public func openFile(_ entry: DriveEntry, in folderID: String, account: String) async throws -> (item: ReaderItem, file: DriveOpenedFile) {
        guard let vault else { throw ReaderError.notFound }
        let file = try await drive.file(entry.id, in: folderID, account: account, limit: cacheLimit)
        let item = ReaderItem(
            id: Self.readerID(account: account, fileID: entry.id), kind: .file, title: file.entry.name, collection: nil,
            mime: file.mime, byteCount: file.data.count, createdAt: file.modifiedAt ?? Date(),
            updatedAt: file.modifiedAt ?? Date(), listenPosition: 0
        )
        try await vault.hold(item, body: file.data)
        await readCacheSize()
        return (item, file)
    }

    public var isAvailable: Bool { drive.isAvailable }

    @ObservationIgnored private var swept = false

    public func load() async {
        if !swept {
            // Once per run: anything another key left in the cache folder goes.
            swept = (try? await drive.sweepCache()) != nil
        }
        accounts = await drive.connections()
        do {
            links = try await drive.links()
        } catch {
            problem = "Your linked Drive folders couldn't be read on this device."
        }
    }

    public func links(for account: String) -> [DriveLink] {
        links.filter { $0.account == account }
    }

    public func isLinked(_ folder: DriveEntry, account: String) -> Bool {
        links.contains { $0.account == account && $0.folderID == folder.id }
    }

    // MARK: Connecting

    /// Allows Drive on an account, or connects a new one when `account` is nil. Returns the account
    /// that now allows Drive, or nil if it didn't happen. An account that already allows it needs nothing.
    public func connect(_ account: String?, signIn: SignIn) async -> String? {
        if let account, accounts.first(where: { $0.address == account })?.allowsDrive == true { return account }
        guard let authorization = await drive.authorization(for: account) else {
            problem = DriveProblem.notSetUp.message
            return nil
        }
        isConnecting = true
        problem = nil
        defer { isConnecting = false }
        do {
            let callback = try await signIn(authorization.url, authorization.callbackScheme)
            let address = try await drive.finish(authorization, callback: callback)
            await load()
            return address
        } catch is CancellationError {
            return nil
        } catch let error as DriveProblem {
            problem = error == .notAllowed
                ? "Drive wasn't allowed on Google's page, so Totality can't see its folders. Try again and leave Drive ticked."
                : error.message
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The person closed Google's page, which isn't a problem to show.
            return nil
        } catch {
            problem = DriveProblem.from(error).message
        }
        await load()
        return nil
    }

    // MARK: Browsing

    public func listing(_ folderID: String, account: String) -> DriveListing? {
        listings[GoogleDrive.key(account, folderID)]
    }

    public func problem(_ folderID: String, account: String) -> DriveProblem? {
        folderProblems[GoogleDrive.key(account, folderID)]
    }

    /// What was kept shows at once, then Google is asked.
    public func open(_ folderID: String, account: String) async {
        let key = GoogleDrive.key(account, folderID)
        if listings[key] == nil, let kept = try? await drive.kept(folderID, account: account) { listings[key] = kept }
        await refresh(folderID, account: account)
    }

    public func refresh(_ folderID: String, account: String) async {
        let key = GoogleDrive.key(account, folderID)
        do {
            listings[key] = try await drive.refresh(folderID, account: account)
            folderProblems[key] = nil
        } catch is CancellationError {
        } catch {
            folderProblems[key] = DriveProblem.from(error)
        }
    }

    /// How often the quiet refresh asks Google, which the Reader's refresher runs every minute.
    static let quietInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var running: Task<RefreshOutcome, Never>?
    @ObservationIgnored private var lastRefreshed: Date?

    /// The Reader's quiet refresh and pull-to-refresh, as steps of its `Refresher`. A pull always asks
    /// Google; the quiet one only every few minutes, so Drive isn't asked every minute.
    public func attach(to refresher: Refresher) {
        refresher.add("google drive", limit: .seconds(60), onlyWhenPulled: true) { [weak self] in
            await self?.refreshAll(force: true) ?? .done
        }
        refresher.add("google drive quietly", limit: .seconds(60)) { [weak self] in
            await self?.refreshAll(force: false) ?? .done
        }
    }

    /// A run already going is joined, not repeated.
    func refreshAll(force: Bool) async -> RefreshOutcome {
        if let running { return await running.value }
        if !force, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < Self.quietInterval { return .done }
        let task = Task { await self.readAll() }
        running = task
        let outcome = await task.value
        running = nil
        lastRefreshed = Date()
        return outcome
    }

    private func readAll() async -> RefreshOutcome {
        let result = await drive.refreshAll()
        await load()
        folderProblems = result.problems
        needsAllowing = result.needsAllowing
        var fresh: [String: DriveListing] = [:]
        for key in listings.keys {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let kept = try? await drive.kept(parts[1], account: parts[0]) { fresh[key] = kept }
        }
        listings = fresh
        let problems = Set(result.problems.values)
        if problems.isEmpty { return .done }
        if problems == [.offline] { return .offline }
        // A folder gone from Drive shows on its own row, and a passing problem only once it lasts.
        let lasting = problems.subtracting([.notFound]).first { !$0.isPassing } ?? problems.first { $0 != .notFound }
        return lasting.map { .failed($0.message) } ?? .done
    }

    // MARK: Choosing

    public func folders(in place: DrivePlace, account: String) async throws -> [DriveEntry] {
        try await drive.folders(in: place, account: account)
    }

    /// Links or unlinks a folder the chooser shows.
    public func setLinked(_ isLinked: Bool, folder: DriveEntry, account: String) async {
        do {
            if isLinked {
                try await drive.link(folder, account: account)
            } else if let link = links.first(where: { $0.account == account && $0.folderID == folder.id }) {
                try await drive.unlink(link)
                await vault?.releaseHeld()
            }
        } catch {
            problem = isLinked ? "\(folder.name) couldn't be linked." : "\(folder.name) couldn't be unlinked."
        }
        await load()
    }

    public func unlink(_ link: DriveLink) async {
        do {
            try await drive.unlink(link)
            await vault?.releaseHeld()
        } catch {
            problem = "\(link.name) couldn't be unlinked."
        }
        await load()
    }

    /// Who's signed in, as the app last said. Nil inside means signed out.
    @ObservationIgnored private var owner: String??

    /// Any change of who's here, signing out included, drops every Drive file held open and what's shown
    /// of folders, so nothing opened by one person can be read after them.
    public func use(owner: String?) async {
        defer { self.owner = .some(owner) }
        guard let before = self.owner, before != owner else { return }
        await forgetOpened()
    }

    func forgetOpened() async {
        await vault?.releaseHeld()
        listings = [:]
        folderProblems = [:]
    }

    /// For a key move or a change of account.
    public func close() async {
        await drive.close()
        links = []
        accounts = []
        listings = [:]
        folderProblems = [:]
    }
}
