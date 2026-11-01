import Foundation
import Network
import TotalityCore
@testable import TotalityWeb

/// Answers requests in place of the gateway, and remembers what it was sent.
final class FakeGateway: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let url: URL
        let authorization: String?
        let body: [String: Sendable]
        let method: String
    }

    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: @Sendable (Sent) -> (Int, Data)] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]

    /// Each client gets its own host, so tests running at once don't meet.
    static func client(
        token: @escaping @Sendable () async throws -> String = { "good.token" },
        answer: @escaping @Sendable (Sent) -> (Int, Data)
    ) -> (WebSearchClient, host: String) {
        let host = "gateway-\(UUID().uuidString.lowercased()).test"
        lock.withLock {
            answers[host] = answer
            sent[host] = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGateway.self]
        let client = WebSearchClient(server: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: token)
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
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let sendable = object.mapValues { value -> Sendable in
            switch value {
            case let number as NSNumber: number.intValue
            case let text as String: text
            default: "\(value)"
            }
        }
        let sent = Sent(url: url, authorization: request.value(forHTTPHeaderField: "Authorization"), body: sendable, method: request.httpMethod ?? "")
        let answer = Self.lock.withLock {
            Self.sent[host, default: []].append(sent)
            return Self.answers[host]
        }
        let (status, body) = answer?(sent) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func resultsJSON(_ titles: [String], partial: Bool = false) -> Data {
    let results = titles.map { title in
        ["title": title, "url": "https://example.com/\(title)", "site": "example.com", "snippet": "About \(title)."] as [String: Any]
    }
    return try! JSONSerialization.data(withJSONObject: ["results": results, "partial": partial])
}

func until(_ done: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if await done() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
}

extension Bundle {
    /// The target's own bundle isn't reachable by name from the tests, so this looks beside them.
    static func module(named name: String) -> URL? {
        let tests = Bundle(for: FakeGateway.self).bundleURL.deletingLastPathComponent()
        return tests.appendingPathComponent("Totality_TotalityWeb.bundle/\(name).json")
    }
}

final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
}

/// A real web server on this machine, so tests can watch what WebKit actually fetches.
final class LocalSite: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var paths: [String] = []
    private let pages: [String: (type: String, extra: String, body: String)]
    /// Paths that never answer, like a server stalling on purpose.
    private let silent: Set<String>
    private var held: [NWConnection] = []

    init(pages: [String: (type: String, extra: String, body: String)], silent: Set<String> = []) throws {
        self.pages = pages
        self.silent = silent
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
    }

    deinit { listener.cancel() }

    var requested: [String] { lock.withLock { paths } }

    func url(_ path: String) async throws -> URL {
        for _ in 0..<200 {
            if let port = listener.port?.rawValue { return URL(string: "http://127.0.0.1:\(port)\(path)")! }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data else { return connection.cancel() }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first ?? ""
            let path = String(line.split(separator: " ").dropFirst().first ?? "/")
            self.lock.withLock { self.paths.append(path) }
            if self.silent.contains(path) {
                self.lock.withLock { self.held.append(connection) }
                return
            }
            let page = self.pages[path] ?? ("text/plain", "", "ok")
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(page.type)\r\n\(page.extra)Content-Length: \(page.body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + page.body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
