import Foundation

/// What makes a Reader item a journal entry (issue 128). It's sealed in the item's details, like the rest.
public struct JournalStamp: Codable, Sendable, Equatable, Hashable {
    /// The day the entry belongs to, as `yyyy-MM-dd`, in the time zone it was started in.
    public let day: String
    /// That time zone's identifier. The entry's day and its lock stay in it however far the person travels.
    public let zone: String
    /// For a note added under an earlier day: that day. Nil for the day's own entry.
    public let about: String?
    /// When the entry locked, once a device has seen its day end. The lock itself comes from the day and
    /// the zone, so it holds even before this is written.
    public var closedAt: Date?

    public init(day: String, zone: String, about: String? = nil, closedAt: Date? = nil) {
        self.day = day
        self.zone = zone
        self.about = about
        self.closedAt = closedAt
    }

    /// The moment the entry stops taking changes: 4 a.m. after its day, in its own zone.
    public var locksAt: Date? {
        JournalClock.locks(day: day, zone: TimeZone(identifier: zone) ?? .current)
    }

    public func isClosed(at now: Date) -> Bool {
        if closedAt != nil { return true }
        guard let locksAt else { return true }
        return now >= locksAt
    }
}

/// The journal's day runs from 4 a.m. to 4 a.m., by the wall clock, so writing at 1 a.m. still belongs to
/// the evening before. Days are counted on the Gregorian calendar whatever the device's own.
public enum JournalClock {
    public static let dayStartHour = 4

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The journal day `date` falls in, by the wall clock in `zone`.
    public static func day(of date: Date, in zone: TimeZone) -> String {
        let calendar = calendar(zone)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        var day = DateComponents(year: parts.year, month: parts.month, day: parts.day)
        if (parts.hour ?? 0) < dayStartHour { day.day = (day.day ?? 1) - 1 }
        // Noon never falls in a clock change, so the date it names is always the one meant.
        day.hour = 12
        let noon = calendar.date(from: day) ?? date
        return key(calendar.dateComponents([.year, .month, .day], from: noon))
    }

    /// 4 a.m. on the wall clock after `day`. On a night the clocks go forward past 4 a.m. it's the first
    /// moment after, so a day always ends.
    public static func locks(day: String, zone: TimeZone) -> Date? {
        guard let parts = components(day) else { return nil }
        let calendar = calendar(zone)
        guard let noon = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)),
              let next = calendar.date(byAdding: .day, value: 1, to: noon)
        else { return nil }
        var morning = calendar.dateComponents([.year, .month, .day], from: next)
        morning.hour = dayStartHour
        return calendar.nextDate(
            after: calendar.startOfDay(for: next).addingTimeInterval(-1), matching: DateComponents(hour: dayStartHour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? calendar.date(from: morning)
    }

    /// Noon on `day` in `zone`, for showing it and sorting by it.
    public static func noon(of day: String, zone: TimeZone) -> Date? {
        guard let parts = components(day) else { return nil }
        return calendar(zone).date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12))
    }

    /// "Saturday, November 15, 2026".
    public static func heading(_ day: String) -> String {
        guard let noon = noon(of: day, zone: TimeZone(identifier: "UTC")!) else { return day }
        let style = Date.FormatStyle(date: .complete, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)
        return noon.formatted(style)
    }

    /// "Nov 20".
    public static func short(_ day: String) -> String {
        guard let noon = noon(of: day, zone: TimeZone(identifier: "UTC")!) else { return day }
        return noon.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
    }

    /// The day after `day`, or before it with a negative `offset`.
    public static func day(_ day: String, adding offset: Int) -> String? {
        let utc = TimeZone(identifier: "UTC")!
        guard let noon = noon(of: day, zone: utc), let moved = calendar(utc).date(byAdding: .day, value: offset, to: noon) else { return nil }
        return key(calendar(utc).dateComponents([.year, .month, .day], from: moved))
    }

    static func key(_ parts: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func components(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// How many days running end today or yesterday, counting each day with any entry once.
    public static func streak(days: Set<String>, today: String) -> Int {
        var current = days.contains(today) ? today : (day(today, adding: -1) ?? today)
        var count = 0
        while days.contains(current) {
            count += 1
            guard let before = day(current, adding: -1) else { break }
            current = before
        }
        return count
    }
}
