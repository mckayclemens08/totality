import Foundation
import UserNotifications

/// Alarms and timers as local notifications, for iOS 17 to 25, which have no AlarmKit. They obey the
/// silent switch, play at most 30 seconds, and Focus can hold them back, so the screens call them
/// notifications, never alarms. iOS keeps 64 pending notifications for the whole app, shared with Tasks and
/// the Calendar; a repeating alarm takes one per weekday.
///
/// Snooze isn't offered here: Tasks answers the app's notification actions, and a notification that
/// rings again by itself would be a second alarm, not a snooze.
public struct NotificationAlarms: AlarmScheduling {
    public static let prefix = "clock."

    public init() {}

    public var ringsAsAlarm: Bool { false }

    public func access() async -> AlarmAccess {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
    }

    public func requestAccess() async -> AlarmAccess {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await access()
    }

    public func schedule(_ alarm: ClockAlarm, sound: String?) async throws {
        await cancelAlarm(alarm.id)
        guard alarm.isOn else { return }
        guard await access() == .allowed else { throw AlarmSchedulingError.notAllowed }
        let center = UNUserNotificationCenter.current()
        for (suffix, trigger) in Self.triggers(for: alarm) {
            let request = UNNotificationRequest(
                identifier: Self.alarmID(alarm.id, suffix), content: Self.content(title: alarm.label.isEmpty ? "Alarm" : alarm.label, body: Self.time(of: alarm), sound: sound),
                trigger: trigger
            )
            do { try await center.add(request) } catch { throw AlarmSchedulingError.failed }
        }
    }

    public func cancelAlarm(_ id: UUID) async {
        await remove { $0.hasPrefix(Self.alarmID(id, "")) }
    }

    public func start(_ timer: RunningTimer, sound: String?, at now: Date) async throws {
        await cancelTimer(timer.id)
        guard await access() == .allowed else { throw AlarmSchedulingError.notAllowed }
        let left = timer.remaining(at: now)
        guard left > 0 else { return }
        let request = UNNotificationRequest(
            identifier: Self.timerID(timer.id), content: Self.content(title: timer.label.isEmpty ? "Timer" : timer.label, body: "Your timer is done.", sound: sound),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: left, repeats: false)
        )
        do { try await UNUserNotificationCenter.current().add(request) } catch { throw AlarmSchedulingError.failed }
    }

    public func pause(_ timer: RunningTimer) async {
        await cancelTimer(timer.id)
    }

    public func cancelTimer(_ id: UUID) async {
        await remove { $0 == Self.timerID(id) }
    }

    public func bedtimeReminder(_ sleep: SleepSchedule?) async {
        await remove { $0.hasPrefix(Self.prefix + "bedtime.") }
        guard let sleep, sleep.isOn, await access() == .allowed else { return }
        for (weekday, parts) in Self.bedtimeParts(sleep) {
            let request = UNNotificationRequest(
                identifier: Self.prefix + "bedtime.\(weekday)",
                content: Self.content(title: "Bedtime", body: sleep.remindMinutes > 0 ? "Bed in \(sleep.remindMinutes) minutes." : "It's time for bed.", sound: nil),
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: Parts

    static func alarmID(_ id: UUID, _ suffix: String) -> String { prefix + "alarm.\(id.uuidString.lowercased())." + suffix }
    static func timerID(_ id: UUID) -> String { prefix + "timer.\(id.uuidString.lowercased())" }

    /// One trigger per weekday for a repeating alarm, or one for a one-time alarm.
    static func triggers(for alarm: ClockAlarm) -> [(String, UNNotificationTrigger)] {
        if let date = alarm.date {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return [("once", UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))]
        }
        if alarm.weekdays.isEmpty {
            return [("once", UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: alarm.hour, minute: alarm.minute), repeats: false))]
        }
        return alarm.weekdays.sorted().map { weekday in
            ("\(weekday)", UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: alarm.hour, minute: alarm.minute, weekday: weekday), repeats: true))
        }
    }

    /// The reminder's times, moved back from bedtime, which can move it to the day before.
    static func bedtimeParts(_ sleep: SleepSchedule) -> [(Int, DateComponents)] {
        let bed = sleep.bedHour * 60 + sleep.bedMinute
        let wake = sleep.wakeHour * 60 + sleep.wakeMinute
        // Bed after the wake-up's time of day is the night before; bed after midnight is the same day.
        var shift = bed < wake ? 0 : -1
        var reminder = bed - sleep.remindMinutes
        if reminder < 0 {
            reminder += 24 * 60
            shift -= 1
        }
        return sleep.weekdays.sorted().map { wakeDay in
            let day = ((wakeDay - 1 + shift) % 7 + 7) % 7 + 1
            return (day, DateComponents(hour: reminder / 60, minute: reminder % 60, weekday: day))
        }
    }

    private static func content(title: String, body: String, sound: String?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        return content
    }

    private static func time(of alarm: ClockAlarm) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func remove(where match: (String) -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter(match)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }
}
