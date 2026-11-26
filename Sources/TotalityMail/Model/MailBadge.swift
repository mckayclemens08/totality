import Foundation

/// When Mail was last looked at, for the app icon's badge. The badge counts unread mail that arrived
/// since then, so an old backlog never sits on the icon. The first time there's no mark, now is it.
public struct MailBadge: Sendable {
    public static let shared = MailBadge()

    private let defaults: UserDefaultsBox
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "mail.badgeSince") {
        self.defaults = UserDefaultsBox(defaults)
        self.key = key
    }

    public func since(now: Date = Date()) -> Date {
        if let stored = defaults.value.object(forKey: key) as? Double { return Date(timeIntervalSince1970: stored) }
        markSeen(now: now)
        return now
    }

    public func markSeen(now: Date = Date()) {
        defaults.value.set(now.timeIntervalSince1970, forKey: key)
    }

    public func count(in mailbox: Mailbox, now: Date = Date()) -> Int {
        mailbox.newUnreadCount(in: .inbox, since: since(now: now))
    }
}

/// UserDefaults is thread-safe; this only says so to the compiler.
struct UserDefaultsBox: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}
