import Foundation

/// What lets Totality into one outside account: an app password for iCloud, which has no other way in,
/// or the token Google gave after the person signed in with Google. Neither one ever prints.
public enum OutsideCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case appPassword(String)
    case google(GoogleGrant)

    public var description: String {
        switch self {
        case .appPassword: "app password"
        case .google(let grant): grant.description
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// What the keychain keeps.
    var keychainData: Data {
        get throws { try JSONEncoder().encode(self) }
    }

    init(keychainData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: keychainData)
    }
}

/// What Google allowed after the person signed in: a refresh token, and whether sending was allowed as
/// well as reading. Reading is asked for when the account is added; sending is asked for separately,
/// only when its switch is turned on.
public struct GoogleGrant: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let refreshToken: String
    public let canSend: Bool

    init(refreshToken: String, canSend: Bool) {
        self.refreshToken = refreshToken
        self.canSend = canSend
    }

    public var description: String { canSend ? "Google grant to read and send" : "Google grant to read" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["canSend": canSend]) }
}
