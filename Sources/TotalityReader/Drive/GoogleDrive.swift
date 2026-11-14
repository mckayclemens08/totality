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

    private struct Links: Codable {
        var links: [DriveLink]
    }

    /// A links blob this key can't open belongs to someone else, so it reads as no links at all.
    private func loadLinks() throws -> [DriveLink] {
        guard let sealed = try store.read(Self.name(Self.linksID)) else { return [] }
        guard let plain = try? ContentCipher.open(sealed, key: rootKey.objectKey(for: Self.linksID, purpose: .googleDrive), objectID: Self.linksID) else {
            return []
        }
        return try JSONDecoder().decode(Links.self, from: plain).links
    }

    private func saveLinks(_ links: [DriveLink]) throws {
        guard !isClosed else { throw ReaderError.closed }
        let sealed = try ContentCipher.seal(
            JSONEncoder().encode(Links(links: links)), key: rootKey.objectKey(for: Self.linksID, purpose: .googleDrive), objectID: Self.linksID
        )
        try store.write(sealed, as: Self.name(Self.linksID))
    }
}
