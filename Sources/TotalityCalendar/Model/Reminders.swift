import Foundation
import TotalityCore
import UserNotifications

/// An alert the device will show. It holds the title and time and nothing else, because the
/// operating system keeps it outside Totality's encryption until it fires. Locations and notes stay
/// out on purpose.
public struct PlannedReminder: Identifiable, Sendable, Equatable {
    public let id: String
    public let fireDate: Date
    public let title: String
    public let body: String
    /// What a tap opens: the occurrence's ID for Totality's events, nil for a Google event. Only an ID.
    public let openItem: String?
}

public protocol ReminderScheduler: Sendable {
    func requestPermission() async -> Bool
    func replace(with reminders: [PlannedReminder]) async
}

/// What was planned, and how many alerts didn't fit under the limit.
struct ReminderPlan: Equatable {
    var planned: [PlannedReminder]
    var skipped: Int
}

enum ReminderPlanner {
    /// iOS keeps 64 pending notifications per app, shared with Tasks, which takes up to 40. The rest are
    /// picked up as these fire and the Calendar is opened again.
    static let limit = 24
    static let horizonDays = 30
    /// All-day events have no start time, so their alerts count back from this hour (minutes after
    /// midnight) unless the Notifications page says otherwise.
    static let allDayMinute = 9 * 60

    static func plan(
        for events: [CalendarEvent], now: Date, display: Calendar, allDayMinute: Int = allDayMinute,
        device: [DeviceEvent] = [], deviceAlerts: [String: [Int]] = [:]
    ) -> [PlannedReminder] {
        planning(for: events, now: now, display: display, allDayMinute: allDayMinute, device: device, deviceAlerts: deviceAlerts).planned
    }

    static func planning(
        for events: [CalendarEvent], now: Date, display: Calendar, allDayMinute: Int = allDayMinute,
        device: [DeviceEvent] = [], deviceAlerts: [String: [Int]] = [:]
    ) -> ReminderPlan {
        let first = CalendarDay(now, in: display)
        let last = first.adding(days: horizonDays, in: display)
        var planned: [PlannedReminder] = []

        func add(_ keyID: String, openItem: String?, title: String, start: Date, day: CalendarDay?, minutes list: [Int]) {
            for minutes in list.prefix(AlertOffset.maxPerEvent) {
                let moment: Date
                let body: String
                if let day {
                    let begin = day.start(in: display)
                    moment = display.date(byAdding: .minute, value: allDayMinute, to: begin) ?? begin
                    body = "All day"
                } else {
                    moment = start
                    body = moment.formatted(date: .abbreviated, time: .shortened)
                }
                let fire = moment.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now else { continue }
                planned.append(PlannedReminder(
                    id: "calendar.\(keyID).\(Int(start.timeIntervalSince1970)).\(minutes)",
                    fireDate: fire, title: title, body: body, openItem: openItem
                ))
            }
        }

        for event in events where !event.alerts.isEmpty {
            for occurrence in event.occurrences(from: first, through: last, in: display) {
                add(event.id.uuidString, openItem: occurrence.id, title: event.displayTitle, start: occurrence.start,
                    day: event.isAllDay ? CalendarDay(occurrence.start, in: event.ownCalendar) : nil, minutes: event.alerts)
            }
        }
        // Google's events: alerts kept on this iPhone only, never sent to Google.
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = .gmt
        for event in device {
            guard case .google = event.origin, let list = deviceAlerts[event.id], !list.isEmpty else { continue }
            add(event.id, openItem: nil, title: event.title.isEmpty ? "Untitled event" : event.title, start: event.start,
                day: event.isAllDay ? CalendarDay(event.start, in: gmt) : nil, minutes: list)
        }
        let sorted = planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        return ReminderPlan(planned: Array(sorted.prefix(limit)), skipped: max(0, sorted.count - limit))
    }
}

public struct SystemReminders: ReminderScheduler {
    private static let prefix = "calendar."

    public init() {}

    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Alerts are replaced as a set, so an edited or deleted event can't fire an old one.
    public func replace(with reminders: [PlannedReminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        )
        // The Notifications page's switch for event alerts (issue 232).
        let (allowed, preferences) = await MainActor.run {
            (NotificationHub.shared.allows(NotificationHub.reminderKinds[1]), NotificationHub.shared.preferences)
        }
        guard allowed else { return }
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            // The same buttons as every Totality alert: Snooze 10 min and Open, which the hub handles.
            content.categoryIdentifier = PlannedAlert.category(for: [.snoozeTen, .open])
            content.userInfo = NotificationTarget(module: .calendar, kind: reminder.openItem == nil ? "day" : "event", item: reminder.openItem ?? "").userInfo
            content.threadIdentifier = "calendar"
            // Quiet hours still apply: it arrives in Notification Centre with no sound.
            if preferences.isQuiet(at: reminder.fireDate) {
                content.interruptionLevel = .passive
            } else {
                content.sound = .default
            }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }
}
