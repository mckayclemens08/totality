import Foundation
import Security

/// One Google account connected to Totality on this device: the one refresh token Google gave for it,
/// and every scope that token carries. Mail, Calendar, and Photos all use the same one, so the person
/// signs in to Google once (owner, 2026-11-08, issue 76). The token never prints.
public struct GoogleConnection: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let address: String
    package let refreshToken: String
    public let granted: Set<String>

    package init(address: String, refreshToken: String, granted: Set<String>) {
        self.address = address.lowercased()
        self.refreshToken = refreshToken
        self.granted = granted
    }

    /// Whether this connection already lets a module do what it needs.
    public func allows(_ scopes: [String]) -> Bool { scopes.allSatisfy(granted.contains) }

    public var description: String { "Google connection" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["granted": granted.sorted()]) }
}

/// Every Google account connected on this device, kept in the Keychain and nowhere else: out of iCloud
/// Keychain and backups, readable only while the device is unlocked. Each module asks for only its own
/// scopes, on the same connection, so a module turned on later is one consent tap, not a second sign-in.
///
/// Taking a token back at Google takes back every scope that Google account gave Totality, so
/// `disconnect` ends the account for every module, and a screen offering it has to say so first.
public struct GoogleAccounts: Sendable {
    public static let service = "app.totality.google"
    /// Who the account is, so a connection can be told apart from another without any module's own API.
    /// Both are Google's basic, non-sensitive scopes.
    public static let identityScopes = ["openid", "email"]
    private static let indexName = "connected"

    public let signIn: GoogleSignIn
    private let keychain: any KeyStore

    public init(signIn: GoogleSignIn, keychain: any KeyStore = KeychainKeyStore(service: GoogleAccounts.service)) {
        self.signIn = signIn
        self.keychain = keychain
    }

    // MARK: What's connected

    /// Every connected account, in the order they were connected. One that won't read is left out.
    public func connections() throws -> [GoogleConnection] {
        try addresses().compactMap { try? connection($0) }
    }

    public func connection(_ address: String) throws -> GoogleConnection? {
        guard let data = try keychain.load(Self.name(address)) else { return nil }
        return try JSONDecoder().decode(GoogleConnection.self, from: data)
    }

    // MARK: Connecting

    /// Google's page for a module's scopes. With no account the person chooses one, and Google asks for
    /// every scope at once. With an account already connected, Google goes straight to it and keeps what
    /// it already gave, so the person taps once to allow the new scopes.
    public func authorization(for scopes: [String], account: String? = nil) -> GoogleAuthorization {
        var asked = scopes
        for scope in Self.identityScopes where !asked.contains(scope) { asked.append(scope) }
        return signIn.authorization(scopes: asked, account: account, includeGranted: true)
    }

    /// Finishes the visit to Google's page and keeps the connection. If the person chose a different
    /// Google account on the page than the one asked about, that's kept as its own connection and the
    /// one asked about is left alone, so the caller checks `address`.
    @discardableResult
    public func finish(_ authorization: GoogleAuthorization, callback: URL) async throws -> GoogleConnection {
        let tokens = try await signIn.finish(authorization, callback: callback)
        guard let address = tokens.email else {
            // Taking the token back at Google takes back the whole account's grant, so it's only done
            // when the token carries nothing another part of Totality already relies on.
            if GoogleUse.uses(of: tokens.granted).isSubset(of: GoogleUse.uses(of: Set(authorization.scopes))) {
                await signIn.revoke(tokens.refreshToken)
            }
            throw GoogleSignInError.unexpected
        }
        return try keep(address: address, refreshToken: tokens.refreshToken, granted: tokens.granted)
    }

    /// Keeps a token a module got from Google itself, like Mail's Gmail sign-ins from before this was
    /// shared. A token asked for with `include_granted_scopes` carries everything, so it replaces what's
    /// here. One that carries less than what's here is older, and the newer one stays.
    @discardableResult
    public func keep(address: String, refreshToken: String, granted: Set<String>) throws -> GoogleConnection {
        let address = address.lowercased()
        guard Self.isAddress(address), !refreshToken.isEmpty else { throw GoogleSignInError.unexpected }
        if let kept = try connection(address), kept.refreshToken != refreshToken, !granted.isSuperset(of: kept.granted) {
            return kept
        }
        let connection = GoogleConnection(address: address, refreshToken: refreshToken, granted: granted)
        try keychain.save(try JSONEncoder().encode(connection), as: Self.name(address))
        var known = try addresses()
        if !known.contains(address) {
            known.append(address)
            try saveAddresses(known)
        }
        return connection
    }

    // MARK: Using

    /// A fresh access token for the account, which lasts about an hour and is never kept. It's only
    /// handed over when the connection carries every scope the module needs.
    public func accessToken(_ address: String, for scopes: [String]) async throws -> String {
        guard let connection = try connection(address) else { throw GoogleSignInError.expired }
        guard connection.allows(scopes) else { throw GoogleSignInError.notAllowed }
        return try await signIn.accessToken(refreshToken: connection.refreshToken)
    }

    /// Takes the account back at Google, which ends it for every module, and forgets it here. The account
    /// goes from this device whether or not Google is reached.
    public func disconnect(_ address: String) async throws {
        let address = address.lowercased()
        if let connection = try connection(address) { await signIn.revoke(connection.refreshToken) }
        try forget(address)
    }

    /// Forgets the account here without going to Google, for when Google already took it back.
    public func forget(_ address: String) throws {
        let address = address.lowercased()
        try keychain.delete(Self.name(address))
        try saveAddresses(try addresses().filter { $0 != address })
    }

    /// Every Google connection on this device, without going to Google, for when the device is handed
    /// to another Totality account. The next person must never inherit someone's Google account.
    public static func forgetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain names

    private static func name(_ address: String) -> String { "account." + address.lowercased() }

    private func addresses() throws -> [String] {
        guard let data = try keychain.load(Self.indexName) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveAddresses(_ addresses: [String]) throws {
        try keychain.save(try JSONEncoder().encode(addresses), as: Self.indexName)
    }

    /// One plain address: printable, no spaces, one @ with something either side, and not too long.
    public static func isAddress(_ text: String) -> Bool {
        guard text.count <= 254, text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
}

/// Which parts of Totality a Google connection is used for, read from the scopes it carries, so a screen
/// can say what disconnecting it ends. It's told apart by Google's own scope names, not by any module.
public enum GoogleUse: String, CaseIterable, Sendable, Hashable {
    case mail, calendar, photos

    public var name: String {
        switch self {
        case .mail: "Gmail"
        case .calendar: "Google Calendar"
        case .photos: "Google Photos"
        }
    }

    public static func uses(of granted: Set<String>) -> Set<GoogleUse> {
        Set(granted.compactMap { scope in
            let path = scope.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "")
            if path.hasPrefix("gmail.") { return .mail }
            if path.hasPrefix("calendar") { return .calendar }
            if path.hasPrefix("photos") { return .photos }
            return nil
        })
    }
}
