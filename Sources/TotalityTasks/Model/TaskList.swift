import Foundation

/// A list of tasks: an area, a project or a smart list. All of it, names, headings and rules included,
/// is sealed before it leaves the device, like a task.
public struct TaskList: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// An ongoing part of life, like School. It holds projects and loose tasks.
        case area
        /// Something finite that finishes, like a paper, with headings and a deadline.
        case project
        /// Tasks found by rules, rather than put there.
        case smart
    }

    /// Where a project stands. Areas and smart lists stay active.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case active, someday, finished

        public var name: String {
            switch self {
            case .active: "Active"
            case .someday: "Someday"
            case .finished: "Finished"
            }
        }
    }

    /// A section inside a project, like "Research" or "Drafting".
    public struct Heading: Identifiable, Codable, Sendable, Hashable {
        public let id: UUID
        public var title: String

        public init(id: UUID = UUID(), title: String) {
            self.id = id
            self.title = title
        }
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    /// The area a project sits in.
    public var areaID: UUID?
    /// A project's headings, in order.
    public var headings: [Heading]
    /// The day a project must be done by.
    public var deadline: TaskDay?
    public var status: Status
    /// A smart list's rules.
    public var rules: SmartRules?
    /// A smart list shown on the Lists screen.
    public var isPinned: Bool
    /// Where it sits among its neighbours. Smaller comes first.
    public var order: Double
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, kind: Kind, areaID: UUID? = nil, headings: [Heading] = [], deadline: TaskDay? = nil,
        status: Status = .active, rules: SmartRules? = nil, isPinned: Bool = false, order: Double = 0, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.areaID = areaID
        self.headings = headings
        self.deadline = deadline
        self.status = status
        self.rules = rules
        self.isPinned = isPinned
        self.order = order
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, areaID, headings, deadline, status, rules, isPinned, order, createdAt, updatedAt
    }

    /// Missing parts take their defaults, so a list saved by step 1 still opens.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(Kind.self, forKey: .kind)
        areaID = try c.decodeIfPresent(UUID.self, forKey: .areaID)
        headings = try c.decodeIfPresent([Heading].self, forKey: .headings) ?? []
        deadline = try c.decodeIfPresent(TaskDay.self, forKey: .deadline)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .active
        rules = try c.decodeIfPresent(SmartRules.self, forKey: .rules)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// What a screen shows for a list with no name yet.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .area: return "New area"
        case .project: return "New project"
        case .smart: return "New smart list"
        }
    }
}

/// A smart list's rules, with one switch for whether a task must match all of them or any one. There
/// are no nested groups (owner, 2026-11-18).
public struct SmartRules: Codable, Sendable, Hashable {
    public enum Match: String, Codable, Sendable, CaseIterable {
        case all, any
    }

    public var match: Match
    public var rules: [SmartRule]

    public init(match: Match = .all, rules: [SmartRule] = []) {
        self.match = match
        self.rules = rules
    }
}

/// One rule, such as "Area is School" or "Deadline is within 7 days".
public struct SmartRule: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case tag, area, project, priority, when, deadline, hasNote
        /// Made by a newer version. It never matches, and it's kept as it was.
        case unknown

        /// The kinds a person can pick.
        public static let pickable: [Kind] = [.tag, .area, .project, .priority, .when, .deadline, .hasNote]

        public var name: String {
            switch self {
            case .tag: "Tag"
            case .area: "Area"
            case .project: "Project"
            case .priority: "Priority"
            case .when: "When"
            case .deadline: "Deadline"
            case .hasNote: "Has a note"
            case .unknown: "Newer rule"
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    /// "is not" rather than "is".
    public var isNegated: Bool
    /// A tag, without the #.
    public var tag: String?
    /// An area or project.
    public var listID: UUID?
    public var priority: TaskItem.Priority?
    /// For When and Deadline: on or before this many days from today, overdue included.
    public var days: Int?

    public init(
        id: UUID = UUID(), kind: Kind, isNegated: Bool = false, tag: String? = nil, listID: UUID? = nil,
        priority: TaskItem.Priority? = nil, days: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isNegated = isNegated
        self.tag = tag
        self.listID = listID
        self.priority = priority
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, isNegated, tag, listID, priority, days
    }

    /// A rule of a kind this version doesn't know never matches, rather than stopping the list opening.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        isNegated = try c.decodeIfPresent(Bool.self, forKey: .isNegated) ?? false
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        listID = try c.decodeIfPresent(UUID.self, forKey: .listID)
        priority = try? c.decodeIfPresent(TaskItem.Priority.self, forKey: .priority)
        days = try c.decodeIfPresent(Int.self, forKey: .days)
    }
}
