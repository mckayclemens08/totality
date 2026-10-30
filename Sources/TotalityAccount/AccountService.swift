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
}

public enum SignOutResult: Equatable, Sendable {
    case complete
    /// Signed out on this device, but the server never heard, so the session is still live there.
    case serverNotReached
}

public struct SupabaseAccountService: AccountService {
    private let client: SupabaseClient
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

    private func mapErrors<Result>(_ work: () async throws -> Result) async throws -> Result {
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
