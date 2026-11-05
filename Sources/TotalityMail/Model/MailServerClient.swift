import Foundation

public enum MailServerError: Error, Equatable, Sendable {
    case signedOut, offline, unavailable
    /// A different key already holds this mailbox. Only the server's owner can put that right, so the
    /// screens show it as a problem with the account, never as something to try again.
    case keyConflict
}

/// One stored message as the list names it. The server can't read mail, so this is all it knows.
public struct MailServerEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let size: Int
    public let received: Date

    public init(id: UUID, size: Int, received: Date) {
        self.id = id
        self.size = size
        self.received = received
    }
}

public struct MailServerList: Codable, Equatable, Sendable {
    public let messages: [MailServerEntry]
    public let used: Int
    public let limit: Int

    public init(messages: [MailServerEntry], used: Int, limit: Int) {
        self.messages = messages
        self.used = used
        self.limit = limit
    }

    public var isFull: Bool { used >= limit }
}

public enum MailKeyPublication: Equatable, Sendable {
    case published
    /// The server already had this exact key.
    case alreadyThere
}

/// What `ServerMailStore` needs from the mail service, so tests can stand in for it.
public protocol MailServer: Sendable {
    func publish(publicKey: Data) async throws -> MailKeyPublication
    func list() async throws -> MailServerList
    func message(_ id: UUID) async throws -> Data
    func delete(_ ids: Set<UUID>) async throws -> Int
}

/// Talks to the mail service on your server. The account always comes from the sign-in, never from the
/// request. Message IDs go in the path only because they're random and say nothing; anything else goes
/// in a body. Nothing is cached, and nothing is logged.
public struct MailServerClient: MailServer {
    public static let server = URL(string: "https://usetotality.com")!

    private let server: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(server: URL = MailServerClient.server, session: URLSession? = nil, token: @escaping @Sendable () async throws -> String) {
        self.server = server
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The public half of `MailKey`. Publish only once the device's key backup is settled, because the
    /// key held here can never be replaced.
    public func publish(publicKey: Data) async throws -> MailKeyPublication {
        guard publicKey.count == 32 else { throw MailServerError.unavailable }
        let body = try JSONEncoder().encode(["publicKey": publicKey.base64EncodedString()])
        let (status, _) = try await send("mail/key", method: "POST", body: body)
        switch status {
        case 201: return .published
        case 200: return .alreadyThere
        case 409: throw MailServerError.keyConflict
        default: throw Self.error(for: status)
        }
    }

    public func list() async throws -> MailServerList {
        let data = try await expectOK(try await send("mail/list", method: "GET"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                // Milliseconds, as JavaScript counts them, unless it's plainly seconds.
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
            }
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date")
        }
        do {
            return try decoder.decode(MailServerList.self, from: data)
        } catch {
            throw MailServerError.unavailable
        }
    }

    /// The bytes exactly as the server sealed them. Only `MailKey` opens them.
    public func message(_ id: UUID) async throws -> Data {
        try expectOK(try await send("mail/message/\(id.uuidString.lowercased())", method: "GET"))
    }

    /// For good. The server keeps no copy.
    public func delete(_ ids: Set<UUID>) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let body = try JSONEncoder().encode(["ids": ids.map { $0.uuidString.lowercased() }.sorted()])
        let data = try expectOK(try await send("mail/delete", method: "POST", body: body))
        struct Answer: Decodable { let deleted: Int }
        do {
            return try JSONDecoder().decode(Answer.self, from: data).deleted
        } catch {
            throw MailServerError.unavailable
        }
    }

    private func expectOK(_ answer: (Int, Data)) throws -> Data {
        guard answer.0 == 200 else { throw Self.error(for: answer.0) }
        return answer.1
    }

    private static func error(for status: Int) -> MailServerError {
        status == 401 ? .signedOut : .unavailable
    }

    private func send(_ path: String, method: String, body: Data? = nil) async throws -> (Int, Data) {
        let bearer: String
        do {
            bearer = try await token()
        } catch {
            throw MailServerError.signedOut
        }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offline.contains(error.code) {
            throw MailServerError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MailServerError.unavailable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MailServerError.unavailable }
        return (status, data)
    }

    private static let offline: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotConnectToHost, .cannotFindHost, .timedOut,
    ]
}
