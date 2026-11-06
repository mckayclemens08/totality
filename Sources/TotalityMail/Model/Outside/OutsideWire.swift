import Foundation

/// A byte stream to one of a provider's servers. Tests stand in for it; the app uses `StreamTaskWire`.
public protocol OutsideWire: AnyObject, Sendable {
    /// Some bytes, or none once the server has closed.
    func read() async throws -> Data
    func write(_ data: Data) async throws
    /// Switches to TLS. Everything after this is encrypted, and the server's certificate is checked as usual.
    func startTLS()
    func close()
}

/// Opens a wire to an endpoint. It only ever gets endpoints that `OutsideProvider` made.
public protocol OutsideWireMaker: Sendable {
    func open(_ endpoint: OutsideEndpoint) -> any OutsideWire
}

/// Apple's own networking, so this needs no new dependency. Certificate checks are the system's, and
/// nothing here relaxes them. Nothing is cached, and nothing is logged.
public struct StreamTaskWireMaker: OutsideWireMaker {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
    }

    public func open(_ endpoint: OutsideEndpoint) -> any OutsideWire {
        StreamTaskWire(task: session.streamTask(withHostName: endpoint.host, port: endpoint.port), tls: endpoint.security == .tls)
    }
}

final class StreamTaskWire: OutsideWire {
    private let task: URLSessionStreamTask
    static let timeout: TimeInterval = 30

    init(task: URLSessionStreamTask, tls: Bool) {
        self.task = task
        if tls { task.startSecureConnection() }
        task.resume()
    }

    func read() async throws -> Data {
        let (data, _) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: Self.timeout)
        return data ?? Data()
    }

    func write(_ data: Data) async throws {
        try await task.write(data, timeout: Self.timeout)
    }

    func startTLS() { task.startSecureConnection() }

    func close() { task.cancel() }
}

/// Reads whole lines off a wire, and never more than a line's worth of a misbehaving server.
final class WireReader {
    let wire: any OutsideWire
    private var buffer = Data()
    static let longestLine = 64 * 1024

    init(_ wire: any OutsideWire) { self.wire = wire }

    /// Whether the server has sent anything not yet read. After STARTTLS there must be nothing, or it was
    /// slipped in before encryption and can't be trusted.
    var hasUnread: Bool { !buffer.isEmpty }

    /// One line, without its CRLF.
    func line() async throws -> Data {
        while true {
            if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
                let line = buffer[buffer.startIndex..<end.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                return Data(line)
            }
            guard buffer.count <= Self.longestLine else { throw OutsideMailProblem.unexpected }
            let more = try await wire.read()
            guard !more.isEmpty else { throw OutsideMailProblem.unexpected }
            buffer.append(more)
        }
    }

    /// Exactly `count` bytes, for an IMAP literal.
    func bytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let more = try await wire.read()
            guard !more.isEmpty else { throw OutsideMailProblem.unexpected }
            buffer.append(more)
        }
        let taken = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(taken)
    }

    func send(_ line: String) async throws {
        try await wire.write(Data((line + "\r\n").utf8))
    }
}
