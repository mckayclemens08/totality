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
/// sign-in. The device talks to Google directly. Totality's server never sees Drive files or the token,
/// and nothing from a file reaches Supabase unless the person imports it.
///
/// What's kept here is sealed with the content key, in its own folder. The links and the files opened
/// from them sync as one sealed record, so the server holds them but can't read them; listings, downloaded
/// files and the sign-in stay on each device, which reads Google itself. Everything belongs to whoever owns
/// the key, so another person on this device opens none of it.
public actor GoogleDrive {
    public static let suffix = ".gdrive"
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .googleDrive, sharedSuffix: .googleDrive]

    let accounts: GoogleAccounts?
    private let api: DriveAPI?
    let store: any BlobStore
    /// Where opened files are kept, apart from the rest because it's only a cache: it isn't carried
    /// through a key move, and anything in it this key can't open is cleared away.
    let cache: (any BlobStore)?
    let rootKey: ContentRootKey
    let now: @Sendable () -> Date
    private(set) var isClosed = false
    /// A conflict's merge, written when sync stores the other side's copy.
    var pendingMerge: SealedRecordStore<DriveShared>.Pending?

    /// `accounts` is nil when this build has no Google sign-in.
    public init(
        accounts: GoogleAccounts?, store: any BlobStore, cache: (any BlobStore)? = nil, rootKey: ContentRootKey,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accounts = accounts
        api = accounts.map { DriveAPI(signIn: $0.signIn) }
        self.store = store
        self.cache = cache
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

    /// Every linked folder, including those of accounts linked on another device and not connected here,
    /// which show "Connect to see".
    public func allLinks() throws -> [DriveLink] {
        guard !isClosed else { throw ReaderError.closed }
        return try loadLinks()
    }

    /// Links a folder the chooser showed. Linking it again only refreshes its name.
    @discardableResult
    public func link(_ folder: DriveEntry, account: String) throws -> DriveLink {
        guard !isClosed else { throw ReaderError.closed }
        guard folder.isFolder, DriveAPI.isID(folder.id) else { throw DriveProblem.unexpected }
        var state = try loadState()
        let link = DriveLink(account: account, folderID: folder.id, name: folder.name, linkedAt: now())
        if let index = state.links.firstIndex(where: { $0.id == link.id }) {
            state.links[index].name = folder.name
        } else {
            state.links.append(link)
        }
        // Connected here, so a disconnection here later is noticed.
        state.seen.insert(link.account)
        try saveState(state)
        try prune()
        return state.links.first { $0.id == link.id } ?? link
    }

    /// Forgets a folder, on every device, and the files opened from it. Drive itself isn't touched.
    public func unlink(_ link: DriveLink) throws {
        guard !isClosed else { throw ReaderError.closed }
        var state = try loadState()
        let inside = Set(listedFiles(in: state, under: [Self.key(link.account, link.folderID)]).keys)
        state.links.removeAll { $0.id == link.id }
        state.recent.removeAll { inside.contains($0.key) }
        try saveState(state)
        try prune()
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
        var changed = state.listings[Self.key(account, folderID)] == nil
        state.listings[Self.key(account, folderID)] = id
        // A file renamed in Drive shows its new name on the home tile, on every device.
        let names = Dictionary(entries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for (index, entry) in state.recent.enumerated() where !entry.isFolder && entry.account == listing.account {
            guard let name = names[entry.id], name != entry.title else { continue }
            state.recent[index] = DriveRecent(id: entry.id, account: entry.account, title: name, mime: entry.mime, openedAt: entry.openedAt)
            changed = true
        }
        if changed { try saveState(state) }
        return listing
    }

    /// Brings every linked folder up to date, and every folder inside them that was opened before, so
    /// they open instantly next time. What can't be read keeps what was there. `onlyChanged` asks Drive
    /// what changed since last time first, and reads only the folders that did; without a starting point
    /// yet, or when Drive has lost it, it reads them all.
    public func refreshAll(onlyChanged: Bool = false) async -> DriveRefresh {
        var result = DriveRefresh()
        try? publishHeld(force: false)
        guard !isClosed, var state = try? loadState() else { return result }
        let connections = connections()
        let allowed = Set(connections.filter(\.allowsDrive).map(\.address))
        result.needsAllowing = Set(connections.filter { !$0.allowsDrive }.map(\.address))
            .intersection(state.links.map(\.account))
        // An account disconnected here from somewhere else, like Calendar, leaves nothing of its folders
        // behind, on any device. One that was never connected here is another device's, and stays.
        let connected = Set(connections.map(\.address))
        if state.seen != connected {
            try? noticeConnections(connected)
            state = (try? loadState()) ?? state
        }
        var budget = Self.mostRefreshed
        for account in Set(state.links.map(\.account)).intersection(allowed).sorted() {
            let roots = state.links.filter { $0.account == account }.map(\.folderID)
            var only: Set<String>?
            var next: String?
            if onlyChanged, let token = state.changeTokens[account] {
                do {
                    let (api, access) = try await reader(account)
                    if let changes = try await api.changes(since: token, accessToken: access) {
                        next = changes.next
                        only = changedFolders(changes, account: account, in: state)
                    }
                } catch DriveProblem.notFound {
                    // Drive no longer has that starting point. Everything is read again below.
                } catch {
                    for root in roots { result.problems[Self.key(account, root)] = DriveProblem.from(error) }
                    continue
                }
            }
            if next == nil {
                // Taken before reading, so a change made while the folders are read is caught next time.
                if let (api, access) = try? await reader(account) {
                    next = try? await api.startPageToken(accessToken: access)
                }
            }
            if only?.isEmpty == true {
                if let next { try? saveChangeToken(next, for: account) }
                continue
            }
            let read = await refreshTree(account, roots: roots, only: only, budget: &budget, result: &result)
            if read, let next { try? saveChangeToken(next, for: account) }
        }
        return result
    }

    /// Reads one account's linked folders and the opened folders inside them, or only those in `only`.
    /// False when something couldn't be read, so the same changes are asked for again next time.
    private func refreshTree(
        _ account: String, roots: [String], only: Set<String>?, budget: inout Int, result: inout DriveRefresh
    ) async -> Bool {
        var waiting = roots
        var done = Set<String>()
        var complete = true
        while !waiting.isEmpty {
            let folderID = waiting.removeFirst()
            guard done.insert(folderID).inserted else { continue }
            let listing: DriveListing
            if only == nil || only?.contains(folderID) == true {
                guard budget > 0 else { return false }
                budget -= 1
                do {
                    listing = try await refresh(folderID, account: account)
                } catch {
                    let problem = DriveProblem.from(error)
                    result.problems[Self.key(account, folderID)] = problem
                    complete = false
                    // An account Google took back, or a Drive API that isn't on, stops everything for it.
                    if [.expired, .notAllowed, .notSetUp, .offline].contains(problem) { return false }
                    continue
                }
            } else {
                guard let kept = try? kept(folderID, account: account) else { continue }
                listing = kept
            }
            // Only folders already opened once are kept fresh, not the whole tree.
            let opened = (try? loadState().listings) ?? [:]
            waiting += listing.entries.filter { $0.isFolder && opened[Self.key(account, $0.id)] != nil }.map(\.id)
        }
        return complete
    }

    /// The kept folders of one account that a list of changes reaches: the ones changed files are in
    /// now, the ones that changed themselves, and the ones that listed a file that moved away or went.
    func changedFolders(_ changes: DriveChanges, account: String, in state: State) -> Set<String> {
        var found = Set<String>()
        for key in reachable(in: state) {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == account else { continue }
            let folderID = parts[1]
            // Linked since the last full read, so never listed yet.
            if changes.parents.contains(folderID) || changes.touched.contains(folderID) || state.listings[key] == nil {
                found.insert(folderID)
                continue
            }
            guard let id = state.listings[key], let plain = try? open(id),
                  let listing = try? JSONDecoder().decode(DriveListing.self, from: plain)
            else { continue }
            if listing.entries.contains(where: { changes.touched.contains($0.id) }) { found.insert(folderID) }
        }
        return found
    }

    private func saveChangeToken(_ token: String, for account: String) throws {
        var state = try loadState()
        // Disconnected while Google was answering: nothing is kept for it.
        guard state.seen.contains(account) || state.links.contains(where: { $0.account == account }) else { return }
        state.changeTokens[account] = token
        try saveState(state)
    }

    /// How long opens wait before they go into the shared record, at most.
    static let holdOpens: TimeInterval = 5 * 60

    /// Sends opens that are waiting into the shared record, for when the app goes to the background, or
    /// once the oldest has waited `holdOpens`.
    public func publishHeld(force: Bool = true) throws {
        guard !isClosed else { return }
        var state = try loadState()
        guard let since = state.heldSince else { return }
        guard force || now().timeIntervalSince(since) >= Self.holdOpens else { return }
        state.publishNow = true
        try saveState(state)
    }

    /// The most folders one quiet refresh reads, so a big tree can't keep the phone busy.
    static let mostRefreshed = 40

    /// Forgets every account that was connected here and isn't now, and remembers the ones that are.
    func noticeConnections(_ connected: Set<String>) throws {
        var state = try loadState()
        let gone = state.seen.subtracting(connected)
        for account in gone {
            state.forgotten[account] = now()
            state.links.removeAll { $0.account == account }
            state.recent.removeAll { $0.account == account }
            state.changeTokens[account] = nil
        }
        state.seen = connected
        try saveState(state)
        if !gone.isEmpty { try prune() }
    }

    /// Every folder that can be read: the linked ones, and the folders found inside them in what's kept.
    func reachable(in state: State, from roots: [String]? = nil) -> Set<String> {
        var found = Set<String>()
        var waiting = roots ?? state.links.map { Self.key($0.account, $0.folderID) }
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

    /// Whether a folder, as `"account/folderID"`, is a linked one or inside one.
    func reachableFolder(_ key: String) throws -> Bool {
        reachable(in: try loadState()).contains(key)
    }

    /// Drops every kept listing that's no longer inside a linked folder, like after an unlink, and what
    /// the home tile remembered from it.
    func prune() throws {
        var state = try loadState()
        let kept = reachable(in: state)
        let gone = state.listings.filter { !kept.contains($0.key) }
        let goneFiles = state.files.filter { !kept.contains($0.value.folderKey) }
        let recent = prunedRecent(state)
        guard !gone.isEmpty || !goneFiles.isEmpty || recent != state.recent else { return }
        state.recent = recent
        for (key, id) in gone {
            try store.delete(Self.name(id))
            state.listings[key] = nil
        }
        for (key, file) in goneFiles {
            try cache?.delete(Self.fileName(file.blob))
            state.files[key] = nil
        }
        try saveState(state)
    }

    /// Only an account that's connected and allows Drive gets a token.
    func reader(_ address: String) async throws -> (DriveAPI, String) {
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

    /// Everything that says what's kept. The links and opened files are the shared record, which syncs;
    /// the rest is this device's own, in one sealed blob with a fixed ID. Every other blob has a random ID
    /// recorded here, so storage shows nothing about which folders or files they are.
    struct State {
        var links: [DriveLink] = []
        /// Each kept listing's blob, by `"account/folderID"`.
        var listings: [String: UUID] = [:]
        /// Files kept on the device after they were opened, by `"account/fileID"`.
        var files: [String: CachedFile] = [:]
        /// Opened files and linked folders, newest first, for the home tile.
        var recent: [DriveRecent] = []
        /// When each account was disconnected, for every device.
        var forgotten: [String: Date] = [:]
        /// Where Drive's list of changes was last read up to, by account. This device's own.
        var changeTokens: [String: String] = [:]
        /// Accounts this device has had connected, so one disconnected here is told apart from one that
        /// was never connected here.
        var seen: Set<String> = []
        /// The shared record as it was read, so a save knows what was removed.
        var base: DriveShared?
        /// Since when opens have waited to go into the shared record.
        var heldSince: Date?
        /// Set to send held opens now, as the app goes to the background.
        var publishNow = false

        init() {}
    }

    /// This device's part, as it's written.
    struct LocalState: Codable {
        var listings: [String: UUID] = [:]
        var files: [String: CachedFile] = [:]
        var changeTokens: [String: String] = [:]
        var seen: Set<String> = []
        /// Opens not yet in the shared record, so the server can't tell when each one happened.
        var heldRecent: [DriveRecent] = []
        var heldSince: Date?
        /// From before links synced. Moved into the shared record on the first save.
        var links: [DriveLink]?
        var recent: [DriveRecent]?

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            listings = try values.decodeIfPresent([String: UUID].self, forKey: .listings) ?? [:]
            files = try values.decodeIfPresent([String: CachedFile].self, forKey: .files) ?? [:]
            changeTokens = try values.decodeIfPresent([String: String].self, forKey: .changeTokens) ?? [:]
            seen = try values.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
            heldRecent = try values.decodeIfPresent([DriveRecent].self, forKey: .heldRecent) ?? []
            heldSince = try values.decodeIfPresent(Date.self, forKey: .heldSince)
            links = try values.decodeIfPresent([DriveLink].self, forKey: .links)
            recent = try values.decodeIfPresent([DriveRecent].self, forKey: .recent)
        }
    }

    /// A state blob this key can't open belongs to someone else, so it reads as nothing kept at all.
    func loadState() throws -> State {
        guard !isClosed else { throw ReaderError.closed }
        var local = LocalState()
        if let sealed = try store.read(Self.name(Self.linksID)),
           let plain = try? ContentCipher.open(sealed, key: rootKey.objectKey(for: Self.linksID, purpose: .googleDrive), objectID: Self.linksID) {
            local = try JSONDecoder().decode(LocalState.self, from: plain)
        }
        let saved = try loadShared()
        var shared = saved ?? DriveShared()
        if local.links != nil || local.recent != nil {
            shared = DriveShared.merged(shared, DriveShared(links: local.links ?? [], recent: local.recent ?? []))
        }
        var state = State()
        state.links = shared.links
        state.recent = DriveShared(links: shared.links, recent: shared.recent + local.heldRecent, removed: shared.removed, forgotten: shared.forgotten)
            .normalized().recent
        state.heldSince = local.heldSince
        state.forgotten = shared.forgotten
        state.listings = local.listings
        state.files = local.files
        state.changeTokens = local.changeTokens
        state.seen = local.seen
        // What's on disk, so links carried over from before differ from it and get written.
        state.base = saved
        return state
    }

    func saveState(_ state: State) throws {
        var local = LocalState()
        local.listings = state.listings
        local.files = state.files
        local.changeTokens = state.changeTokens
        local.seen = state.seen
        let before = (state.base ?? DriveShared()).normalized()
        var next = DriveShared(links: state.links, recent: state.recent, removed: before.removed, forgotten: state.forgotten)
        next = before.changed(to: next, at: now())
        // Opening something only adds to what was opened. That waits, so what reaches the server says
        // nothing about when each file was opened. Linking, unlinking and disconnecting go at once.
        let onlyOpened = state.base != nil && next.links == before.links && next.removed == before.removed
            && next.forgotten == before.forgotten
        let due = state.publishNow || state.heldSince.map { now().timeIntervalSince($0) >= Self.holdOpens } == true
        if onlyOpened, !due {
            local.heldRecent = next.recent.filter { !before.recent.contains($0) }
            local.heldSince = local.heldRecent.isEmpty ? nil : (state.heldSince ?? now())
        } else if state.base == nil ? (next != DriveShared()) : (next != before) {
            // Written only when it changed, so a save of this device's own part doesn't send it again.
            try writeShared(next)
        }
        try seal(JSONEncoder().encode(local), id: Self.linksID)
    }

    private func loadLinks() throws -> [DriveLink] {
        try loadState().links
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
