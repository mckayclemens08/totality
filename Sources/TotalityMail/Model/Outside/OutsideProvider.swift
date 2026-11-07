import Foundation

/// An outside mail service the device connects to directly, the way Apple Mail does. Totality's server is
/// never in the path. Each provider's servers are fixed here, so nothing a person types, and nothing a
/// message or a server says, can point a sign-in anywhere else. Outlook isn't here: Microsoft's sign-in
/// needs an app registration that isn't confirmed to cost nothing (issue 43, trial of 2026-11-05).
public enum OutsideProvider: String, Codable, CaseIterable, Sendable {
    case icloud
    case gmail

    public var name: String {
        switch self {
        case .icloud: "iCloud"
        case .gmail: "Gmail"
        }
    }

    /// Who keeps the mail at the other end, and can read it.
    public var keeper: String {
        switch self {
        case .icloud: "Apple"
        case .gmail: "Google"
        }
    }

    /// Where reading happens: IMAP, with TLS from the first byte.
    public var reading: OutsideEndpoint {
        switch self {
        case .icloud: OutsideEndpoint(host: "imap.mail.me.com", port: 993, security: .tls)
        case .gmail: OutsideEndpoint(host: "imap.gmail.com", port: 993, security: .tls)
        }
    }

    /// Where sending happens: SMTP submission, which has to switch to TLS before anything is signed in.
    public var sending: OutsideEndpoint {
        switch self {
        case .icloud: OutsideEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .gmail: OutsideEndpoint(host: "smtp.gmail.com", port: 587, security: .startTLS)
        }
    }

    /// The provider's own page on making an app password, which is the only password Totality takes.
    public var appPasswordHelp: URL {
        switch self {
        case .icloud: URL(string: "https://support.apple.com/en-us/102654")!
        case .gmail: URL(string: "https://support.google.com/accounts/answer/185833")!
        }
    }
}

/// One of a provider's published servers. Only `OutsideProvider` makes these.
public struct OutsideEndpoint: Equatable, Sendable {
    public enum Security: Equatable, Sendable {
        /// TLS before anything else is said.
        case tls
        /// Starts plain and must switch to TLS before signing in. A server that won't switch is never sent a password.
        case startTLS
    }

    public let host: String
    public let port: Int
    public let security: Security

    fileprivate init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// An address and app password for one outside account. The password never prints: not in a log, a
/// crash report, a test failure, or a debugger's description.
public struct OutsideSignIn: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let provider: OutsideProvider
    public let address: String
    let appPassword: String

    /// Nil when either can't be right, so it never reaches a server. App passwords are shown with
    /// spaces between groups, which aren't part of them.
    public init?(provider: OutsideProvider, address: String, appPassword: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appPassword.filter { !$0.isWhitespace }
        guard Self.isAddress(address), (1...256).contains(password.count),
              password.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.provider = provider
        self.address = address
        self.appPassword = password
    }

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard text.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
                && !"\"()<>[]\\,;:".unicodeScalars.contains($0)
        }
    }

    /// SASL PLAIN, as both IMAP and SMTP take it: no authorization name, then the address and password.
    var plain: String {
        Data("\0\(address)\0\(appPassword)".utf8).base64EncodedString()
    }

    public var description: String { "\(provider.name) sign-in for \(address)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider, "address": address]) }
}
