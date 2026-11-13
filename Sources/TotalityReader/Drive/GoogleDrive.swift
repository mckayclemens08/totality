import Foundation
import TotalityCore

/// One Drive folder the person linked into the Reader. Only these, and what's inside them, ever show in
/// the Reader (issue 102).
public struct DriveLink: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let account: String
    public let folderID: String
    public var name: String
    public let linkedAt: Date

    public init(account: String, folderID: String, name: String, linkedAt: Date) {
        self.account = account.lowercased()
        self.folderID = folderID
        self.name = name
        self.linkedAt = linkedAt
    }

    public var id: String { account + "/" + folderID }
}

/// One folder's contents as Drive last listed them, kept sealed so the folder opens instantly.
public struct DriveListing: Codable, Equatable, Sendable {
    public let account: String
    public let folderID: String
    public let entries: [DriveEntry]
    public let readAt: Date
}

/// What a refresh of every linked folder found.
public struct DriveRefresh: Equatable, Sendable {
    /// Folders that couldn't be read this time, by `"account/folderID"`. What was kept still shows.
    public var problems: [String: DriveProblem] = [:]
    /// Accounts with linked folders that no longer allow Drive.
    public var needsAllowing: Set<String> = []
}

/// A connected Google account, as the Drive screens need it: whether it has allowed Drive yet.
public struct DriveAccount: Equatable, Hashable, Sendable, Identifiable {
    public let address: String
    public let allowsDrive: Bool
    public var id: String { address }
}

/// The Reader's Google Drive (issue 102): linked folders, read live from Google, on the shared Google
/// sign-in. The device talks to Google directly. Totality's server never sees Drive files, their names, or
/// the token, and nothing from Drive reaches Supabase unless the person imports it.
///
/// What's kept here is sealed with the content key, in its own folder, and never syncs: each device
/// reads Google itself. The links belong to whoever owns the key, so another person on this device opens
/// none of them.
public actor GoogleDrive {
    public static let suffix = ".gdrive"
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .googleDrive]

    private let accounts: GoogleAccounts?
    private let api: DriveAPI?
    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private let now: @Sendable () -> Date
    private var isClosed = false

    /// `accounts` is nil when this build has no Google sign-in.
    public init(accounts: GoogleAccounts?, store: any BlobStore, rootKey: ContentRootKey, now: @escaping @Sendable () -> Date = { Date() }) {
        self.accounts = accounts
        api = accounts.map { DriveAPI(signIn: $0.signIn) }
        self.store = store
        self.rootKey = rootKey
        self.now = now
    }

    public nonisolated var isAvailable: Bool { accounts != nil }

    /// Refuses all further reads and writes, for a key move or a change of account.
    public func close() {
        isClosed = true
    }

    // MARK: Connecting

    /// Every Google account on this device, and whether each allows Drive yet.
    public func connections() -> [DriveAccount] {
        ((try? accounts?.connections()) ?? []).map {
            DriveAccount(address: $0.address, allowsDrive: $0.allows([DriveAPI.scope]))
        }
    }

    /// Google's page to allow Drive. With an account already connected for something else, it's one tap
    /// there instead of signing in again.
    public func authorization(for account: String? = nil) -> GoogleAuthorization? {
        accounts?.authorization(for: [DriveAPI.scope], account: account)
    }

    /// Finishes on Google's page. The person can untick Drive there, which is said, not ignored.
    public func finish(_ authorization: GoogleAuthorization, callback: URL) async throws -> String {
        guard let accounts else { throw DriveProblem.unexpected }
        let connection: GoogleConnection
        do {
            connection = try await accounts.finish(authorization, callback: callback)
        } catch GoogleSignInError.cancelled {
            throw CancellationError()
        } catch {
            throw DriveProblem.from(error)
        }
        guard connection.allows([DriveAPI.scope]) else { throw DriveProblem.notAllowed }
        return connection.address
    }

    // MARK: Choosing folders

    /// The folders in one place of the person's Drive, for the chooser. This is the only listing that
    /// reaches beyond the linked folders, and it's never kept.
    public func folders(in place: DrivePlace, account: String) async throws -> [DriveEntry] {
        let (api, token) = try await reader(account)
        return try await api.list(place, foldersOnly: true, accessToken: token)
    }

    // MARK: Links

    /// The linked folders of every Google account still connected, in the order they were linked.
    public func links() throws -> [DriveLink] {
        guard !isClosed else { throw ReaderError.closed }
        let connected = Set(connections().map(\.address))
        return try loadLinks().filter { connected.contains($0.account) }
    }

    /// Links a folder the chooser showed. Linking it again only refreshes its name.
    @discardableResult
    public func link(_ folder: DriveEntry, account: String) throws -> DriveLink {
        guard !isClosed else { throw ReaderError.closed }
        guard folder.isFolder, DriveAPI.isID(folder.id) else { throw DriveProblem.unexpected }
        var links = try loadLinks()
        let link = DriveLink(account: account, folderID: folder.id, name: folder.name, linkedAt: now())
        if let index = links.firstIndex(where: { $0.id == link.id }) {
            links[index].name = folder.name
        } else {
            links.append(link)
        }
        try saveLinks(links)
        return links.first { $0.id == link.id } ?? link
    }

    /// Forgets a folder. Drive itself isn't touched.
    public func unlink(_ link: DriveLink) throws {
        guard !isClosed else { throw ReaderError.closed }
        try saveLinks(try loadLinks().filter { $0.id != link.id })
    }

    // MARK: Browsing linked folders

    static func key(_ account: String, _ folderID: String) -> String { account.lowercased() + "/" + folderID }

    /// What was last read of a folder inside a linked one, without asking Google. Nil when it was never
    /// read, or when it's no longer inside a linked folder.
    public func kept(_ folderID: String, account: String) throws -> DriveListing? {
        let state = try loadState()
        guard reachable(in: state).contains(Self.key(account, folderID)),
              let id = state.listings[Self.key(account, folderID)], let plain = try open(id)
        else { return nil }
        let listing = try JSONDecoder().decode(DriveListing.self, from: plain)
        guard listing.account == account.lowercased(), listing.folderID == folderID else { return nil }
        return listing
    }

    /// Reads a folder from Google and keeps it. Only a linked folder, or a folder found inside one, can
    /// be read here: the rest of the person's Drive is only ever listed on the chooser.
    @discardableResult
    public func refresh(_ folderID: String, account: String) async throws -> DriveListing {
        guard try reachable(in: loadState()).contains(Self.key(account, folderID)) else { throw DriveProblem.notFound }
        let (api, token) = try await reader(account)
        let entries = try await api.list(.folder(id: folderID, name: ""), foldersOnly: false, accessToken: token)
        let listing = DriveListing(account: account.lowercased(), folderID: folderID, entries: entries, readAt: now())
        // Unlinked while Google was answering: nothing is kept.
        var state = try loadState()
        guard reachable(in: state).contains(Self.key(account, folderID)) else { throw DriveProblem.notFound }
        let id = state.listings[Self.key(account, folderID)] ?? UUID()
        try seal(JSONEncoder().encode(listing), id: id)
        if state.listings[Self.key(account, folderID)] == nil {
            state.listings[Self.key(account, folderID)] = id
            try saveState(state)
        }
        return listing
    }

    /// Brings every linked folder up to date, and every folder inside them that was opened before, so
    /// they open instantly next time. What can't be read keeps what was there.
    public func refreshAll() async -> DriveRefresh {
        var result = DriveRefresh()
        guard !isClosed, let state = try? loadState() else { return result }
        let connections = connections()
        let allowed = Set(connections.filter(\.allowsDrive).map(\.address))
        result.needsAllowing = Set(connections.filter { !$0.allowsDrive }.map(\.address))
            .intersection(state.links.map(\.account))
        // An account disconnected elsewhere, like from Calendar, leaves nothing of its folders behind.
        let connected = Set(connections.map(\.address))
        if state.links.contains(where: { !connected.contains($0.account) }) {
            try? saveLinks(state.links.filter { connected.contains($0.account) })
        }
        var waiting = state.links.filter { allowed.contains($0.account) }.map { ($0.account, $0.folderID) }
        var done = Set<String>()
        while let (account, folderID) = waiting.first, done.count < Self.mostRefreshed {
            waiting.removeFirst()
            guard done.insert(Self.key(account, folderID)).inserted else { continue }
            do {
                let listing = try await refresh(folderID, account: account)
                // Only folders already opened once are kept fresh, not the whole tree.
                let opened = (try? loadState().listings) ?? [:]
                waiting += listing.entries.filter { $0.isFolder && opened[Self.key(account, $0.id)] != nil }.map { (account, $0.id) }
            } catch {
                let problem = DriveProblem.from(error)
                result.problems[Self.key(account, folderID)] = problem
                // An account Google took back, or a Drive API that isn't on, stops everything for it.
                if [.expired, .notAllowed, .notSetUp, .offline].contains(problem) {
                    waiting.removeAll { $0.0 == account }
                }
            }
        }
        return result
    }

    /// The most folders one quiet refresh reads, so a big tree can't keep the phone busy.
    static let mostRefreshed = 40

    /// Every folder that can be read: the linked ones, and the folders found inside them in what's kept.
    private func reachable(in state: State) -> Set<String> {
        var found = Set<String>()
        var waiting = state.links.map { Self.key($0.account, $0.folderID) }
        while let next = waiting.popLast() {
            guard found.insert(next).inserted else { continue }
            guard let id = state.listings[next], let plain = try? open(id),
                  let listing = try? JSONDecoder().decode(DriveListing.self, from: plain),
                  Self.key(listing.account, listing.folderID) == next
            else { continue }
            waiting += listing.entries.filter(\.isFolder).map { Self.key(listing.account, $0.id) }
        }
        return found
    }

    /// Drops every kept listing that's no longer inside a linked folder, like after an unlink.
    func prune() throws {
        var state = try loadState()
        let kept = reachable(in: state)
        let gone = state.listings.filter { !kept.contains($0.key) }
        guard !gone.isEmpty else { return }
        for (key, id) in gone {
            try store.delete(Self.name(id))
            state.listings[key] = nil
        }
        try saveState(state)
    }

    /// Only an account that's connected and allows Drive gets a token.
    private func reader(_ address: String) async throws -> (DriveAPI, String) {
        guard let accounts, let api else { throw DriveProblem.unexpected }
        guard !isClosed else { throw ReaderError.closed }
        do {
            return (api, try await accounts.accessToken(address, for: [DriveAPI.scope]))
        } catch {
            throw DriveProblem.from(error)
        }
    }

    // MARK: Sealed blobs

    static let linksID = UUID(derivedFrom: "totality.reader.drive.links")

    static func name(_ id: UUID) -> String { id.uuidString.lowercased() + suffix }

    /// Everything that says what's kept, in one sealed blob with a fixed ID. Every other blob has a random
    /// ID recorded here, so storage shows nothing about which folders or files they are.
    struct State: Codable {
        var links: [DriveLink] = []
        /// Each kept listing's blob, by `"account/folderID"`.
        var listings: [String: UUID] = [:]

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            links = try values.decode([DriveLink].self, forKey: .links)
            listings = try values.decodeIfPresent([String: UUID].self, forKey: .listings) ?? [:]
        }
    }

    /// A state blob this key can't open belongs to someone else, so it reads as nothing kept at all.
    func loadState() throws -> State {
        guard !isClosed else { throw ReaderError.closed }
        guard let sealed = try store.read(Self.name(Self.linksID)) else { return State() }
        guard let plain = try? ContentCipher.open(sealed, key: rootKey.objectKey(for: Self.linksID, purpose: .googleDrive), objectID: Self.linksID) else {
            return State()
        }
        return try JSONDecoder().decode(State.self, from: plain)
    }

    func saveState(_ state: State) throws {
        try seal(JSONEncoder().encode(state), id: Self.linksID)
    }

    private func loadLinks() throws -> [DriveLink] {
        try loadState().links
    }

    private func saveLinks(_ links: [DriveLink]) throws {
        var state = try loadState()
        state.links = links
        try saveState(state)
        try prune()
    }

    func seal(_ plain: Data, id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        try store.write(try ContentCipher.seal(plain, key: rootKey.objectKey(for: id, purpose: .googleDrive), objectID: id), as: Self.name(id))
    }

    func open(_ id: UUID) throws -> Data? {
        guard !isClosed else { throw ReaderError.closed }
        guard let sealed = try store.read(Self.name(id)) else { return nil }
        return try? ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: .googleDrive), objectID: id)
    }
}
