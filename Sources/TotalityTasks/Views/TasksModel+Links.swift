import Foundation
import TotalityCore

// MARK: - Step 4: sources, waiting for replies

extension TasksModel {
    /// The Waiting list: open ones first, then those a reply ticked off today.
    public var waitingList: (open: [TaskItem], doneToday: [TaskItem]) {
        TaskConnections.waitingList(tasks, today: today, in: calendar)
    }

    public func waitingLine(for task: TaskItem) -> String? {
        TaskConnections.waitingLine(task, today: today, in: calendar)
    }

    /// Asks each watcher about the tasks waiting in it, and ticks off any that got a reply. It's quiet: the
    /// only sign is the Undo bar (decision 2).
    public func checkReplies() async {
        for watcher in replyWatchers {
            let asked = TaskConnections.questions(for: tasks, in: watcher.module)
            guard !asked.isEmpty else { continue }
            let replies = await watcher.replies(to: asked)
            for (task, reply) in TaskConnections.answered(tasks, in: watcher.module, by: replies) {
                await answer(task.id, by: reply)
            }
        }
    }

    /// Ticks off a waiting task because a reply came.
    func answer(_ id: UUID, by reply: Reply) async {
        let at = now
        await change(id) { task in
            task.source?.waiting?.repliedAt = reply.at
        }
        guard await finish(id, at: max(at, reply.at)) else { return }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let who = reply.from.trimmingCharacters(in: .whitespacesAndNewlines)
        showUndo(Completion(
            id: id, title: task.displayTitle,
            line: who.isEmpty ? "A reply came, so “\(task.displayTitle)” is done" : "\(who) replied, so the task is done"
        ))
    }

    /// Undo after a reply: the task waits again, from now, so the same reply doesn't tick it off again.
    func keepWaiting(_ id: UUID) async {
        guard tasks.first(where: { $0.id == id })?.source?.waiting != nil else { return }
        let at = now
        await change(id) { task in
            let replied = task.source?.waiting?.repliedAt ?? at
            task.source?.waiting = TaskSource.Waiting(since: max(at, replied))
        }
    }

    /// Opens where a task came from.
    public func openSource(of task: TaskItem) {
        guard let source = task.source else { return }
        onOpenSource?(source)
    }

    /// Takes away a link whose source is gone. The task keeps its title (decision 6).
    public func removeSource(of id: UUID) async {
        await change(id) { $0.source = nil }
    }
}

extension TasksModel {
    /// A task with a day and a time still ahead can ring as an alarm, through the Clock (issue 204).
    public func alarmOffer(for task: TaskItem) -> AlarmDraft? {
        guard alarmMaker != nil, !task.isCompleted, let day = task.when, let time = task.time else { return nil }
        let date = day.date(at: time, in: calendar)
        guard date > now else { return nil }
        return AlarmDraft(
            label: task.displayTitle, fireDate: date,
            source: TaskSource(module: .tasks, itemID: task.id.uuidString, title: task.displayTitle)
        )
    }
}
