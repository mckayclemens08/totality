import CryptoKit
import Foundation
import Security

/// One HTTPS request and its answer, so tests can stand in for Google.
public protocol GoogleHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Talks to Google with nothing remembered between requests: no cookies, no cache, TLS 1.2 or later.
public struct EphemeralHTTP: GoogleHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a Google sign-in didn't give Totality what it asked for. Errors from the network itself are
/// passed on as they came, so each module can say them in its own words.
public enum GoogleSignInError: Error, Equatable, Sendable {
    /// The person said no on Google's page.
    case cancelled
    /// Google refused, in its own words. Not yet made safe to show.
    case refused(String)
    /// The account is connected, but not for what's being asked. One consent tap adds it.
    case notAllowed
    /// The grant was taken back at Google, or ran out. Signing in again fixes it.
    case expired
    /// Google couldn't be reached properly.
    case unreachable
    /// Google said something that doesn't fit, or the answer wasn't to this request.
    case unexpected
}

/// The page Google's sign-in opens on, and what Totality needs to check the answer. The verifier and
/// state stay on the device, in memory, and never print.
public struct GoogleAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    /// The scheme Google sends the person back on, for the web sign-in sheet to catch.
    public let callbackScheme: String
    /// What this visit asks for. With `include_granted_scopes`, Google hands back these and every scope
    /// this Google account already gave Totality.
    public let scopes: [String]
    /// The Google account this is for, when it's adding to one already connected.
    public let account: String?
    package let state: String
    package let verifier: String

    public var description: String { "Google sign-in" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What a finished Google sign-in hands back. The access token is for using straight away. The refresh
/// token goes to the Keychain and nowhere else. Neither one ever prints.
public struct GoogleSignInTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let refreshToken: String
    public let accessToken: String
    /// Every scope Google says this token carries. The person can untick any of them on Google's page,
    /// so a module checks for its own before relying on it.
    public let granted: Set<String>
    /// The Google account's address, when `openid email` was granted and Google vouched for it.
    public let email: String?

    public init(refreshToken: String, accessToken: String, granted: Set<String>, email: String? = nil) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.granted = granted
        self.email = email
    }

    public var description: String { "Google tokens" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Sign in with Google, the way an installed app does it (RFC 8252): the person signs in on Google's
/// own page, Totality never sees their password, and the answer is bound to this device by PKCE. There's
/// no client secret, because an app can't keep one. Every address here is fixed in code.
///
/// It knows no module's scopes. Each module asks for only its own, and a module added later asks on the
/// same Google account with `include_granted_scopes`, so the person taps once instead of signing in again.
public struct GoogleSignIn: Sendable {
    public static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    private static let clientSuffix = ".apps.googleusercontent.com"

    public let clientID: String
    private let http: any GoogleHTTP

    /// Nil when this build has no Google client, or it isn't the shape Google gives an iOS app.
    public init?(clientID: String?, http: any GoogleHTTP = EphemeralHTTP()) {
        guard let clientID = clientID?.trimmingCharacters(in: .whitespaces), clientID.hasSuffix(Self.clientSuffix) else { return nil }
        let name = clientID.dropLast(Self.clientSuffix.count)
        guard !name.isEmpty, name.count <= 200, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        self.clientID = clientID
        self.http = http
    }

    /// Google's iOS clients come back on their own reversed ID.
    public var callbackScheme: String { "com.googleusercontent.apps." + clientID.dropLast(Self.clientSuffix.count) }
    var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    /// Google's page for these scopes. With no account, the person chooses one. With an account, Google
    /// goes straight to it. `includeGranted` keeps what the account already gave Totality in the new token.
    public func authorization(scopes: [String], account: String? = nil, includeGranted: Bool = false) -> GoogleAuthorization {
        precondition(!scopes.isEmpty, "A Google sign-in has to ask for something")
        let state = Self.random(), verifier = Self.random()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Asking each time makes sure Google gives a refresh token, and shows what's being allowed.
            URLQueryItem(name: "prompt", value: account == nil ? "select_account consent" : "consent"),
        ]
        if includeGranted { items.append(URLQueryItem(name: "include_granted_scopes", value: "true")) }
        if let account { items.append(URLQueryItem(name: "login_hint", value: account)) }
        components.queryItems = items
        // `+` in a query reads as a space to some servers, so it's always escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return GoogleAuthorization(
            url: components.url!, callbackScheme: callbackScheme, scopes: scopes, account: account, state: state, verifier: verifier
        )
    }

    /// Checks what Google sent back and swaps it for tokens. It has to be the answer to this request.
    /// What was granted comes back as Google said it; the caller decides whether that's enough.
    public func finish(_ authorization: GoogleAuthorization, callback: URL) async throws -> GoogleSignInTokens {
        guard callback.scheme?.lowercased() == callbackScheme.lowercased(),
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GoogleSignInError.unexpected
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == authorization.state else { throw GoogleSignInError.unexpected }
        if let error = value("error") {
            if error == "access_denied" { throw GoogleSignInError.cancelled }
            throw GoogleSignInError.refused(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw GoogleSignInError.unexpected }
        let answer = try await token([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": authorization.verifier,
        ])
        guard let refresh = answer.refresh_token, !refresh.isEmpty else { throw GoogleSignInError.unexpected }
        return GoogleSignInTokens(
            refreshToken: refresh, accessToken: answer.access_token,
            granted: Set((answer.scope ?? "").split(separator: " ").map(String.init)),
            email: answer.id_token.flatMap(verifiedEmail)
        )
    }

    /// A fresh access token, which lasts about an hour and is never kept.
    public func accessToken(refreshToken: String) async throws -> String {
        try await token([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]).access_token
    }

    /// Takes Totality's access away at Google, for every scope this Google account gave it. Best effort:
    /// whatever's being removed goes from Totality whether or not Google is reached.
    public func revoke(_ refreshToken: String) async {
        var request = URLRequest(url: Self.revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": refreshToken])
        _ = try? await http.send(request)
    }

    /// Any other request to Google, through the same cookie-free, cache-free connection.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await http.send(request)
    }

    private struct TokenAnswer: Decodable {
        let access_token: String
        let refresh_token: String?
        let scope: String?
        let id_token: String?
    }

    /// The address in an ID token straight from Google's token endpoint. It came over TLS from Google
    /// in answer to this app's own code, which OpenID Connect (Core 3.1.3.7) accepts in place of checking
    /// the signature. It still has to be from Google, for this client, and an address Google has verified.
    func verifiedEmail(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        struct Claims: Decodable {
            let iss: String
            let aud: String
            let email: String?
            let email_verified: Bool?
        }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(Claims.self, from: data),
              ["https://accounts.google.com", "accounts.google.com"].contains(claims.iss), claims.aud == clientID,
              claims.email_verified == true, let email = claims.email, GoogleAccounts.isAddress(email) else { return nil }
        return email.lowercased()
    }

    private func token(_ fields: [String: String]) async throws -> TokenAnswer {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            struct Refusal: Decodable { let error: String }
            let error = try? JSONDecoder().decode(Refusal.self, from: data).error
            if error == "invalid_grant" { throw GoogleSignInError.expired }
            throw response.statusCode >= 500 ? GoogleSignInError.unreachable : GoogleSignInError.unexpected
        }
        guard let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data), !answer.access_token.isEmpty else {
            throw GoogleSignInError.unexpected
        }
        return answer
    }

    public static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// 32 random bytes, which is what PKCE asks of a verifier.
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system's random numbers aren't available")
        return base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
