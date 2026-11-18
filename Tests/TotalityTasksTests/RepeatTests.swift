import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Step 3: next dates for every kind of repeat, month ends, clock changes, skipping and ending.
@Suite struct RepeatTests {
    // Wed 18 Nov 2026 is the start for most of these.
    private let wed = day(2026, 11, 18)

    @Test("Daily and every few days count calendar days")
    func daily() {
        #expect(RepeatRule(kind: .daily, start: wed).next(after: wed, in: denver) == day(2026, 11, 19))
        #expect(RepeatRule(kind: .daily, interval: 3, start: wed).next(after: wed, in: denver) == day(2026, 11, 21))
    }

    @Test("Weekly on Mon and Wed walks the chosen days")
    func weeklyOnDays() {
        let rule = RepeatRule(kind: .weekly, weekdays: [2, 4], start: wed)
        #expect(rule.next(after: wed, in: denver) == day(2026, 11, 23))
        #expect(rule.next(after: day(2026, 11, 23), in: denver) == day(2026, 11, 25))
        #expect(rule.summary(in: denver) == "Every Mon and Wed")
        #expect(rule.shortSummary(in: denver) == "Mon, Wed")
    }

    @Test("Every 2 weeks on Tuesday skips the off weeks")
    func everyOtherWeek() {
        let tue = day(2026, 11, 17)
        let rule = RepeatRule(kind: .custom, interval: 2, customUnit: .week, weekdays: [3], start: tue)
        #expect(rule.next(after: tue, in: denver) == day(2026, 12, 1))
        #expect(rule.next(after: day(2026, 12, 1), in: denver) == day(2026, 12, 15))
        #expect(rule.summary(in: denver) == "Every 2 weeks on Tue")
    }

    @Test("Every weekday passes over the weekend")
    func weekdays() {
        let fri = day(2026, 11, 20)
        let rule = RepeatRule(kind: .custom, customUnit: .week, weekdays: [2, 3, 4, 5, 6], start: fri)
        #expect(rule.next(after: fri, in: denver) == day(2026, 11, 23))
        #expect(rule.summary(in: denver) == "Every weekday")
    }

    @Test("Monthly on the 31st lands on each month's last day")
    func monthEnd() {
        let rule = RepeatRule(kind: .monthly, start: day(2027, 1, 31))
        #expect(rule.next(after: day(2027, 1, 31), in: denver) == day(2027, 2, 28))
        #expect(rule.next(after: day(2027, 2, 28), in: denver) == day(2027, 3, 31))
        #expect(rule.next(after: day(2027, 3, 31), in: denver) == day(2027, 4, 30))
        // A leap year's February.
        let leap = RepeatRule(kind: .monthly, start: day(2028, 1, 31))
        #expect(leap.next(after: day(2028, 1, 31), in: denver) == day(2028, 2, 29))
    }

    @Test("Monthly on the 1st and 15th, and on the last day")
    func monthDays() {
        let rule = RepeatRule(kind: .monthly, monthDays: [1, 15], start: day(2026, 11, 1))
        #expect(rule.next(after: day(2026, 11, 1), in: denver) == day(2026, 11, 15))
        #expect(rule.next(after: day(2026, 11, 15), in: denver) == day(2026, 12, 1))
        let last = RepeatRule(kind: .monthly, monthDays: [-1], start: day(2026, 11, 30))
        #expect(last.next(after: day(2026, 11, 30), in: denver) == day(2026, 12, 31))
        #expect(last.next(after: day(2026, 12, 31), in: denver) == day(2027, 1, 31))
        #expect(last.next(after: day(2027, 1, 31), in: denver) == day(2027, 2, 28))
    }

    @Test("Monthly on the last Friday")
    func lastFriday() {
        let rule = RepeatRule(kind: .monthly, monthWeekday: .init(ordinal: -1, weekday: 6), start: day(2026, 11, 27))
        #expect(rule.next(after: day(2026, 11, 27), in: denver) == day(2026, 12, 25))
        #expect(rule.next(after: day(2026, 12, 25), in: denver) == day(2027, 1, 29))
        #expect(rule.summary(in: denver) == "Monthly on the last Friday")
    }

    @Test("Yearly keeps the date, and 29 February falls on the 28th in other years")
    func yearly() {
        let birthday = RepeatRule(kind: .yearly, start: day(2027, 4, 3))
        #expect(birthday.next(after: day(2027, 4, 3), in: denver) == day(2028, 4, 3))
        let leapDay = RepeatRule(kind: .yearly, start: day(2028, 2, 29))
        #expect(leapDay.next(after: day(2028, 2, 29), in: denver) == day(2029, 2, 28))
    }

    @Test("After I finish counts from the tick, or from the due date, as chosen")
    func afterFinish() {
        let fromTick = RepeatRule(kind: .afterFinish, interval: 3, customUnit: .day, countFrom: .completion, start: wed)
        // Due Wednesday, finished late on Friday: three days after Friday.
        #expect(fromTick.next(after: wed, completed: day(2026, 11, 20), in: denver) == day(2026, 11, 23))
        let fromDue = RepeatRule(kind: .afterFinish, interval: 3, customUnit: .day, countFrom: .dueDate, start: wed)
        #expect(fromDue.next(after: wed, completed: day(2026, 11, 20), in: denver) == day(2026, 11, 21))
        let monthly = RepeatRule(kind: .afterFinish, customUnit: .month, start: day(2027, 1, 31))
        #expect(monthly.next(after: day(2027, 1, 31), completed: day(2027, 1, 31), in: denver) == day(2027, 2, 28))
        #expect(fromTick.summary(in: denver) == "3 days after I finish")
    }

    @Test("Clock changes don't move a repeat to another day")
    func daylightSaving() {
        // 2027's spring change in Denver is Sunday 14 March, 2am; autumn's is Sunday 7 November.
        let sat = day(2027, 3, 13)
        let daily = RepeatRule(kind: .daily, start: sat)
        let sun = daily.next(after: sat, in: denver)!
        #expect(sun == day(2027, 3, 14))
        #expect(daily.next(after: sun, in: denver) == day(2027, 3, 15))
        let weekly = RepeatRule(kind: .weekly, start: day(2027, 3, 7))
        #expect(weekly.next(after: day(2027, 3, 7), in: denver) == day(2027, 3, 14))
        #expect(weekly.next(after: day(2027, 10, 31), in: denver) == day(2027, 11, 7))
        // A 2:30am reminder on the day 2:30 doesn't exist still rings that day, just after the change.
        let ring = sun.date(at: TaskTime(hour: 2, minute: 30)!, in: denver)
        #expect(TaskDay(ring, in: denver) == sun)
        // And in a zone with no clock change, against one with a midnight change (Santiago).
        let santiago = calendar("America/Santiago")
        let rule = RepeatRule(kind: .daily, start: day(2026, 9, 5))
        #expect(rule.next(after: day(2026, 9, 5), in: santiago) == day(2026, 9, 6))
    }

    @Test("Skipped days are passed over, and the end stops it")
    func skipAndEnd() {
        var rule = RepeatRule(kind: .weekly, weekdays: [2, 4], end: .on(day(2026, 12, 11)), start: wed)
        rule.skipped = [day(2026, 11, 25)]
        #expect(rule.next(after: day(2026, 11, 23), in: denver) == day(2026, 11, 30))
        #expect(rule.next(after: day(2026, 12, 9), in: denver) == nil)
        let coming = rule.upcoming(from: wed, count: 4, in: denver)
        #expect(coming.map(\.day) == [wed, day(2026, 11, 23), day(2026, 11, 25), day(2026, 11, 30)])
        #expect(coming.map(\.skipped) == [false, false, true, false])
        #expect(rule.remaining(after: wed, in: denver) == 5)
        let tenTimes = RepeatRule(kind: .daily, end: .after(times: 2), start: wed, done: 1)
        #expect(tenTimes.next(after: wed, in: denver) == nil)
    }

    @Test("A rule seals and opens the same, sets written in order")
    func coding() throws {
        let rule = RepeatRule(kind: .weekly, weekdays: [6, 2, 4], start: wed, skipped: [day(2026, 12, 2), day(2026, 11, 25)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(rule)
        #expect(try JSONDecoder().decode(RepeatRule.self, from: data) == rule)
        let again = RepeatRule(kind: .weekly, weekdays: [4, 6, 2], start: wed, skipped: [day(2026, 11, 25), day(2026, 12, 2)])
        #expect(try encoder.encode(again) == data)
    }

    // MARK: - Ticking off

    private func repeating(_ rule: RepeatRule) -> TaskItem {
        var task = TaskItem(title: "Seminar reading: Nagel", when: wed, time: TaskTime(hour: 8, minute: 30), checklist: [.init(title: "Take notes", isDone: true)], createdAt: agreed)
        task.repeatRule = rule
        task.reminders = [TaskReminder(kind: .at(wed, TaskTime(hour: 8)!))]
        return task
    }

    @Test("Ticking off leaves the next copy, its reminder and checklist moved along")
    func following() throws {
        let task = repeating(RepeatRule(kind: .weekly, weekdays: [2, 4], start: wed))
        let next = try #require(TaskRepeats.following(task, completedAt: moment(2026, 11, 18, 9), in: denver))
        #expect(next.when == day(2026, 11, 23))
        #expect(next.repeatRule?.done == 1)
        #expect(next.checklist.allSatisfy { !$0.isDone })
        #expect(next.reminders.first?.kind == .at(day(2026, 11, 23), TaskTime(hour: 8)!))
        // The same copy on any device.
        #expect(TaskRepeats.following(task, completedAt: moment(2026, 11, 18, 11), in: denver)?.id == next.id)
        #expect(next.id != task.id)
    }

    @Test("Skip next moves the task on and remembers the skip")
    func skipNext() throws {
        let task = repeating(RepeatRule(kind: .weekly, weekdays: [2, 4], start: wed))
        let skipped = try #require(TaskRepeats.skippingNext(task, in: denver))
        #expect(skipped.id == task.id)
        #expect(skipped.when == day(2026, 11, 23))
        #expect(skipped.repeatRule?.skipped.contains(wed) == true)
    }

    @MainActor
    @Test("The model makes the next copy, and Undo takes it back")
    func modelRepeats() async throws {
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let model = TasksModel(vault: vault, calendar: denver, now: { moment(2026, 11, 18, 9) })
        try await vault.save(repeating(RepeatRule(kind: .weekly, weekdays: [2, 4], start: wed)))
        await model.load()
        let id = try #require(model.tasks.first?.id)
        await model.toggle(id)
        #expect(model.tasks.count == 2)
        #expect(model.tasks.first { $0.id == id }?.repeatRule == nil)
        #expect(model.tasks.contains { $0.when == day(2026, 11, 23) && !$0.isCompleted && $0.repeatRule != nil })
        await model.undoCompletion()
        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.repeatRule?.done == 0)
        await model.setRepeat(id, nil)
        #expect(model.tasks.first?.repeatRule == nil)
    }
}
