import Foundation
import TotalityCore

/// One change to a shared list, as it travels inside the list's end-to-end encrypted room (step 6). Who
/// sent it is never read from here: the room says, and the sender's role at that point decides whether
/// it counts.
public struct SharedPost: Codable, Sendable, Equatable {
    public static let version = 1
    /// The longest comment kept, in characters.
    public static let commentLimit = 4000

    public enum Kind: String, Codable, Sendable {
        /// The list itself: name, kind, headings, deadline.
        case list
        /// A task, whole, with its per-part edit times so it merges like a task synced between devices.
        case task
        case removeTask
        case comment
        /// The owner deleted the list for everyone.
        case closeList
    }

    /// Who a task is given to, and when that was decided.
    public struct Assignment: Codable, Sendable, Equatable {
        /// A handle, or nil for unassigned.
        public var username: String?
        public var at: Date

        public init(username: String?, at: Date) {
            self.username = username
            self.at = at
        }
    }

    public var v: Int
    public var kind: Kind
    public var list: TaskList?
    public var task: TaskItem?
    public var assignment: Assignment?
    public var taskID: UUID?
    public var text: String?

    public init(
        kind: Kind, list: TaskList? = nil, task: TaskItem? = nil, assignment: Assignment? = nil, taskID: UUID? = nil,
        text: String? = nil
    ) {
        v = Self.version
        self.kind = kind
        self.list = list
        self.task = task
        self.assignment = assignment
        self.taskID = taskID
        self.text = text
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Nil for anything that isn't a post this version can read.
    public static func decode(_ body: String) -> SharedPost? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let post = try? decoder.decode(SharedPost.self, from: Data(body.utf8)), post.v >= 1 else { return nil }
        return post
    }
}

/// A task in a shared list, with who it's given to.
public struct SharedTask: Sendable, Equatable, Identifiable {
    public var task: TaskItem
    /// As last set. Whether it still stands depends on who is in the list now: see `SharedListState.assignee(of:)`.
    public var assignee: String?
    public var assignedAt: Date
    /// Who gave it, from the room, never from the post.
    public var assignedBy: String?
    /// Who added it.
    public var addedBy: String
    public var removed = false

    public var id: UUID { task.id }
}

public struct SharedComment: Sendable, Equatable, Identifiable {
    /// The room's ID for the post.
    public let id: String
    public let taskID: UUID
    public let author: String
    public let date: Date
    public let text: String
}

/// One line of what happened, such as "Eli ticked off …".
public struct SharedActivity: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case added, ticked, unticked, dated, removed
        case assigned(to: String?)
    }

    public let id: String
    public let taskID: UUID
    public let actor: String
    public let date: Date
    public let kind: Kind
}

/// A shared list as its room's history makes it. Every device builds the same state from the same
/// history, so nothing about it is stored outside the room.
public struct SharedListState: Sendable, Equatable, Identifiable {
    public let room: String
    /// Nil until the list's first post has been read.
    public private(set) var list: TaskList?
    public private(set) var tasks: [UUID: SharedTask] = [:]
    public private(set) var comments: [SharedComment] = []
    public private(set) var activity: [SharedActivity] = []
    public private(set) var members: [SharedRoomMember] = []
    /// The owner deleted it for everyone.
    public private(set) var isClosed = false
    /// Posts this device couldn't open, such as ones from before it joined.
    public private(set) var unreadable = 0
    /// Posts dropped because their sender wasn't allowed to make them.
    public private(set) var refused = 0
    public let isEncrypted: Bool
    /// Everyone's role as the history goes, by handle.
    private var roles: [String: Int] = [:]

    public var id: String { room }

    public init(room: String, isEncrypted: Bool = true) {
        self.room = room
        self.isEncrypted = isEncrypted
    }

    /// The list as its room's history makes it, oldest post first.
    public static func build(room: String, history: SharedRoomHistory) -> SharedListState {
        var state = SharedListState(room: room, isEncrypted: history.isEncrypted)
        for event in history.events { state.apply(event) }
        state.members = history.members
        return state
    }

    public mutating func apply(_ event: SharedRoomEvent) {
        switch event {
        case .roles(let levels):
            roles = levels
        case .unreadable:
            unreadable += 1
        case .post(let id, let sender, let date, let body):
            guard let post = SharedPost.decode(body) else { return }
            if !apply(post, id: id, sender: sender, date: date) { refused += 1 }
        }
    }

    /// The sender's role at this point in the history.
    public func role(of username: String) -> SharedRole? {
        roles[username].map(SharedRole.init(powerLevel:))
    }

    /// Applies one post, if its sender may make it. Returns whether it counted.
    @discardableResult
    public mutating func apply(_ post: SharedPost, id: String, sender: String, date: Date) -> Bool {
        guard let role = role(of: sender), !isClosed else { return false }
        switch post.kind {
        case .list:
            guard role.canEdit, var incoming = post.list else { return false }
            // A shared list stands alone: it sits in nobody's area.
            incoming.areaID = nil
            guard incoming.kind != .smart else { return false }
            if let current = list {
                // The ID is fixed by the first post, so a later one can't swap in another list.
                guard incoming.id == current.id else { return false }
                if incoming.updatedAt > current.updatedAt { list = incoming }
            } else {
                list = incoming
            }
            return true

        case .task:
            guard role.canEdit, var incoming = post.task, let list else { return false }
            incoming.listID = list.id
            if let heading = incoming.headingID, !list.headings.contains(where: { $0.id == heading }) { incoming.headingID = nil }
            // Reminders and snoozes are each person's own, so they never travel in a shared list.
            incoming.reminders = []
            incoming.nagging = nil
            incoming.snoozedUntil = nil
            if var existing = tasks[incoming.id] {
                guard !existing.removed else { return false }
                let before = existing
                existing.task = existing.task.merged(with: incoming)
                take(post.assignment, into: &existing, sender: sender)
                tasks[incoming.id] = existing
                note(before: before, after: existing, id: id, actor: sender, date: date)
            } else {
                var added = SharedTask(task: incoming, assignee: nil, assignedAt: .distantPast, assignedBy: nil, addedBy: sender)
                take(post.assignment, into: &added, sender: sender)
                tasks[incoming.id] = added
                activity.append(SharedActivity(id: id, taskID: incoming.id, actor: sender, date: date, kind: .added))
                if added.assignee != nil {
                    activity.append(SharedActivity(id: id + ".a", taskID: incoming.id, actor: sender, date: date, kind: .assigned(to: added.assignee)))
                }
            }
            return true

        case .removeTask:
            guard role.canEdit, let taskID = post.taskID, tasks[taskID] != nil else { return false }
            // Removed wins over any later edit, so a list never brings back what someone removed.
            tasks[taskID]?.removed = true
            activity.append(SharedActivity(id: id, taskID: taskID, actor: sender, date: date, kind: .removed))
            return true

        case .comment:
            guard let taskID = post.taskID, let task = tasks[taskID], !task.removed,
                  let text = post.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return false }
            comments.append(SharedComment(id: id, taskID: taskID, author: sender, date: date, text: String(text.prefix(SharedPost.commentLimit))))
            return true

        case .closeList:
            guard role == .owner else { return false }
            isClosed = true
            return true
        }
    }

    /// Takes a newer assignment, if the person it names could edit at that point.
    private func take(_ assignment: SharedPost.Assignment?, into task: inout SharedTask, sender: String) {
        guard let assignment else { return }
        if let username = assignment.username {
            guard role(of: username)?.canEdit == true else { return }
        }
        let newer = assignment.at > task.assignedAt
            || (assignment.at == task.assignedAt && (assignment.username ?? "") > (task.assignee ?? ""))
        guard newer else { return }
        task.assignee = assignment.username
        task.assignedAt = assignment.at
        task.assignedBy = sender
    }

    private mutating func note(before: SharedTask, after: SharedTask, id: String, actor: String, date: Date) {
        if before.task.isCompleted != after.task.isCompleted {
            activity.append(SharedActivity(id: id + ".c", taskID: after.id, actor: actor, date: date, kind: after.task.isCompleted ? .ticked : .unticked))
        }
        if before.assignee != after.assignee {
            activity.append(SharedActivity(id: id + ".a", taskID: after.id, actor: actor, date: date, kind: .assigned(to: after.assignee)))
        }
        if before.task.when != after.task.when || before.task.deadline != after.task.deadline {
            activity.append(SharedActivity(id: id + ".d", taskID: after.id, actor: actor, date: date, kind: .dated))
        }
    }

    // MARK: Reading it

    /// Someone in the list now, joined or invited.
    public func member(_ username: String) -> SharedRoomMember? {
        members.first { $0.username == username }
    }

    public var owner: SharedRoomMember? {
        members.first { $0.role == .owner && !$0.isInvited }
    }

    /// Who a task is given to now. Someone who left, was removed or can only view no longer holds it, so
    /// their tasks go back to unassigned without anyone posting.
    public func assignee(of task: SharedTask) -> String? {
        guard let username = task.assignee, let member = member(username), member.role.canEdit else { return nil }
        return username
    }

    /// The tasks still in the list, by heading and order.
    public var liveTasks: [SharedTask] {
        tasks.values.filter { !$0.removed }.sorted { a, b in
            if a.task.order != b.task.order { return a.task.order < b.task.order }
            return a.task.createdAt < b.task.createdAt
        }
    }

    /// Tasks under no heading first, then each heading in order.
    public var sections: [(heading: TaskList.Heading?, tasks: [SharedTask])] {
        let live = liveTasks
        var result: [(heading: TaskList.Heading?, tasks: [SharedTask])] = []
        let loose = live.filter { $0.task.headingID == nil }
        if !loose.isEmpty || (list?.headings.isEmpty ?? true) { result.append((nil, loose)) }
        for heading in list?.headings ?? [] {
            result.append((heading, live.filter { $0.task.headingID == heading.id }))
        }
        return result
    }

    public func comments(on taskID: UUID) -> [SharedComment] {
        comments.filter { $0.taskID == taskID }
    }

    public func activity(on taskID: UUID) -> [SharedActivity] {
        activity.filter { $0.taskID == taskID && $0.kind != .added }
    }

    /// Open tasks given to `username`.
    public func assigned(to username: String) -> [SharedTask] {
        liveTasks.filter { !$0.task.isCompleted && assignee(of: $0) == username }
    }

    public var openCount: Int { liveTasks.filter { !$0.task.isCompleted }.count }
    public var displayName: String { list?.displayName ?? "Shared list" }
}
