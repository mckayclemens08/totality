import Foundation

/// An outside mail account added beside the Totality address. It never holds the app password: that
/// stays in the keychain, and in the sealed record that syncs it.
public struct OutsideAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: OutsideProvider
    public let address: String
    /// Reading an account never lets Totality send from it. This starts off, and turning it on checks
    /// that sending works first.
    public var canSend: Bool
    public let addedAt: Date

    public init(id: UUID = UUID(), provider: OutsideProvider, address: String, canSend: Bool = false, addedAt: Date) {
        self.id = id
        self.provider = provider
        self.address = address
        self.canSend = canSend
        self.addedAt = addedAt
    }

    /// Two entries for one mailbox would fetch everything twice.
    func isSameMailbox(as other: OutsideAccount) -> Bool {
        provider == other.provider && address.lowercased() == other.address.lowercased()
    }
}

/// Why adding or changing an outside account didn't happen.
public enum OutsideAccountError: Error, Equatable, Sendable {
    /// The provider wasn't reached or turned the sign-in down. Nothing was saved.
    case problem(OutsideMailProblem)
    case tooMany
    case alreadyAdded
    /// The account isn't here, or its sign-in is missing on this device.
    case notFound
    /// This device can't keep sign-ins, because it has no content key or keychain open.
    case unavailable
}

/// Where outside accounts live, as the screens reach them. `ServerMailStore` is the real one.
public protocol OutsideAccountStore: Sendable {
    func outsideAccounts() async throws -> [OutsideAccount]
    /// Checks the sign-in for reading, then keeps it. Nothing is saved unless the check passes.
    func addOutside(_ signIn: OutsideSignIn) async throws -> OutsideAccount
    /// Takes away the sign-in and the account on this device and, through sync, the others. Nothing at
    /// the provider is touched.
    func removeOutside(_ id: UUID) async throws
    /// Turning sending on checks that it works first.
    func setOutsideSending(_ id: UUID, on: Bool) async throws
}

public enum OutsideAccountLimits {
    /// Up to three, to start with (issue 43).
    public static let most = 3
}
