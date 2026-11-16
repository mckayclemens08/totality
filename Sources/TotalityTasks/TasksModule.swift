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

    /// `refresh` brings Tasks up to date, quietly.
    public init(
        vault: TaskVault?, calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        now: @escaping @Sendable () -> Date = { Date() }, refresh: @escaping @Sendable () async -> Void = {}
    ) {
        self.vault = vault
        self.calendar = calendar
        self.now = now
        self.refresh = refresh
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
