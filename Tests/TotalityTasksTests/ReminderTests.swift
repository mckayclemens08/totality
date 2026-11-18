import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Step 3: reminders, nagging within iOS's limit, and snooze.
@Suite struct ReminderTests {
    private let wed = day(2026, 11, 18)

    private func task(_ title: String = "Submit the Hegel paper", reminders: [TaskReminder.Kind], nagging: Nagging? = nil) -> TaskItem {
        var task = TaskItem(title: title, deadline: wed, createdAt: agreed)
        task.deadlineTime = TaskTime(hour: 23, minute: 59)
        task.reminders = reminders.map { TaskReminder(kind: $0) }
        task.nagging = nagging
        return task
    }

    @Test("Time and deadline reminders ring when they should")
    func fireDates() {
        let t = task(reminders: [])
        #expect(TaskReminder(kind: .at(wed, TaskTime(hour: 20)!)).fireDate(for: t, in: denver) == moment(2026, 11, 18, 20))
        #expect(TaskReminder(kind: .beforeDeadline(.hour)).fireDate(for: t, in: denver) == moment(2026, 11, 18, 22, 59))
        #expect(TaskReminder(kind: .beforeDeadline(.day)).fireDate(for: t, in: denver) == moment(2026, 11, 17, 23, 59))
        #expect(TaskReminder(kind: .beforeDeadline(.morningOf)).fireDate(for: t, in: denver) == moment(2026, 11, 18, 9))
        var noTime = t
        noTime.deadlineTime = nil
        #expect(TaskReminder(kind: .beforeDeadline(.hour)).fireDate(for: noTime, in: denver) == nil)
    }

    @Test("Nagging gives up at midnight, 16 at most, the first included")
    func naggingRun() {
        let run = Nagging(everyMinutes: 15).run(from: moment(2026, 11, 18, 20), in: denver)
        #expect(run.count == 16)
        #expect(run.first == moment(2026, 11, 18, 20))
        #expect(run.last == moment(2026, 11, 18, 23, 45))
        let five = Nagging(everyMinutes: 5).run(from: moment(2026, 11, 18, 20), in: denver)
        #expect(five.count == Nagging.maxPerRun)
        let hour = Nagging(everyMinutes: 30, giveUp: .afterHours(1)).run(from: moment(2026, 11, 18, 20), in: denver)
        #expect(hour == [moment(2026, 11, 18, 20), moment(2026, 11, 18, 20, 30)])
    }

    @Test("Nagging picks up where it is after the app opens late, and never passes the budget")
    func planWithinLimit() {
        let nagged = task(reminders: [.at(wed, TaskTime(hour: 20)!)], nagging: Nagging(everyMinutes: 5))
        // Opened at 9:02pm: the 8pm run is 16, every 5 minutes to 9:15; those before 9:02 are gone.
        let plan = TaskReminderPlanner.plan([nagged], now: moment(2026, 11, 18, 21, 2), calendar: denver)
        #expect(plan.first?.fireDate == moment(2026, 11, 18, 21, 5))
        #expect(plan.count == 3)
        // Many nagging tasks: the soonest fill the budget and no more.
        let many = (0..<10).map { i in
            task("Task \(i)", reminders: [.at(wed, TaskTime(hour: 18, minute: i)!)], nagging: Nagging(everyMinutes: 10))
        }
        let full = TaskReminderPlanner.plan(many, now: moment(2026, 11, 18, 12), calendar: denver)
        #expect(full.count == TaskReminderPlanner.budget)
        #expect(full == full.sorted { $0.fireDate < $1.fireDate })
        #expect(TaskReminderPlanner.plan(many, now: moment(2026, 11, 18, 12), calendar: denver, budget: 5).count == 5)
        #expect(Set(full.map(\.id)).count == full.count)
    }

    @Test("Finished tasks and past reminders ring no more")
    func finishedAndPast() {
        var done = task(reminders: [.at(wed, TaskTime(hour: 20)!)], nagging: Nagging())
        done.completedAt = moment(2026, 11, 18, 19)
        #expect(TaskReminderPlanner.plan([done], now: moment(2026, 11, 18, 12), calendar: denver).isEmpty)
        let past = task(reminders: [.at(day(2026, 11, 17), TaskTime(hour: 20)!)])
        #expect(TaskReminderPlanner.plan([past], now: moment(2026, 11, 18, 12), calendar: denver).isEmpty)
    }

    @Test("Snoozing pauses nagging until it ends, then nagging picks up")
    func snooze() {
        var nagged = task(reminders: [.at(wed, TaskTime(hour: 20)!)], nagging: Nagging(everyMinutes: 15))
        nagged.snoozedUntil = moment(2026, 11, 18, 20, 40)
        let plan = TaskReminderPlanner.plan([nagged], now: moment(2026, 11, 18, 20, 25), calendar: denver)
        #expect(plan.first?.fireDate == moment(2026, 11, 18, 20, 40))
        #expect(!plan.contains { $0.fireDate < moment(2026, 11, 18, 20, 40) })
        #expect(plan.dropFirst().first?.fireDate == moment(2026, 11, 18, 20, 55))
        // Without nagging, a snooze is one reminder.
        var plain = task(reminders: [.at(wed, TaskTime(hour: 20)!)])
        plain.snoozedUntil = moment(2026, 11, 18, 20, 15)
        #expect(TaskReminderPlanner.plan([plain], now: moment(2026, 11, 18, 20, 1), calendar: denver).map(\.fireDate) == [moment(2026, 11, 18, 20, 15)])
    }

    @Test("Snooze lengths are fixed: 15 minutes, or tomorrow at 9")
    func snoozeLengths() {
        let now = moment(2026, 11, 18, 20, 15)
        #expect(ReminderAction.Snooze.fifteenMinutes.until(from: now, in: denver) == moment(2026, 11, 18, 20, 30))
        #expect(ReminderAction.Snooze.tomorrowMorning.until(from: now, in: denver) == moment(2026, 11, 19, 9))
    }

    @Test("A notification carries the real title and the due line, and no notes or place")
    func words() throws {
        var t = task(reminders: [.at(wed, TaskTime(hour: 20)!)], nagging: Nagging())
        t.notes = "Private draft notes"
        let listID = UUID()
        t.listID = listID
        let plan = TaskReminderPlanner.plan([t], listNames: [listID: "PHIL 425"], now: moment(2026, 11, 18, 12), calendar: denver)
        let first = try #require(plan.first)
        #expect(first.title == "Submit the Hegel paper")
        #expect(first.body.contains("PHIL 425"))
        #expect(first.body.contains("Reminding you every 15 min."))
        #expect(!first.body.contains("Private"))
        #expect(TaskReminderPlanner.taskID(in: first.id) == t.id)
    }

    @Test("Places to watch stay within iOS's 20")
    func placeLimit() {
        let place = ReminderPlace(name: "Marriott Library", latitude: 40.7623, longitude: -111.8465)
        let tasks = (0..<25).map { task("Return book \($0)", reminders: [.place(place)]) }
        let watched = TaskReminderPlanner.places(tasks, calendar: denver)
        #expect(watched.count == TaskReminderPlanner.placeLimit)
        #expect(watched.first?.body == "Arriving at Marriott Library")
    }

    @MainActor
    @Test("Complete and Snooze from a notification apply once Tasks opens")
    func queuedActions() async throws {
        let defaults = try #require(UserDefaults(suiteName: "tasks.tests.\(UUID())"))
        let queue = ReminderActionQueue(defaults: defaults)
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let snoozed = task("Email Dr. Lee", reminders: [.at(wed, TaskTime(hour: 20)!)])
        let finished = task(reminders: [.at(wed, TaskTime(hour: 20)!)])
        try await vault.save(snoozed)
        try await vault.save(finished)
        let until = moment(2026, 11, 18, 20, 15)
        queue.add(ReminderAction(taskID: snoozed.id, kind: .snooze(until: until), at: moment(2026, 11, 18, 20)))
        queue.add(ReminderAction(taskID: finished.id, kind: .complete, at: moment(2026, 11, 18, 20, 1)))
        let model = TasksModel(vault: vault, calendar: denver, now: { moment(2026, 11, 18, 20, 5) })
        model.actionQueue = queue
        await model.load()
        #expect(model.tasks.first { $0.id == snoozed.id }?.snoozedUntil == until)
        #expect(model.tasks.first { $0.id == finished.id }?.completedAt == moment(2026, 11, 18, 20, 1))
        #expect(queue.drain().isEmpty)
    }

    @Test("A task saved before step 3 still opens, with no reminders")
    func olderTask() throws {
        let old = #"{"id":"6F1C2C8E-6B39-4C5B-9C0E-2B7B9E2F1A11","title":"Call Gran","createdAt":0}"#
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(old.utf8))
        #expect(task.reminders.isEmpty)
        #expect(task.repeatRule == nil)
    }

    @Test("Reminders and repeats merge as their own parts")
    func merge() {
        let base = task(reminders: [])
        var mine = base
        mine.reminders = [TaskReminder(kind: .beforeDeadline(.morningOf))]
        mine.noteChanges(from: base, at: moment(2026, 11, 18, 10))
        var theirs = base
        theirs.repeatRule = RepeatRule(kind: .daily, start: wed)
        theirs.noteChanges(from: base, at: moment(2026, 11, 18, 11))
        let merged = mine.merged(with: theirs)
        #expect(merged.reminders == mine.reminders)
        #expect(merged.repeatRule == theirs.repeatRule)
        #expect(merged == theirs.merged(with: mine))
    }
}
