import Foundation

/// The Clock's sums, kept apart from the screens so they can be tested at any moment in any zone.
public enum ClockMath {
    /// When the alarm next rings after `now`, or nil if it's off or a one-time day has passed.
    public static func nextFire(of alarm: ClockAlarm, after now: Date, in calendar: Calendar) -> Date? {
        guard alarm.isOn else { return nil }
        if let date = alarm.date { return date > now ? date : nil }
        let days = alarm.weekdays.isEmpty ? [nil] : alarm.weekdays.sorted().map { Optional($0) }
        return days.compactMap { weekday -> Date? in
            var parts = DateComponents(hour: alarm.hour, minute: alarm.minute, second: 0)
            parts.weekday = weekday
            return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime, direction: .forward)
        }.min()
    }

    /// The soonest of the alarms, with the alarm.
    public static func nextAlarm(in alarms: [ClockAlarm], after now: Date, in calendar: Calendar) -> (alarm: ClockAlarm, date: Date)? {
        alarms.compactMap { alarm in nextFire(of: alarm, after: now, in: calendar).map { (alarm, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// "in 16 h 55 min", "in 3 min", "in 2 d 4 h". Rounded up to the minute, so it never says "in 0 min".
    public static func until(_ date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let rest = minutes % 60
        if days > 0 { return hours > 0 ? "in \(days) d \(hours) h" : "in \(days) d" }
        if hours > 0 { return rest > 0 ? "in \(hours) h \(rest) min" : "in \(hours) h" }
        return "in \(rest) min"
    }

    /// How a city's clock stands against this one: "3 h ahead", "2 h 30 min behind", "Same time".
    public static func offset(of zone: TimeZone, from local: TimeZone, at now: Date) -> String {
        let seconds = zone.secondsFromGMT(for: now) - local.secondsFromGMT(for: now)
        guard seconds != 0 else { return "Same time" }
        let minutes = abs(seconds) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        let amount = rest == 0 ? "\(hours) h" : (hours == 0 ? "\(rest) min" : "\(hours) h \(rest) min")
        return "\(amount) \(seconds > 0 ? "ahead" : "behind")"
    }

    /// "Tomorrow" or "Yesterday" when the city's date isn't this one's, else nil.
    public static func dayWord(in zone: TimeZone, local: TimeZone, at now: Date) -> String? {
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        var here = Calendar(identifier: .gregorian)
        here.timeZone = local
        let a = there.dateComponents([.year, .month, .day], from: now)
        let b = here.dateComponents([.year, .month, .day], from: now)
        guard let dayThere = here.date(from: a), let dayHere = here.date(from: b), dayThere != dayHere else { return nil }
        return dayThere > dayHere ? "Tomorrow" : "Yesterday"
    }

    /// A timer's or stopwatch's time: "12:48", "1:02:03", or with hundredths "00:07.42".
    public static func duration(_ interval: TimeInterval, hundredths: Bool = false) -> String {
        let clamped = max(0, interval)
        if hundredths {
            let total = Int((clamped * 100).rounded(.down))
            let minutes = total / 6000
            let seconds = (total / 100) % 60
            let cents = total % 100
            return String(format: "%02d:%02d.%02d", minutes, seconds, cents)
        }
        let total = Int(clamped.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// A preset's length: "3 min", "1 h 30 min", "45 s".
    public static func length(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) s") }
        return parts.joined(separator: " ")
    }

    /// "Weekdays", "Weekends", "Every day", "Tue, Thu", or "Once".
    public static func repeatText(_ weekdays: Set<Int>, calendar: Calendar) -> String {
        if weekdays.isEmpty { return "Once" }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let names = calendar.shortWeekdaySymbols
        // In the week's own order, so Monday-first places put Sunday last.
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return order.filter(weekdays.contains).map { names[$0 - 1] }.joined(separator: ", ")
    }
}
