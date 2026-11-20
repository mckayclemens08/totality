import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let today = Date(timeIntervalSince1970: 1_794_000_000)

/// A plain Gmail with a big Inbox, newest first, that counts what it's asked and how much at once.
/// Each message fetch can be slowed, or answered some other way, by the test.
private final class CountingGmail: OutsideHTTP, @unchecked Sendable {
    private let lock = NSLock()
    let inbox: [String]
    var latency: Duration = .zero
    /// Decides a message fetch's answer from how many have been asked before it. Nil answers normally.
    var trouble: (@Sendable (Int) -> (Int, [String: String])?)?
    private(set) var listPages = 0
    private(set) var gets = 0
    private(set) var fetched: [String] = []
    private var inFlight = 0
    private(set) var mostInFlight = 0

    init(count: Int) {
        inbox = (0..<count).map { String(0x18f3_a2b4_c5d6_0000 + count - $0, radix: 16) }
    }

    static func raw(_ id: String) -> String {
        "From: Rosa Delgado <rosa@delgado-studio.com>\r\nSubject: Site visit \(id)\r\nMessage-ID: <\(id)@delgado-studio.com>\r\n\r\nSee you Thursday.\r\n"
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url == GoogleOAuth.tokenURL { return Self.json(200, ["access_token": "ya29.counting", "token_type": "Bearer"]) }
        switch url.path {
        case "/gmail/v1/users/me/labels": return Self.json(200, ["labels": []])
        case "/gmail/v1/users/me/profile": return Self.json(200, ["historyId": "4812000"])
        case "/gmail/v1/users/me/messages":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            lock.withLock { listPages += 1 }
            guard value("labelIds") == "INBOX" else { return Self.json(200, [:]) }
            let size = Int(value("maxResults") ?? "100") ?? 100
            let from = Int(value("pageToken") ?? "0") ?? 0
            let page = Array(inbox[min(from, inbox.count)..<min(from + size, inbox.count)])
            var answer: [String: Any] = ["messages": page.map { ["id": $0, "threadId": $0] }]
            if from + size < inbox.count { answer["nextPageToken"] = String(from + size) }
            return Self.json(200, answer)
        default:
            let id = url.lastPathComponent
            let asked = lock.withLock {
                gets += 1
                inFlight += 1
                mostInFlight = max(mostInFlight, inFlight)
                return gets - 1
            }
            defer { lock.withLock { inFlight -= 1 } }
            if latency > .zero { try await Task.sleep(for: latency) }
            if let answer = trouble?(asked) { return Self.json(answer.0, [:], headers: answer.1) }
            lock.withLock { fetched.append(id) }
            let raw = Data(Self.raw(id).utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return Self.json(200, ["raw": raw, "internalDate": "1793990000000", "labelIds": ["INBOX", "UNREAD"]])
        }
    }

    func stream(_ request: URLRequest, into receive: @escaping @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    static func json(_ status: Int, _ body: [String: Any], headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: GoogleOAuth.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// Answers each request with the next of `answers`, recording how many came.
private final class Scripted: OutsideHTTP, @unchecked Sendable {
    enum Answer { case status(Int, [String: String], [String: Any]), failure(URLError) }
    private let lock = NSLock()
    private var answers: [Answer]
    private let last: Answer
    private(set) var asked = 0

    init(_ answers: [Answer], then last: Answer = .status(200, [:], ["id": "18f3a2b4c5d6e7f8"])) {
        self.answers = answers
        self.last = last
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { asked += 1; return answers.isEmpty ? last : answers.removeFirst() }
        switch answer {
        case .status(let status, let headers, let body): return CountingGmail.json(status, body, headers: headers)
        case .failure(let error): throw error
        }
    }

    func stream(_ request: URLRequest, into receive: @escaping @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

/// Google's own "too fast" refusal, as a 403.
nonisolated(unsafe) private let userRateLimit: [String: Any] = [
    "error": ["code": 403, "message": "User-rate limit exceeded.", "errors": [["reason": "userRateLimitExceeded", "domain": "usageLimits"]]],
]

/// A Gmail that waits nowhere, notes each wait it would have made, and has no quota pacing.
private func google(_ http: any OutsideHTTP, waits: Locked<[Duration]> = Locked([])) throws -> GoogleOAuth {
    var google = try #require(GoogleOAuth(clientID: clientID, http: http))
    google.retry.jitter = { 1 }
    google.retry.sleep = { wait in waits.update { $0.append(wait) } }
    google.pace = nil
    return google
}

private func request() -> URLRequest { URLRequest(url: GoogleOAuth.messagesURL.appendingPathComponent("18f3a2b4c5d6e7f8")) }

@Suite struct GmailRetryTests {
    @Test func waitsDoubleWithJitterUpToACapAndNeverUnderRetryAfter() {
        var retry = GmailRetry(first: .seconds(1))
        retry.jitter = { 1 }
        #expect((1...7).map { retry.wait(after: $0, retryAfter: nil) } == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(retry.wait(after: 1, retryAfter: .seconds(7)) == .seconds(7))
        #expect(retry.wait(after: 4, retryAfter: .seconds(3)) == .seconds(8))
        retry.jitter = { 0.5 }
        #expect(retry.wait(after: 3, retryAfter: nil) == .seconds(2))
    }

    @Test func retryAfterIsReadInSecondsOrAsADate() {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: GoogleOAuth.messagesURL, statusCode: 429, httpVersion: nil, headerFields: value.map { ["Retry-After": $0] })!
        }
        #expect(GmailRetry.retryAfter(response("12")) == .seconds(12))
        #expect(GmailRetry.retryAfter(response(nil)) == nil)
        #expect(GmailRetry.retryAfter(response("soon")) == nil)
        #expect(GmailRetry.retryAfter(response("Fri, 20 Nov 2026 16:00:45 GMT"), now: Date(timeIntervalSince1970: 1_795_190_400)) == .seconds(45))
        #expect(GmailRetry.retryAfter(response("Fri, 20 Nov 2026 15:00:00 GMT"), now: Date(timeIntervalSince1970: 1_795_190_400)) == .zero)
    }

    @Test func passingTroublesAreWaitedOutQuietlyHonouringRetryAfter() async throws {
        let waits = Locked<[Duration]>([])
        let http = Scripted([
            .status(503, ["Retry-After": "7"], [:]), .status(429, [:], [:]), .status(403, [:], userRateLimit),
            .failure(URLError(.timedOut)), .status(500, [:], [:]),
        ])
        let data = try await google(http, waits: waits).gmailAnswer(request())
        #expect(!data.isEmpty)
        #expect(http.asked == 6)
        #expect(waits.value == [7, 2, 4, 8, 16].map { Duration.seconds($0) })
    }

    @Test func troubleLastingPastTwoMinutesIsSaid() async throws {
        let waits = Locked<[Duration]>([])
        let http = Scripted([], then: .status(503, [:], [:]))
        await #expect(throws: OutsideMailProblem.unreachable) { try await google(http, waits: waits).gmailAnswer(request()) }
        #expect(waits.value == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(waits.value.reduce(.zero, +) <= .seconds(120))
    }

    @Test func aRetryAfterPastPatienceIsSaidAtOnce() async throws {
        let waits = Locked<[Duration]>([])
        let http = Scripted([], then: .status(429, ["Retry-After": "600"], [:]))
        await #expect(throws: OutsideMailProblem.unreachable) { try await google(http, waits: waits).gmailAnswer(request()) }
        #expect(http.asked == 1 && waits.value.isEmpty)
    }

    @Test func beingOfflineIsSaidAtOnce() async throws {
        let http = Scripted([], then: .failure(URLError(.notConnectedToInternet)))
        await #expect(throws: OutsideMailProblem.offline) { try await google(http).gmailAnswer(request()) }
        #expect(http.asked == 1)
    }

    @Test func aSendIsNeverRepeatedAfterGmailsOwnTrouble() async throws {
        let http = Scripted([.status(503, [:], [:])])
        await #expect(throws: OutsideMailProblem.unreachable) { try await google(http).gmailAnswer(request(), idempotent: false) }
        #expect(http.asked == 1)
        // "Too fast" is said before Gmail does anything, so that one is waited out even for a send.
        let tooFast = Scripted([.status(429, [:], [:])])
        _ = try await google(tooFast).gmailAnswer(request(), idempotent: false)
        #expect(tooFast.asked == 2)
    }
}

@Suite struct GmailImportTests {
    private let account = OutsideAccount(provider: .gmail, address: "mckay.clemens@gmail.com", addedAt: today)

    /// One open of the account, keeping what arrives and what the places record last said.
    private func open(
        _ gmail: CountingGmail, kept: Locked<[String]>, places: Locked<OutsideAccountPlaces?>
    ) async throws {
        let reader = OutsideReader(maker: ICloudInbox(), google: try google(gmail))
        try await reader.download(
            account, credential: .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false)), since: today.addingTimeInterval(-86_400),
            have: { id in kept.value.contains(id) },
            keep: { message in kept.update { $0.append(message.providerID) } },
            seen: { seen in if case .gmail(let seen) = seen { places.update { $0 = seen } } },
            now: today
        )
    }

    @Test func messagesArriveNewestFirstWhileSeveralAreFetchedAtOnce() async throws {
        let gmail = CountingGmail(count: 120)
        gmail.latency = .milliseconds(2)
        let kept = Locked<[String]>([]), places = Locked<OutsideAccountPlaces?>(nil)
        try await open(gmail, kept: kept, places: places)
        #expect(kept.value == gmail.inbox)
        #expect(gmail.mostInFlight > 1 && gmail.mostInFlight <= OutsideReading.gmailInFlight)
        #expect(places.value?.waiting == [])
    }

    @Test func aDownloadCutShortStartsAgainWhereItStopped() async throws {
        let gmail = CountingGmail(count: 40)
        // Gmail stops answering after 15 messages, for longer than is waited out.
        gmail.trouble = { asked in asked >= 15 ? (503, [:]) : nil }
        let kept = Locked<[String]>([]), places = Locked<OutsideAccountPlaces?>(nil)
        await #expect(throws: OutsideMailProblem.unreachable) { try await open(gmail, kept: kept, places: places) }
        let first = kept.value
        // What was kept is the newest, in order, and the rest is noted as waiting.
        #expect(!first.isEmpty && first == Array(gmail.inbox.prefix(first.count)))
        #expect(places.value?.waiting == Array(gmail.inbox.dropFirst(first.count)))
        gmail.trouble = nil
        let before = gmail.gets, fetchedBefore = gmail.fetched.count
        try await open(gmail, kept: kept, places: places)
        #expect(kept.value == gmail.inbox)
        // Nothing already here was asked for again.
        #expect(Set(gmail.fetched.dropFirst(fetchedBefore)).isDisjoint(with: first))
        #expect(gmail.gets - before == gmail.inbox.count - first.count)
    }

    /// Before and after, on the same Gmail: one message at a time, as it was, against several at once.
    /// The request count is the same; the time is what changes.
    @Test func severalAtOnceIsFasterForTheSameRequests() async throws {
        func time(inFlight: Int) async throws -> (Duration, Int) {
            let gmail = CountingGmail(count: 200)
            gmail.latency = .milliseconds(5)
            let api = try google(gmail)
            let ids = try await api.ids(in: "INBOX", accessToken: "ya29.counting", since: today, limit: OutsideReading.mostListed).ids
            let clock = ContinuousClock()
            let took = try await clock.measure {
                try await OutsideReader.fetchGmail(ids, inFlight: inFlight) { try await api.message($0, accessToken: "ya29.counting") } keep: { _, _ in }
            }
            #expect(gmail.listPages == 1)
            return (took, gmail.gets)
        }
        let (before, beforeGets) = try await time(inFlight: 1)
        let (after, afterGets) = try await time(inFlight: OutsideReading.gmailInFlight)
        #expect(beforeGets == 200 && afterGets == 200)
        #expect(after * 3 < before)
        print("Gmail import, 200 messages at 5 ms each: one at a time \(before), \(OutsideReading.gmailInFlight) at once \(after)")
    }

    @Test func fetchingHandsOnInOrderWhateverOrderAnswersCome() async throws {
        let ids = (0..<60).map { String(format: "%04x", $0) }
        let handed = Locked<[String]>([])
        try await OutsideReader.fetchGmail(ids, inFlight: 8) { id in
            try await Task.sleep(for: .microseconds(Int.random(in: 0...3_000)))
            return id == "0007" ? nil : GmailMessage(raw: Data(), received: today, isUnread: false, isStarred: false, labels: [])
        } keep: { id, message in
            handed.update { $0.append(id) }
            #expect((message == nil) == (id == "0007"))
        }
        #expect(handed.value == ids)
    }
}
