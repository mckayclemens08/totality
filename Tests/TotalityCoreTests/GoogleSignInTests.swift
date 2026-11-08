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
        var answer = ["access_token": "ya29.1", "scope": granted]
        if giveRefresh { answer["refresh_token"] = "1//refresh-1" }
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
