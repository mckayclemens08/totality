import Foundation
import TotalityCore

/// Tasks' entry in the registry. It meets other modules only here, through refs, search and refresh.
public struct TasksModule: ContentHandler {
    public let module = ModuleID.tasks
    public let kinds: Set<ContentKind> = [.task, .taskList]
    private let vault: TaskVault?
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private let refresh: @Sendable () async -> Void
    private let changed: @Sendable () async -> Void

    /// `refresh` brings Tasks up to date, quietly. `changed` tells Tasks' screens that another module
    /// made or planned a task, so they read it in.
    public init(
        vault: TaskVault?, calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        now: @escaping @Sendable () -> Date = { Date() }, refresh: @escaping @Sendable () async -> Void = {},
        changed: @escaping @Sendable () async -> Void = {}
    ) {
        self.vault = vault
        self.calendar = calendar
        self.now = now
        self.refresh = refresh
        self.changed = changed
    }
}

extension TasksModule: ModuleSearcher {
    /// Reads the sealed tasks on this device. Nothing searched for is kept or sent.
    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard let vault, !terms.isEmpty else { return [] }
        let tasks = try await vault.everything().tasks
        try Task.checkCancellation()
        let calendar = calendar()
        return TasksSearch.hits(terms: terms, tasks: tasks, today: TaskDay(now(), in: calendar), calendar: calendar)
    }
}

/// The app keeps Tasks fresh before it's opened, through `AppRefresh`, without showing it.
extension TasksModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

public enum TasksModuleError: Error, Equatable {
    case unavailable, notFound
}

/// Other modules hand Tasks a draft and get the new task's ID back (step 4). The task is sealed like any
/// other, source and quote included.
extension TasksModule: TaskMaker {
    public func makeTask(_ draft: TaskDraft) async throws -> TaskMade {
        guard let vault else { throw TasksModuleError.unavailable }
        let order = (try await vault.everything().tasks.map(\.order).max() ?? 0) + 1
        let task = TaskConnections.task(from: draft, order: order, now: now())
        _ = try await vault.save(task, over: nil)
        await changed()
        return TaskMade(id: task.id, title: task.displayTitle, place: TaskBucket.inbox.name)
    }
}

/// Timed tasks show on the Calendar, lighter than events, and an untimed one can be dropped onto a time.
/// Only Totality's own calendar sees them: nothing goes to Google or the device (decision 3).
extension TasksModule: AgendaPlanner {
    public func agenda(from start: Date, to end: Date) async -> [AgendaItem] {
        guard let vault, let listing = try? await vault.everything() else { return [] }
        return TaskConnections.agenda(listing.tasks, lists: listing.lists, from: start, to: end, in: calendar())
    }

    public func unplanned(on day: Date) async -> [AgendaItem] {
        guard let vault, let listing = try? await vault.everything() else { return [] }
        let calendar = calendar()
        return TaskConnections.unplanned(
            listing.tasks, on: TaskDay(day, in: calendar), today: TaskDay(now(), in: calendar), in: calendar
        )
    }

    public func plan(_ id: String, at start: Date, minutes: Int) async throws {
        guard let vault else { throw TasksModuleError.unavailable }
        guard let uuid = UUID(uuidString: id), let old = try? await vault.task(uuid) else { throw TasksModuleError.notFound }
        var new = TaskConnections.planned(old, at: start, minutes: minutes, in: calendar())
        new.noteChanges(from: old, at: now())
        _ = try await vault.save(new, over: old)
        await changed()
    }
}
