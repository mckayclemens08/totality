import Foundation

/// The Notifications page's choices (issue 232). They stay on this device: each phone may want its own
/// quiet hours, and nothing here is worth sending anywhere.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    public enum Grouping: String, Codable, Sendable, CaseIterable, Identifiable {
        /// One stack per module.
        case module
        /// One stack per chat, post or mail conversation.
        case thread
        /// iOS groups them as it likes.
        case off

        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .module: "By module"
            case .thread: "By chat or post"
            case .off: "Off"
            }
        }
    }

    /// Modules turned off entirely.
    public var modulesOff: Set<ModuleID> = []
    /// Kinds switched away from where they start: off for ones that start on, on for ones that start off.
    public var flipped: Set<String> = []
    public var quietHoursOn = false
    /// Minutes after midnight. Start after end means quiet runs past midnight.
    public var quietStart = 22 * 60
    public var quietEnd = 7 * 60
    public var closeFriendsBreakThrough = false
    public var grouping: Grouping = .module
    /// Show text from encrypted content in alerts. Off, they say only who it's from.
    public var showsPrivateText = true
    public var badgesOff: Set<ModuleID> = []
    /// What new calendar events start with, and when all-day alerts ring.
    public var calendarAlerts = CalendarAlertDefaults()

    public init() {}

    /// Choices saved before a field existed keep working: each is read only when it's there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modulesOff = try c.decodeIfPresent(Set<ModuleID>.self, forKey: .modulesOff) ?? []
        flipped = try c.decodeIfPresent(Set<String>.self, forKey: .flipped) ?? []
        quietHoursOn = try c.decodeIfPresent(Bool.self, forKey: .quietHoursOn) ?? false
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? 22 * 60
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? 7 * 60
        closeFriendsBreakThrough = try c.decodeIfPresent(Bool.self, forKey: .closeFriendsBreakThrough) ?? false
        grouping = try c.decodeIfPresent(Grouping.self, forKey: .grouping) ?? .module
        showsPrivateText = try c.decodeIfPresent(Bool.self, forKey: .showsPrivateText) ?? true
        badgesOff = try c.decodeIfPresent(Set<ModuleID>.self, forKey: .badgesOff) ?? []
        calendarAlerts = try c.decodeIfPresent(CalendarAlertDefaults.self, forKey: .calendarAlerts) ?? CalendarAlertDefaults()
    }

    public func isOn(_ kind: NotificationKind) -> Bool {
        guard !modulesOff.contains(kind.module) else { return false }
        return kind.startsOn != flipped.contains(kind.id)
    }

    public mutating func set(_ kind: NotificationKind, on: Bool) {
        if on == kind.startsOn { flipped.remove(kind.id) } else { flipped.insert(kind.id) }
    }

    public func isOn(_ module: ModuleID) -> Bool { !modulesOff.contains(module) }

    public mutating func set(_ module: ModuleID, on: Bool) {
        if on { modulesOff.remove(module) } else { modulesOff.insert(module) }
    }

    public func badges(_ module: ModuleID) -> Bool { isOn(module) && !badgesOff.contains(module) }

    public mutating func setBadges(_ module: ModuleID, on: Bool) {
        if on { badgesOff.remove(module) } else { badgesOff.insert(module) }
    }

    /// Whether `date` falls in quiet hours, read on this phone's clock.
    public func isQuiet(at date: Date, in calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard quietHoursOn, quietStart != quietEnd else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }
}

/// Where this device keeps its choices.
public final class NotificationSettingsStore: @unchecked Sendable {
    public static let shared = NotificationSettingsStore()
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "notifications.preferences") {
        self.defaults = defaults
        self.key = key
    }

    public var current: NotificationPreferences {
        get {
            lock.withLock {
                guard let data = defaults.data(forKey: key) else { return NotificationPreferences() }
                return (try? JSONDecoder().decode(NotificationPreferences.self, from: data)) ?? NotificationPreferences()
            }
        }
        set {
            lock.withLock { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
        }
    }
}

/// What one alert looks like once the choices are applied, before it becomes an iOS notification. Kept
/// apart from iOS so every rule can be tested.
public struct PlannedAlert: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let subtitle: String
    public let body: String
    /// Quiet hours: it arrives in Notification Centre with no sound and no banner.
    public let isQuiet: Bool
    public let thread: String
    public let category: String
    public let userInfo: [String: String]

    /// Nil when the person turned this kind off.
    public static func plan(
        _ note: AppNotification, preferences: NotificationPreferences, now: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> PlannedAlert? {
        guard preferences.isOn(note.kind) else { return nil }
        let quiet = preferences.isQuiet(at: now, in: calendar) && !(note.fromCloseFriend && preferences.closeFriendsBreakThrough)
        let thread: String = switch preferences.grouping {
        // Mail's thread is the account it came to, and each account is a group of its own even by app.
        case .module where note.target.module == .mail: note.target.module.rawValue + "." + note.thread
        case .module: note.target.module.rawValue
        case .thread: note.target.module.rawValue + "." + note.thread
        case .off: ""
        }
        let body = note.isPrivate && !preferences.showsPrivateText ? "" : note.body
        return PlannedAlert(
            identifier: "totality." + note.id, title: note.title,
            subtitle: note.subtitle ?? NotificationWording.subtitle(for: note.target.module), body: body, isQuiet: quiet, thread: thread,
            category: category(for: note.actions), userInfo: note.target.userInfo
        )
    }

    /// iOS knows each set of buttons by a category. These are all the sets any module uses.
    public static let categories: [[NotificationAction]] = [
        [], [.reply, .markRead], [.markRead], [.approve], [.done, .snoozeShort, .snoozeMorning], [.snoozeTen, .open],
    ]

    public static func category(for actions: [NotificationAction]) -> String {
        actions.isEmpty ? "totality.open" : "totality." + actions.map(\.rawValue).joined(separator: "+")
    }
}
