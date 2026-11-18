import Foundation

/// One notification the iPhone will show. It holds the task's real title, which the owner chose to show
/// on the lock screen (2026-11-18), and nothing else from the task: no notes, no place.
public struct PlannedTaskNotification: Sendable, Equatable, Identifiable {
    public let id: String
    public let taskID: UUID
    public let fireDate: Date
    public let title: String
    public let body: String
}

/// A place the iPhone watches for one task.
public struct PlannedPlace: Sendable, Equatable, Identifiable {
    public let id: String
    public let taskID: UUID
    public let place: ReminderPlace
    public let title: String
    public let body: String
}

/// Works out every notification Tasks wants, from the tasks alone, so it can be tested without iOS.
public enum TaskReminderPlanner {
    /// iOS keeps 64 pending notifications per app, Calendar's included. Tasks takes what's left, up to this.
    public static let budget = 40
    /// iOS watches at most 20 regions per app.
    public static let placeLimit = 20
    public static let prefix = "task."

    public static func notificationID(_ task: UUID, _ date: Date) -> String {
        "\(prefix)\(task.uuidString.lowercased()).\(Int(date.timeIntervalSince1970))"
    }

    /// The task a notification ID belongs to.
    public static func taskID(in identifier: String) -> UUID? {
        let parts = identifier.split(separator: ".")
        guard parts.count >= 2, parts[0] == "task" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// The soonest `budget` notifications, in order.
    public static func plan(
        _ tasks: [TaskItem], listNames: [UUID: String] = [:], now: Date, calendar: Calendar, budget: Int = budget
    ) -> [PlannedTaskNotification] {
        var planned: [PlannedTaskNotification] = []
        for task in tasks where !task.isCompleted {
            var fires = Set(moments(for: task, now: now, calendar: calendar).map { Int($0.timeIntervalSince1970) })
            fires = fires.filter { Double($0) > now.timeIntervalSince1970 }
            for second in fires {
                let date = Date(timeIntervalSince1970: Double(second))
                planned.append(PlannedTaskNotification(
                    id: notificationID(task.id, date), taskID: task.id, fireDate: date, title: task.displayTitle,
                    body: body(for: task, listName: task.listID.flatMap { listNames[$0] }, on: date, calendar: calendar)
                ))
            }
        }
        return Array(planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(max(0, budget)))
    }

    /// Every moment a task rings, past ones included; `plan` keeps the future ones.
    static func moments(for task: TaskItem, now: Date, calendar: Calendar) -> [Date] {
        let starts = task.reminders.compactMap { $0.fireDate(for: task, in: calendar) }
        if let until = task.snoozedUntil, until > now {
            // Snoozing pauses everything, nagging too, until the snooze ends; then it picks up again.
            let later = starts.filter { $0 > until }
            let resumed = task.nagging.map { $0.run(from: until, in: calendar) } ?? [until]
            return resumed + later.flatMap { run(from: $0, task.nagging, calendar) }
        }
        return starts.flatMap { run(from: $0, task.nagging, calendar) }
    }

    private static func run(from start: Date, _ nagging: Nagging?, _ calendar: Calendar) -> [Date] {
        nagging?.run(from: start, in: calendar) ?? [start]
    }

    /// "Due tonight 11:59 PM · Hegel paper. Reminding you every 15 min."
    static func body(for task: TaskItem, listName: String?, on date: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if let deadline = task.deadline {
            let fireDay = TaskDay(date, in: calendar)
            var due = TaskText.deadline(deadline, today: fireDay, in: calendar)
            if let time = task.deadlineTime { due += " " + TaskText.time(time, in: calendar) }
            parts.append(due)
        }
        if let listName { parts.append(listName) }
        var body = parts.joined(separator: " · ")
        if let nagging = task.nagging {
            let every = nagging.everyMinutes == 60 ? "hour" : "\(nagging.everyMinutes) min"
            body += (body.isEmpty ? "" : ". ") + "Reminding you every \(every)."
        } else if let rule = task.repeatRule {
            body += (body.isEmpty ? "" : " · ") + "repeats " + rule.shortSummary(in: calendar)
        }
        return body
    }

    /// The places to watch, one per place reminder on an unfinished task, up to iOS's limit.
    public static func places(_ tasks: [TaskItem], calendar: Calendar) -> [PlannedPlace] {
        var planned: [PlannedPlace] = []
        for task in tasks.sorted(by: { $0.order < $1.order }) where !task.isCompleted {
            for reminder in task.reminders {
                guard case .place(let place) = reminder.kind else { continue }
                let verb = place.onArrival ? "Arriving at" : "Leaving"
                planned.append(PlannedPlace(
                    id: "\(prefix)\(task.id.uuidString.lowercased()).\(reminder.id.uuidString.lowercased())",
                    taskID: task.id, place: place, title: task.displayTitle, body: "\(verb) \(place.name)"
                ))
            }
        }
        return Array(planned.prefix(placeLimit))
    }
}
