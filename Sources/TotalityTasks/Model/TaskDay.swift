import Foundation

/// A date with no time or zone. A task's When and Deadline are these, so "Thursday" stays Thursday
/// wherever the person is, and a clock change can never move a task to another day.
public struct TaskDay: Codable, Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    public static func < (a: TaskDay, b: TaskDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Midnight, or the first moment of the day where a clock change skips midnight.
    public func start(in calendar: Calendar) -> Date {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
        return calendar.startOfDay(for: noon)
    }

    /// Counts calendar days, not 24-hour spans, so a clock change can't skip or repeat one.
    public func adding(days: Int, in calendar: Calendar) -> TaskDay {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
        return TaskDay(calendar.date(byAdding: .day, value: days, to: noon) ?? noon, in: calendar)
    }

    /// Whole days from this one to `other`, negative when `other` is earlier.
    public func days(to other: TaskDay, in calendar: Calendar) -> Int {
        let from = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
        let to = calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day, hour: 12)) ?? .distantPast
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 1 is Sunday, as `Calendar` counts.
    public func weekday(in calendar: Calendar) -> Int {
        calendar.component(.weekday, from: start(in: calendar).addingTimeInterval(12 * 3600))
    }

    /// The moment this day reaches `time` on the person's clock. A time a clock change skips moves to the
    /// first moment after it, on the same day.
    public func date(at time: TaskTime, in calendar: Calendar) -> Date {
        let wanted = DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute)
        if let exact = calendar.date(from: wanted), TaskDay(exact, in: calendar) == self { return exact }
        return calendar.nextDate(
            after: start(in: calendar), matching: DateComponents(hour: time.hour, minute: time.minute),
            matchingPolicy: .nextTime
        ) ?? start(in: calendar)
    }
}

/// A time on the person's clock, with no date or zone.
public struct TaskTime: Codable, Sendable, Hashable, Comparable {
    public let hour: Int
    public let minute: Int

    /// Nil unless it's a real time of day.
    public init?(hour: Int, minute: Int = 0) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
    }

    public var minutes: Int { hour * 60 + minute }

    public static func < (a: TaskTime, b: TaskTime) -> Bool { a.minutes < b.minutes }

    public static let noon = TaskTime(hour: 12)!
    /// Where the evening starts, for Today's sections.
    public static let evening = TaskTime(hour: 17)!
}
