import Foundation
import Observation

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

    public private(set) var phase = Phase.loading
    public private(set) var isWorking = false
    /// False after sign-in if this device could not be added. Signing in still counts.
    public private(set) var deviceRegistered = false
    public var notice: String?

    private let service: any AccountService

    public init(service: any AccountService) {
        self.service = service
    }

    public func load() async {
        if let username = await service.currentUsername() {
            phase = .signedIn(username: username)
            await registerDevice()
        } else {
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
            phase = .signedIn(username: name.value)
        }
        if case .signedIn = phase { await registerDevice() }
    }

    /// Passwords stay out of the model. A typo here can't be fixed later, so it's typed twice.
    public func signUp(username: String, password: String, confirmation: String) async {
        guard let name = Username(username) else {
            notice = "Use 3 to 24 letters, numbers, or underscores for your username."
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
            phase = .signedIn(username: name.value)
        }
        if case .signedIn = phase { await registerDevice() }
    }

    public func signOut() async {
        await run {
            let result = try await service.signOut()
            phase = .signedOut
            deviceRegistered = false
            if result == .serverNotReached {
                notice = "You're signed out on this device, but the server couldn't be reached to end the session."
            }
        }
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
