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
    /// Allowed to change mail at Gmail. Grants from before that was asked for can only read.
    public let canChange: Bool

    init(refreshToken: String, canSend: Bool, canChange: Bool = true) {
        self.refreshToken = refreshToken
        self.canSend = canSend
        self.canChange = canChange
    }

    private enum CodingKeys: String, CodingKey { case refreshToken, canSend, canChange }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        canSend = try container.decode(Bool.self, forKey: .canSend)
        canChange = try container.decodeIfPresent(Bool.self, forKey: .canChange) ?? false
    }

    public var description: String { "Google grant to read\(canChange ? ", change" : "")\(canSend ? ", send" : "")" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["canSend": canSend, "canChange": canChange]) }
}
