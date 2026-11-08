import Foundation

/// An outside mail account added beside the Totality address. It never holds the app password or
/// Google's token: those stay in the keychain, and in the sealed record that syncs them.
public struct OutsideAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: OutsideProvider
    public let address: String
    /// Reading an account never lets Totality send from it. This starts off, and turning it on checks
    /// that sending works first.
    public var canSend: Bool
    public let addedAt: Date
    /// Changes made in Totality reach the provider. False only for a Gmail account added before that was
    /// asked for, until it's allowed. Worked out from the sign-in, never stored on its own.
    public internal(set) var keepsInStep = true

    private enum CodingKeys: String, CodingKey { case id, provider, address, canSend, addedAt }

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
    /// The person closed the sign-in page. Nothing changed, and there's nothing to say.
    case cancelled
    /// This build of Totality has no Google sign-in set up.
    case notSetUp
    /// Google's page was signed in to a different Google account from the one being changed.
    case differentAccount
}

/// Where outside accounts live, as the screens reach them. `ServerMailStore` is the real one.
public protocol OutsideAccountStore: Sendable {
    func outsideAccounts() async throws -> [OutsideAccount]
    /// Checks the sign-in for reading, then keeps it. Nothing is saved unless the check passes.
    func addOutside(_ signIn: OutsideSignIn) async throws -> OutsideAccount
    /// The page to sign in with Google on: to add a Gmail account, or with an id, to let it send.
    /// Throws `notSetUp` when this build has no Google sign-in.
    func googleSignIn(for id: UUID?, sending: Bool) async throws -> GoogleSignInRequest
    /// Finishes signing in with Google to add a Gmail account that reads, and nothing more.
    func addGoogle(_ request: GoogleSignInRequest, callback: URL) async throws -> OutsideAccount
    /// Finishes signing in with Google to let a Gmail account send, and turns its switch on.
    func allowGoogleSending(_ id: UUID, _ request: GoogleSignInRequest, callback: URL) async throws
    /// Finishes signing in with Google to let changes made in Totality reach a Gmail account.
    func allowGoogleChanges(_ id: UUID, _ request: GoogleSignInRequest, callback: URL) async throws
    /// Takes away the sign-in and the account on this device and, through sync, the others. Nothing at
    /// the provider is touched.
    func removeOutside(_ id: UUID) async throws
    /// Turning sending on checks that it works first. Gmail turns on through `allowGoogleSending`.
    func setOutsideSending(_ id: UUID, on: Bool) async throws
}

public enum OutsideAccountLimits {
    /// Up to three, to start with (issue 43).
    public static let most = 3
}
