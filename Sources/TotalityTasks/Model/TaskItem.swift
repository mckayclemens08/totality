import Foundation

/// One task. All of it is sealed before it leaves the device: the server sees one ciphertext row.
public struct TaskItem: Identifiable, Codable, Sendable, Hashable {
    /// Where a task without a date lives.
    public enum Place: String, Codable, Sendable, CaseIterable {
        /// Captured without a place yet. Quick add drops tasks here by default.
        case inbox
        /// Active, whenever there's time.
        case anytime
        /// Parked, out of sight until it's reviewed.
        case someday
    }

    public enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
        case none, low, medium, high

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

        public var name: String {
            switch self {
            case .none: "None"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    public struct ChecklistItem: Identifiable, Codable, Sendable, Hashable {
        public let id: UUID
        public var title: String
        public var isDone: Bool

        public init(id: UUID = UUID(), title: String, isDone: Bool = false) {
            self.id = id
            self.title = title
            self.isDone = isDone
        }
    }

    /// The parts of a task that two devices can change apart. Each keeps its own edit time, so a merge
    /// takes the newer of each part and nothing either side changed is lost.
    public enum Field: String, Codable, Sendable, CaseIterable {
        case title, notes, place, schedule, deadline, checklist, tags, priority, list, order, completion
    }

    public let id: UUID
    public var title: String
    /// Markdown, stored exactly as typed.
    public var notes: String
    public var place: Place
    /// The day the person plans to start, which puts it in Today.
    public var when: TaskDay?
    /// In Today's evening, when it has no time.
    public var isEvening: Bool
    /// An optional time on the When day.
    public var time: TaskTime?
    /// The day it must be done by.
    public var deadline: TaskDay?
    public var checklist: [ChecklistItem]
    /// Nested with a slash, like "school/thesis".
    public var tags: [String]
    public var priority: Priority
    /// A project or area, from step 2.
    public var listID: UUID?
    /// A heading inside its project. It moves with `listID`, as one part, so a task never sits under a
    /// heading of a project it has left.
    public var headingID: UUID?
    /// Where it sits among its neighbours. Smaller comes first.
    public var order: Double
    public let createdAt: Date
    public var completedAt: Date?
    public var updatedAt: Date
    /// When each part last changed, by `Field` name. Names this version doesn't know are kept.
    public var edits: [String: Date]

    public init(
        id: UUID = UUID(), title: String, notes: String = "", place: Place = .inbox, when: TaskDay? = nil,
        isEvening: Bool = false, time: TaskTime? = nil, deadline: TaskDay? = nil, checklist: [ChecklistItem] = [],
        tags: [String] = [], priority: Priority = .none, listID: UUID? = nil, headingID: UUID? = nil, order: Double = 0,
        createdAt: Date, completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.place = place
        self.when = when
        self.isEvening = isEvening
        self.time = time
        self.deadline = deadline
        self.checklist = checklist
        self.tags = tags
        self.priority = priority
        self.listID = listID
        self.headingID = headingID
        self.order = order
        self.createdAt = createdAt
        self.completedAt = completedAt
        updatedAt = createdAt
        edits = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, place, when, isEvening, time, deadline, checklist, tags, priority, listID, headingID, order
        case createdAt, completedAt, updatedAt, edits
    }

    /// Missing parts take their defaults, so a task saved by an older version still opens.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        place = (try? c.decodeIfPresent(Place.self, forKey: .place)) ?? .inbox
        when = try c.decodeIfPresent(TaskDay.self, forKey: .when)
        isEvening = try c.decodeIfPresent(Bool.self, forKey: .isEvening) ?? false
        time = try c.decodeIfPresent(TaskTime.self, forKey: .time)
        deadline = try c.decodeIfPresent(TaskDay.self, forKey: .deadline)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        priority = (try? c.decodeIfPresent(Priority.self, forKey: .priority)) ?? .none
        listID = try c.decodeIfPresent(UUID.self, forKey: .listID)
        headingID = try c.decodeIfPresent(UUID.self, forKey: .headingID)
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        edits = try c.decodeIfPresent([String: Date].self, forKey: .edits) ?? [:]
    }

    public var isCompleted: Bool { completedAt != nil }

    /// What a list shows for a task with no title yet.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New task" : trimmed
    }

    /// Notes with any Markdown, for search and the quiet line.
    public var hasNotes: Bool { !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var checklistDone: Int { checklist.filter(\.isDone).count }

    /// Marks every part that differs from `old` as changed at `date`.
    public mutating func noteChanges(from old: TaskItem, at date: Date) {
        var changed = false
        for field in Field.allCases where !sameValue(field, as: old) {
            edits[field.rawValue] = date
            changed = true
        }
        if changed { updatedAt = max(date, old.updatedAt) }
    }

    /// The parts the person changed from `base` to `edited`, put onto this task. A screen that fell
    /// behind a sync sends only what it changed, so it can't undo what the sync brought in.
    public func applying(_ edited: TaskItem, since base: TaskItem, at date: Date) -> TaskItem {
        var result = self
        for field in Field.allCases where !edited.sameValue(field, as: base) {
            result.take(field, from: edited)
        }
        result.noteChanges(from: self, at: date)
        return result
    }

    private func sameValue(_ field: Field, as other: TaskItem) -> Bool {
        switch field {
        case .title: title == other.title
        case .notes: notes == other.notes
        case .place: place == other.place
        case .schedule: when == other.when && isEvening == other.isEvening && time == other.time
        case .deadline: deadline == other.deadline
        case .checklist: checklist == other.checklist
        case .tags: tags == other.tags
        case .priority: priority == other.priority
        case .list: listID == other.listID && headingID == other.headingID
        case .order: order == other.order
        case .completion: completedAt == other.completedAt
        }
    }

    private mutating func take(_ field: Field, from other: TaskItem) {
        switch field {
        case .title: title = other.title
        case .notes: notes = other.notes
        case .place: place = other.place
        case .schedule:
            when = other.when
            isEvening = other.isEvening
            time = other.time
        case .deadline: deadline = other.deadline
        case .checklist: checklist = other.checklist
        case .tags: tags = other.tags
        case .priority: priority = other.priority
        case .list:
            listID = other.listID
            headingID = other.headingID
        case .order: order = other.order
        case .completion: completedAt = other.completedAt
        }
    }

    private func editTime(_ field: Field) -> Date {
        edits[field.rawValue] ?? createdAt
    }

    /// Two versions of the same task, merged part by part: the newer edit of each part wins. When both
    /// changed whether it's done at the same moment, done wins. The result is the same whichever side
    /// is `self`, so two devices settle on the same task.
    public func merged(with other: TaskItem) -> TaskItem {
        precondition(id == other.id)
        var result = self
        for field in Field.allCases {
            let mine = editTime(field)
            let theirs = other.editTime(field)
            if let latest = [edits[field.rawValue], other.edits[field.rawValue]].compactMap({ $0 }).max() {
                result.edits[field.rawValue] = latest
            }
            guard !sameValue(field, as: other) else { continue }
            let takeTheirs: Bool
            if mine != theirs {
                takeTheirs = theirs > mine
            } else if field == .completion {
                takeTheirs = other.isCompleted && (!isCompleted || other.completedAt! > completedAt!)
            } else {
                // A tie on the clock: settle it the same way on both devices, by the bytes of the value.
                takeTheirs = Self.tieBreak(field, self, other)
            }
            if takeTheirs { result.take(field, from: other) }
        }
        for (name, date) in other.edits where Field(rawValue: name) == nil {
            result.edits[name] = max(date, edits[name] ?? .distantPast)
        }
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }

    private static func tieBreak(_ field: Field, _ a: TaskItem, _ b: TaskItem) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let left = (try? encoder.encode(Projection(task: a, field: field))) ?? Data()
        let right = (try? encoder.encode(Projection(task: b, field: field))) ?? Data()
        return right.lexicographicallyPrecedes(left)
    }

    /// Just one part of a task, for comparing.
    private struct Projection: Encodable {
        let task: TaskItem
        let field: Field

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch field {
            case .title: try c.encode(task.title)
            case .notes: try c.encode(task.notes)
            case .place: try c.encode(task.place)
            case .schedule: try c.encode([String(describing: task.when), String(task.isEvening), String(describing: task.time)])
            case .deadline: try c.encode(String(describing: task.deadline))
            case .checklist: try c.encode(task.checklist.map { "\($0.id)|\($0.title)|\($0.isDone)" })
            case .tags: try c.encode(task.tags)
            case .priority: try c.encode(task.priority.rawValue)
            case .list: try c.encode((task.listID?.uuidString ?? "") + "|" + (task.headingID?.uuidString ?? ""))
            case .order: try c.encode(task.order)
            case .completion: try c.encode(task.completedAt?.timeIntervalSince1970 ?? 0)
            }
        }
    }
}
