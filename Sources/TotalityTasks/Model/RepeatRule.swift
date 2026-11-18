import Foundation

/// How a task comes back. It lives inside the sealed task, so the server never sees it.
///
/// Dates are `TaskDay`s, counted on the calendar rather than in 24-hour spans, so a clock change can't
/// move a repeat to another day.
public struct RepeatRule: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly
        /// Counts from when it's ticked off, or from the due date: the person picks (owner, 2026-11-18).
        case afterFinish
        /// Every few days, weeks, months or years, on chosen weekdays.
        case custom
    }

    public enum Unit: String, Codable, Sendable, CaseIterable {
        case day, week, month, year
    }

    /// Where an "After I finish" repeat counts from.
    public enum CountFrom: String, Codable, Sendable {
        case completion, dueDate
    }

    public enum End: Codable, Sendable, Hashable {
        case never
        case on(TaskDay)
        case after(times: Int)
    }

    public var kind: Kind
    /// Every 1, 2, 3… units. Never less than 1.
    public var interval: Int
    /// The unit for `custom` and `afterFinish`. The others have their own.
    public var customUnit: Unit
    /// Weekdays for weekly and custom weekly repeats, 1 being Sunday as `Calendar` counts. Empty means the
    /// start day's weekday.
    public var weekdays: Set<Int>
    /// Days of the month for monthly repeats; -1 is the last day. Empty means the start day. A day a
    /// month doesn't have, like the 31st in April, falls on that month's last day.
    public var monthDays: Set<Int>
    /// "The last Friday": an ordinal (1…4, or -1 for last) and a weekday. Used instead of `monthDays`.
    public var monthWeekday: MonthWeekday?
    public var countFrom: CountFrom
    public var end: End
    /// The first day it falls on. Weeks and months are counted from here.
    public var start: TaskDay
    /// Days passed over with Skip. They stay crossed out in Coming up.
    public var skipped: Set<TaskDay>
    /// How many times it has been done, for "After 10 times".
    public var done: Int

    public struct MonthWeekday: Codable, Sendable, Hashable {
        public var ordinal: Int
        public var weekday: Int

        public init(ordinal: Int, weekday: Int) {
            self.ordinal = ordinal
            self.weekday = weekday
        }
    }

    public init(
        kind: Kind, interval: Int = 1, customUnit: Unit = .day, weekdays: Set<Int> = [], monthDays: Set<Int> = [],
        monthWeekday: MonthWeekday? = nil, countFrom: CountFrom = .completion, end: End = .never, start: TaskDay,
        skipped: Set<TaskDay> = [], done: Int = 0
    ) {
        self.kind = kind
        self.interval = max(1, interval)
        self.customUnit = customUnit
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.monthWeekday = monthWeekday
        self.countFrom = countFrom
        self.end = end
        self.start = start
        self.skipped = skipped
        self.done = done
    }

    private enum CodingKeys: String, CodingKey {
        case kind, interval, customUnit, weekdays, monthDays, monthWeekday, countFrom, end, start, skipped, done
    }

    /// Sets are written sorted, so two devices write the same bytes for the same rule.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(interval, forKey: .interval)
        try c.encode(customUnit, forKey: .customUnit)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
        try c.encode(monthDays.sorted(), forKey: .monthDays)
        try c.encodeIfPresent(monthWeekday, forKey: .monthWeekday)
        try c.encode(countFrom, forKey: .countFrom)
        try c.encode(end, forKey: .end)
        try c.encode(start, forKey: .start)
        try c.encode(skipped.sorted(), forKey: .skipped)
        try c.encode(done, forKey: .done)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .daily
        interval = max(1, (try? c.decode(Int.self, forKey: .interval)) ?? 1)
        customUnit = (try? c.decode(Unit.self, forKey: .customUnit)) ?? .day
        weekdays = Set((try? c.decode([Int].self, forKey: .weekdays)) ?? []).filter { (1...7).contains($0) }
        monthDays = Set((try? c.decode([Int].self, forKey: .monthDays)) ?? [])
        monthWeekday = try? c.decodeIfPresent(MonthWeekday.self, forKey: .monthWeekday)
        countFrom = (try? c.decode(CountFrom.self, forKey: .countFrom)) ?? .completion
        end = (try? c.decode(End.self, forKey: .end)) ?? .never
        start = try c.decode(TaskDay.self, forKey: .start)
        skipped = Set((try? c.decode([TaskDay].self, forKey: .skipped)) ?? [])
        done = (try? c.decode(Int.self, forKey: .done)) ?? 0
    }

    public var unit: Unit {
        switch kind {
        case .daily: .day
        case .weekly: .week
        case .monthly: .month
        case .yearly: .year
        case .afterFinish, .custom: customUnit
        }
    }

    // MARK: - Next dates

    /// The first day after `day` the task falls on, not counting skipped days or the end. Nil once it ends.
    /// `completed` is the day it was ticked off, which "After I finish" counts from.
    public func next(after day: TaskDay, completed: TaskDay? = nil, in calendar: Calendar) -> TaskDay? {
        var from = day
        // A long run of skipped days ends somewhere; this stops a rule that can't fall anywhere.
        for _ in 0..<500 {
            guard let candidate = rawNext(after: from, completed: completed, in: calendar) else { return nil }
            if isPastEnd(candidate) { return nil }
            if !skipped.contains(candidate) { return candidate }
            from = candidate
        }
        return nil
    }

    /// The next `count` days from `day` on, `day` included, with skipped days marked. For Coming up.
    public func upcoming(from day: TaskDay, count: Int, in calendar: Calendar) -> [(day: TaskDay, skipped: Bool)] {
        var result: [(TaskDay, Bool)] = [(day, skipped.contains(day))]
        var current = day
        while result.count < count, let next = rawNext(after: current, completed: nil, in: calendar), !isPastEnd(next) {
            result.append((next, skipped.contains(next)))
            current = next
        }
        return result
    }

    /// How many more times it falls after `day`, or nil when it never ends.
    public func remaining(after day: TaskDay, in calendar: Calendar) -> Int? {
        switch end {
        case .never: return nil
        case .after(let times): return max(0, times - done - 1)
        case .on:
            var count = 0
            var current = day
            while count < 1000, let next = next(after: current, in: calendar) {
                count += 1
                current = next
            }
            return count
        }
    }

    private func isPastEnd(_ day: TaskDay) -> Bool {
        switch end {
        case .never: false
        case .on(let last): day > last
        // `done` counts the ones finished; the one due now is the next, so one more may follow it.
        case .after(let times): done + 1 >= times
        }
    }

    private func rawNext(after day: TaskDay, completed: TaskDay?, in calendar: Calendar) -> TaskDay? {
        switch kind {
        case .afterFinish:
            let base = countFrom == .completion ? (completed ?? day) : day
            return Self.add(interval, unit, to: base, in: calendar)
        default:
            switch unit {
            case .day: return Self.add(interval, .day, to: day, in: calendar)
            case .week: return nextWeekly(after: day, in: calendar)
            case .month: return nextMonthly(after: day, in: calendar)
            case .year: return nextYearly(after: day, in: calendar)
            }
        }
    }

    /// Adds whole units. A month or year that lands past its last day takes the last day instead.
    static func add(_ count: Int, _ unit: Unit, to day: TaskDay, in calendar: Calendar) -> TaskDay {
        switch unit {
        case .day: return day.adding(days: count, in: calendar)
        case .week: return day.adding(days: 7 * count, in: calendar)
        case .month: return Self.month(adding: count, to: day, wanting: day.day, in: calendar)
        case .year: return Self.month(adding: 12 * count, to: day, wanting: day.day, in: calendar)
        }
    }

    private func nextWeekly(after day: TaskDay, in calendar: Calendar) -> TaskDay? {
        let days = weekdays.isEmpty ? [start.weekday(in: calendar)] : weekdays
        let startWeek = Self.weekStart(of: start, in: calendar)
        var candidate = day.adding(days: 1, in: calendar)
        for _ in 0..<(7 * interval + 7) {
            let weeks = startWeek.days(to: Self.weekStart(of: candidate, in: calendar), in: calendar) / 7
            if weeks >= 0, weeks % interval == 0, days.contains(candidate.weekday(in: calendar)) { return candidate }
            candidate = candidate.adding(days: 1, in: calendar)
        }
        return nil
    }

    private func nextMonthly(after day: TaskDay, in calendar: Calendar) -> TaskDay? {
        let startIndex = start.year * 12 + start.month - 1
        var index = max(startIndex, day.year * 12 + day.month - 1)
        while (index - startIndex) % interval != 0 { index += 1 }
        for _ in 0..<24 {
            let year = index / 12
            let month = index % 12 + 1
            let candidates = daysIn(year: year, month: month, in: calendar).sorted()
            if let found = candidates.first(where: { $0 > day && $0 >= start }) { return found }
            index += interval
        }
        return nil
    }

    private func daysIn(year: Int, month: Int, in calendar: Calendar) -> [TaskDay] {
        let last = Self.lastDay(year: year, month: month, in: calendar)
        if let monthWeekday {
            var matches: [Int] = []
            for d in 1...last where TaskDay(year: year, month: month, day: d).weekday(in: calendar) == monthWeekday.weekday {
                matches.append(d)
            }
            let pick = monthWeekday.ordinal < 0 ? matches.last : (matches.indices.contains(monthWeekday.ordinal - 1) ? matches[monthWeekday.ordinal - 1] : nil)
            return pick.map { [TaskDay(year: year, month: month, day: $0)] } ?? []
        }
        let wanted = monthDays.isEmpty ? [start.day] : monthDays
        return Set(wanted.map { $0 < 0 ? last : min($0, last) }).map { TaskDay(year: year, month: month, day: $0) }
    }

    private func nextYearly(after day: TaskDay, in calendar: Calendar) -> TaskDay? {
        var year = max(start.year, day.year)
        while (year - start.year) % interval != 0 { year += 1 }
        for _ in 0..<4 {
            let candidate = TaskDay(year: year, month: start.month, day: min(start.day, Self.lastDay(year: year, month: start.month, in: calendar)))
            if candidate > day { return candidate }
            year += interval
        }
        return nil
    }

    static func lastDay(year: Int, month: Int, in calendar: Calendar) -> Int {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) ?? .distantPast
        return calendar.range(of: .day, in: .month, for: noon)?.count ?? 28
    }

    private static func month(adding months: Int, to day: TaskDay, wanting wanted: Int, in calendar: Calendar) -> TaskDay {
        let index = day.year * 12 + day.month - 1 + months
        let year = index / 12
        let month = index % 12 + 1
        return TaskDay(year: year, month: month, day: min(wanted, lastDay(year: year, month: month, in: calendar)))
    }

    private static func weekStart(of day: TaskDay, in calendar: Calendar) -> TaskDay {
        let back = (day.weekday(in: calendar) - calendar.firstWeekday + 7) % 7
        return day.adding(days: -back, in: calendar)
    }
}

// MARK: - Words

extension RepeatRule {
    /// "Every Mon and Wed", "Every 2 weeks on Tue", "3 days after I finish".
    public func summary(in calendar: Calendar) -> String {
        let n = interval
        if kind == .afterFinish {
            let amount = "\(n) \(unit.rawValue)\(n == 1 ? "" : "s")"
            return countFrom == .completion ? "\(amount) after I finish" : "\(amount) after the due date"
        }
        switch unit {
        case .day: return n == 1 ? "Every day" : "Every \(n) days"
        case .week:
            let names = Self.dayNames(weekdays.isEmpty ? [start.weekday(in: calendar)] : weekdays, in: calendar)
            if n == 1 { return "Every " + names }
            return "Every \(n) weeks on " + names
        case .month:
            let every = n == 1 ? "Monthly" : "Every \(n) months"
            if let monthWeekday {
                let ordinal = monthWeekday.ordinal < 0 ? "last" : ["first", "second", "third", "fourth"][max(0, min(3, monthWeekday.ordinal - 1))]
                return every + " on the \(ordinal) " + calendar.weekdaySymbols[monthWeekday.weekday - 1]
            }
            let days = (monthDays.isEmpty ? [start.day] : monthDays).sorted { ($0 < 0 ? 99 : $0) < ($1 < 0 ? 99 : $1) }
            return every + " on the " + Self.join(days.map { $0 < 0 ? "last day" : Self.ordinal($0) })
        case .year:
            let date = "\(start.day) " + calendar.monthSymbols[start.month - 1]
            return n == 1 ? "Every \(date)" : "Every \(n) years on \(date)"
        }
    }

    /// "Mon, Wed" for a row's chip.
    public func shortSummary(in calendar: Calendar) -> String {
        switch unit {
        case .week where kind != .afterFinish:
            let days = weekdays.isEmpty ? [start.weekday(in: calendar)] : weekdays
            return days.count == 7 ? "Daily" : Self.sortedDays(days, in: calendar).map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        default:
            return summary(in: calendar)
        }
    }

    static func sortedDays(_ days: Set<Int>, in calendar: Calendar) -> [Int] {
        days.sorted { ($0 - calendar.firstWeekday + 7) % 7 < ($1 - calendar.firstWeekday + 7) % 7 }
    }

    static func dayNames(_ days: Set<Int>, in calendar: Calendar) -> String {
        if days == [2, 3, 4, 5, 6] { return "weekday" }
        if days.count == 7 { return "day" }
        return join(sortedDays(days, in: calendar).map { calendar.shortWeekdaySymbols[$0 - 1] })
    }

    static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : (n % 10 == 1 ? "st" : n % 10 == 2 ? "nd" : n % 10 == 3 ? "rd" : "th")
        return "\(n)\(suffix)"
    }
}
