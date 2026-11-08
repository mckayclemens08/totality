import CryptoKit
import Foundation
import Security

/// One HTTPS request and its answer, so tests can stand in for Google.
public protocol OutsideHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Talks to Google with nothing remembered between requests: no cookies, no cache, TLS 1.2 or later.
public struct EphemeralHTTP: OutsideHTTP {
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

/// The page Google's sign-in opens on, and what Totality needs to check the answer. The verifier and
/// state stay on the device, in memory, and never print.
public struct GoogleSignInRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    /// The scheme Google sends the person back on, for the web sign-in sheet to catch.
    public let callbackScheme: String
    let state: String
    let verifier: String
    let scopes: [String]

    public var description: String { "Google sign-in" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Sign in with Google, the way an installed app does it (RFC 8252): the person signs in on Google's
/// own page, Totality never sees their password, and the answer is bound to this device by PKCE. There's
/// no client secret, because an app can't keep one. Then Gmail's own API, which is how a Google sign-in
/// reaches the mail. Every address here is fixed in code.
public struct GoogleOAuth: Sendable {
    /// Read only. Asked for when the account is added.
    public static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// Send only, never read. Asked for separately, only when the Send switch is turned on.
    public static let sendScope = "https://www.googleapis.com/auth/gmail.send"

    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let profileURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!

    private static let clientSuffix = ".apps.googleusercontent.com"

    public let clientID: String
    private let http: any OutsideHTTP

    /// Nil when this build has no Google client, or it isn't the shape Google gives an iOS app.
    public init?(clientID: String?, http: any OutsideHTTP = EphemeralHTTP()) {
        guard let clientID = clientID?.trimmingCharacters(in: .whitespaces), clientID.hasSuffix(Self.clientSuffix) else { return nil }
        let name = clientID.dropLast(Self.clientSuffix.count)
        guard !name.isEmpty, name.count <= 200, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        self.clientID = clientID
        self.http = http
    }

    /// Google's iOS clients come back on their own reversed ID.
    var callbackScheme: String { "com.googleusercontent.apps." + clientID.dropLast(Self.clientSuffix.count) }
    var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    /// To add an account: read only, choosing which Google account. To turn sending on: reading and
    /// sending together, for the account already added.
    func request(sendingFor address: String? = nil) -> GoogleSignInRequest {
        let scopes = address == nil ? [Self.readScope] : [Self.readScope, Self.sendScope]
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
            URLQueryItem(name: "prompt", value: address == nil ? "select_account consent" : "consent"),
        ]
        if let address { items.append(URLQueryItem(name: "login_hint", value: address)) }
        components.queryItems = items
        // `+` in a query reads as a space to some servers, so it's always escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return GoogleSignInRequest(url: components.url!, callbackScheme: callbackScheme, state: state, verifier: verifier, scopes: scopes)
    }

    /// Checks what Google sent back and swaps it for tokens. It has to be the answer to this request,
    /// and every scope asked for has to have been allowed: Google lets the person untick each one.
    func finish(_ request: GoogleSignInRequest, callback: URL) async throws -> GoogleTokens {
        guard callback.scheme?.lowercased() == callbackScheme.lowercased(),
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw OutsideMailProblem.unexpected
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == request.state else { throw OutsideMailProblem.unexpected }
        if let error = value("error") {
            if error == "access_denied" { throw OutsideAccountError.cancelled }
            throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(error))
        }
        guard let code = value("code"), !code.isEmpty else { throw OutsideMailProblem.unexpected }
        let answer = try await token([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": request.verifier,
        ])
        guard let refresh = answer.refresh_token, !refresh.isEmpty else { throw OutsideMailProblem.unexpected }
        let allowed = Set((answer.scope ?? "").split(separator: " ").map(String.init))
        guard request.scopes.allSatisfy(allowed.contains) else {
            // Taking a token back at Google takes back everything this app was given, so it's only done
            // when nothing was added yet. Turning sending on for an account that reads keeps its reading.
            if request.scopes == [Self.readScope] { await revoke(refresh) }
            throw OutsideMailProblem.notAllowed
        }
        return GoogleTokens(refreshToken: refresh, accessToken: answer.access_token)
    }

    /// A fresh access token, which lasts about an hour and is never kept.
    func accessToken(for grant: GoogleGrant) async throws -> String {
        try await token([
            "grant_type": "refresh_token",
            "refresh_token": grant.refreshToken,
            "client_id": clientID,
        ]).access_token
    }

    /// The Gmail address the token belongs to, which is also proof it can read.
    func address(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 401: throw OutsideMailProblem.expired
        case 403: throw OutsideMailProblem.notAllowed
        default: throw OutsideMailProblem.unreachable
        }
        struct Profile: Decodable { let emailAddress: String }
        guard let address = try? JSONDecoder().decode(Profile.self, from: data).emailAddress,
              OutsideSignIn.isAddress(address) else { throw OutsideMailProblem.unexpected }
        return address
    }

    /// Takes Totality's access away at Google, for every scope. Best effort: the account goes from
    /// Totality whether or not Google is reached.
    func revoke(_ refreshToken: String) async {
        var request = URLRequest(url: Self.revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": refreshToken])
        _ = try? await send(request)
    }

    private struct TokenAnswer: Decodable {
        let access_token: String
        let refresh_token: String?
        let scope: String?
    }

    private func token(_ fields: [String: String]) async throws -> TokenAnswer {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            struct Refusal: Decodable { let error: String }
            let error = try? JSONDecoder().decode(Refusal.self, from: data).error
            // The grant was taken back at Google, or ran out.
            if error == "invalid_grant" { throw OutsideMailProblem.expired }
            throw response.statusCode >= 500 ? OutsideMailProblem.unreachable : OutsideMailProblem.unexpected
        }
        guard let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data), !answer.access_token.isEmpty else {
            throw OutsideMailProblem.unexpected
        }
        return answer
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch {
            throw OutsideMailProblem.from(error)
        }
    }

    static func form(_ fields: [String: String]) -> Data {
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

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a finished Google sign-in hands back. The access token is used straight away and dropped.
struct GoogleTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let refreshToken: String
    let accessToken: String

    var description: String { "Google tokens" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
