import CryptoKit
import Foundation
import Testing
@testable import TotalityCore

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let scheme = "com.googleusercontent.apps.204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0"
private let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
private let photosScope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

/// Stands in for Google's token endpoint. It grants what it's told to, and checks PKCE.
private final class FakeTokens: GoogleHTTP, @unchecked Sendable {
    private let lock = NSLock()
    var granted = "\(calendarScope) \(photosScope)"
    var refusal: (Int, String)?
    var giveRefresh = true
    /// The ID token's claims, or nil for none.
    var claims: [String: Any]? = ["iss": "https://accounts.google.com", "aud": clientID, "email": "McKay.Clemens@gmail.com", "email_verified": true]
    private(set) var issued = 0
    private(set) var sent: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        var components = URLComponents()
        components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(fields["client_secret"] == nil)
        if let (status, error) = refusal { return Self.answer(status, ["error": error]) }
        if request.url == GoogleSignIn.revokeURL { return Self.answer(200, [:]) }
        if fields["grant_type"] == "refresh_token" { return Self.answer(200, ["access_token": "ya29.refreshed"]) }
        guard let code = fields["code"], let verifier = fields["code_verifier"],
              code == GoogleSignIn.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) else {
            return Self.answer(400, ["error": "invalid_grant"])
        }
        let n = lock.withLock { issued += 1; return issued }
        var answer = ["access_token": "ya29.\(n)", "scope": granted]
        if giveRefresh { answer["refresh_token"] = "1//refresh-\(n)" }
        if let claims {
            let payload = GoogleSignIn.base64URL(try! JSONSerialization.data(withJSONObject: claims))
            answer["id_token"] = "eyJhbGciOiJSUzI1NiJ9.\(payload).c2lnbmF0dXJl"
        }
        return Self.answer(200, answer)
    }

    var revoked: [String] {
        lock.withLock { sent }.filter { $0.url == GoogleSignIn.revokeURL }.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
    }

    static func answer(_ status: Int, _ body: [String: String]) -> (Data, HTTPURLResponse) {
        (try! JSONEncoder().encode(body), HTTPURLResponse(url: GoogleSignIn.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// Google's answer, coming back on the app's scheme. The fake takes the PKCE challenge as the code.
private func callback(for authorization: GoogleAuthorization, state: String? = nil, error: String? = nil) -> URL {
    let challenge = query(authorization)["code_challenge"] ?? ""
    var components = URLComponents(string: "\(scheme):/oauth2redirect")!
    components.queryItems = [URLQueryItem(name: "state", value: state ?? authorization.state)]
        + (error.map { [URLQueryItem(name: "error", value: $0)] } ?? [URLQueryItem(name: "code", value: challenge)])
    return components.url!
}

private func query(_ authorization: GoogleAuthorization) -> [String: String] {
    Dictionary((URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

@Suite struct GoogleSignInTests {
    @Test func onlyAcceptsAnIOSClient() {
        #expect(GoogleSignIn(clientID: clientID) != nil)
        #expect(GoogleSignIn(clientID: nil) == nil)
        #expect(GoogleSignIn(clientID: "evil/../x.apps.googleusercontent.com") == nil)
        #expect(GoogleSignIn(clientID: "204117362514-abc.apps.example.com") == nil)
        #expect(GoogleSignIn(clientID: clientID)?.callbackScheme == scheme)
    }

    @Test func asksForOnlyTheScopesGiven() throws {
        let google = try #require(GoogleSignIn(clientID: clientID, http: FakeTokens()))
        let first = google.authorization(scopes: [calendarScope])
        let items = query(first)
        #expect(items["scope"] == calendarScope)
        #expect(items["prompt"] == "select_account consent")
        #expect(items["include_granted_scopes"] == nil && items["login_hint"] == nil)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == GoogleSignIn.base64URL(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
        #expect(items["state"] == first.state && first.state.count >= 43)
        let again = google.authorization(scopes: [calendarScope])
        #expect(again.state != first.state && again.verifier != first.verifier)
    }

    /// A module added later asks on the same Google account, keeping what it already gave.
    @Test func addsToAnAccountWithoutSigningInAgain() throws {
        let google = try #require(GoogleSignIn(clientID: clientID, http: FakeTokens()))
        let more = google.authorization(scopes: [photosScope], account: "mckay.clemens+cal@gmail.com", includeGranted: true)
        let items = query(more)
        #expect(items["include_granted_scopes"] == "true")
        #expect(items["login_hint"] == "mckay.clemens+cal@gmail.com")
        #expect(items["prompt"] == "consent")
        #expect(more.url.absoluteString.contains("mckay.clemens%2Bcal"))
        #expect(more.account == "mckay.clemens+cal@gmail.com")
    }

    @Test func handsBackWhatGoogleGranted() async throws {
        let fake = FakeTokens()
        fake.granted = calendarScope
        let google = try #require(GoogleSignIn(clientID: clientID, http: fake))
        let authorization = google.authorization(scopes: [calendarScope, photosScope])
        let tokens = try await google.finish(authorization, callback: callback(for: authorization))
        #expect(tokens.refreshToken == "1//refresh-1" && tokens.accessToken == "ya29.1")
        // The person unticked Photos. That's the caller's to decide on, and nothing is taken back here.
        #expect(tokens.granted == [calendarScope])
        #expect(fake.revoked.isEmpty)
    }

    @Test func refusesAnAnswerToAnotherRequest() async throws {
        let google = try #require(GoogleSignIn(clientID: clientID, http: FakeTokens()))
        let mine = google.authorization(scopes: [calendarScope]), theirs = google.authorization(scopes: [calendarScope])
        await #expect(throws: GoogleSignInError.unexpected) { try await google.finish(mine, callback: callback(for: theirs)) }
        let elsewhere = URL(string: "https://attacker.example/oauth2redirect?state=\(mine.state)&code=x")!
        await #expect(throws: GoogleSignInError.unexpected) { try await google.finish(mine, callback: elsewhere) }
    }

    @Test func saysWhatGoogleRefused() async throws {
        let fake = FakeTokens()
        let google = try #require(GoogleSignIn(clientID: clientID, http: fake))
        let authorization = google.authorization(scopes: [calendarScope])
        await #expect(throws: GoogleSignInError.cancelled) {
            try await google.finish(authorization, callback: callback(for: authorization, error: "access_denied"))
        }
        await #expect(throws: GoogleSignInError.refused("org_internal")) {
            try await google.finish(authorization, callback: callback(for: authorization, error: "org_internal"))
        }
        fake.giveRefresh = false
        await #expect(throws: GoogleSignInError.unexpected) { try await google.finish(authorization, callback: callback(for: authorization)) }
    }

    @Test func refreshesAndKnowsWhenItsBeenTakenBack() async throws {
        let fake = FakeTokens()
        let google = try #require(GoogleSignIn(clientID: clientID, http: fake))
        #expect(try await google.accessToken(refreshToken: "1//refresh-1") == "ya29.refreshed")
        fake.refusal = (400, "invalid_grant")
        await #expect(throws: GoogleSignInError.expired) { try await google.accessToken(refreshToken: "1//old") }
        fake.refusal = (503, "backendError")
        await #expect(throws: GoogleSignInError.unreachable) { try await google.accessToken(refreshToken: "1//refresh-1") }
    }

    @Test func revokesAtGoogle() async throws {
        let fake = FakeTokens()
        let google = try #require(GoogleSignIn(clientID: clientID, http: fake))
        await google.revoke("1//refresh-1")
        #expect(fake.revoked == ["token=1%2F%2Frefresh-1"])
    }

    @Test func neverPrintsASecret() throws {
        let google = try #require(GoogleSignIn(clientID: clientID, http: FakeTokens()))
        let authorization = google.authorization(scopes: [calendarScope])
        let tokens = GoogleSignInTokens(refreshToken: "1//refresh-secret", accessToken: "ya29.secret", granted: [calendarScope])
        for text in [
            String(describing: authorization), String(reflecting: authorization), "\(authorization)", String(describing: Mirror(reflecting: authorization).children.map(\.value)),
            String(describing: tokens), String(reflecting: tokens), String(describing: Mirror(reflecting: tokens).children.map(\.value)),
        ] {
            #expect(!text.contains("secret") && !text.contains(authorization.verifier) && !text.contains(authorization.state))
        }
    }
}

/// Keeps keychain items in memory.
private final class MemoryKeychain: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var names: [String] { lock.withLock { items.keys.sorted() } }
    func load(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { items[name] = data } }
    func delete(_ name: String) throws { lock.withLock { items[name] = nil } }
}

@Suite struct GoogleAccountsTests {
    private func accounts(_ fake: FakeTokens = FakeTokens(), _ keychain: MemoryKeychain = MemoryKeychain()) throws -> GoogleAccounts {
        GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: keychain)
    }

    @Test func connectsOnceAndKnowsTheAccount() async throws {
        let fake = FakeTokens()
        fake.granted = "openid https://www.googleapis.com/auth/userinfo.email \(calendarScope)"
        let accounts = try accounts(fake)
        let authorization = accounts.authorization(for: [calendarScope])
        #expect(authorization.scopes == [calendarScope, "openid", "email"])
        #expect(query(authorization)["include_granted_scopes"] == "true")
        let connection = try await accounts.finish(authorization, callback: callback(for: authorization))
        #expect(connection.address == "mckay.clemens@gmail.com")
        #expect(connection.allows([calendarScope]) && !connection.allows([photosScope]))
        #expect(try accounts.connections() == [connection])
        #expect(try await accounts.accessToken("MCKAY.clemens@gmail.com", for: [calendarScope]) == "ya29.refreshed")
        await #expect(throws: GoogleSignInError.notAllowed) { try await accounts.accessToken("mckay.clemens@gmail.com", for: [photosScope]) }
        await #expect(throws: GoogleSignInError.expired) { try await accounts.accessToken("someone.else@gmail.com", for: [calendarScope]) }
    }

    /// Photos turned on later: one tap on the same account, and the one token now carries both.
    @Test func addsAModuleToTheSameToken() async throws {
        let fake = FakeTokens()
        fake.granted = "openid email \(calendarScope)"
        let accounts = try accounts(fake)
        let first = accounts.authorization(for: [calendarScope])
        try await accounts.finish(first, callback: callback(for: first))
        fake.granted = "openid email \(calendarScope) \(photosScope)"
        let more = accounts.authorization(for: [photosScope], account: "mckay.clemens@gmail.com")
        #expect(query(more)["login_hint"] == "mckay.clemens@gmail.com")
        let connection = try await accounts.finish(more, callback: callback(for: more))
        #expect(connection.allows([calendarScope, photosScope]))
        #expect(connection.refreshToken == "1//refresh-2")
        #expect(try accounts.connections().count == 1)
        #expect(GoogleUse.uses(of: connection.granted) == [.calendar, .photos])
    }

    @Test func refusesAnIDTokenItCantTrust() async throws {
        for claims: [String: Any]? in [
            nil,
            ["iss": "https://evil.example", "aud": clientID, "email": "a@b.co", "email_verified": true],
            ["iss": "https://accounts.google.com", "aud": "someone-else.apps.googleusercontent.com", "email": "a@b.co", "email_verified": true],
            ["iss": "https://accounts.google.com", "aud": clientID, "email": "a@b.co", "email_verified": false],
            ["iss": "https://accounts.google.com", "aud": clientID, "email": "not an address", "email_verified": true],
        ] {
            let fake = FakeTokens()
            fake.claims = claims
            let keychain = MemoryKeychain()
            let accounts = try accounts(fake, keychain)
            let authorization = accounts.authorization(for: [calendarScope])
            await #expect(throws: GoogleSignInError.unexpected) { try await accounts.finish(authorization, callback: callback(for: authorization)) }
            // Nothing kept, and what Google gave was handed back.
            #expect(keychain.names.isEmpty)
            #expect(fake.revoked.count == 1)
        }
    }

    /// Mail's Gmail sign-ins from before sharing: an older token that carries less never replaces a newer one.
    @Test func keepsTheNewerToken() throws {
        let accounts = try accounts()
        let gmail = "https://www.googleapis.com/auth/gmail.modify"
        try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//both", granted: [gmail, calendarScope])
        let kept = try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//old", granted: [gmail])
        #expect(kept.refreshToken == "1//both")
        let newer = try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//newer", granted: [gmail, calendarScope, photosScope])
        #expect(newer.refreshToken == "1//newer")
        #expect(throws: GoogleSignInError.unexpected) { try accounts.keep(address: "nobody", refreshToken: "1//x", granted: []) }
    }

    @Test func disconnectingEndsItForEveryModule() async throws {
        let fake = FakeTokens()
        let keychain = MemoryKeychain()
        let accounts = try accounts(fake, keychain)
        try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//shared", granted: [calendarScope, photosScope])
        try accounts.keep(address: "family.clemens@gmail.com", refreshToken: "1//family", granted: [calendarScope])
        try await accounts.disconnect("McKay.Clemens@gmail.com")
        #expect(fake.revoked == ["token=1%2F%2Fshared"])
        #expect(try accounts.connections().map(\.address) == ["family.clemens@gmail.com"])
        try accounts.forget("family.clemens@gmail.com")
        #expect(try accounts.connections().isEmpty)
    }

    @Test func neverPrintsTheToken() throws {
        let connection = GoogleConnection(address: "mckay.clemens@gmail.com", refreshToken: "1//refresh-secret", granted: [calendarScope])
        for text in [String(describing: connection), String(reflecting: connection), String(describing: Mirror(reflecting: connection).children.map(\.value))] {
            #expect(!text.contains("secret"))
        }
    }

    @Test func tellsModulesApartByGooglesScopeNames() {
        #expect(GoogleUse.uses(of: ["https://www.googleapis.com/auth/gmail.modify", "openid", "email"]) == [.mail])
        #expect(GoogleUse.uses(of: [calendarScope, photosScope]) == [.calendar, .photos])
        #expect(GoogleUse.uses(of: ["https://www.googleapis.com/auth/userinfo.email"]).isEmpty)
    }
}
