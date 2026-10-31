import Foundation
import UserNotifications

/// A reminder the device will show. It holds the title and time and nothing else, because the
/// operating system keeps it outside Totality's encryption until it fires. Locations and notes stay
/// out on purpose.
public struct PlannedReminder: Identifiable, Sendable, Equatable {
    public let id: String
    public let fireDate: Date
    public let title: String
    public let body: String
}

public protocol ReminderScheduler: Sendable {
    func requestPermission() async -> Bool
    func replace(with reminders: [PlannedReminder]) async
}

enum ReminderPlanner {
    /// iOS keeps 64 pending notifications per app. The rest are picked up as these fire and the
    /// Calendar is opened again.
    static let limit = 60
    static let horizonDays = 30
    /// All-day events have no start time, so their reminders count back from this hour.
    static let allDayHour = 9

    static func plan(for events: [CalendarEvent], now: Date, display: Calendar) -> [PlannedReminder] {
        let first = CalendarDay(now, in: display)
        let last = first.adding(days: horizonDays, in: display)
        var planned: [PlannedReminder] = []
        for event in events {
            guard let minutes = event.reminderMinutes else { continue }
            for occurrence in event.occurrences(from: first, through: last, in: display) {
                let moment: Date
                let body: String
                if event.isAllDay {
                    let day = CalendarDay(occurrence.start, in: event.ownCalendar)
                    moment = display.date(byAdding: .hour, value: allDayHour, to: day.start(in: display)) ?? day.start(in: display)
                    body = "All day"
                } else {
                    moment = occurrence.start
                    body = moment.formatted(date: .abbreviated, time: .shortened)
                }
                let fire = moment.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now else { continue }
                planned.append(PlannedReminder(
                    id: "calendar.\(event.id.uuidString).\(Int(occurrence.start.timeIntervalSince1970))",
                    fireDate: fire, title: event.displayTitle, body: body
                ))
            }
        }
        return Array(planned.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
    }
}

public struct SystemReminders: ReminderScheduler {
    private static let prefix = "calendar."

    public init() {}

    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Reminders are replaced as a set, so an edited or deleted event can't fire an old one.
    public func replace(with reminders: [PlannedReminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        )
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }
}
