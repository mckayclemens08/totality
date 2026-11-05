import Foundation
import Testing
@testable import TotalityMail

/// Answers in place of the mail service on the server, and remembers what it was sent.
final class FakeMailServer: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let body: Data
    }

    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: @Sendable (Sent) -> (Int, Data)] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]
    nonisolated(unsafe) private static var failures: [String: URLError.Code] = [:]

    /// Each client gets its own host, so tests running at once don't meet.
    static func client(
        token: @escaping @Sendable () async throws -> String = { "eyJ.signed-in.token" },
        failing: URLError.Code? = nil,
        answer: @escaping @Sendable (Sent) -> (Int, Data)
    ) -> (MailServerClient, host: String) {
        let host = "mail-\(UUID().uuidString.lowercased()).test"
        lock.withLock {
            answers[host] = answer
            sent[host] = []
            failures[host] = failing
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeMailServer.self]
        let client = MailServerClient(server: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: token)
        return (client, host)
    }

    static func requests(to host: String) -> [Sent] {
        lock.withLock { sent[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        let sent = Sent(url: url, method: request.httpMethod ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"), body: data)
        let (answer, failure) = Self.lock.withLock {
            Self.sent[host, default: []].append(sent)
            return (Self.answers[host], Self.failures[host])
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let (status, body) = answer?(sent) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func body(_ sent: FakeMailServer.Sent) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: sent.body)) as? [String: Any] ?? [:]
}

@Suite struct MailServerClientTests {
    private let publicKey = Data((0..<32).map { UInt8($0 * 7 % 256) })
    private let invoice = UUID(uuidString: "6f1c2a7e-93d4-4b8e-a1f0-2c5d8e9b7a31")!
    private let ferry = UUID(uuidString: "0b9e4d12-5a6f-4c3b-8e7d-1f2a3b4c5d6e")!

    @Test("Publishing a key sends the public half in the body of a POST, signed in")
    func publishes() async throws {
        let (client, host) = FakeMailServer.client { _ in (201, Data()) }
        #expect(try await client.publish(publicKey: publicKey) == .published)
        let sent = try #require(FakeMailServer.requests(to: host).first)
        #expect(sent.method == "POST")
        #expect(sent.url.path() == "/mail/key")
        #expect(sent.url.query() == nil)
        #expect(sent.authorization == "Bearer eyJ.signed-in.token")
        #expect(body(sent)["publicKey"] as? String == publicKey.base64EncodedString())
        #expect(!sent.url.absoluteString.contains(publicKey.base64EncodedString()))
    }

    @Test func theSameKeyAgainIsFine() async throws {
        let (client, _) = FakeMailServer.client { _ in (200, Data()) }
        #expect(try await client.publish(publicKey: publicKey) == .alreadyThere)
    }

    @Test("A different key holding the mailbox is its own error, never one to retry")
    func keyConflict() async {
        let (client, _) = FakeMailServer.client { _ in (409, Data()) }
        await #expect(throws: MailServerError.keyConflict) { try await client.publish(publicKey: publicKey) }
    }

    @Test func aKeyOfTheWrongSizeIsNeverSent() async {
        let (client, host) = FakeMailServer.client { _ in (201, Data()) }
        await #expect(throws: MailServerError.unavailable) { try await client.publish(publicKey: Data(count: 16)) }
        #expect(FakeMailServer.requests(to: host).isEmpty)
    }

    @Test("The list is a signed-in GET with nothing in the address")
    func lists() async throws {
        let (client, host) = FakeMailServer.client { _ in
            (200, json([
                "messages": [
                    ["id": "6f1c2a7e-93d4-4b8e-a1f0-2c5d8e9b7a31", "size": 48_213, "received": "2026-11-04T09:12:44.512Z"],
                    ["id": "0b9e4d12-5a6f-4c3b-8e7d-1f2a3b4c5d6e", "size": 3_907, "received": "2026-11-05T17:40:02.000Z"],
                ],
                "used": 52_120, "limit": 1_073_741_824,
            ]))
        }
        let list = try await client.list()
        let sent = try #require(FakeMailServer.requests(to: host).first)
        #expect(sent.method == "GET")
        #expect(sent.url.path() == "/mail/list")
        #expect(sent.url.query() == nil)
        #expect(sent.authorization == "Bearer eyJ.signed-in.token")
        #expect(list.messages.map(\.id) == [invoice, ferry])
        #expect(list.messages.first?.size == 48_213)
        #expect(list.messages.first?.received == Date(timeIntervalSince1970: 1_793_783_564.512))
        #expect(list.used == 52_120)
        #expect(!list.isFull)
    }

    @Test func aFullMailboxSaysSo() async throws {
        let (client, _) = FakeMailServer.client { _ in (200, json(["messages": [], "used": 1_073_741_824, "limit": 1_073_741_824])) }
        #expect(try await client.list().isFull)
    }

    @Test("A message is fetched by its random ID alone, and comes back exactly as sealed")
    func fetches() async throws {
        let sealed = Data([1] + (0..<120).map { UInt8($0) })
        let (client, host) = FakeMailServer.client { _ in (200, sealed) }
        #expect(try await client.message(invoice) == sealed)
        let sent = try #require(FakeMailServer.requests(to: host).first)
        #expect(sent.method == "GET")
        #expect(sent.url.path() == "/mail/message/6f1c2a7e-93d4-4b8e-a1f0-2c5d8e9b7a31")
        #expect(sent.url.query() == nil)
        #expect(sent.authorization == "Bearer eyJ.signed-in.token")
    }

    @Test("Deleting names the messages in the body of a POST")
    func deletes() async throws {
        let (client, host) = FakeMailServer.client { _ in (200, json(["deleted": 2])) }
        #expect(try await client.delete([invoice, ferry]) == 2)
        let sent = try #require(FakeMailServer.requests(to: host).first)
        #expect(sent.method == "POST")
        #expect(sent.url.path() == "/mail/delete")
        #expect(sent.url.query() == nil)
        #expect(!sent.url.absoluteString.contains(invoice.uuidString.lowercased()))
        #expect(Set(body(sent)["ids"] as? [String] ?? []) == [invoice.uuidString.lowercased(), ferry.uuidString.lowercased()])
    }

    @Test func deletingNothingSendsNothing() async throws {
        let (client, host) = FakeMailServer.client { _ in (200, json(["deleted": 0])) }
        #expect(try await client.delete([]) == 0)
        #expect(FakeMailServer.requests(to: host).isEmpty)
    }

    @Test("Each refusal says what it is", arguments: [
        (401, MailServerError.signedOut), (500, .unavailable), (502, .unavailable), (503, .unavailable), (404, .unavailable),
    ])
    func refusals(status: Int, error: MailServerError) async {
        let (client, _) = FakeMailServer.client { _ in (status, Data()) }
        await #expect(throws: error) { try await client.list() }
        await #expect(throws: error) { try await client.message(invoice) }
        await #expect(throws: error) { try await client.delete([invoice]) }
        await #expect(throws: error) { try await client.publish(publicKey: publicKey) }
    }

    @Test("No network is offline", arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost])
    func offline(code: URLError.Code) async {
        let (client, _) = FakeMailServer.client(failing: code) { _ in (500, Data()) }
        await #expect(throws: MailServerError.offline) { try await client.list() }
    }

    @Test func noSignInMeansNothingIsSent() async {
        let (client, host) = FakeMailServer.client(token: { throw CancellationError() }) { _ in (200, Data()) }
        await #expect(throws: MailServerError.signedOut) { try await client.list() }
        await #expect(throws: MailServerError.signedOut) { try await client.publish(publicKey: publicKey) }
        #expect(FakeMailServer.requests(to: host).isEmpty)
    }

    @Test func aDamagedListIsNotACrash() async {
        let (client, _) = FakeMailServer.client { _ in (200, Data("<html>Bad gateway</html>".utf8)) }
        await #expect(throws: MailServerError.unavailable) { try await client.list() }
    }
}
