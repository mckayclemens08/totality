import Foundation

/// A project's tasks under one heading. Done tasks stay in place, ticked (owner, 2026-11-18).
public struct ProjectSection: Identifiable, Equatable, Sendable {
    /// Nil for the tasks above the first heading.
    public let heading: TaskList.Heading?
    public let tasks: [TaskItem]

    public var id: UUID? { heading?.id }
    public var done: Int { tasks.filter(\.isCompleted).count }
}

/// How far through a project is.
public struct ListProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// What areas, projects and smart lists hold. Pure, so it's tested without screens.
public enum ListRules {
    public static func ordered(_ lists: [TaskList]) -> [TaskList] {
        lists.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
    }

    public static func areas(in lists: [TaskList]) -> [TaskList] {
        ordered(lists.filter { $0.kind == .area })
    }

    public static func smartLists(in lists: [TaskList]) -> [TaskList] {
        ordered(lists.filter { $0.kind == .smart })
    }

    /// Projects in an area, or with none when `area` is nil.
    public static func projects(in area: UUID?, from lists: [TaskList], status: TaskList.Status? = .active) -> [TaskList] {
        ordered(lists.filter { $0.kind == .project && $0.areaID == area && (status == nil || $0.status == status) })
    }

    /// A project's tasks under their headings: first those with no heading, then each heading in order,
    /// empty headings included so a new one shows. A task whose heading is gone sits with no heading.
    public static func sections(of project: TaskList, from tasks: [TaskItem]) -> [ProjectSection] {
        let mine = tasks.filter { $0.listID == project.id }.sorted(by: inOrder)
        let known = Set(project.headings.map(\.id))
        let loose = mine.filter { $0.headingID.map { !known.contains($0) } ?? true }
        var sections: [ProjectSection] = loose.isEmpty ? [] : [ProjectSection(heading: nil, tasks: loose)]
        for heading in project.headings {
            sections.append(ProjectSection(heading: heading, tasks: mine.filter { $0.headingID == heading.id }))
        }
        return sections
    }

    public static func progress(of project: TaskList, from tasks: [TaskItem]) -> ListProgress {
        let mine = tasks.filter { $0.listID == project.id }
        return ListProgress(done: mine.filter(\.isCompleted).count, total: mine.count)
    }

    /// The first open task in a project, in its order: the "Next:" line on an area's card.
    public static func nextTask(in project: TaskList, from tasks: [TaskItem]) -> TaskItem? {
        sections(of: project, from: tasks).lazy.flatMap(\.tasks).first { !$0.isCompleted }
    }

    /// An area's own open tasks, not those in its projects.
    public static func looseTasks(in area: TaskList, from tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { $0.listID == area.id && !$0.isCompleted }.sorted(by: inOrder)
    }

    /// The area a task belongs to, directly or through its project.
    public static func area(of task: TaskItem, in lists: [TaskList]) -> UUID? {
        guard let listID = task.listID, let list = lists.first(where: { $0.id == listID }) else { return nil }
        switch list.kind {
        case .area: return list.id
        case .project: return list.areaID
        case .smart: return nil
        }
    }

    // MARK: - Smart lists

    /// The open tasks a smart list finds. With no rules it finds nothing, so a new list doesn't fill with
    /// everything at once.
    public static func tasks(
        matching rules: SmartRules, from tasks: [TaskItem], lists: [TaskList], today: TaskDay, in calendar: Calendar
    ) -> [TaskItem] {
        guard !rules.rules.isEmpty else { return [] }
        return tasks.filter { !$0.isCompleted && matches($0, rules, lists: lists, today: today, in: calendar) }
            .sorted { a, b in
                switch (a.deadline, b.deadline) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return inOrder(a, b)
                }
            }
    }

    public static func matches(
        _ task: TaskItem, _ rules: SmartRules, lists: [TaskList], today: TaskDay, in calendar: Calendar
    ) -> Bool {
        guard !rules.rules.isEmpty else { return false }
        let check = { (rule: SmartRule) in matches(task, rule, lists: lists, today: today, in: calendar) }
        switch rules.match {
        case .all: return rules.rules.allSatisfy(check)
        case .any: return rules.rules.contains(where: check)
        }
    }

    public static func matches(
        _ task: TaskItem, _ rule: SmartRule, lists: [TaskList], today: TaskDay, in calendar: Calendar
    ) -> Bool {
        let found: Bool
        switch rule.kind {
        case .unknown:
            return false
        case .tag:
            guard let wanted = rule.tag.map(normalTag), !wanted.isEmpty else { return false }
            // A tag finds its nested tags too: "school" finds "school/thesis".
            found = task.tags.map(normalTag).contains { $0 == wanted || $0.hasPrefix(wanted + "/") }
        case .area:
            guard let id = rule.listID else { return false }
            found = area(of: task, in: lists) == id
        case .project:
            guard let id = rule.listID else { return false }
            found = task.listID == id
        case .priority:
            guard let priority = rule.priority else { return false }
            found = task.priority == priority
        case .when:
            found = within(task.when, rule.days, today: today, in: calendar)
        case .deadline:
            found = within(task.deadline, rule.days, today: today, in: calendar)
        case .hasNote:
            found = task.hasNotes
        }
        return rule.isNegated ? !found : found
    }

    private static func within(_ day: TaskDay?, _ days: Int?, today: TaskDay, in calendar: Calendar) -> Bool {
        guard let day else { return false }
        guard let days else { return true }
        return today.days(to: day, in: calendar) <= days
    }

    private static func normalTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
    }

    private static func inOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        a.order == b.order ? a.createdAt < b.createdAt : a.order < b.order
    }
}
