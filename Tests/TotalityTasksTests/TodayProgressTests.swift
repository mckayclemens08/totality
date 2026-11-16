import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

@Suite struct TodayProgressTests {
    private let today = day(2026, 11, 15)
    private let school = TaskList(name: "School", kind: .area, createdAt: agreed)
    private let debate = TaskList(name: "Debate", kind: .area, createdAt: agreed)

    private func task(
        _ title: String, list: TaskList? = nil, place: TaskItem.Place = .anytime, when: TaskDay? = nil,
        deadline: TaskDay? = nil, finished: Date? = nil
    ) -> TaskItem {
        TaskItem(title: title, place: place, when: when, deadline: deadline, listID: list?.id, createdAt: agreed, completedAt: finished)
    }

    @Test("Today's ring counts what's planned, due or overdue, and what was finished today, split by list")
    func counts() {
        let all = [
            task("Read Hayes ch. 4", list: school, when: today, finished: moment(2026, 11, 15, 8)),
            task("Reading response on Hayes ch. 3", list: school, deadline: day(2026, 11, 13)),
            task("Email Dr. Lee about chapter 2", list: school, when: day(2026, 11, 14)),
            task("Cut the rebuttal to two minutes", list: debate, when: today, finished: moment(2026, 11, 15, 9)),
            task("Pick up blazer from the cleaners", when: today),
            task("Capture: committee names idea", place: .inbox, when: today),
            // Not today's: finished yesterday, planned ahead, someday, and a deadline still ahead.
            task("Outline thesis chapter 1", list: school, when: day(2026, 11, 14), finished: moment(2026, 11, 14, 18)),
            task("MUN conference packing", when: day(2026, 11, 19)),
            task("Learn the Shavian alphabet", place: .someday),
            task("Thesis draft", list: school, deadline: day(2026, 11, 20)),
        ]
        let progress = TaskRules.todayProgress(from: all, lists: [school, debate], today: today, in: denver)
        #expect(progress.count == "2 of 6")
        #expect(progress.parts.map(\.name) == ["School", "Debate", "Inbox", "No list"])
        #expect(progress.parts.map(\.done) == [1, 1, 0, 0])
        #expect(progress.parts.map(\.planned) == [3, 1, 1, 1])
        #expect(progress.spoken == "Today: 2 of 6 done; School 1 of 3, Debate 1 of 1, Inbox 0 of 1, No list 0 of 1")
    }

    @Test("A day with nothing planned has no ring, and one list reads without a breakdown")
    func emptyAndSingle() {
        let none = TaskRules.todayProgress(from: [task("Sort the Zotero library")], lists: [], today: today, in: denver)
        #expect(none.isEmpty)
        #expect(none.spoken == "Nothing planned today")
        let one = TaskRules.todayProgress(from: [task("Gym", when: today)], lists: [], today: today, in: denver)
        #expect(one.spoken == "Today: 0 of 1 done")
    }

    @Test("Finished today means today on the person's own clock")
    func zone() {
        // 11:30pm on the 14th in Denver is already the 15th in UTC.
        let late = task("Read Hayes ch. 4", when: day(2026, 11, 14), finished: moment(2026, 11, 14, 23, 30))
        #expect(TaskRules.todayProgress(from: [late], lists: [], today: today, in: denver).isEmpty)
        #expect(TaskRules.todayProgress(from: [late], lists: [], today: today, in: calendar("UTC")).done == 1)
    }
}
