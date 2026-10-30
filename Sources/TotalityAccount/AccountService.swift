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

    private func mapErrors(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            throw Self.accountError(from: error)
        }
    }

    static func accountError(from error: any Error) -> AccountError {
        switch error {
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
