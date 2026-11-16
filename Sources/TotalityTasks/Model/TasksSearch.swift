import Foundation
import TotalityCore

/// Finds tasks by title, notes, checklist and tags, done ones included. Active tasks come first.
enum TasksSearch {
    static func hits(terms: [String], tasks: [TaskItem], today: TaskDay, calendar: Calendar) -> [SearchHit] {
        guard !terms.isEmpty else { return [] }
        let found = tasks.filter { task in
            let fields = self.fields(of: task)
            return terms.allSatisfy { term in ([task.title] + fields).contains { SearchText.find(term, in: $0) != nil } }
        }
        let active = found.filter { !$0.isCompleted }.sorted { ($0.when ?? $0.deadline ?? today, $0.createdAt) < ($1.when ?? $1.deadline ?? today, $1.createdAt) }
        let done = found.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return (active + done).map { task in
            let bucket = TaskRules.bucket(of: task, today: today)
            let line = TaskText.quietLine(for: task, in: bucket, today: today, calendar: calendar)
            return SearchHit(
                module: .tasks, itemID: task.id.uuidString, title: task.displayTitle,
                detail: [bucket.name, line].compactMap { $0 }.joined(separator: " · "),
                snippet: snippet(terms: terms, task: task),
                date: task.completedAt ?? task.when.map { $0.start(in: calendar) } ?? task.deadline.map { $0.start(in: calendar) }
            )
        }
    }

    private static func fields(of task: TaskItem) -> [String] {
        [task.notes] + task.checklist.map(\.title) + task.tags.map { "#" + $0 }
    }

    /// The first field with a match. A match in the title alone needs no snippet.
    private static func snippet(terms: [String], task: TaskItem) -> String? {
        if terms.allSatisfy({ SearchText.find($0, in: task.title) != nil }) { return nil }
        for field in fields(of: task) {
            if let match = terms.lazy.compactMap({ SearchText.find($0, in: field) }).first {
                return SearchText.excerpt(of: field, around: match)
            }
        }
        return nil
    }
}
