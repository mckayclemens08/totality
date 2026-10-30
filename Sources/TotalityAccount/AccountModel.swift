import Foundation
import Observation

/// What the account screens show. Signing in and out never touches notes or their keys.
@MainActor
@Observable
public final class AccountModel {
    public enum Phase: Equatable {
        case loading
        case signedOut
        case awaitingLink(email: String)
        case signedIn(email: String)
    }

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
        if let email = await service.currentEmail() {
            phase = .signedIn(email: email)
            await registerDevice()
        } else if case .awaitingLink = phase {
            return
        } else {
            phase = .signedOut
        }
    }

    public func sendLink(to email: String) async {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(cleaned) else {
            notice = "Enter your full email address."
            return
        }
        await run {
            try await service.requestLink(email: cleaned)
            phase = .awaitingLink(email: cleaned)
        }
    }

    /// The phase can't be relied on here: iOS may close the app while the person is in Mail. PKCE is
    /// what decides, because only the device holding the matching secret can redeem a link.
    public func finishSignIn(from url: URL) async {
        guard SignInLink.isCallback(url) else { return }
        var requested: String?
        switch phase {
        case .signedIn: return
        case .awaitingLink(let email): requested = email
        case .loading, .signedOut: break
        }
        await run {
            let confirmed = try await service.finishSignIn(from: url)
            phase = .signedIn(email: confirmed ?? requested ?? "your account")
        }
        if case .signedIn = phase { await registerDevice() }
    }

    public func startOver() {
        phase = .signedOut
        notice = nil
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

    private static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !text.contains(where: \.isWhitespace)
    }
}
