import Foundation

/// Who can start a chat with you (issue 149 §4). Totality's Matrix guard checks it on every invite, so a
/// modified app can't get past it. Chats you already have keep working whatever you pick.
public enum MessageReach: String, CaseIterable, Sendable, Identifiable {
    case anyone, followers, friends

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anyone: "Anyone"
        case .followers: "Followers"
        case .friends: "Friends"
        }
    }

    public var detail: String {
        switch self {
        case .anyone: "Anyone on Totality can start a chat"
        case .followers: "People who follow you"
        case .friends: "People you follow who follow you back"
        }
    }
}

/// Whether you can start a chat with someone right now.
public enum ReachAnswer: String, Sendable {
    /// Start it.
    case allowed
    /// Their setting doesn't include you: send a request first.
    case ask
    /// Your request is waiting for them.
    case asked
    /// No such person, as far as you can tell.
    case unknown
}

/// Someone asking to message you. It says who, and nothing else: their first message waits for the chat.
public struct MessageRequest: Identifiable, Equatable, Sendable {
    public let username: String
    public let sent: Date?
    public var id: String { username }

    public init(username: String, sent: Date?) {
        self.username = username
        self.sent = sent
    }
}

public protocol MessagePrivacyService: Sendable {
    func myReach() async throws -> MessageReach
    func setReach(_ reach: MessageReach) async throws
    func reach(_ username: String) async throws -> ReachAnswer
    func sendRequest(to username: String) async throws
    func incoming() async throws -> [MessageRequest]
    func answer(_ username: String, accept: Bool) async throws
    /// People who accepted your requests.
    func accepted() async throws -> [String]
}

/// The setting and requests on Totality's Supabase, with the signed-in person's own token. Nothing is
/// logged, and requests hold no message content.
public final class RestMessagePrivacy: MessagePrivacyService {
    private let base: URL
    private let key: String
    private let token: @Sendable () async throws -> String
    private let session: URLSession

    public init(base: URL, publishableKey: String, token: @escaping @Sendable () async throws -> String, session: URLSession = .shared) {
        self.base = base
        self.key = publishableKey
        self.token = token
        self.session = session
    }

    private struct HandleRow: Decodable { let handle: String; let created_at: String? }

    public func myReach() async throws -> MessageReach {
        let value = try JSONDecoder().decode(String.self, from: try await call("message_my_reach"))
        return MessageReach(rawValue: value) ?? .anyone
    }

    public func setReach(_ reach: MessageReach) async throws {
        _ = try await call("message_set_reach", ["p_reach": reach.rawValue])
    }

    public func reach(_ username: String) async throws -> ReachAnswer {
        let value = try JSONDecoder().decode(String.self, from: try await call("message_reach", ["p_handle": username]))
        return ReachAnswer(rawValue: value) ?? .unknown
    }

    public func sendRequest(to username: String) async throws {
        _ = try await call("message_request_send", ["p_handle": username])
    }

    public func incoming() async throws -> [MessageRequest] {
        try JSONDecoder().decode([HandleRow].self, from: try await call("message_requests_incoming"))
            .map { MessageRequest(username: $0.handle, sent: $0.created_at.flatMap(Self.date)) }
    }

    public func answer(_ username: String, accept: Bool) async throws {
        _ = try await call("message_request_answer", ["p_handle": username, "p_accept": accept])
    }

    public func accepted() async throws -> [String] {
        try JSONDecoder().decode([HandleRow].self, from: try await call("message_requests_accepted")).map(\.handle)
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/" + name))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        let token: String
        do { token = try await self.token() } catch { throw MessagesError.notSignedIn }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw MessagesError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    /// The server's refusal in plain words. Its own text is only matched, never shown.
    static func error(status: Int, data: Data) -> MessagesError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        if status == 401 { return .notSignedIn }
        if message.contains("too many message requests") { return .failed("That's a lot of requests today. Try again tomorrow.") }
        if message.contains("no such user") { return .noSuchPerson }
        if message.contains("no such request") { return .failed("That request isn't there any more.") }
        return .failed("That didn't go through. Try again.")
    }

    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        let trimmed = text.replacingOccurrences(of: " ", with: "T")
            .replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\+00$", with: "Z", options: .regularExpression)
        return plain.date(from: trimmed)
    }
}
