import Foundation

/// One way a task asks for attention. It lives inside the sealed task, so the server sees none of it.
public struct TaskReminder: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        /// A day and a time on the person's clock.
        case at(TaskDay, TaskTime)
        /// Counted back from the deadline.
        case beforeDeadline(DeadlineOffset)
        /// Arriving at or leaving a place. The place is sealed with the task; where the person is never
        /// leaves the iPhone.
        case place(ReminderPlace)
    }

    public enum DeadlineOffset: String, Codable, Sendable, Hashable, CaseIterable {
        case hour, day, morningOf

        public var name: String {
            switch self {
            case .hour: "1 hour before"
            case .day: "1 day before"
            case .morningOf: "Morning of"
            }
        }
    }

    public let id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public var isPlace: Bool {
        if case .place = kind { return true }
        return false
    }

    /// When a time reminder rings, or nil for a place, or one that needs a deadline the task doesn't have.
    public func fireDate(for task: TaskItem, in calendar: Calendar) -> Date? {
        switch kind {
        case .at(let day, let time):
            return day.date(at: time, in: calendar)
        case .beforeDeadline(let offset):
            guard let deadline = task.deadline else { return nil }
            switch offset {
            case .hour:
                // Only with a time on the deadline: an hour before "some time Friday" means nothing.
                guard let time = task.deadlineTime else { return nil }
                return deadline.date(at: time, in: calendar).addingTimeInterval(-3600)
            case .day:
                let dayBefore = deadline.adding(days: -1, in: calendar)
                return dayBefore.date(at: task.deadlineTime ?? Self.morning, in: calendar)
            case .morningOf:
                return deadline.date(at: Self.morning, in: calendar)
            }
        case .place:
            return nil
        }
    }

    /// The hour a day-only reminder rings at, and where "tomorrow" snoozes to.
    public static let morning = TaskTime(hour: 9)!
}

/// A place to be reminded at.
public struct ReminderPlace: Codable, Sendable, Hashable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Metres: 100, 200 or 500.
    public var radius: Double
    public var onArrival: Bool

    public static let radii: [Double] = [100, 200, 500]

    public init(name: String, latitude: Double, longitude: Double, radius: Double = 200, onArrival: Bool = true) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.onArrival = onArrival
    }
}

/// "Keep reminding me until it's done."
public struct Nagging: Codable, Sendable, Hashable {
    public enum GiveUp: Codable, Sendable, Hashable {
        case afterHours(Int)
        /// The default (owner, 2026-11-18).
        case midnight
    }

    public var everyMinutes: Int
    public var giveUp: GiveUp

    public static let intervals = [5, 10, 15, 30, 60]
    /// At most this many reminders in one run, the first included (owner, 2026-11-18).
    public static let maxPerRun = 16

    public init(everyMinutes: Int = 15, giveUp: GiveUp = .midnight) {
        self.everyMinutes = everyMinutes
        self.giveUp = giveUp
    }

    /// The moments of one run that starts at `first`, the first included.
    public func run(from first: Date, in calendar: Calendar) -> [Date] {
        let stop: Date
        switch giveUp {
        case .afterHours(let hours): stop = first.addingTimeInterval(Double(hours) * 3600)
        case .midnight: stop = TaskDay(first, in: calendar).adding(days: 1, in: calendar).start(in: calendar)
        }
        var moments: [Date] = []
        var next = first
        while next < stop, moments.count < Self.maxPerRun {
            moments.append(next)
            next = next.addingTimeInterval(Double(max(1, everyMinutes)) * 60)
        }
        return moments
    }
}
