import Foundation

/// The Calendar's alert settings on the Notifications page (issue 232): what new events start with, and the
/// hour all-day alerts ring. They stay on this device with the rest of the page's choices, and apply to new
/// events only. Offsets are minutes before the start; for all-day events they count back from the all-day hour.
public struct CalendarAlertDefaults: Codable, Equatable, Sendable {
    /// Alerts a new timed event starts with. 15 minutes before, as the owner chose.
    public var timed: [Int] = [15]
    /// Alerts a new all-day event starts with: 0 is "On the day".
    public var allDay: [Int] = [0]
    /// Minutes after midnight that all-day alerts ring.
    public var allDayMinute = 9 * 60

    public init() {}

    public func defaults(allDay isAllDay: Bool) -> [Int] { isAllDay ? allDay : timed }
}

/// How alert offsets are named and chosen. Shared by the event editor and the Notifications page.
public enum AlertOffset {
    /// Alerts per event. Five covers any real use and keeps the pending list small.
    public static let maxPerEvent = 5
    /// How long Snooze waits.
    public static let snoozeMinutes = 10

    public static let timedPresets = [0, 5, 10, 15, 30, 60, 120, 1_440, 2_880, 10_080]
    public static let allDayPresets = [0, 1_440, 2_880, 10_080]

    public static func presets(allDay: Bool) -> [Int] { allDay ? allDayPresets : timedPresets }

    /// "At the start", "30 minutes before", "1 hour 15 minutes before". All-day ones say "On the day".
    public static func name(_ minutes: Int, allDay: Bool = false) -> String {
        if minutes == 0 { return allDay ? "On the day" : "At the start" }
        if minutes % 10_080 == 0 { return unit(minutes / 10_080, "week") + " before" }
        if minutes % 1_440 == 0 { return unit(minutes / 1_440, "day") + " before" }
        if minutes < 60 { return unit(minutes, "minute") + " before" }
        let hours = minutes / 60, rest = minutes % 60
        let text = rest == 0 ? unit(hours, "hour") : unit(hours, "hour") + " " + unit(rest, "minute")
        return text + " before"
    }

    /// The units a custom amount can be in.
    public enum Unit: String, CaseIterable, Sendable, Identifiable {
        case minutes = "Minutes", hours = "Hours", days = "Days", weeks = "Weeks"
        public var id: String { rawValue }
        public var minutes: Int {
            switch self {
            case .minutes: 1
            case .hours: 60
            case .days: 1_440
            case .weeks: 10_080
            }
        }
    }

    /// Past four weeks is longer than an alert is useful for.
    public static let longest = 4 * 10_080

    /// A custom amount as minutes, or nil when it's none or too long.
    public static func custom(_ amount: Int, _ unit: Unit) -> Int? {
        let total = amount * unit.minutes
        return amount > 0 && total <= longest ? total : nil
    }

    /// One alert added to a list. No repeats, and nothing past the limit.
    public static func adding(_ minutes: Int, to list: [Int]) -> [Int] {
        guard !list.contains(minutes), list.count < maxPerEvent else { return sorted(list) }
        return sorted(list + [minutes])
    }

    /// Earliest ring first, which is the biggest offset. No repeats.
    public static func sorted(_ list: [Int]) -> [Int] { Array(Set(list)).sorted(by: >) }

    /// "9:00 AM", from minutes after midnight.
    public static func clock(_ minute: Int) -> String {
        let hour = minute / 60 % 24
        let shown = hour % 12 == 0 ? 12 : hour % 12
        return "\(shown):" + String(format: "%02d", minute % 60) + (hour < 12 ? " AM" : " PM")
    }

    private static func unit(_ count: Int, _ word: String) -> String {
        "\(count) \(word)" + (count == 1 ? "" : "s")
    }
}
