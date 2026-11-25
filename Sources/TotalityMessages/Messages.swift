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
    /// Where a group's photo is kept on the server. Group photos aren't end-to-end encrypted.
    public let photo: String?
    /// The Matrix ID of the one other person in a joined chat, for their public profile. Never set on a
    /// request: looking them up would only tell the directory the request was seen.
    public let otherPerson: String?
    /// The Matrix ID of whoever sent the last message, when it wasn't you. A group's row names them.
    public let lastSender: String?

    public init(
        id: String, title: String, isRequest: Bool = false, from: String? = nil,
        lastMessage: String? = nil, lastActivity: Date? = nil, unread: Int = 0, isGroup: Bool = false,
        photo: String? = nil, otherPerson: String? = nil, lastSender: String? = nil
    ) {
        self.id = id
        self.lastSender = lastSender
        self.otherPerson = otherPerson
        self.isGroup = isGroup
        self.photo = photo
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
    /// A photo sent to be opened once.
    public let viewOnce: Bool
    /// For a view-once photo: someone other than the sender has opened it (or, on the receiving
    /// side, you have). Nothing else sets this.
    public var opened: Bool

    public init(
        id: String, sender: String, body: String, isOwn: Bool, time: Date,
        state: State = .sent, decrypted: Bool = true, seen: Bool = false,
        kind: Kind = .text, reactions: [ChatReaction] = [], replyTo: ReplyPreview? = nil, canReply: Bool = true,
        viewOnce: Bool = false, opened: Bool = false
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
        self.viewOnce = viewOnce
        self.opened = opened
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
    /// What a double tap puts on a message.
    public static let heart = "❤️"
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
    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String
    /// A group's photo. These are stored on the server without end-to-end encryption.
    func groupPhoto(_ location: String) async throws -> Data
    /// Ignores this person, so nothing more from them arrives, and leaves your chat with them.
    func block(person: String, leaving chat: String?) async throws
    func blocked() async throws -> [String]
    func unblock(_ person: String) async throws
    func leave(_ chat: String) async throws
    /// Backs up message keys under the secret from the recovery key, or opens the backup with it, which
    /// also verifies this device. Nil when this device doesn't have the recovery key. Never resets.
    func settleKeys(recoverySecret: String?) async -> MessageKeys
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
    /// People in a one-to-one chat who aren't you or the person it's with. Anything sent reaches them too.
    var extraPeople: [String] { get }
    var isGroup: Bool { get }
    /// The chat's disappearing setting, now and whenever someone changes it.
    /// A group's name and photo. Matrix keeps both outside the encryption, which the screens say.
    func rename(_ name: String?) async throws
    func setPhoto(_ photo: GroupPhoto?) async throws
    var photo: String? { get }

    func observeDisappearing(_ onChange: @escaping @Sendable (DisappearingState) -> Void) async
    func setDisappearing(_ setting: Disappearing) async throws
    /// A private receipt when `share` is off, so your own devices still know what you've read.
    func markRead(share: Bool) async
    func setTyping(_ typing: Bool) async
    func close()
}

/// Whether this account's message history is backed up under the recovery key, and this device verified.
public enum MessageKeys: Equatable, Sendable {
    case checking
    /// Backed up, and this device is verified by the account's own keys.
    case backedUp
    /// This device doesn't have the account's recovery key yet, so it can't back up or be verified.
    case needsRecoveryKey
    /// History is backed up from another device, and entering the recovery key here restores it.
    case canRestore
    /// A backup exists, but this account's recovery key doesn't open it.
    case doesntOpen
    case failed(String)

    /// Said plainly in Messages' menu.
    public var summary: String? {
        switch self {
        case .checking: nil
        case .backedUp: "Your message history is backed up with your recovery key, and this device is verified."
        case .needsRecoveryKey: "Set up your recovery key to back up your message history and verify this device. Messages works without it, but a new phone won't get your history."
        case .canRestore: "Your message history is backed up. Enter your recovery key to restore it on this device."
        case .doesntOpen: "Your message history backup didn't open with your recovery key. New messages still work, but older ones may not open on this device."
        case .failed(let reason): reason
        }
    }
}

/// When this device may hand Messages the secret that locks an account's key backup: only for the
/// account that owns this device's content key, and only once that key is in the account's backup, so
/// the recovery key can bring it back on a new device. Anything else would lock one person's history
/// with another person's key, or with a key nothing can restore.
public enum RecoverySecretRule {
    public static func allows(keyOwner: String?, account: String, joinedBackup: Bool) -> Bool {
        joinedBackup && keyOwner == account
    }
}

/// What a message that won't open says, which depends on who sent it. Someone else's message usually
/// opens once their device shares its key. One of your own from an earlier install of Totality only
/// opens if its key reached the backup; if that install never had one, the key went with it.
public enum LockedMessage {
    /// Shown in place of the text.
    public static func placeholder(isOwn: Bool) -> String {
        isOwn ? "Can't be opened on this device" : "Waiting for this message's key"
    }

    /// Shown under it.
    public static func note(isOwn: Bool) -> String {
        isOwn
            ? "Sent from an earlier install of Totality. Its key stayed on that install, so this device can't open it."
            : "It will open once the sender's device shares the key, usually when they're next online."
    }

    /// Restoring only helps your own messages, and only once a backup exists to restore from.
    public static func offersRestore(isOwn: Bool, keys: MessageKeys) -> Bool {
        isOwn && keys == .canRestore
    }

    public static let restoreLabel = "Restore with your recovery key"
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

extension MessagesPreferences {
    public static let newChatsDisappearKey = "messages.newChatsDisappear"

    /// What a chat you start gets for its timer. Off unless you pick one.
    public static func newChatsDisappear(_ defaults: UserDefaults = .standard) -> Disappearing {
        defaults.string(forKey: newChatsDisappearKey).flatMap(Disappearing.init(rawValue:)) ?? .off
    }
}

/// View-once photos. The marker is the file's name, which travels inside the encrypted message, and
/// "opened" is a reaction with a key no emoji picker offers, so the server sees neither.
public enum ViewOnce {
    public static let filename = "totality-once.jpg"
    public static let openedKey = "app.totality.opened"

    public static func isViewOnce(filename: String) -> Bool { filename == Self.filename }

    /// The words under the choice to send one, and in its viewer. Literally what happens.
    public static let explanation = "Opens once on their phone, then it's deleted for everyone. In a group, the first person to open it removes it for the others. It is removed from the server the next time your app opens this chat. Nothing stops a screenshot or another camera."
}

/// Disappearing messages, per chat and off by default (owner, 2026-11-05).
public enum Disappearing: String, Sendable, Equatable, CaseIterable, Identifiable {
    case off
    case afterViewing
    case hour
    case day
    case week

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .afterViewing: "After viewing"
        case .hour: "After 1 hour"
        case .day: "After 24 hours"
        case .week: "After 7 days"
        }
    }

    /// What it really does, said plainly before it's turned on and while it's on.
    public var explanation: String {
        switch self {
        case .off:
            "Messages stay until someone deletes them."
        case .afterViewing:
            "Messages sent from now on go once they've been read. In a group, the first person to read one removes it for everyone. Someone who doesn't share read receipts never marks one read, so it stays until they do. On your phone, messages you've read go when you leave the chat."
        case .hour, .day, .week:
            "Messages sent from now on are hidden on everyone's phone \(timeWords). Each person's own messages are deleted for everyone the next time their app opens this chat. Earlier messages stay."
        }
    }

    /// How the timer reads in a sentence.
    public var timeWords: String {
        switch self {
        case .hour: "after 1 hour"
        case .day: "after 24 hours"
        case .week: "after 7 days"
        case .off, .afterViewing: ""
        }
    }

    /// The short form shown in the chat header and on messages.
    public var short: String {
        switch self {
        case .off: "Off"
        case .afterViewing: "Viewed"
        case .hour: "1h"
        case .day: "24h"
        case .week: "7d"
        }
    }

    /// How long a message lasts, for the timed choices.
    public var lifetime: TimeInterval? {
        switch self {
        case .hour: 3_600
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
        case .hour, .day, .week: "{\"max_lifetime\":\(Int(lifetime! * 1000))}"
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
            self = ms <= 3_600_000 ? .hour : ms <= 86_400_000 ? .day : .week
        } else {
            self = .off
        }
    }
}

/// A chat's disappearing setting, when it took effect, and who chose it. Only messages sent after
/// `since` are affected, so turning it on never reaches back into earlier history.
public struct DisappearingState: Sendable, Equatable {
    public let setting: Disappearing
    public let since: Date?
    /// Someone else who chose it. Nil when it was you.
    public let changedBy: String?

    public init(setting: Disappearing, since: Date?, changedBy: String? = nil) {
        self.setting = setting
        self.since = since
        self.changedBy = changedBy
    }

    public static let off = DisappearingState(setting: .off, since: nil)

    /// True when this message was sent while the setting was on. Without a start time, nothing is.
    func covers(_ message: ChatMessage) -> Bool {
        guard setting != .off, let since else { return false }
        return message.time >= since
    }
}

/// Which messages a disappearing chat still shows, and which of your own to remove from the server.
public enum DisappearingRule {
    /// Hides other people's messages once they've expired here, even if their sender hasn't removed
    /// them yet. `viewedUpTo` is the newest message time you'd already seen when you last left the chat.
    public static func visible(
        _ messages: [ChatMessage], state: DisappearingState, now: Date, viewedUpTo: Date?
    ) -> [ChatMessage] {
        let setting = state.setting
        return messages.filter { message in
            guard message.kind != .deleted, state.covers(message) else { return true }
            if let lifetime = setting.lifetime { return message.time.addingTimeInterval(lifetime) > now }
            if setting == .afterViewing, !message.isOwn, let viewedUpTo { return message.time > viewedUpTo }
            return true
        }
    }

    /// The words under a message that will disappear, or nil when it won't. Only what's true: a timed
    /// message says how long is left here; "after viewing" says what it waits for.
    public static func marker(for message: ChatMessage, state: DisappearingState, now: Date) -> String? {
        guard message.kind != .deleted, !message.viewOnce, state.covers(message) else { return nil }
        if let lifetime = state.setting.lifetime {
            let left = message.time.addingTimeInterval(lifetime).timeIntervalSince(now)
            guard left > 0 else { return "Disappearing now" }
            return "Disappears in \(duration(left))"
        }
        if state.setting == .afterViewing {
            return message.isOwn && message.seen ? "Read. Disappearing now" : "Disappears once read"
        }
        return nil
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Your own messages that are due to go: past their time, or seen by someone when it's after viewing.
    public static func due(_ messages: [ChatMessage], state: DisappearingState, now: Date) -> [ChatMessage] {
        let setting = state.setting
        return messages.filter { message in
            // A view-once photo goes as soon as someone opens it, whatever the chat's own setting.
            if message.isOwn, message.state == .sent, message.kind != .deleted, message.viewOnce, message.opened { return true }
            guard message.isOwn, message.state == .sent, message.kind != .deleted, state.covers(message) else { return false }
            if let lifetime = setting.lifetime { return message.time.addingTimeInterval(lifetime) <= now }
            return setting == .afterViewing && message.seen
        }
    }
}

/// Said wherever a group's name or photo is set or shown, because it's the one part of a group that
/// isn't end-to-end encrypted (owner, 2026-11-08: "allow group names and photos in messages").
public enum GroupLabels {
    public static let notEncrypted = "Group name and photo aren't end-to-end encrypted. Messages are."
    public static let photoOnServer = "The photo is kept on Totality's server without end-to-end encryption, so the server can see it."
}

/// A group's name, tidied. Nil when there's nothing left.
public enum GroupName {
    public static let longest = 60

    public static func clean(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return String(name.prefix(longest))
    }
}

/// Who may be in a one-to-one chat. Anyone in a chat can invite others, so an existing chat with a
/// person is only reused while it holds exactly the two of you, joined or invited.
public enum DirectChatRule {
    public static func isJustTheTwoOfYou(members: [String], own: String, other: String) -> Bool {
        Set(members) == [own, other] && members.count == 2
    }

    /// Anyone in a one-to-one chat besides you and the person it's with.
    public static func extraPeople(members: [String], own: String, other: String?) -> [String] {
        members.filter { $0 != own && $0 != other }
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
