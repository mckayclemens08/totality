import Foundation

/// Where a task came from, so it can open the source again (issue 123, step 4). It lives inside the task's
/// seal, like the rest of the task, so the server never sees what it points at.
///
/// `itemID` means the same as a `SearchHit`'s: something only the source module understands, which the app
/// hands back to that module to open. Mail's is a conversation, Messages' a chat, Photos' and the Reader's
/// an item's UUID, and Web's the page's address.
public struct TaskSource: Codable, Hashable, Sendable {
    public var module: ModuleID
    public var itemID: String
    /// What the source was called when the task was made: a subject, a page, a book.
    public var title: String
    /// The quiet line under it, like the sender or the site.
    public var detail: String?
    /// Words chosen in the Reader, kept with the task.
    public var quote: String?
    /// Set when the task waits for someone to reply in a Mail conversation. It ticks itself off once
    /// a reply comes after `since`.
    public var waiting: Waiting?

    public struct Waiting: Codable, Hashable, Sendable {
        public var since: Date
        /// When the reply came that ticked it off.
        public var repliedAt: Date?

        public init(since: Date, repliedAt: Date? = nil) {
            self.since = since
            self.repliedAt = repliedAt
        }
    }

    public init(module: ModuleID, itemID: String, title: String, detail: String? = nil, quote: String? = nil, waiting: Waiting? = nil) {
        self.module = module
        self.itemID = itemID
        self.title = title
        self.detail = detail
        self.quote = quote
        self.waiting = waiting
    }

    /// The same thing as a search result, so the app opens it the way it opens one.
    public var hit: SearchHit {
        SearchHit(module: module, itemID: itemID, title: title, detail: detail)
    }
}

/// A task another module asks Tasks to make. Nothing is made until the person says so: Add in a sheet, or
/// the menu item itself.
public struct TaskDraft: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var source: TaskSource

    public init(title: String, source: TaskSource) {
        self.title = title
        self.source = source
    }
}

/// The module that makes tasks from other modules' content. Other modules reach it only through
/// `ModuleRegistry.taskMaker`, and get back the new task's ID.
public protocol TaskMaker: ContentHandler {
    /// Makes the task in the Inbox, and says where it went, like "Inbox".
    func makeTask(_ draft: TaskDraft) async throws -> TaskMade
}

public struct TaskMade: Sendable, Hashable {
    public let id: UUID
    public let title: String
    /// Where it landed, for "Added … to Inbox".
    public let place: String

    public init(id: UUID, title: String, place: String) {
        self.id = id
        self.title = title
        self.place = place
    }

    /// What the module that asked shows once it's made.
    public var line: String { "Added “\(title)” to \(place)" }
}

/// A module that can say whether someone replied, so a task waiting for a reply ticks itself off.
public protocol ReplyWatcher: ContentHandler {
    /// For each item asked about, by `itemID`, the first reply from someone else after the date given. Items
    /// with no reply yet are left out.
    func replies(to waiting: [String: Date]) async -> [String: Reply]
}

/// A reply that came in. Who sent it is for the Undo banner only, and is never stored.
public struct Reply: Sendable, Hashable {
    public let at: Date
    public let from: String

    public init(at: Date, from: String) {
        self.at = at
        self.from = from
    }
}

/// A module whose untimed items can be dragged onto a time on the Calendar, like Tasks' Today.
public protocol AgendaPlanner: AgendaProvider {
    /// What's planned for the day with no time yet.
    func unplanned(on day: Date) async -> [AgendaItem]
    /// Gives an item a time and a length. It stays on Totality's calendar only: nothing is written to
    /// Google or the device's calendars.
    func plan(_ id: String, at start: Date, minutes: Int) async throws
}

extension ModuleRegistry {
    /// The module that makes tasks, if one is installed.
    public var taskMaker: (any TaskMaker)? {
        handlers.compactMap { $0 as? any TaskMaker }.first
    }

    /// Modules whose untimed items can be given a time on the Calendar.
    public var planners: [any AgendaPlanner] {
        handlers.compactMap { $0 as? any AgendaPlanner }
    }

    /// Everything on the calendar from `start` up to `end`, leaving out `module`'s own, so a module that's
    /// also a provider doesn't see itself twice.
    public func agenda(from start: Date, to end: Date, except module: ModuleID) async -> [AgendaItem] {
        var items: [AgendaItem] = []
        for provider in agendas where provider.module != module { items += await provider.agenda(from: start, to: end) }
        return items
    }
}
