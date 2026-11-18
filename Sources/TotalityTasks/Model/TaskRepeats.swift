import CryptoKit
import Foundation

/// What happens to a repeating task when it's ticked off, skipped or stopped.
public enum TaskRepeats {
    /// The day a repeat counts from: When, or the deadline when there's no When.
    public static func anchor(of task: TaskItem) -> TaskDay? {
        task.when ?? task.deadline
    }

    /// The next copy of a task finished at `completedAt`, or nil when it doesn't repeat or has ended.
    /// Its ID comes from the finished task's and the new day, so two devices that tick off the same task
    /// make the same copy and sync settles on one.
    public static func following(_ task: TaskItem, completedAt: Date, in calendar: Calendar) -> TaskItem? {
        guard let rule = task.repeatRule else { return nil }
        let completedDay = TaskDay(completedAt, in: calendar)
        let anchor = anchor(of: task) ?? completedDay
        guard let next = rule.next(after: anchor, completed: completedDay, in: calendar) else { return nil }
        var rule2 = rule
        rule2.done += 1
        return moved(task, from: anchor, to: next, rule: rule2, id: followingID(of: task.id, on: next), now: completedAt, in: calendar)
    }

    /// Passes over the occurrence that's due and moves the task to the one after. Nil when there's none.
    public static func skippingNext(_ task: TaskItem, in calendar: Calendar) -> TaskItem? {
        guard var rule = task.repeatRule, let anchor = anchor(of: task) else { return nil }
        rule.skipped.insert(anchor)
        guard let next = rule.next(after: anchor, in: calendar) else { return nil }
        // Old skips before the new day are dropped, so the sealed rule doesn't grow for ever.
        rule.skipped = rule.skipped.filter { $0 >= anchor }
        var result = moved(task, from: anchor, to: next, rule: rule, id: task.id, now: task.updatedAt, in: calendar)
        result.completedAt = task.completedAt
        return result
    }

    static func followingID(of id: UUID, on day: TaskDay) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("totality.task.repeat|\(id.uuidString.lowercased())|\(day.year)-\(day.month)-\(day.day)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func moved(
        _ task: TaskItem, from anchor: TaskDay, to next: TaskDay, rule: RepeatRule, id: UUID, now: Date, in calendar: Calendar
    ) -> TaskItem {
        let shift = anchor.days(to: next, in: calendar)
        var copy = TaskItem(
            id: id, title: task.title, notes: task.notes, place: task.place == .inbox ? .anytime : task.place,
            when: task.when.map { $0.adding(days: shift, in: calendar) }, isEvening: task.isEvening, time: task.time,
            deadline: task.when == nil ? next : task.deadline.map { $0.adding(days: shift, in: calendar) },
            checklist: task.checklist.map { .init(title: $0.title) }, tags: task.tags, priority: task.priority,
            listID: task.listID, headingID: task.headingID, order: task.order, createdAt: id == task.id ? task.createdAt : now
        )
        if id == task.id {
            copy.checklist = task.checklist
            copy.edits = task.edits
            copy.updatedAt = task.updatedAt
        }
        copy.deadlineTime = task.deadlineTime
        copy.repeatRule = rule
        copy.nagging = task.nagging
        copy.reminders = task.reminders.map { reminder in
            guard case .at(let day, let time) = reminder.kind else { return reminder }
            return TaskReminder(id: reminder.id, kind: .at(day.adding(days: shift, in: calendar), time))
        }
        return copy
    }
}
