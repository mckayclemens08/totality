import Foundation
import TotalityCore

/// Step 4: tasks made from other modules, waiting for replies, and tasks on the Calendar (issue 123,
/// mockup approved 2026-11-18). Pure, so the rules are tested without a vault.
public enum TaskConnections {
    /// The length a task gets on the Calendar when it has a time but no length yet.
    public static let defaultBlock = 30

    /// A task made from another module's content. It goes to the Inbox, like quick add (decision 7), and
    /// keeps only the title the person kept plus the link, so a message's words aren't copied (decision 4).
    public static func task(from draft: TaskDraft, order: Double, now: Date) -> TaskItem {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var task = TaskItem(title: title.isEmpty ? draft.source.title : title, place: .inbox, order: order, createdAt: now)
        var source = draft.source
        source.quote = source.quote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        task.source = source
        return task
    }

    /// Open tasks waiting for a reply, by the module they wait in.
    public static func waiting(in tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { !$0.isCompleted && $0.source?.waiting != nil }
    }

    /// The Waiting list: open ones, longest wait first, then those a reply ticked off today.
    public static func waitingList(_ tasks: [TaskItem], today: TaskDay, in calendar: Calendar) -> (open: [TaskItem], doneToday: [TaskItem]) {
        func since(_ task: TaskItem) -> Date { task.source?.waiting?.since ?? .distantPast }
        func completed(_ task: TaskItem) -> Date { task.completedAt ?? .distantPast }
        let open = waiting(in: tasks).sorted { since($0) < since($1) }
        let done = tasks.filter { task in
            guard let at = task.completedAt, task.source?.waiting != nil else { return false }
            return TaskDay(at, in: calendar) == today
        }
        return (open, done.sorted { completed($0) > completed($1) })
    }

    /// What to ask a module: each waiting item, and the moment from which a reply counts.
    public static func questions(for tasks: [TaskItem], in module: ModuleID) -> [String: Date] {
        var asked: [String: Date] = [:]
        for task in waiting(in: tasks) {
            guard let source = task.source, source.module == module, let since = source.waiting?.since else { continue }
            asked[source.itemID] = min(asked[source.itemID] ?? since, since)
        }
        return asked
    }

    /// The waiting tasks a reply has answered: each with the reply that answered it.
    public static func answered(_ tasks: [TaskItem], in module: ModuleID, by replies: [String: Reply]) -> [(task: TaskItem, reply: Reply)] {
        waiting(in: tasks).compactMap { task in
            guard let source = task.source, source.module == module, let since = source.waiting?.since,
                  let reply = replies[source.itemID], reply.at > since
            else { return nil }
            return (task, reply)
        }
    }

    /// "Waiting 3 days", or "Waiting since today".
    public static func waitingLine(_ task: TaskItem, today: TaskDay, in calendar: Calendar) -> String? {
        guard let waiting = task.source?.waiting else { return nil }
        if let replied = waiting.repliedAt {
            return "Reply arrived \(replied.formatted(Date.FormatStyle(date: .omitted, time: .shortened)))"
        }
        let days = TaskDay(waiting.since, in: calendar).days(to: today, in: calendar)
        switch days {
        case ..<1: return "Waiting since today"
        case 1: return "Waiting 1 day"
        default: return "Waiting \(days) days"
        }
    }

    // MARK: The Calendar

    /// Timed tasks touching the range, for the Calendar to draw lighter than its events. Done ones stay
    /// off, and so do tasks with no time.
    public static func agenda(_ tasks: [TaskItem], lists: [TaskList], from start: Date, to end: Date, in calendar: Calendar) -> [AgendaItem] {
        tasks.compactMap { task in
            guard !task.isCompleted, let day = task.when, let time = task.time else { return nil }
            let begins = day.date(at: time, in: calendar)
            let ends = begins.addingTimeInterval(TimeInterval((task.blockMinutes ?? defaultBlock) * 60))
            guard begins < end, ends > start else { return nil }
            let list = lists.first { $0.id == task.listID }?.displayName
            return AgendaItem(
                id: task.id.uuidString, title: task.displayTitle, start: begins, end: ends, isAllDay: false,
                module: .tasks, detail: list
            )
        }
    }

    /// Open tasks planned for the day with no time yet, which can be dragged onto one. Today's include
    /// anything overdue still waiting, as Today shows them.
    public static func unplanned(_ tasks: [TaskItem], on day: TaskDay, today: TaskDay, in calendar: Calendar) -> [AgendaItem] {
        tasks
            .filter { task in
                guard !task.isCompleted, task.time == nil, let when = task.when else { return false }
                return day == today ? when <= today : when == day
            }
            .sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
            .map { task in
                let start = day.start(in: calendar)
                return AgendaItem(
                    id: task.id.uuidString, title: task.displayTitle, start: start, end: start, isAllDay: true,
                    module: .tasks, detail: task.deadline.map { "Due \($0.start(in: calendar).formatted(.dateTime.weekday(.abbreviated)))" }
                )
            }
    }

    /// The task given a time and a length, from a drop on the Calendar.
    public static func planned(_ task: TaskItem, at start: Date, minutes: Int, in calendar: Calendar) -> TaskItem {
        var task = task
        task.when = TaskDay(start, in: calendar)
        task.time = TaskTime(start, in: calendar)
        task.isEvening = false
        task.blockMinutes = max(5, minutes)
        if task.place != .anytime { task.place = .anytime }
        return task
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
