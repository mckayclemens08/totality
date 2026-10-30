import Foundation
import Supabase
import TotalityCore
#if canImport(UIKit)
import UIKit
#endif

/// The address the email link returns to. PKCE makes a link useless to any app but the one that
/// requested it, which stops another app using a link Totality asked for. It does not stop an app
/// that claims this scheme from starting its own request and catching the reply, so this is a
/// stopgap for one person's devices. See proposal §11-N before anyone else signs in.
public enum SignInLink {
    public static let callback = URL(string: "app.totality.client://auth/callback")!

    public static func isCallback(_ url: URL) -> Bool {
        url.scheme == callback.scheme && url.host == callback.host && url.path == callback.path
    }
}

public enum AccountError: Error, Equatable {
    case invalidLink
    case rateLimited
    case offline
    case failed
}

extension AccountError {
    /// Written for the person using the app. Raw server errors are never shown.
    public var message: String {
        switch self {
        case .invalidLink: "That link has expired or was already used. Ask for a new one."
        case .rateLimited: "Too many tries. Wait a while, then try again."
        case .offline: "You're offline. Connect and try again."
        case .failed: "That didn't work. Try again."
        }
    }
}

/// What the account screens need from a backend.
public protocol AccountService: Sendable {
    func currentEmail() async -> String?
    func requestLink(email: String) async throws
    func finishSignIn(from url: URL) async throws -> String?
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
                    redirectToURL: SignInLink.callback,
                    flowType: .pkce,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    public func currentEmail() async -> String? {
        client.auth.currentSession?.user.email
    }

    public func requestLink(email: String) async throws {
        try await mapErrors { try await client.auth.signInWithOTP(email: email, redirectTo: SignInLink.callback) }
    }

    public func finishSignIn(from url: URL) async throws -> String? {
        var email: String?
        try await mapErrors { email = try await client.auth.session(from: url).user.email }
        return email
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

    private static func accountError(from error: any Error) -> AccountError {
        switch error {
        case let error as URLError:
            let offline: Set<URLError.Code> = [
                .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
            ]
            return offline.contains(error.code) ? .offline : .failed
        case AuthError.pkceGrantCodeExchange:
            return .invalidLink
        case let error as AuthError:
            switch error.errorCode {
            case .otpExpired, .flowStateExpired, .flowStateNotFound, .badCodeVerifier: return .invalidLink
            case .overEmailSendRateLimit, .overRequestRateLimit: return .rateLimited
            default: return .failed
            }
        default:
            return .failed
        }
    }
}
