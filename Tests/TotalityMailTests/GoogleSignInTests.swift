import CryptoKit
import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let scheme = "com.googleusercontent.apps.204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0"

/// Plays Google: the token endpoint, Gmail's profile, and revoking. Anywhere else stops the test.
final class FakeGoogle: OutsideHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var issued = 0
    /// Who the person signs in as on Google's page.
    var address = "mckay.clemens@gmail.com"
    /// What the person leaves ticked on Google's page. Nil means everything asked for.
    var allowed: [String]?
    var refusesRefresh = false
    var refusesMail = false
    /// What's in the Gmail Inbox, newest first.
    var inbox: [(id: String, raw: String, unread: Bool, at: Date)] = []
    /// Labels each message has beside INBOX, and the ones taken out of the Inbox.
    var labelsOf: [String: [String]] = [:]
    var archived: Set<String> = []
    var starred: Set<String> = []
    var spam: Set<String> = []
    var trashed: Set<String> = []
    /// Read or unread changed since it arrived.
    var unreadNow: [String: Bool] = [:]
    private var changeLog: [String] = []
    private var sentLog: [String] = []
    /// Each message Totality handed Gmail to send, as Gmail got it.
    var sentMessages: [String] { lock.withLock { sentLog } }
    /// Each change Totality made at Gmail, as `modify <id> +A -B`, `trash <id>` or `untrash <id>`.
    var changes: [String] { lock.withLock { changeLog } }
    /// The labels the person made, by ID and name.
    var userLabels: [(id: String, name: String)] = []
    /// How many listings Gmail turns down as too fast before answering.
    var tooFast = 0
    /// A label Gmail won't list, for its own reason.
    var refusedLabel: String?
    private var fetchedIDs: [String] = []

    func labels(of id: String) -> [String] {
        lock.withLock {
            var labels = labelsOf[id] ?? []
            if trashed.contains(id) { labels.append("TRASH") } else if spam.contains(id) { labels.append("SPAM") } else if !archived.contains(id) { labels.append("INBOX") }
            if unreadNow[id] ?? inbox.first(where: { $0.id == id })?.unread ?? false { labels.append("UNREAD") }
            if starred.contains(id) { labels.append("STARRED") }
            return labels
        }
    }

    private func changeAnswer(_ request: URLRequest, id: String, action: String) -> (Data, HTTPURLResponse) {
        #expect(request.httpMethod == "POST")
        guard lock.withLock({ inbox.contains { $0.id == id } }) else { return Self.answer(404, [:]) }
        switch action {
        case "trash": lock.withLock { trashed.insert(id); changeLog.append("trash \(id)") }
        case "untrash": lock.withLock { trashed.remove(id); changeLog.append("untrash \(id)") }
        case "modify":
            struct Body: Decodable { let addLabelIds: [String]; let removeLabelIds: [String] }
            guard let body = request.httpBody.flatMap({ try? JSONDecoder().decode(Body.self, from: $0) }) else { return Self.answer(400, [:]) }
            lock.withLock {
                for label in body.addLabelIds {
                    switch label {
                    case "INBOX": archived.remove(id)
                    case "SPAM": spam.insert(id)
                    case "UNREAD": unreadNow[id] = true
                    case "STARRED": starred.insert(id)
                    default: Issue.record("added \(label)")
                    }
                }
                for label in body.removeLabelIds {
                    switch label {
                    case "INBOX": archived.insert(id)
                    case "SPAM": spam.remove(id)
                    case "UNREAD": unreadNow[id] = false
                    case "STARRED": starred.remove(id)
                    default: Issue.record("removed \(label)")
                    }
                }
                changeLog.append((["modify", id] + body.addLabelIds.map { "+" + $0 } + body.removeLabelIds.map { "-" + $0 }).joined(separator: " "))
            }
        default: return Self.answer(404, [:])
        }
        return Self.json(200, ["id": id])
    }
    /// Which messages were downloaded, in order.
    var fetched: [String] { lock.withLock { fetchedIDs } }

    var requests: [URLRequest] { lock.withLock { sent } }
    var revoked: [String] {
        requests.filter { $0.url == GoogleOAuth.revokeURL }.compactMap { Self.fields($0)["token"] }
    }

    static func fields(_ request: URLRequest) -> [String: String] {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let url = try #require(request.url)
        switch url {
        case GoogleOAuth.tokenURL:
            let fields = Self.fields(request)
            #expect(fields["client_secret"] == nil)
            #expect(fields["client_id"] == clientID)
            if fields["grant_type"] == "refresh_token" {
                if refusesRefresh { return Self.answer(400, ["error": "invalid_grant"]) }
                return Self.answer(200, ["access_token": "ya29.refreshed", "token_type": "Bearer"])
            }
            #expect(fields["grant_type"] == "authorization_code")
            #expect(fields["redirect_uri"] == "\(scheme):/oauth2redirect")
            // PKCE: the verifier sent now has to hash to the challenge the page was opened with.
            guard let code = fields["code"], let verifier = fields["code_verifier"],
                  let challenge = code.split(separator: ".").last, challenge == GoogleOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) else {
                return Self.answer(400, ["error": "invalid_grant"])
            }
            let scopes = code.split(separator: ".").dropFirst().first
                .flatMap { Data(base64Encoded: String($0)) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let n = lock.withLock { issued += 1; return issued }
            return Self.answer(200, ["access_token": "ya29.\(n)", "refresh_token": "1//refresh-\(n)", "scope": scopes, "token_type": "Bearer"])
        case GoogleOAuth.profileURL:
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ya29.") == true)
            return Self.answer(200, ["emailAddress": address, "messagesTotal": "18342"])
        case GoogleOAuth.revokeURL:
            return Self.answer(200, [:])
        case GoogleOAuth.labelsURL:
            if refusesMail { return Self.answer(401, [:]) }
            let own = lock.withLock { userLabels }
            let system = [["id": "INBOX", "name": "INBOX", "type": "system"], ["id": "CATEGORY_SOCIAL", "name": "CATEGORY_SOCIAL", "type": "system"]]
            return Self.json(200, ["labels": system + own.map { ["id": $0.id, "name": $0.name, "type": "user"] }])
        case _ where url.host == "gmail.googleapis.com" && url.path == "/upload/gmail/v1/users/me/messages/send":
            #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "message/rfc822")
            #expect(request.url?.query == "uploadType=media")
            if refusesMail { return Self.answer(401, [:]) }
            let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let n = lock.withLock { sentLog.append(raw); return sentLog.count }
            return Self.json(200, ["id": "19a0b1c2d3e4f5a\(n)", "threadId": "19a0b1c2d3e4f5a0", "labelIds": ["SENT"]])
        case _ where url.host == "gmail.googleapis.com" && url.path.hasPrefix("/gmail/v1/users/me/messages"):
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ya29.") == true)
            if refusesMail { return Self.answer(401, [:]) }
            let messages = lock.withLock { inbox }
            if url.path == "/gmail/v1/users/me/messages" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(items.first { $0.name == "q" }?.value?.hasPrefix("after:") == true)
                let label = items.first { $0.name == "labelIds" }?.value ?? ""
                let slowDown = lock.withLock { tooFast > 0 ? { tooFast -= 1; return true }() : false }
                if slowDown {
                    return Self.json(403, ["error": ["code": 403, "message": "User-rate limit exceeded.", "status": "PERMISSION_DENIED",
                                                     "errors": [["reason": "userRateLimitExceeded", "domain": "usageLimits"]]]])
                }
                if label == refusedLabel {
                    return Self.json(403, ["error": ["code": 403, "message": "Label not reachable.", "errors": [["reason": "forbidden"]]]])
                }
                let spamToo = items.first { $0.name == "includeSpamTrash" }?.value == "true"
                let listed = messages.filter {
                    let labels = labels(of: $0.id)
                    return labels.contains(label) && (spamToo || !labels.contains("SPAM") && !labels.contains("TRASH"))
                }
                let listing: [String: Any] = ["messages": listed.map { ["id": $0.id, "threadId": $0.id] }, "resultSizeEstimate": listed.count]
                return Self.json(200, listing)
            }
            let parts = url.pathComponents
            if parts.count == 8 { return changeAnswer(request, id: parts[6], action: parts[7]) }
            let id = url.lastPathComponent
            guard let message = messages.first(where: { $0.id == id }) else { return Self.answer(404, [:]) }
            lock.withLock { fetchedIDs.append(id) }
            let raw = Data(message.raw.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return Self.json(200, [
                "id": id, "raw": raw, "internalDate": String(Int(message.at.timeIntervalSince1970 * 1000)),
                "labelIds": labels(of: id),
            ])
        default:
            Issue.record("reached \(url), which isn't Google's")
            throw URLError(.unsupportedURL)
        }
    }

    /// Google's page: the person signs in and allows what's ticked. The code carries the challenge and
    /// the scopes, so the fake token endpoint can check them.
    func page(_ page: URL, _ callbackScheme: String) -> URL {
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        #expect(callbackScheme == scheme)
        let scopes = Data((allowed ?? value("scope").split(separator: " ").map(String.init)).joined(separator: " ").utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        return URL(string: "\(scheme):/oauth2redirect?state=\(value("state"))&code=4/0AQ.\(scopes).\(value("code_challenge"))&scope=x")!
    }

    private static func json(_ status: Int, _ body: [String: Any]) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: GoogleOAuth.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private static func answer(_ status: Int, _ body: [String: String]) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: GoogleOAuth.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private struct NoMailServer: MailServer {
    func publish(publicKey: Data) async throws -> MailKeyPublication { throw MailServerError.unavailable }
    func list() async throws -> MailServerList { throw MailServerError.unavailable }
    func message(_ id: UUID) async throws -> Data { throw MailServerError.unavailable }
    func delete(_ ids: Set<UUID>) async throws -> Int { throw MailServerError.unavailable }
    func recipientKey(_ name: String) async throws -> Data? { throw MailServerError.unavailable }
    func deliver(to name: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer { throw MailServerError.unavailable }
    func keep(id: UUID, sealed: Data) async throws { throw MailServerError.unavailable }
    func sendOutside(_ message: MailOutsideMessage) async throws -> MailOutsideAnswer { throw MailServerError.unavailable }
}

@Suite struct GoogleOAuthTests {
    @Test func onlyAnIOSClientIDIsTaken() {
        #expect(GoogleOAuth(clientID: clientID) != nil)
        #expect(GoogleOAuth(clientID: nil) == nil)
        #expect(GoogleOAuth(clientID: "") == nil)
        #expect(GoogleOAuth(clientID: ".apps.googleusercontent.com") == nil)
        #expect(GoogleOAuth(clientID: "204117362514-abc.apps.example.com") == nil)
        #expect(GoogleOAuth(clientID: "evil/../x.apps.googleusercontent.com") == nil)
        #expect(GoogleOAuth(clientID: clientID)?.callbackScheme == scheme)
    }

    @Test func addingAsksOnlyToReadWithPKCE() throws {
        let google = try #require(GoogleOAuth(clientID: clientID, http: FakeGoogle()))
        let request = google.request()
        let url = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(url.scheme == "https" && url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        let items = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(items["scope"] == "https://www.googleapis.com/auth/gmail.modify")
        #expect(items["response_type"] == "code" && items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == GoogleOAuth.base64URL(Data(SHA256.hash(data: Data(request.verifier.utf8)))))
        #expect(items["state"] == request.state && request.state.count >= 43)
        #expect(items["login_hint"] == nil && items["client_secret"] == nil)
        #expect(request.callbackScheme == scheme)
        // Each sign-in is its own.
        let again = google.request()
        #expect(again.state != request.state && again.verifier != request.verifier)
    }

    @Test func sendingAsksForTheAccountAlreadyAdded() throws {
        let google = try #require(GoogleOAuth(clientID: clientID, http: FakeGoogle()))
        let items = URLComponents(url: google.request(.send("mckay.clemens+news@gmail.com")).url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("scope") == "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send")
        #expect(value("login_hint") == "mckay.clemens+news@gmail.com")
        #expect(google.request(.send("mckay.clemens+news@gmail.com")).url.absoluteString.contains("mckay.clemens%2Bnews"))
    }

    @Test func nothingSecretEverPrints() throws {
        let google = try #require(GoogleOAuth(clientID: clientID, http: FakeGoogle()))
        let request = google.request()
        let grant = GoogleGrant(refreshToken: "1//refresh-secret", canSend: true)
        let shown = [
            String(describing: request), String(reflecting: request), String(describing: Mirror(reflecting: request).children.map(\.value)),
            String(describing: grant), String(reflecting: grant), String(describing: Mirror(reflecting: grant).children.map(\.value)),
            String(describing: OutsideCredential.google(grant)), String(reflecting: OutsideCredential.appPassword("abcd-efgh")),
            String(describing: GoogleTokens(refreshToken: "1//refresh-secret", accessToken: "ya29.secret")),
        ]
        for text in shown {
            #expect(!text.contains(request.verifier) && !text.contains(request.state))
            #expect(!text.contains("secret") && !text.contains("abcd"))
        }
    }

    @Test func anAnswerToSomeoneElsesRequestIsRefused() async throws {
        let fake = FakeGoogle()
        let google = try #require(GoogleOAuth(clientID: clientID, http: fake))
        let mine = google.request(), theirs = google.request()
        let callback = fake.page(theirs.url, scheme)
        await #expect(throws: OutsideMailProblem.unexpected) { try await google.finish(mine, callback: callback) }
        let elsewhere = URL(string: "https://attacker.example/oauth2redirect?state=\(mine.state)&code=x")!
        await #expect(throws: OutsideMailProblem.unexpected) { try await google.finish(mine, callback: elsewhere) }
        #expect(fake.requests.isEmpty)
    }

    @Test func aRevokedGrantSaysToSignInAgain() async throws {
        let fake = FakeGoogle()
        fake.refusesRefresh = true
        let google = try #require(GoogleOAuth(clientID: clientID, http: fake))
        await #expect(throws: OutsideMailProblem.expired) { try await google.accessToken(for: GoogleGrant(refreshToken: "1//old", canSend: false)) }
    }
}

@Suite struct GoogleAccountTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"
    private let bob = "3c7b1d9e-5f2a-4b6c-8d0e-1a2b3c4d5e6f"

    private func store(_ fake: FakeGoogle, maker: ProviderMaker = ProviderMaker(), keys: MailMemoryKeys = MailMemoryKeys(), account: String? = nil, blobs: MailMemoryStore = MailMemoryStore(), root: ContentRootKey? = nil) throws -> (ServerMailStore, MailVault) {
        let account = account ?? alice
        let root = try root ?? ContentRootKey.generate()
        let vault = MailVault(store: blobs, rootKey: root, account: account, secrets: keys)
        let store = try ServerMailStore(
            account: account, rootKey: root, vault: vault, server: NoMailServer(), canPublish: { false },
            username: { "mckay" }, outsideCheck: OutsideSignInCheck(maker: maker), google: GoogleOAuth(clientID: clientID, http: fake)
        )
        return (store, vault)
    }

    private func add(_ store: ServerMailStore, _ fake: FakeGoogle) async throws -> OutsideAccount {
        let request = try await store.googleSignIn(for: nil, sending: false)
        return try await store.addGoogle(request, callback: fake.page(request.url, request.callbackScheme))
    }

    private func allowSending(_ store: ServerMailStore, _ fake: FakeGoogle, _ id: UUID) async throws {
        let request = try await store.googleSignIn(for: id, sending: true)
        try await store.allowGoogleSending(id, request, callback: fake.page(request.url, request.callbackScheme))
    }

    @Test func signingInWithGoogleAddsAGmailThatOnlyReads() async throws {
        let fake = FakeGoogle(), maker = ProviderMaker(), keys = MailMemoryKeys()
        let (store, vault) = try store(fake, maker: maker, keys: keys)
        let added = try await add(store, fake)
        #expect(added.provider == .gmail && added.address == "mckay.clemens@gmail.com" && !added.canSend)
        #expect(try await store.outsideAccounts() == [added])
        #expect(try await vault.credential(for: added.id) == .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false)))
        let kept = try #require(try keys.load(MailVault.secretName(added.id, account: alice)))
        #expect(try OutsideCredential(keychainData: kept) == .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false)))
        // No password, and no IMAP: Gmail is reached only through Google's own addresses.
        #expect(maker.connections.isEmpty)
        #expect(try await vault.signIn(for: added.id) == nil)
        #expect(fake.requests.allSatisfy { ["oauth2.googleapis.com", "gmail.googleapis.com"].contains($0.url?.host) })
    }

    @Test func untickingReadingKeepsNothingAndTakesTheGrantBack() async throws {
        let fake = FakeGoogle()
        fake.allowed = []
        let (store, vault) = try store(fake)
        await #expect(throws: OutsideAccountError.problem(.notAllowed)) { _ = try await add(store, fake) }
        #expect(try await vault.outsideAccounts().isEmpty)
        #expect(fake.revoked == ["1//refresh-1"])
    }

    @Test func theSameGmailTwiceIsRefusedAndTheFirstKeepsItsAccess() async throws {
        let fake = FakeGoogle()
        let (store, _) = try store(fake)
        _ = try await add(store, fake)
        fake.address = "McKay.Clemens@gmail.com"
        await #expect(throws: OutsideAccountError.alreadyAdded) { _ = try await add(store, fake) }
        #expect(fake.revoked.isEmpty)
        #expect(try await store.outsideAccounts().count == 1)
    }

    @Test func threeIsTheMostBeforeGooglesPageOpens() async throws {
        let fake = FakeGoogle()
        let (store, _) = try store(fake)
        for name in ["mckay.clemens", "clemens.family", "mckay.receipts"] {
            fake.address = "\(name)@gmail.com"
            _ = try await add(store, fake)
        }
        await #expect(throws: OutsideAccountError.tooMany) { _ = try await store.googleSignIn(for: nil, sending: false) }
    }

    @Test func sendingIsAskedForSeparatelyAndOnlyForTheSameAccount() async throws {
        let fake = FakeGoogle()
        let (store, vault) = try store(fake)
        let added = try await add(store, fake)
        // The Send switch can't skip Google's page.
        await #expect(throws: OutsideAccountError.notFound) { try await store.setOutsideSending(added.id, on: true) }
        fake.address = "someone.else@gmail.com"
        await #expect(throws: OutsideAccountError.differentAccount) { try await allowSending(store, fake, added.id) }
        #expect(try await store.outsideAccounts().first?.canSend == false)
        fake.address = "mckay.clemens@gmail.com"
        try await allowSending(store, fake, added.id)
        #expect(try await store.outsideAccounts().first?.canSend == true)
        #expect(try await vault.credential(for: added.id) == .google(GoogleGrant(refreshToken: "1//refresh-3", canSend: true)))
        try await store.setOutsideSending(added.id, on: false)
        #expect(try await store.outsideAccounts().first?.canSend == false)
    }

    @Test func untickingSendingKeepsReadingAsItWas() async throws {
        let fake = FakeGoogle()
        let (store, vault) = try store(fake)
        let added = try await add(store, fake)
        fake.allowed = [GoogleOAuth.changeScope]
        await #expect(throws: OutsideAccountError.problem(.notAllowed)) { try await allowSending(store, fake, added.id) }
        #expect(fake.revoked.isEmpty)
        #expect(try await vault.credential(for: added.id) == .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false)))
    }

    @Test func aGmailThatOnlyReadsIsAskedOnceToAllowChanges() async throws {
        let fake = FakeGoogle()
        let (store, vault) = try store(fake)
        var added = try await add(store, fake)
        // As accounts added before changes were asked for are kept.
        try await vault.save(added, credential: .google(GoogleGrant(refreshToken: "1//refresh-old", canSend: false, canChange: false)))
        added = try #require(try await store.outsideAccounts().first)
        #expect(!added.keepsInStep)
        let request = try await store.googleSignIn(for: added.id, sending: false)
        #expect(request.scopes == [GoogleOAuth.changeScope])
        try await store.allowGoogleChanges(added.id, request, callback: fake.page(request.url, request.callbackScheme))
        #expect(try await store.outsideAccounts().first?.keepsInStep == true)
        #expect(try await store.outsideAccounts().first?.canSend == false)
        // Unticked on Google's page: nothing is taken back, and it still reads as before.
        try await vault.save(added, credential: .google(GoogleGrant(refreshToken: "1//refresh-old", canSend: false, canChange: false)))
        fake.allowed = [GoogleOAuth.readScope]
        let again = try await store.googleSignIn(for: added.id, sending: false)
        await #expect(throws: OutsideAccountError.problem(.notAllowed)) {
            try await store.allowGoogleChanges(added.id, again, callback: fake.page(again.url, again.callbackScheme))
        }
        #expect(fake.revoked.isEmpty)
        #expect(try await vault.credential(for: added.id) == .google(GoogleGrant(refreshToken: "1//refresh-old", canSend: false, canChange: false)))
    }

    @Test func allowingChangesCantTurnOnSending() async throws {
        let fake = FakeGoogle()
        let (store, _) = try store(fake)
        let added = try await add(store, fake)
        let sending = try await store.googleSignIn(for: added.id, sending: true)
        await #expect(throws: OutsideAccountError.notFound) {
            try await store.allowGoogleChanges(added.id, sending, callback: fake.page(sending.url, sending.callbackScheme))
        }
        #expect(try await store.outsideAccounts().first?.canSend == false)
    }

    @Test func aSignInRequestForAddingCantTurnOnSending() async throws {
        let fake = FakeGoogle()
        let (store, _) = try store(fake)
        let added = try await add(store, fake)
        let request = try await store.googleSignIn(for: nil, sending: false)
        await #expect(throws: OutsideAccountError.notFound) {
            try await store.allowGoogleSending(added.id, request, callback: fake.page(request.url, request.callbackScheme))
        }
    }

    @Test func removingTakesTheAccessBackAtGoogle() async throws {
        let fake = FakeGoogle(), keys = MailMemoryKeys()
        let (store, _) = try store(fake, keys: keys)
        let added = try await add(store, fake)
        try await store.removeOutside(added.id)
        #expect(try await store.outsideAccounts().isEmpty)
        #expect(try keys.load(MailVault.secretName(added.id, account: alice)) == nil)
        #expect(fake.revoked == ["1//refresh-1"])
    }

    @Test func withoutAGoogleClientGmailCantBeAdded() async throws {
        let root = try ContentRootKey.generate()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: alice, secrets: MailMemoryKeys())
        let store = try ServerMailStore(account: alice, rootKey: root, vault: vault, server: NoMailServer(), canPublish: { false }, username: { "mckay" })
        await #expect(throws: OutsideAccountError.notSetUp) { _ = try await store.googleSignIn(for: nil, sending: false) }
    }

    @Test func anotherAccountOnTheSameDeviceCantSeeOrUseTheGrant() async throws {
        let fake = FakeGoogle(), keys = MailMemoryKeys(), blobs = MailMemoryStore(), root = try ContentRootKey.generate()
        let (mine, _) = try store(fake, keys: keys, blobs: blobs, root: root)
        let added = try await add(mine, fake)
        let (theirs, theirVault) = try store(fake, keys: keys, account: bob, blobs: blobs, root: root)
        #expect(try await theirs.outsideAccounts().isEmpty)
        #expect(try await theirVault.credential(for: added.id) == nil)
        await #expect(throws: OutsideAccountError.notFound) { _ = try await theirs.googleSignIn(for: added.id, sending: true) }
    }
}

@MainActor
@Suite struct GoogleAccountsModelTests {
    private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"

    private func model(_ fake: FakeGoogle) throws -> OutsideAccountsModel {
        let root = try ContentRootKey.generate()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: alice, secrets: MailMemoryKeys())
        let store = try ServerMailStore(
            account: alice, rootKey: root, vault: vault, server: NoMailServer(), canPublish: { false },
            username: { "mckay" }, google: GoogleOAuth(clientID: clientID, http: fake)
        )
        return try #require(MailModel(store: store).outside)
    }

    @Test func signingInAddsTheAccountAndTurningSendOnAsksGoogle() async throws {
        let fake = FakeGoogle()
        let model = try model(fake)
        var pages = 0
        let page: OutsideWebSignIn = { url, scheme in
            pages += 1
            return fake.page(url, scheme)
        }
        #expect(await model.addGoogle(signingIn: page) == .added)
        let account = try #require(model.accounts.first)
        #expect(account.address == "mckay.clemens@gmail.com" && !account.canSend)
        await model.setSending(account, on: true, signingIn: page)
        #expect(model.accounts.first?.canSend == true && model.notice == nil)
        #expect(pages == 2)
        // Turning it off needs no page.
        await model.setSending(try #require(model.accounts.first), on: false, signingIn: neverOpened)
        #expect(model.accounts.first?.canSend == false)
    }

    @Test func closingGooglesPageSaysNothing() async throws {
        let fake = FakeGoogle()
        let model = try model(fake)
        let denied: OutsideWebSignIn = { _, _ in URL(string: "\(scheme):/oauth2redirect?error=access_denied")! }
        // The state is missing, so this one is refused outright; one with the right state is a cancel.
        #expect(await model.addGoogle(signingIn: denied) != .added)
        let declined: OutsideWebSignIn = { url, _ in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?error=access_denied&state=\(state)")!
        }
        #expect(await model.addGoogle(signingIn: declined) == .cancelled)
        let closed: OutsideWebSignIn = { _, _ in throw CancellationError() }
        #expect(await model.addGoogle(signingIn: closed) == .cancelled)
        #expect(model.accounts.isEmpty && fake.requests.isEmpty)
    }
}
