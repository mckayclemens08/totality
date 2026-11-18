import Foundation

/// Something done from a notification: Complete or Snooze, which works without opening the app.
public struct ReminderAction: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case complete
        case snooze(until: Date)
    }

    public let taskID: UUID
    public let kind: Kind
    public let at: Date

    public init(taskID: UUID, kind: Kind, at: Date) {
        self.taskID = taskID
        self.kind = kind
        self.at = at
    }

    /// The two fixed snooze lengths (owner, 2026-11-18): 15 minutes, or tomorrow at 9 AM.
    public enum Snooze: String, CaseIterable, Sendable {
        case fifteenMinutes = "task.snooze.15"
        case tomorrowMorning = "task.snooze.tomorrow"

        public var title: String {
            switch self {
            case .fifteenMinutes: "Snooze 15 minutes"
            case .tomorrowMorning: "Snooze until tomorrow, 9 AM"
            }
        }

        public func until(from now: Date, in calendar: Calendar) -> Date {
            switch self {
            case .fifteenMinutes:
                return now.addingTimeInterval(15 * 60)
            case .tomorrowMorning:
                return TaskDay(now, in: calendar).adding(days: 1, in: calendar).date(at: TaskReminder.morning, in: calendar)
            }
        }
    }

    public static let completeID = "task.complete"
    public static let category = "task.reminder"
}

/// Actions waiting for Tasks to open. iOS may run a notification action while the tasks are still locked
/// away, so the action is kept here, holding only a task's random ID, a kind and a time, and applied when
/// Tasks next loads.
public final class ReminderActionQueue: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public static let shared = ReminderActionQueue()

    public init(defaults: UserDefaults = .standard, key: String = "tasks.reminderActions") {
        self.defaults = defaults
        self.key = key
    }

    public func add(_ action: ReminderAction) {
        lock.withLock {
            var all = read()
            all.append(action)
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }

    /// Everything waiting, in order, and clears it.
    public func drain() -> [ReminderAction] {
        lock.withLock {
            let all = read()
            defaults.removeObject(forKey: key)
            return all
        }
    }

    private func read() -> [ReminderAction] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ReminderAction].self, from: data)) ?? []
    }
}

/// Whether reminders can ring on this iPhone.
public struct ReminderAccess: Equatable, Sendable {
    public enum Notifications: Sendable { case allowed, denied, notAsked }
    public enum Location: Sendable { case always, whileUsing, denied, notAsked }

    public var notifications: Notifications
    public var location: Location

    public init(notifications: Notifications = .notAsked, location: Location = .notAsked) {
        self.notifications = notifications
        self.location = location
    }

    /// A time reminder can ring.
    public var timeWorks: Bool { notifications != .denied }
    /// A place reminder can ring: it needs notifications and Always.
    public var placeWorks: Bool { notifications != .denied && (location == .always || location == .notAsked) }

    /// True when some reminder on the task can't ring, for the small bell with a slash.
    public func isPaused(_ task: TaskItem) -> Bool {
        task.reminders.contains { $0.isPlace ? !placeWorks : !timeWorks }
    }
}

/// What Tasks needs from the iPhone to ring reminders. The real one is `SystemTaskReminders`.
public protocol TaskReminderScheduling: Sendable {
    /// Replaces every Tasks notification and watched place, so an edited or finished task can't ring.
    func replace(with notifications: [PlannedTaskNotification], places: [PlannedPlace]) async
    func access() async -> ReminderAccess
    func requestNotifications() async -> Bool
    /// Asks for "Always", only when the first place reminder is made (owner, 2026-11-18).
    func requestAlwaysLocation() async
}
