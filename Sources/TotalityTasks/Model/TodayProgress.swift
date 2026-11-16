import Foundation

/// How far through today the person is: today's tasks done against planned, in all and for each list
/// they come from. Planned is everything in Today now, which includes anything due or overdue, plus
/// what was finished today that would otherwise still be there.
public struct TodayProgress: Equatable, Sendable {
    /// The share of today's tasks from one list, or from no list.
    public struct Part: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let done: Int
        public let planned: Int
    }

    /// Largest first, so the ring's biggest segment starts at the top.
    public let parts: [Part]

    public var done: Int { parts.reduce(0) { $0 + $1.done } }
    public var planned: Int { parts.reduce(0) { $0 + $1.planned } }
    public var isEmpty: Bool { planned == 0 }
    public var fraction: Double { planned == 0 ? 0 : Double(done) / Double(planned) }

    /// "3 of 7"
    public var count: String { "\(done) of \(planned)" }

    /// What VoiceOver reads: "Today: 3 of 7 done; School 2 of 3, No list 1 of 4".
    public var spoken: String {
        guard !isEmpty else { return "Nothing planned today" }
        let whole = "Today: \(count) done"
        guard parts.count > 1 else { return whole }
        return whole + "; " + parts.map { "\($0.name) \($0.done) of \($0.planned)" }.joined(separator: ", ")
    }

    /// The name used for today's tasks that sit in no list.
    static func placeName(_ place: TaskItem.Place) -> String {
        place == .inbox ? "Inbox" : "No list"
    }
}

extension TaskRules {
    public static func todayProgress(from all: [TaskItem], lists: [TaskList], today: TaskDay, in calendar: Calendar) -> TodayProgress {
        let names = Dictionary(lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: (name: String, done: Int, planned: Int)] = [:]
        for task in all {
            if let finished = task.completedAt, TaskDay(finished, in: calendar) != today { continue }
            var open = task
            open.completedAt = nil
            guard bucket(of: open, today: today) == .today else { continue }
            let key: String
            let name: String
            if let id = task.listID, let listName = names[id] {
                key = id.uuidString
                name = listName
            } else {
                name = TodayProgress.placeName(task.place)
                key = name
            }
            var entry = counts[key] ?? (name, 0, 0)
            entry.planned += 1
            if task.isCompleted { entry.done += 1 }
            counts[key] = entry
        }
        let parts = counts.map { TodayProgress.Part(id: $0.key, name: $0.value.name, done: $0.value.done, planned: $0.value.planned) }
            .sorted { ($1.planned, $0.name) < ($0.planned, $1.name) }
        return TodayProgress(parts: parts)
    }
}
