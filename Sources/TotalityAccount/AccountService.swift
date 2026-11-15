import Foundation
import Supabase
import TotalityCore
#if canImport(UIKit)
import UIKit
#endif

public enum AccountError: Error, Equatable {
    case wrongPassword
    case usernameTaken
    case weakPassword
    case backupExists
    case rateLimited
    case offline
    case failed
}

extension AccountError {
    /// Written for the person using the app. Raw server errors are never shown.
    public var message: String {
        switch self {
        case .wrongPassword: "That username and password don't match."
        case .usernameTaken: "That username is taken. Try another."
        case .weakPassword: "Choose a harder password."
        case .backupExists: "Your account already has a recovery key."
        case .rateLimited: "Too many tries. Wait a while, then try again."
        case .offline: "You're offline. Connect and try again."
        case .failed: "That didn't work. Try again."
        }
    }
}

/// What the account screens need from a backend.
public protocol AccountService: Sendable {
    func currentUsername() async -> String?
    func signUp(username: Username, password: String) async throws
    func signIn(username: Username, password: String) async throws
    func registerDevice() async throws
    func signOut() async throws -> SignOutResult
    func loadProfile() async throws -> Profile
    func saveProfile(displayName: String?, bio: String?) async throws
    /// Replaces the public photo, or removes it when given nil. Returns where the new one is.
    func updatePhoto(_ jpeg: Data?) async throws -> URL?
    /// Whether this account's public web page is up.
    func webPageIsPublished() async throws -> Bool
    /// Puts the page up from the profile as the server reads it, or takes it down.
    func setWebPage(published: Bool) async throws
    /// Someone else's profile, if they have one this account is allowed to see. Its photo has been
    /// checked and rebuilt on this device, never shown as the server's file.
    func lookUpProfile(_ username: Username) async throws -> PublicProfile?
}

public enum SignOutResult: Equatable, Sendable {
    case complete
    /// Signed out on this device, but the server never heard, so the session is still live there.
    case serverNotReached
}

public struct SupabaseAccountService: AccountService {
    let client: SupabaseClient
    private let deviceStore: any KeyStore

    public init(config: AccountConfig, sessionStore: any KeyStore, deviceStore: any KeyStore) {
        self.deviceStore = deviceStore
        client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: SessionStorage(store: sessionStore),
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    /// A current sign-in token for the web search gateway. It's refreshed here if it has expired.
    public func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    public func currentUsername() async -> String? {
        client.auth.currentSession?.user.email.flatMap { Username(address: $0)?.value }
    }

    /// With confirmation off the server signs the new account straight in. No session means it didn't.
    public func signUp(username: Username, password: String) async throws {
        try await mapErrors {
            let response = try await client.auth.signUp(email: username.address, password: password)
            guard response.session != nil else { throw AccountError.failed }
        }
    }

    public func signIn(username: Username, password: String) async throws {
        try await mapErrors { try await client.auth.signIn(email: username.address, password: password) }
    }

    /// Adds this device once. The row-level rules tie it to the signed-in user.
    public func registerDevice() async throws {
        try await mapErrors {
            let owner = try await client.auth.session.user.id
            let key = try DeviceKey.publicKey(in: deviceStore)
            let encoded = "\\x" + key.map { String(format: "%02x", $0) }.joined()
            let existing: [Registered] = try await client.from("devices")
                .select("id")
                .eq("device_pub", value: encoded)
                .execute()
                .value
            guard existing.isEmpty else { return }
            let name = await Self.deviceName
            try await client.from("devices")
                .insert(NewDevice(owner_id: owner, name: name, platform: Self.platform, device_pub: encoded))
                .execute()
        }
    }

    /// The SDK deletes the local session before it calls the server, so a failure there leaves the
    /// session live on the server. Checking first means being offline changes nothing.
    public func signOut() async throws -> SignOutResult {
        do {
            _ = try await client.auth.user()
        } catch AuthError.sessionMissing {
            return .complete
        } catch {
            let mapped = Self.accountError(from: error)
            if mapped == .offline { throw mapped }
        }
        do {
            try await client.auth.signOut(scope: .local)
            return .complete
        } catch AuthError.sessionMissing {
            return .complete
        } catch {
            return .serverNotReached
        }
    }

    /// Makes the profile the first time it's needed. The handle is the username, so there's nothing
    /// to ask. Two devices can race here, and whichever loses just reads what the other made.
    public func loadProfile() async throws -> Profile {
        try await mapErrors {
            let session = try await client.auth.session
            if let row = try await profileRow(of: session.user.id) { return try profile(from: row) }
            guard let username = session.user.email.flatMap({ Username(address: $0) }) else { throw AccountError.failed }
            do {
                try await client.rpc("claim_handle", params: ["p_handle": username.value]).execute()
            } catch let error as PostgrestError where error.code == "23505" {}
            guard let row = try await profileRow(of: session.user.id) else { throw AccountError.failed }
            return try profile(from: row)
        }
    }

    public func saveProfile(displayName: String?, bio: String?) async throws {
        try await mapErrors {
            let owner = try await client.auth.session.user.id
            let edit: [String: AnyJSON] = [
                "display_name": displayName.map(AnyJSON.string) ?? .null,
                "bio": bio.map(AnyJSON.string) ?? .null,
            ]
            try await client.from("profiles").update(edit).eq("id", value: owner.uuidString).execute()
        }
    }

    /// Photos get a new name each time, so a cached old one can't show. Removing has to really remove
    /// the file, so that goes first and a failure counts. When replacing, the swap has already worked
    /// by then, and a failed delete only leaves an unused file behind.
    public func updatePhoto(_ jpeg: Data?) async throws -> URL? {
        try await mapErrors {
            let owner = try await client.auth.session.user.id
            let previous = try await profileRow(of: owner)?.avatar_key
            var key: String?
            if let jpeg {
                let path = "\(owner.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                _ = try await photos.upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
                key = path
            } else if let previous {
                _ = try await photos.remove(paths: [previous])
            }
            let edit: [String: AnyJSON] = ["avatar_key": key.map(AnyJSON.string) ?? .null]
            try await client.from("profiles").update(edit).eq("id", value: owner.uuidString).execute()
            if jpeg != nil, let previous { _ = try? await photos.remove(paths: [previous]) }
            return try key.map(photoURL)
        }
    }

    public func webPageIsPublished() async throws -> Bool {
        try await mapErrors { try await askProfileServer("mine", method: "GET") }
    }

    public func setWebPage(published: Bool) async throws {
        try await mapErrors {
            let now = try await askProfileServer(published ? "publish" : "unpublish", method: "POST")
            guard now == published else { throw AccountError.failed }
        }
    }

    public func lookUpProfile(_ username: Username) async throws -> PublicProfile? {
        try await otherProfiles([username], photos: [:])[username.value]
    }

    /// Several people's profiles in one query, so keeping a chat list's faces fresh costs one request.
    /// A photo is downloaded only when its file name isn't among `photos`, which are already rebuilt here.
    func otherProfiles(_ usernames: [Username], photos known: [String: Data]) async throws -> [String: PublicProfile] {
        let handles = Array(Set(usernames.map(\.value))).sorted()
        guard !handles.isEmpty else { return [:] }
        var rows: [OtherProfileRow] = []
        // A long list goes in parts, so the query stays a sensible length.
        for start in stride(from: 0, to: handles.count, by: 100) {
            let part = Array(handles[start..<min(start + 100, handles.count)])
            rows += try await mapErrors {
                try await client.from("profiles")
                    .select("id, handle, display_name, bio, avatar_key")
                    .in("handle", values: part)
                    .execute()
                    .value as [OtherProfileRow]
            }
        }
        return await withTaskGroup(of: PublicProfile?.self) { group in
            for row in rows where handles.contains(row.handle) {
                group.addTask {
                    // Only a file in the profile owner's own folder, named the way this app names it, is used.
                    guard let key = row.avatar_key, AvatarKey.isOwned(key, by: row.id) else {
                        return PublicProfile(username: row.handle, displayName: row.display_name, bio: row.bio, photo: nil)
                    }
                    var photo = known[key]
                    if photo == nil, let url = try? photoURL(key) { photo = await AvatarDownload.fetch(url) }
                    // A failed download keeps no name, so the next refresh tries again.
                    return PublicProfile(
                        username: row.handle, displayName: row.display_name, bio: row.bio, photo: photo,
                        photoKey: photo == nil ? nil : key
                    )
                }
            }
            var found: [String: PublicProfile] = [:]
            for await case let profile? in group { found[profile.username] = profile }
            return found
        }
    }

    private struct OtherProfileRow: Decodable, Sendable {
        let id: UUID
        let handle: String
        let display_name: String?
        let bio: String?
        let avatar_key: String?
    }

    /// The profile server answers with whether the page is up. It takes the username from the sign-in.
    private func askProfileServer(_ action: String, method: String) async throws -> Bool {
        var request = URLRequest(url: Self.profileServer.appending(path: "profile/\(action)"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AccountError.failed }
        guard status == 200 else { throw status == 429 ? AccountError.rateLimited : AccountError.failed }
        return try JSONDecoder().decode(PageState.self, from: data).published
    }

    private static let profileServer = URL(string: "https://\(MailDomain.name)")!

    private struct PageState: Decodable {
        let published: Bool
    }

    private var photos: StorageFileApi { client.storage.from("avatars") }

    private func photoURL(_ key: String) throws -> URL {
        try photos.getPublicURL(path: key)
    }

    private func profileRow(of owner: UUID) async throws -> ProfileRow? {
        let rows: [ProfileRow] = try await client.from("profiles")
            .select("handle, display_name, bio, avatar_key")
            .eq("id", value: owner.uuidString)
            .execute()
            .value
        return rows.first
    }

    private func profile(from row: ProfileRow) throws -> Profile {
        Profile(username: row.handle, displayName: row.display_name, bio: row.bio, avatarURL: try row.avatar_key.map(photoURL))
    }

    private struct ProfileRow: Decodable {
        let handle: String
        let display_name: String?
        let bio: String?
        let avatar_key: String?
    }

    private struct Registered: Decodable {
        let id: UUID
    }

    private struct NewDevice: Encodable {
        let owner_id: UUID
        let name: String
        let platform: String
        let device_pub: String
    }

    // The model name only. A device's own name often holds its owner's real name.
    @MainActor private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    private static var platform: String {
        #if os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    @discardableResult
    func mapErrors<Result>(_ work: () async throws -> Result) async throws -> Result {
        do {
            return try await work()
        } catch {
            throw Self.accountError(from: error)
        }
    }

    static func accountError(from error: any Error) -> AccountError {
        switch error {
        case let error as AccountError:
            return error
        case let error as URLError:
            let offline: Set<URLError.Code> = [
                .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
            ]
            return offline.contains(error.code) ? .offline : .failed
        case let error as AuthError:
            switch error.errorCode {
            case .invalidCredentials: return .wrongPassword
            case .userAlreadyExists, .emailExists: return .usernameTaken
            case .weakPassword: return .weakPassword
            case .overRequestRateLimit: return .rateLimited
            default: return .failed
            }
        default:
            return .failed
        }
    }
}

extension SupabaseAccountService: ProfileDirectory {
    public func profiles(of usernames: [String], photos: [String: Data]) async throws -> [String: PublicProfile] {
        try await otherProfiles(usernames.compactMap { Username($0) }, photos: photos)
    }
}

/// Where someone's photo may be: in their own folder, under a name this app gives it. Anything else in
/// the column is ignored, so a crafted value can't point the device at another file or path.
enum AvatarKey {
    static func isOwned(_ key: String, by owner: UUID) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == owner.uuidString.lowercased() else { return false }
        return parts[1].wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg/) != nil
    }
}

/// Downloads another person's photo with a size cap, then hands the bytes to `SafeAvatar`.
enum AvatarDownload {
    static func fetch(_ url: URL, session: URLSession = .shared) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(SafeAvatar.maximumBytes)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > SafeAvatar.maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        return SafeAvatar.prepare(data)
    }
}
