import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

@Suite struct TaskRulesTests {
    private let today = day(2026, 11, 15)

    private func task(_ title: String, place: TaskItem.Place = .anytime, when: TaskDay? = nil, deadline: TaskDay? = nil, done: Bool = false) -> TaskItem {
        TaskItem(title: title, place: place, when: when, deadline: deadline, createdAt: agreed, completedAt: done ? agreed : nil)
    }

    @Test("Each task belongs to one list, from its dates and place")
    func buckets() {
        #expect(TaskRules.bucket(of: task("Capture idea", place: .inbox), today: today) == .inbox)
        #expect(TaskRules.bucket(of: task("Outline chapter 3", when: today), today: today) == .today)
        #expect(TaskRules.bucket(of: task("Overdue reading", when: day(2026, 11, 10)), today: today) == .today)
        #expect(TaskRules.bucket(of: task("Position paper", deadline: today), today: today) == .today)
        #expect(TaskRules.bucket(of: task("MUN conference", when: day(2026, 11, 20)), today: today) == .upcoming)
        #expect(TaskRules.bucket(of: task("Tidy references"), today: today) == .anytime)
        #expect(TaskRules.bucket(of: task("Learn Toki Pona", place: .someday), today: today) == .someday)
        #expect(TaskRules.bucket(of: task("Done thing", when: today, done: true), today: today) == .logbook)
        // A deadline ahead with no plan stays where it lives, and Upcoming shows it on its day.
        #expect(TaskRules.bucket(of: task("Thesis draft", deadline: day(2026, 11, 18)), today: today) == .anytime)
    }

    @Test("Whether a task is Today depends on the day on the person's own clock")
    func zones() {
        let planned = task("Call Gran", when: day(2026, 11, 16))
        let instant = ISO8601DateFormatter().date(from: "2026-11-16T05:30:00Z")!
        #expect(TaskRules.bucket(of: planned, today: TaskDay(instant, in: denver)) == .upcoming)
        #expect(TaskRules.bucket(of: planned, today: TaskDay(instant, in: calendar("Asia/Tokyo"))) == .today)
    }

    @Test("Today lists untimed tasks first, then by time, and splits into parts of the day")
    func todayOrder() {
        var morning = task("Gym", when: today); morning.time = TaskTime(hour: 7)
        var afternoon = task("MUN committee", when: today); afternoon.time = TaskTime(hour: 14)
        var evening = task("Read", when: today); evening.isEvening = true
        let untimed = task("Outline chapter 3", when: today)
        let order = TaskRules.tasks(in: .today, from: [afternoon, evening, morning, untimed], today: today).map(\.title)
        #expect(order == ["Read", "Outline chapter 3", "Gym", "MUN committee"] || order == ["Outline chapter 3", "Read", "Gym", "MUN committee"])
        #expect(TaskRules.part(of: morning) == .morning)
        #expect(TaskRules.part(of: afternoon) == .afternoon)
        #expect(TaskRules.part(of: evening) == .evening)
        #expect(TaskRules.part(of: untimed) == .anyTime)
    }

    @Test("Upcoming lists each day with its events, its planned tasks and its deadlines")
    func upcoming() {
        let lecture = AgendaItem(
            id: "lecture", title: "Phonology lecture", start: moment(2026, 11, 16, 9), end: moment(2026, 11, 16, 10, 30), isAllDay: false
        )
        let conference = AgendaItem(
            id: "mun", title: "MUN conference", start: day(2026, 11, 20).start(in: denver), end: day(2026, 11, 22).start(in: denver), isAllDay: true
        )
        let planned = task("Pack for MUN", when: day(2026, 11, 19))
        let due = task("Thesis draft", deadline: day(2026, 11, 18))
        let days = TaskRules.upcoming(from: [planned, due], events: [lecture, conference], today: today, in: denver)
        #expect(days.first?.day == day(2026, 11, 16))
        #expect(days.first?.events.map(\.title) == ["Phonology lecture"])
        #expect(days.first { $0.day == day(2026, 11, 18) }?.deadlines.map(\.title) == ["Thesis draft"])
        #expect(days.first { $0.day == day(2026, 11, 19) }?.tasks.map(\.title) == ["Pack for MUN"])
        // An all-day event shows on each of its days and not the day after.
        #expect(days.filter { $0.events.contains(conference) }.map(\.day) == [day(2026, 11, 20), day(2026, 11, 21)])
        // The first week always shows; later only days with something.
        #expect(days.count == TaskRules.alwaysShownDays)
    }

    @Test("Upcoming's days run one after another across a clock change, with none skipped or doubled")
    func upcomingAcrossDaylightSaving() {
        let days = TaskRules.upcoming(from: [], events: [], today: day(2027, 3, 11), in: denver).map(\.day)
        #expect(days == (12...18).map { day(2027, 3, $0) })
        let autumn = TaskRules.upcoming(from: [], events: [], today: day(2026, 10, 29), in: denver).map(\.day)
        #expect(autumn == [day(2026, 10, 30), day(2026, 10, 31)] + (1...5).map { day(2026, 11, $0) })
        #expect(day(2027, 3, 13).days(to: day(2027, 3, 15), in: denver) == 2)
        // An event on the short day still lands on it.
        let shuttle = AgendaItem(id: "s", title: "Airport shuttle", start: moment(2027, 3, 14, 4), end: moment(2027, 3, 14, 5), isAllDay: false)
        let spring = TaskRules.upcoming(from: [], events: [shuttle], today: day(2027, 3, 13), in: denver)
        #expect(spring.first?.events == [shuttle])
    }

    @Test("Later holds what's planned past Upcoming's days")
    func later() {
        let far = task("Apply for summer school", when: day(2027, 2, 1))
        #expect(TaskRules.later(from: [far], today: today, in: denver).map(\.title) == ["Apply for summer school"])
    }

    @Test("The Logbook groups by the day each task was finished, newest first")
    func logbook() {
        var a = task("Outline chapter 2"); a.completedAt = moment(2026, 11, 14, 21)
        var b = task("Book MUN hotel"); b.completedAt = moment(2026, 11, 15, 8)
        var c = task("Conlang notes"); c.completedAt = moment(2026, 11, 15, 9)
        let days = TaskRules.logbook(from: [a, b, c, task("Not done")], in: denver)
        #expect(days.map(\.day) == [day(2026, 11, 15), day(2026, 11, 14)])
        #expect(days[0].tasks.map(\.title) == ["Conlang notes", "Book MUN hotel"])
    }

    @Test("A deadline turns red when it's close or passed, and the line says how it stands")
    func deadlines() {
        #expect(TaskRules.deadlineIsNear(task("x", deadline: day(2026, 11, 17)), today: today, in: denver))
        #expect(!TaskRules.deadlineIsNear(task("x", deadline: day(2026, 11, 25)), today: today, in: denver))
        #expect(TaskRules.isOverdue(task("x", deadline: day(2026, 11, 12)), today: today))
        #expect(TaskText.deadline(day(2026, 11, 12), today: today, in: denver) == "Overdue by 3 days")
        #expect(TaskText.deadline(day(2026, 11, 15), today: today, in: denver) == "Due today")
        #expect(TaskText.deadline(day(2026, 11, 18), today: today, in: denver) == "Due Wednesday")
        var checklist = task("Pack", when: today)
        checklist.checklist = [.init(title: "Gown", isDone: true), .init(title: "Placard"), .init(title: "Charger")]
        checklist.tags = ["mun"]
        #expect(TaskText.quietLine(for: checklist, in: .today, today: today, calendar: denver) == "1 of 3 · #mun")
    }
}
