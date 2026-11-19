import Foundation

/// One thing on someone's calendar, as another module sees it: a title and its times, nothing more. It
/// comes from private content, so it stays in memory on this device and is never stored or sent.
public struct AgendaItem: Identifiable, Sendable, Hashable {
    /// Means something only to the module that gave it.
    public let id: String
    public let title: String
    public let start: Date
    /// For an all-day item, the start of the day after its last day.
    public let end: Date
    public let isAllDay: Bool
    /// The module it comes from, when it isn't an event, like a task given a time. The Calendar draws
    /// these lighter than its events and hands them back to their module to open.
    public let module: ModuleID?
    /// The quiet line, like the task's project.
    public let detail: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, module: ModuleID? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.module = module
        self.detail = detail
    }

    /// Whether any of it falls between these two moments.
    public func touches(from lower: Date, to upper: Date) -> Bool {
        start < upper && (end > lower || (end <= start && start >= lower))
    }
}

/// A module that can say what's on the person's calendar, so another can show it beside its own content,
/// like Tasks showing each day's events faintly above that day's tasks.
public protocol AgendaProvider: ContentHandler {
    /// Everything that touches the time from `start` up to `end`, in no particular order.
    func agenda(from start: Date, to end: Date) async -> [AgendaItem]
}
