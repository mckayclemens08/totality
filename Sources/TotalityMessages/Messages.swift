import Foundation

// What Messages shows, in plain types that don't depend on the Matrix SDK, so the screens and their
// logic work and test on every platform.

/// One conversation in the list, or a request someone sent.
public struct ChatSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// A first message from someone you haven't talked to. It stays a request until you accept it.
    public let isRequest: Bool
    /// Who sent the request, when it is one.
    public let from: String?
    public let lastMessage: String?
    public let lastActivity: Date?
    public let unread: Int
    /// A small group rather than a chat with one person.
    public let isGroup: Bool

    public init(
        id: String, title: String, isRequest: Bool = false, from: String? = nil,
        lastMessage: String? = nil, lastActivity: Date? = nil, unread: Int = 0, isGroup: Bool = false
    ) {
        self.id = id
        self.isGroup = isGroup
        self.title = title
        self.isRequest = isRequest
        self.from = from
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.unread = unread
    }

    /// Newest first. Chats with no activity yet go last, in a stable order.
    public static func newestFirst(_ a: ChatSummary, _ b: ChatSummary) -> Bool {
        switch (a.lastActivity, b.lastActivity) {
        case let (x?, y?) where x != y: x > y
        case (_?, nil): true
        case (nil, _?): false
        default: a.id < b.id
        }
    }
}

/// One message in a conversation.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case sending
        /// It didn't go. `canRetry` is false when the server refused it outright.
        case failed(canRetry: Bool)
        case sent
    }

    public enum Kind: Sendable, Equatable {
        case text
        /// A photo, sealed on the sender's device. Its size helps lay it out before it opens.
        case photo(width: Int?, height: Int?)
        /// A short video, sealed the same way.
        case video(seconds: Double?)
        /// Removed by its sender. Only the fact that something was there remains.
        case deleted
    }

    public let id: String
    public let sender: String
    /// The text, or a short description for a photo or a deleted message.
    public let body: String
    public let isOwn: Bool
    public let time: Date
    public let state: State
    /// False when this device hasn't got the key yet. The body is then a placeholder.
    public let decrypted: Bool
    /// Someone else in the chat has read up to this message or past it.
    public var seen: Bool
    public let kind: Kind
    public let reactions: [ChatReaction]
    public let replyTo: ReplyPreview?
    /// The server has it, so it can be replied to.
    public let canReply: Bool

    public init(
        id: String, sender: String, body: String, isOwn: Bool, time: Date,
        state: State = .sent, decrypted: Bool = true, seen: Bool = false,
        kind: Kind = .text, reactions: [ChatReaction] = [], replyTo: ReplyPreview? = nil, canReply: Bool = true
    ) {
        self.id = id
        self.sender = sender
        self.body = body
        self.isOwn = isOwn
        self.time = time
        self.state = state
        self.decrypted = decrypted
        self.seen = seen
        self.kind = kind
        self.reactions = reactions
        self.replyTo = replyTo
        self.canReply = canReply
    }

    /// Only your own messages, and only once they exist on the server or failed to get there.
    public var canDelete: Bool { isOwn && kind != .deleted }
    /// Text you can copy. Photos and deleted messages have none.
    public var copyableText: String? { kind == .text && decrypted ? body : nil }
    public var isPhoto: Bool { if case .photo = kind { true } else { false } }
    public var isVideo: Bool { if case .video = kind { true } else { false } }
}

/// One reaction on a message: which emoji, how many people, and whether you're one of them.
public struct ChatReaction: Sendable, Equatable, Hashable {
    public let key: String
    public let count: Int
    public let mine: Bool

    public init(key: String, count: Int, mine: Bool) {
        self.key = key
        self.count = count
        self.mine = mine
    }
}

/// The message a reply answers, shown above it.
public struct ReplyPreview: Sendable, Equatable {
    public let sender: String
    public let text: String

    public init(sender: String, text: String) {
        self.sender = sender
        self.text = text
    }
}

/// The few reactions a long press offers: four, so they fit in one row of the menu.
public enum QuickReactions {
    public static let all = ["❤️", "😂", "👍", "😢"]
}

/// Whether the device can reach the Matrix server right now.
public enum Connection: Sendable, Equatable {
    case connecting, online, offline
}

public enum MessagesError: Error, Equatable, Sendable {
    case notSignedIn
    case notAUsername
    case ownUsername
    case noSuchPerson
    case notEncrypted
    case offline
    case failed(String)

    public var message: String {
        switch self {
        case .notSignedIn: "Sign in to Totality to use Messages."
        case .notAUsername: "That isn't a Totality username."
        case .ownUsername: "That's your own username."
        case .noSuchPerson: "There's no one with that username."
        case .notEncrypted: "That chat isn't end-to-end encrypted, so nothing was sent."
        case .offline: "You're offline. Try again when you're connected."
        case .failed(let reason): reason
        }
    }
}

public enum MessagesUsername {
    /// A typed username as the server knows it: an @ in front and spaces around are dropped, and it's
    /// lower case. Nil unless it follows the rule handles are claimed under.
    public static func normalized(_ typed: String) -> String? {
        let name = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "@" }).lowercased()
        return name.wholeMatch(of: /[a-z0-9_]{3,24}/) != nil ? name : nil
    }

    /// `@name:usetotality.com` shown as `name`. Anything else is shown as it is.
    public static func display(_ matrixID: String) -> String {
        guard matrixID.hasPrefix("@"), let colon = matrixID.firstIndex(of: ":") else { return matrixID }
        return String(matrixID[matrixID.index(after: matrixID.startIndex)..<colon])
    }
}

/// The SDK describes every list as a series of changes. This applies them to an array, ignoring any
/// change that points past the end rather than crashing on it.
public enum ListChange<Element> {
    case append([Element])
    case clear
    case pushFront(Element)
    case pushBack(Element)
    case popFront
    case popBack
    case insert(Int, Element)
    case set(Int, Element)
    case remove(Int)
    case truncate(Int)
    case reset([Element])

    public func apply(to list: inout [Element]) {
        switch self {
        case .append(let values): list += values
        case .clear: list = []
        case .pushFront(let value): list.insert(value, at: 0)
        case .pushBack(let value): list.append(value)
        case .popFront: if !list.isEmpty { list.removeFirst() }
        case .popBack: if !list.isEmpty { list.removeLast() }
        case .insert(let index, let value): list.insert(value, at: min(max(index, 0), list.count))
        case .set(let index, let value): if list.indices.contains(index) { list[index] = value }
        case .remove(let index): if list.indices.contains(index) { list.remove(at: index) }
        case .truncate(let length): list = Array(list.prefix(max(length, 0)))
        case .reset(let values): list = values
        }
    }
}

extension ChatMessage {
    /// Marks each of your messages as seen when someone else has read it or anything after it.
    /// `readUpTo` is the index of the newest message someone else has read, if any.
    public static func markingSeen(_ messages: [ChatMessage], readUpTo: Int?) -> [ChatMessage] {
        guard let readUpTo else { return messages }
        return messages.enumerated().map { index, message in
            var message = message
            message.seen = message.isOwn && index <= readUpTo
            return message
        }
    }
}

/// What a signed-in Messages connection can do. The Matrix one is the real thing; tests use a fake.
public protocol MessagesService: AnyObject, Sendable {
    /// The account this connection belongs to, so a different sign-in gets a different connection.
    var account: String { get }
    var userID: String { get }
    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws
    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void)
    func accept(_ chat: String) async throws
    func decline(_ chat: String) async throws
    /// Declines the request and ignores its sender, so nothing more arrives from them.
    func block(_ chat: String) async throws
    /// Finds the direct chat with that username, or starts an encrypted one. Returns its ID.
    func startChat(with username: String) async throws -> String
    func openChat(_ chat: String) async throws -> any ChatChannel
    /// Starts an encrypted group with these usernames. It has no name of its own: a Matrix room
    /// name isn't end-to-end encrypted, so the group is shown by who's in it.
    func startGroup(with usernames: [String]) async throws -> String
    /// Ignores this person, so nothing more from them arrives, and leaves your chat with them.
    func block(person: String, leaving chat: String?) async throws
    func blocked() async throws -> [String]
    func unblock(_ person: String) async throws
    func leave(_ chat: String) async throws
    func stop() async
}

/// One open conversation.
public protocol ChatChannel: AnyObject, Sendable {
    var title: String { get }
    func observe(
        messages: @escaping @Sendable ([ChatMessage]) -> Void,
        typing: @escaping @Sendable ([String]) -> Void
    ) async
    func loadEarlier() async
    /// Sends text, as a reply when `replyingTo` names a message.
    func send(_ text: String, replyingTo: String?) async throws
    /// Sends a photo. The SDK seals it on this device before it's uploaded, and the key travels inside
    /// the encrypted message.
    func sendPhoto(_ photo: OutgoingPhoto, replyingTo: String?) async throws
    /// Sends a short video, sealed the same way as a photo. Its file is removed once it's queued.
    func sendVideo(_ video: OutgoingVideo, replyingTo: String?) async throws
    func retry(_ message: String) async throws
    /// Adds your reaction, or takes it away if it's already there.
    func toggleReaction(_ key: String, on message: String) async throws
    /// Removes your message for everyone in the chat.
    func delete(_ message: String) async throws
    /// A photo's bytes, opened on this device. `thumbnail` asks for the small version.
    func photo(_ message: String, thumbnail: Bool) async throws -> Data
    /// A video's bytes, opened on this device.
    func video(_ message: String) async throws -> Data
    /// This chat's ID, so per-chat settings on this device can be kept apart.
    var id: String { get }
    /// The other person in a one-to-one chat. Nil in a group.
    var otherPerson: String? { get }
    var isGroup: Bool { get }
    /// The chat's disappearing setting, now and whenever someone changes it.
    func observeDisappearing(_ onChange: @escaping @Sendable (Disappearing) -> Void) async
    func setDisappearing(_ setting: Disappearing) async throws
    /// A private receipt when `share` is off, so your own devices still know what you've read.
    func markRead(share: Bool) async
    func setTyping(_ typing: Bool) async
    func close()
}

/// Opens a connection for an account. Throws `notSignedIn` when there's no Totality sign-in.
public typealias MessagesConnector = @Sendable (_ account: String) async throws -> any MessagesService

/// Read receipts and typing are on by default (owner, 2026-11-05), with one switch to stop sending yours.
public enum MessagesPreferences {
    public static let shareReadAndTypingKey = "messages.shareReadAndTyping"

    public static func shareReadAndTyping(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: shareReadAndTypingKey) as? Bool ?? true
    }
}

/// Disappearing messages, per chat and off by default (owner, 2026-11-05).
public enum Disappearing: String, Sendable, Equatable, CaseIterable, Identifiable {
    case off
    case afterViewing
    case day
    case week

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .afterViewing: "After viewing"
        case .day: "After 24 hours"
        case .week: "After 7 days"
        }
    }

    /// How long a message lasts, for the timed choices.
    public var lifetime: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .off, .afterViewing: nil
        }
    }

    /// Kept in the room's standard retention setting, which every member's app can read. The server
    /// can see that it's on and for how long, but never the messages.
    public static let afterViewingKey = "app.totality.after_viewing"

    public var stateJSON: String {
        switch self {
        case .off: "{}"
        case .afterViewing: "{\"\(Self.afterViewingKey)\":true}"
        case .day, .week: "{\"max_lifetime\":\(Int(lifetime! * 1000))}"
        }
    }

    public init(stateJSON: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(stateJSON.utf8))) as? [String: Any] else {
            self = .off
            return
        }
        if object[Self.afterViewingKey] as? Bool == true {
            self = .afterViewing
        } else if let ms = (object["max_lifetime"] as? NSNumber)?.doubleValue, ms > 0 {
            self = ms <= 86_400_000 ? .day : .week
        } else {
            self = .off
        }
    }
}

/// Which messages a disappearing chat still shows, and which of your own to remove from the server.
public enum DisappearingRule {
    /// Hides other people's messages once they've expired here, even if their sender hasn't removed
    /// them yet. `viewedUpTo` is the newest message time you'd already seen when you last left the chat.
    public static func visible(
        _ messages: [ChatMessage], setting: Disappearing, now: Date, viewedUpTo: Date?
    ) -> [ChatMessage] {
        messages.filter { message in
            guard message.kind != .deleted else { return true }
            if let lifetime = setting.lifetime { return message.time.addingTimeInterval(lifetime) > now }
            if setting == .afterViewing, !message.isOwn, let viewedUpTo { return message.time > viewedUpTo }
            return true
        }
    }

    /// Your own messages that are due to go: past their time, or seen by someone when it's after viewing.
    public static func due(_ messages: [ChatMessage], setting: Disappearing, now: Date) -> [ChatMessage] {
        messages.filter { message in
            guard message.isOwn, message.state == .sent, message.kind != .deleted else { return false }
            if let lifetime = setting.lifetime { return message.time.addingTimeInterval(lifetime) <= now }
            return setting == .afterViewing && message.seen
        }
    }
}

/// Usernames typed for a group, separated by commas or spaces.
public enum GroupMembers {
    /// Up to 20 people, you included.
    public static let limit = 20

    public static func parse(_ typed: String, own: String) throws -> [String] {
        let parts = typed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        var names: [String] = []
        for part in parts {
            guard let name = MessagesUsername.normalized(part) else { throw MessagesError.failed("“\(part)” isn't a Totality username.") }
            if name != own && !names.contains(name) { names.append(name) }
        }
        guard names.count >= 2 else { throw MessagesError.failed("A group needs at least two other people. For one person, start a chat.") }
        guard names.count < limit else { throw MessagesError.failed("A group can have up to \(limit) people, you included.") }
        return names
    }
}
