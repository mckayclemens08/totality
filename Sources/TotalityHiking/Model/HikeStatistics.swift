import Foundation

/// Totals, a chart and personal bests from the hikes recorded in Totality, worked out on the iPhone. Trails
/// brought in from GPX files are not hikes and never count (owner, 2026-11-26).
public struct HikeStatistics: Equatable, Sendable {
    public enum Period: String, CaseIterable, Hashable, Sendable {
        case week = "Week", month = "Month", year = "Year", allTime = "All time"
    }

    /// One bar of the chart.
    public struct Bar: Equatable, Sendable, Identifiable {
        public var start: Date
        public var label: String
        public var hikes: Int
        public var id: Date { start }
    }

    public struct Totals: Equatable, Sendable {
        public var hikes = 0
        public var metres = 0.0
        public var climb = 0.0
        public var seconds: TimeInterval = 0
        public var averageMetres: Double { hikes > 0 ? metres / Double(hikes) : 0 }
        public var averageClimb: Double { hikes > 0 ? climb / Double(hikes) : 0 }
        public var averageSeconds: TimeInterval { hikes > 0 ? seconds / Double(hikes) : 0 }
    }

    public struct Bests: Equatable, Sendable {
        public var longest: Hike?
        public var mostClimb: Hike?
        public var highest: Hike?
        public var longestTime: Hike?
        /// The month with the most hikes, as its first day, and how many.
        public var busiestMonth: (start: Date, count: Int)?
        /// The most weeks in a row with at least one hike.
        public var streakWeeks = 0

        public static func == (a: Bests, b: Bests) -> Bool {
            a.longest == b.longest && a.mostClimb == b.mostClimb && a.highest == b.highest && a.longestTime == b.longestTime
                && a.busiestMonth?.start == b.busiestMonth?.start && a.busiestMonth?.count == b.busiestMonth?.count
                && a.streakWeeks == b.streakWeeks
        }
    }

    public var period: Period
    /// The hikes inside the period.
    public var hikes: [Hike]
    public var totals: Totals
    public var bars: [Bar]
    /// Personal bests are over every hike, whatever the period.
    public var bests: Bests

    public init(hikes all: [Hike], period: Period, now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        let window = Self.window(for: period, now: now, calendar: calendar)
        let inside = all.filter { window?.contains($0.startedAt) ?? true }
        hikes = inside.sorted { $0.startedAt > $1.startedAt }
        var totals = Totals()
        for hike in inside {
            totals.hikes += 1
            totals.metres += hike.metres
            totals.climb += hike.climb
            totals.seconds += hike.seconds
        }
        self.totals = totals
        bars = Self.bars(for: period, hikes: inside, window: window, now: now, calendar: calendar)
        bests = Self.bests(of: all, calendar: calendar)
    }

    /// The calendar week, month or year around `now`. All time has none.
    static func window(for period: Period, now: Date, calendar: Calendar) -> DateInterval? {
        switch period {
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: calendar.dateInterval(of: .month, for: now)
        case .year: calendar.dateInterval(of: .year, for: now)
        case .allTime: nil
        }
    }

    /// Days for a week, weeks for a month, months for a year and for all time, each from the start of the
    /// period (or the first hike) to its end, with empty ones kept so the chart has no gaps.
    static func bars(for period: Period, hikes: [Hike], window: DateInterval?, now: Date, calendar: Calendar) -> [Bar] {
        let step: Calendar.Component
        switch period {
        case .week: step = .day
        case .month: step = .weekOfYear
        case .year, .allTime: step = .month
        }
        let span: DateInterval
        if let window {
            span = window
        } else if let first = hikes.map(\.startedAt).min() {
            span = DateInterval(start: first, end: max(now, hikes.map(\.startedAt).max() ?? first).addingTimeInterval(1))
        } else {
            return []
        }
        guard var cursor = calendar.dateInterval(of: step, for: span.start)?.start else { return [] }
        var bars: [Bar] = []
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(step == .day ? "EEEEE" : step == .weekOfYear ? "d" : "MMM")
        while cursor < span.end, bars.count < 600 {
            let next = calendar.date(byAdding: step, value: 1, to: cursor) ?? span.end
            let count = hikes.filter { $0.startedAt >= cursor && $0.startedAt < next }.count
            bars.append(Bar(start: cursor, label: formatter.string(from: cursor), hikes: count))
            cursor = next
        }
        return bars
    }

    static func bests(of hikes: [Hike], calendar: Calendar) -> Bests {
        var bests = Bests()
        bests.longest = hikes.max { $0.metres < $1.metres }
        bests.mostClimb = hikes.filter { $0.climb > 0 }.max { $0.climb < $1.climb }
        bests.highest = hikes.filter { $0.highest != nil }.max { ($0.highest ?? 0) < ($1.highest ?? 0) }
        bests.longestTime = hikes.max { $0.seconds < $1.seconds }
        var months: [Date: Int] = [:]
        for hike in hikes {
            if let start = calendar.dateInterval(of: .month, for: hike.startedAt)?.start { months[start, default: 0] += 1 }
        }
        if let best = months.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { bests.busiestMonth = (best.key, best.value) }
        bests.streakWeeks = streak(hikes.map(\.startedAt), calendar: calendar)
        return bests
    }

    /// The longest run of consecutive calendar weeks that each have a hike.
    static func streak(_ dates: [Date], calendar: Calendar) -> Int {
        let weeks = Set(dates.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }).sorted()
        var best = 0, run = 0
        var previous: Date?
        for week in weeks {
            if let previous, calendar.date(byAdding: .weekOfYear, value: 1, to: previous) == week { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = week
        }
        return best
    }

    /// "this week", "this month", "this year" or "in all", for the line under a total.
    public var periodName: String {
        switch period {
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        case .allTime: "in all"
        }
    }
}
