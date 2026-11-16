import Foundation
import TotalityCore

/// The lists every person has.
public enum TaskBucket: String, CaseIterable, Sendable, Identifiable, Hashable {
    case inbox, today, upcoming, anytime, someday, logbook

    public var id: Self { self }

    public var name: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .logbook: "Logbook"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .today: "star"
        case .upcoming: "calendar"
        case .anytime: "square.stack"
        case .someday: "archivebox"
        case .logbook: "checkmark.circle"
        }
    }

    /// What a list says when there's nothing in it.
    public var emptyTitle: String {
        switch self {
        case .inbox: "Your Inbox is clear"
        case .today: "Nothing planned"
        case .upcoming: "Nothing coming up"
        case .anytime: "Nothing waiting"
        case .someday: "No parked ideas"
        case .logbook: "Nothing done yet"
        }
    }

    public var emptyDetail: String {
        switch self {
        case .inbox: "Anything you capture without a place lands here. Tap + to add one."
        case .today: "Take it easy, or pull something from Anytime."
        case .upcoming: "Tasks with a date and your calendar's events show here, day by day."
        case .anytime: "Tasks with no date that you mean to get to show here."
        case .someday: "Park an idea here and it stays out of sight until you look for it."
        case .logbook: "Everything you finish shows here by day, and anything can come back."
        }
    }
}

/// Today's optional parts.
public enum TodayPart: String, CaseIterable, Sendable, Identifiable {
    case anyTime, morning, afternoon, evening

    public var id: Self { self }

    public var name: String? {
        switch self {
        case .anyTime: nil
        case .morning: "This morning"
        case .afternoon: "This afternoon"
        case .evening: "This evening"
        }
    }
}

/// One day of Upcoming: its events, faintly, then its tasks.
public struct UpcomingDay: Identifiable, Sendable, Equatable {
    public let day: TaskDay
    public let events: [AgendaItem]
    public let tasks: [TaskItem]
    /// Tasks whose deadline is this day and that aren't planned on it.
    public let deadlines: [TaskItem]

    public var id: TaskDay { day }
    public var isEmpty: Bool { events.isEmpty && tasks.isEmpty && deadlines.isEmpty }
}

/// One day of the Logbook.
public struct LogbookDay: Identifiable, Sendable, Equatable {
    public let day: TaskDay
    public let tasks: [TaskItem]

    public var id: TaskDay { day }
}

/// Where each task shows, worked out on the device from its dates and the day it is now.
public enum TaskRules {
    /// How many days Upcoming lists one by one before "Later".
    public static let upcomingDays = 28
    /// Upcoming always shows this many days, even empty ones, so the week ahead reads at a glance.
    public static let alwaysShownDays = 7
    /// A deadline this close turns red.
    public static let deadlineNear = 2

    /// The one list a task belongs to. Upcoming also shows tasks whose deadline is ahead.
    public static func bucket(of task: TaskItem, today: TaskDay) -> TaskBucket {
        if task.isCompleted { return .logbook }
        if let when = task.when { return when <= today ? .today : .upcoming }
        if let deadline = task.deadline, deadline <= today { return .today }
        switch task.place {
        case .inbox: return .inbox
        case .anytime: return .anytime
        case .someday: return .someday
        }
    }

    public static func tasks(in bucket: TaskBucket, from all: [TaskItem], today: TaskDay) -> [TaskItem] {
        let chosen = all.filter { self.bucket(of: $0, today: today) == bucket }
        switch bucket {
        case .today:
            return chosen.sorted { a, b in
                switch (a.time, b.time) {
                case (nil, nil): return ordered(a, b)
                case (nil, _): return true
                case (_, nil): return false
                case let (x?, y?): return x == y ? ordered(a, b) : x < y
                }
            }
        case .upcoming:
            return chosen.sorted { ($0.when ?? today, $0.time?.minutes ?? -1, $0.order) < ($1.when ?? today, $1.time?.minutes ?? -1, $1.order) }
        case .logbook:
            return chosen.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        default:
            return chosen.sorted(by: ordered)
        }
    }

    private static func ordered(_ a: TaskItem, _ b: TaskItem) -> Bool {
        a.order == b.order ? a.createdAt < b.createdAt : a.order < b.order
    }

    /// Which part of Today a task falls in, when Today is split.
    public static func part(of task: TaskItem) -> TodayPart {
        if task.isEvening { return .evening }
        guard let time = task.time else { return .anyTime }
        if time < .noon { return .morning }
        return time < .evening ? .afternoon : .evening
    }

    public static func isOverdue(_ task: TaskItem, today: TaskDay) -> Bool {
        guard !task.isCompleted, let deadline = task.deadline else { return false }
        return deadline < today
    }

    /// Whether the deadline should show in red: it's passed, or it's close.
    public static func deadlineIsNear(_ task: TaskItem, today: TaskDay, in calendar: Calendar) -> Bool {
        guard !task.isCompleted, let deadline = task.deadline else { return false }
        return today.days(to: deadline, in: calendar) <= deadlineNear
    }

    /// The next `upcomingDays` days after today, each with its events and tasks.
    public static func upcoming(from all: [TaskItem], events: [AgendaItem], today: TaskDay, in calendar: Calendar) -> [UpcomingDay] {
        let active = all.filter { !$0.isCompleted }
        return (1...upcomingDays).compactMap { offset in
            let day = today.adding(days: offset, in: calendar)
            let lower = day.start(in: calendar)
            let upper = day.adding(days: 1, in: calendar).start(in: calendar)
            let planned = active.filter { $0.when == day }
                .sorted { ($0.time?.minutes ?? -1, $0.order) < ($1.time?.minutes ?? -1, $1.order) }
            let due = active.filter { $0.deadline == day && ($0.when == nil || $0.when! > day) }
            let onDay = events.filter { $0.touches(from: lower, to: upper) }
                .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
            let entry = UpcomingDay(day: day, events: onDay, tasks: planned, deadlines: due)
            return offset <= alwaysShownDays || !entry.isEmpty ? entry : nil
        }
    }

    /// Tasks planned past the days Upcoming lists one by one.
    public static func later(from all: [TaskItem], today: TaskDay, in calendar: Calendar) -> [TaskItem] {
        let last = today.adding(days: upcomingDays, in: calendar)
        return all.filter { !$0.isCompleted && ($0.when.map { $0 > last } ?? false) }
            .sorted { ($0.when!, $0.order) < ($1.when!, $1.order) }
    }

    /// Completed tasks by the day they were finished, newest first.
    public static func logbook(from all: [TaskItem], in calendar: Calendar) -> [LogbookDay] {
        let done = all.compactMap { task in task.completedAt.map { (task, $0) } }
        let byDay = Dictionary(grouping: done) { TaskDay($0.1, in: calendar) }
        return byDay.keys.sorted(by: >).map { day in
            LogbookDay(day: day, tasks: byDay[day]!.sorted { $0.1 > $1.1 }.map(\.0))
        }
    }
}
