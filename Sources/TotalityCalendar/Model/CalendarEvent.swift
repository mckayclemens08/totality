import Foundation
import TotalityCore

/// A date with no time or zone. All-day events and the grid are made of these, so a day stays the
/// same day wherever the person is.
public struct CalendarDay: Codable, Sendable, Hashable, Comparable {
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

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public func adding(days: Int, in calendar: Calendar) -> CalendarDay {
        CalendarDay(calendar.date(byAdding: .day, value: days, to: start(in: calendar)) ?? start(in: calendar), in: calendar)
    }

    public func adding(months: Int, in calendar: Calendar) -> CalendarDay {
        CalendarDay(calendar.date(byAdding: .month, value: months, to: firstOfMonth.start(in: calendar)) ?? start(in: calendar), in: calendar)
    }

    public var firstOfMonth: CalendarDay {
        CalendarDay(year: year, month: month, day: 1)
    }

    /// Every cell of a month, whole weeks only, with nil for the days outside it.
    public func monthGrid(in calendar: Calendar) -> [CalendarDay?] {
        let first = firstOfMonth
        let weekday = calendar.component(.weekday, from: first.start(in: calendar))
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: first.start(in: calendar))?.count ?? 0
        var cells: [CalendarDay?] = Array(repeating: nil, count: leading)
        cells += (1...max(length, 1)).map { CalendarDay(year: year, month: month, day: $0) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return cells
    }
}

public struct RepeatRule: Codable, Sendable, Hashable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly

        public var name: String {
            switch self {
            case .daily: "Every day"
            case .weekly: "Every week"
            case .monthly: "Every month"
            case .yearly: "Every year"
            }
        }
    }

    public var frequency: Frequency
    /// The last day it can happen on, in the event's own zone.
    public var until: CalendarDay?

    public init(frequency: Frequency, until: CalendarDay? = nil) {
        self.frequency = frequency
        self.until = until
    }
}

/// One of the person's own events. All of this is encrypted at rest, including the times.
public struct CalendarEvent: Identifiable, Codable, Sendable, Hashable {
    /// All-day events are midnight GMT on their first and last days, which keeps them as plain dates.
    public static let allDayZone = "GMT"

    public let id: UUID
    public var title: String
    public var location: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZoneID: String
    public var repeatRule: RepeatRule?
    /// Starts of occurrences that were deleted or edited on their own.
    public var skipped: Set<Date>
    /// Minutes before the start. Nil means no reminder.
    public var reminderMinutes: Int?
    public var attachments: [ContentRef]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), title: String, location: String = "", notes: String = "", start: Date, end: Date,
        isAllDay: Bool = false, timeZoneID: String, repeatRule: RepeatRule? = nil, skipped: Set<Date> = [],
        reminderMinutes: Int? = nil, attachments: [ContentRef] = [], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.repeatRule = repeatRule
        self.skipped = skipped
        self.reminderMinutes = reminderMinutes
        self.attachments = attachments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        title.isEmpty ? "Untitled event" : title
    }

    /// The calendar repeats are worked out in, so an event keeps its wall-clock time through
    /// daylight-saving changes and when the person travels.
    public var ownCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return calendar
    }

    /// Every occurrence touching these days, in the person's calendar. Skips straight to the range,
    /// so a daily event from years ago costs the same as a new one.
    public func occurrences(from first: CalendarDay, through last: CalendarDay, in display: Calendar) -> [EventOccurrence] {
        let own = ownCalendar
        let frame = isAllDay ? own : display
        let lower = first.start(in: frame)
        let upper = last.adding(days: 1, in: frame).start(in: frame)
        let length = end.timeIntervalSince(start)
        // An all-day end is the start of its last day, so it runs one day past that.
        let span = max(length, 0) + (isAllDay ? 86_400 : 0)

        func occurrence(at begin: Date) -> EventOccurrence? {
            let finish = begin.addingTimeInterval(span)
            let touches = begin < upper && (finish > lower || (span == 0 && begin >= lower))
            guard touches, !skipped.contains(begin) else { return nil }
            return EventOccurrence(event: self, start: begin, end: begin.addingTimeInterval(max(length, 0)))
        }

        guard let rule = repeatRule else {
            return [occurrence(at: start)].compactMap { $0 }
        }

        let approximate: Double = switch rule.frequency {
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_678_400
        case .yearly: 31_622_400
        }
        let elapsed = lower.addingTimeInterval(-span).timeIntervalSince(start) / approximate
        var index = elapsed.isFinite ? Int(max(0, min(elapsed - 1, Double(Int32.max)))) : 0
        var found: [EventOccurrence] = []
        var misses = 0
        while misses < 500 {
            defer { index += 1 }
            guard let begin = start(ofRepeat: index, rule: rule, in: own) else {
                misses += 1
                continue
            }
            if begin >= upper { break }
            if let until = rule.until, CalendarDay(begin, in: own) > until { break }
            if let hit = occurrence(at: begin) { found.append(hit) }
        }
        return found
    }

    /// Nil when that repeat doesn't exist, like the 31st of a short month. Those are skipped, not
    /// moved, which is what Apple and Google calendars do.
    private func start(ofRepeat index: Int, rule: RepeatRule, in own: Calendar) -> Date? {
        switch rule.frequency {
        case .daily: return own.date(byAdding: .day, value: index, to: start)
        case .weekly: return own.date(byAdding: .day, value: index * 7, to: start)
        case .monthly, .yearly:
            var parts = own.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
            let wanted = parts.day
            if rule.frequency == .monthly {
                parts.month = (parts.month ?? 1) + index
            } else {
                parts.year = (parts.year ?? 0) + index
            }
            guard let date = own.date(from: parts), own.component(.day, from: date) == wanted else { return nil }
            return date
        }
    }
}

public struct EventOccurrence: Identifiable, Sendable, Hashable {
    public let event: CalendarEvent
    public let start: Date
    public let end: Date

    public var id: String { "\(event.id.uuidString)-\(start.timeIntervalSince1970)" }
}
