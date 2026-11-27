import Foundation

/// One kind of alert a module can send, with its own switch on the Notifications page (issue 232).
public struct NotificationKind: Hashable, Codable, Sendable, Identifiable {
    public let module: ModuleID
    /// Short and stable, such as "like". With the module it names the switch, so it never changes.
    public let key: String
    public let name: String
    public let detail: String
    /// On until the person turns it off. Noisy kinds start off.
    public let startsOn: Bool

    public init(module: ModuleID, key: String, name: String, detail: String, startsOn: Bool = true) {
        self.module = module
        self.key = key
        self.name = name
        self.detail = detail
        self.startsOn = startsOn
    }

    public var id: String { module.rawValue + "." + key }
}

/// What a lock-screen button does. A module offers only the ones that make sense for it, and handles
/// them itself.
public enum NotificationAction: String, Codable, Sendable, CaseIterable {
    case reply, markRead, done, snoozeShort, snoozeMorning, approve, snoozeTen, open

    /// The identifier iOS knows the button by.
    public var identifier: String { "totality.action." + rawValue }

    public init?(identifier: String) {
        guard identifier.hasPrefix("totality.action.") else { return nil }
        self.init(rawValue: String(identifier.dropFirst("totality.action.".count)))
    }

    public var title: String {
        switch self {
        case .reply: "Reply"
        case .markRead: "Mark read"
        case .done: "Done"
        case .snoozeShort: "Snooze 15 minutes"
        case .snoozeMorning: "Snooze until 9 AM"
        case .approve: "Approve"
        case .snoozeTen: "Snooze 10 min"
        case .open: "Open"
        }
    }

    /// Whether the button needs the phone unlocked. Replying and approving act for the person, so they do.
    public var needsUnlock: Bool { self == .reply || self == .approve }
}

/// Where tapping an alert goes: a module and one thing in it, such as a chat, a post or a profile. Only
/// the module that made it reads `item`.
public struct NotificationTarget: Hashable, Codable, Sendable {
    public let module: ModuleID
    /// What kind of thing `item` names, such as "post", "profile" or "chat".
    public let kind: String
    public let item: String

    public init(module: ModuleID, kind: String, item: String) {
        self.module = module
        self.kind = kind
        self.item = item
    }

    /// The keys an alert carries it under. Only IDs: never words from the content.
    public var userInfo: [String: String] {
        ["totality.module": module.rawValue, "totality.kind": kind, "totality.item": item]
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["totality.module"] as? String, let module = ModuleID(rawValue: raw),
              let kind = userInfo["totality.kind"] as? String, let item = userInfo["totality.item"] as? String
        else { return nil }
        self.init(module: module, kind: kind, item: item)
    }
}

/// One alert, written on this phone from what a module fetched. The server never sees it.
/// The word under every alert's title that says which part of Totality it's from (owner, 2026-11-26: a
/// Gmail alert showed only a sender and a subject, and could have been anything).
public enum NotificationWording {
    public static func subtitle(for module: ModuleID) -> String {
        switch module {
        case .mail: "New email"
        case .messages: "Message"
        case .social: "Social"
        case .calendar: "Calendar"
        case .tasks: "Task"
        case .photos: "Photos"
        case .reader: "Reader"
        case .weather: "Weather"
        case .clock: "Clock"
        case .contacts: "Contacts"
        case .hiking: "Hiking"
        case .web: "Web"
        case .calls: "Call"
        case .money: "Money"
        case .player: "Player"
        case .ai: "Assistant"
        }
    }
}

public struct AppNotification: Hashable, Sendable, Identifiable {
    /// Stable for the same event, so the same thing is never alerted twice.
    public let id: String
    public let kind: NotificationKind
    public let title: String
    /// The line under the title that says what this is: "New email · Gmail", "Message". Nil uses the
    /// module's own word, so no alert reaches the lock screen without saying where it's from.
    public let subtitle: String?
    public let body: String
    /// Whether `body` comes from end-to-end encrypted content, which the Previews switch can hide.
    public let isPrivate: Bool
    /// What the alert is about, for grouping by conversation or post: a chat ID, a post ID.
    public let thread: String
    public let target: NotificationTarget
    public let actions: [NotificationAction]
    /// From someone on the person's Close friends list, which can ring through quiet hours.
    public let fromCloseFriend: Bool
    public let date: Date

    public init(
        id: String, kind: NotificationKind, title: String, subtitle: String? = nil, body: String, isPrivate: Bool = false,
        thread: String, target: NotificationTarget, actions: [NotificationAction] = [], fromCloseFriend: Bool = false, date: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.isPrivate = isPrivate
        self.thread = thread
        self.target = target
        self.actions = actions
        self.fromCloseFriend = fromCloseFriend
        self.date = date
    }
}

/// A module that sends alerts. It plugs into `NotificationHub`, which the app hands each module's adapter,
/// so modules never import each other (non-negotiable 7).
@MainActor
public protocol NotificationSource: AnyObject {
    var module: ModuleID { get }
    var kinds: [NotificationKind] { get }
    /// What's new since the last call, fetched by the module itself. The first call after install only
    /// marks where it is, so a new phone doesn't ring with everything that came before.
    func newNotifications() async -> [AppNotification]
    /// What this module adds to the app icon's badge, such as unread chats.
    func badgeCount() -> Int
    /// Gets ready to show `target`, before the app brings this module up.
    func prepareToOpen(_ target: NotificationTarget)
    /// A lock-screen button. `text` is what was typed for Reply.
    func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async
}

public extension NotificationSource {
    func badgeCount() -> Int { 0 }
    func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async {}
}

/// Where a source got to: the time of the newest thing it has seen, kept on this device. Nil until the
/// first look, which only sets it.
public struct NotificationCursor: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(_ name: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "notifications.cursor." + name
    }

    public var date: Date? {
        get { defaults.object(forKey: key) as? Date }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
