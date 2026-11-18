import Foundation
import Observation
import TotalityCore

/// Shared lists and projects (step 6). Each lives in its own end-to-end encrypted room, which the app
/// hands over as `SharedRooms`; nothing of a shared list is kept anywhere else. A list that isn't shared
/// stays in the person's own sealed storage until they share it.
@MainActor
@Observable
public final class SharedListsModel {
    public enum Phase: Equatable {
        case idle, loading, ready
        case unavailable(String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var lists: [SharedListState] = []
    public private(set) var invites: [SharedRoomInvite] = []
    public private(set) var own: String?
    /// Names and photos of people in your lists, from their public profiles.
    public private(set) var profiles: [String: PublicProfile] = [:]
    public var notice: String?

    @ObservationIgnored private let rooms: (any SharedRooms)?
    @ObservationIgnored public var directory: (any ProfileDirectory)?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var refreshing = false

    public init(rooms: (any SharedRooms)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rooms = rooms
        clock = now
    }

    public var isAvailable: Bool {
        if case .unavailable = phase { return false }
        return rooms != nil
    }

    public func list(_ room: String) -> SharedListState? {
        lists.first { $0.room == room }
    }

    /// Open tasks given to you in every shared list, with the list each is from.
    public var assignedToMe: [(list: SharedListState, task: SharedTask)] {
        guard let own else { return [] }
        return lists.flatMap { list in list.assigned(to: own).map { (list, $0) } }
    }

    /// What to call someone: "You", their profile name, or their handle.
    public func name(of username: String) -> String {
        if username == own { return "You" }
        return profiles[username]?.name ?? username
    }

    /// First name only, for short lines like "From Jonah".
    public func shortName(of username: String) -> String {
        if username == own { return "You" }
        return name(of: username).split(separator: " ").first.map(String.init) ?? username
    }

    public func photo(of username: String) -> Data? {
        profiles[username]?.photo
    }

    // MARK: Loading

    /// Reads invites and every shared list's room again.
    public func refresh() async {
        guard let rooms, !refreshing else { return }
        if let reason = rooms.unavailableReason {
            phase = .unavailable(reason)
            return
        }
        refreshing = true
        defer { refreshing = false }
        if phase == .idle { phase = .loading }
        own = await rooms.ownUsername
        do {
            invites = try await rooms.invites()
            var loaded: [SharedListState] = []
            for room in try await rooms.rooms() {
                do {
                    let state = SharedListState.build(room: room, history: try await rooms.history(of: room))
                    if state.isClosed {
                        // The owner deleted it for everyone, so it leaves this person's Tasks too.
                        try? await rooms.leave(room)
                        continue
                    }
                    loaded.append(state)
                } catch SharedRoomError.notEncrypted {
                    // Never shown: the label says end-to-end encrypted, so a room that isn't is left.
                    try? await rooms.leave(room)
                }
            }
            lists = loaded.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            phase = .ready
            await loadProfiles()
        } catch let error as SharedRoomError {
            if case .unavailable(let reason) = error { phase = .unavailable(reason) } else { show(error) }
        } catch {
            notice = "Shared lists couldn't be read. Pull down to try again."
            if phase == .loading { phase = .ready }
        }
    }

    private func loadProfiles() async {
        guard let directory else { return }
        var people = Set(lists.flatMap { $0.members.map(\.username) })
        people.formUnion(invites.compactMap(\.inviter))
        if let own { people.remove(own) }
        guard !people.isEmpty, let found = try? await directory.profiles(of: Array(people).sorted(), photos: [:]) else { return }
        profiles.merge(found) { _, new in new }
    }

    private func reload(_ room: String) async {
        guard let rooms else { return }
        do {
            let state = SharedListState.build(room: room, history: try await rooms.history(of: room))
            if let index = lists.firstIndex(where: { $0.room == room }) { lists[index] = state } else { lists.append(state) }
        } catch let error as SharedRoomError {
            show(error)
        } catch {
            notice = "That list couldn't be read. Pull down to try again."
        }
    }

    private func show(_ error: any Error) {
        notice = (error as? SharedRoomError)?.message ?? "That didn't go through. Check your connection and try again."
    }

    /// Runs a change, then reads the room again so the screen shows what everyone now sees.
    @discardableResult
    private func perform(_ room: String?, _ work: @MainActor (any SharedRooms) async throws -> Void) async -> Bool {
        guard let rooms else { return false }
        do {
            try await work(rooms)
            if let room { await reload(room) }
            return true
        } catch {
            show(error)
            return false
        }
    }

    // MARK: Sharing and invites

    /// Shares a project or an area with no projects in it: makes its room, posts the list and its tasks,
    /// then invites each person. Returns the room, after which the caller removes the private copy.
    public func share(_ list: TaskList, tasks: [TaskItem], with people: [String: SharedRole]) async -> String? {
        guard let rooms else { return nil }
        guard list.kind != .smart else {
            notice = "Smart lists can't be shared. Share a project or an area instead."
            return nil
        }
        let invitees = people.filter { $0.key != own && $0.value != .owner }
        do {
            // Nobody is invited until everything is in, so no one joins a half-made list.
            let room = try await rooms.create(inviting: [:])
            var shared = list
            shared.areaID = nil
            shared.isPinned = false
            try await rooms.post(try SharedPost(kind: .list, list: shared).encoded(), to: room)
            for task in tasks where task.listID == list.id {
                var copy = task
                copy.reminders = []
                copy.nagging = nil
                copy.snoozedUntil = nil
                try await rooms.post(try SharedPost(kind: .task, task: copy).encoded(), to: room)
            }
            for (person, role) in invitees.sorted(by: { $0.key < $1.key }) {
                try await rooms.invite(person, as: role, to: room)
            }
            await reload(room)
            return room
        } catch {
            show(error)
            return nil
        }
    }

    public func invite(_ username: String, as role: SharedRole, to room: String) async -> Bool {
        let handle = Self.handle(username)
        guard !handle.isEmpty, handle != own else { return false }
        return await perform(room) { try await $0.invite(handle, as: role, to: room) }
    }

    public func accept(_ invite: SharedRoomInvite) async {
        guard await perform(invite.room, { try await $0.accept(invite.room) }) else { return }
        invites.removeAll { $0.room == invite.room }
    }

    /// Quiet: the person who invited you isn't told (owner decision, 2026-11-18).
    public func decline(_ invite: SharedRoomInvite) async {
        guard await perform(nil, { try await $0.decline(invite.room) }) else { return }
        invites.removeAll { $0.room == invite.room }
    }

    public func setRole(_ role: SharedRole, for username: String, in room: String) async {
        await perform(room) { try await $0.setRole(role, for: username, in: room) }
    }

    /// They stop getting changes. What they already saw stays on their devices: that's how end-to-end
    /// encryption works, and the confirmation says so.
    public func remove(_ username: String, from room: String) async {
        await perform(room) { try await $0.remove(username, from: room) }
    }

    /// Leaves a list. The owner must hand it over first, so a list is never left without one.
    public func leave(_ room: String) async -> Bool {
        if let list = list(room), list.owner?.username == own, list.members.contains(where: { !$0.isInvited && $0.username != own }) {
            notice = "Make someone who can edit the owner first, or delete the list for everyone."
            return false
        }
        guard await perform(nil, { try await $0.leave(room) }) else { return false }
        lists.removeAll { $0.room == room }
        return true
    }

    /// Makes `username` the owner and you an editor, then leaves.
    public func handOverAndLeave(_ room: String, to username: String) async -> Bool {
        guard let list = list(room), list.member(username)?.role.canEdit == true else {
            notice = "Only someone who can edit can become the owner."
            return false
        }
        guard await perform(room, { try await $0.setRole(.owner, for: username, in: room) }) else { return false }
        return await leave(room)
    }

    /// Owner only: everyone's copy goes, then the room is emptied and left.
    public func deleteForEveryone(_ room: String) async -> Bool {
        guard let list = list(room), list.owner?.username == own else {
            notice = SharedRoomError.notAllowed.message
            return false
        }
        let done = await perform(nil) { rooms in
            try await rooms.post(try SharedPost(kind: .closeList).encoded(), to: room)
            for member in list.members where member.username != self.own {
                try? await rooms.remove(member.username, from: room)
            }
            try await rooms.leave(room)
        }
        if done { lists.removeAll { $0.room == room } }
        return done
    }

    public func chatPartners() async -> [String] {
        await rooms?.chatPartners() ?? []
    }

    // MARK: Tasks in a shared list

    private func myRole(in room: String) -> SharedRole? {
        guard let own else { return nil }
        return list(room)?.member(own)?.role
    }

    public func canEdit(_ room: String) -> Bool {
        myRole(in: room)?.canEdit == true
    }

    public func isOwner(_ room: String) -> Bool {
        myRole(in: room) == .owner
    }

    private func send(_ post: SharedPost, to room: String) async -> Bool {
        guard canEdit(room) || post.kind == .comment else {
            notice = "You can view this list. Ask its owner if you'd like to edit it."
            return false
        }
        return await perform(room) { try await $0.post(try post.encoded(), to: room) }
    }

    @discardableResult
    public func add(_ title: String, to room: String, heading: UUID? = nil) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let list = list(room)?.list else { return false }
        let last = self.list(room)?.liveTasks.map(\.task.order).max() ?? 0
        let task = TaskItem(title: trimmed, place: .anytime, listID: list.id, headingID: heading, order: last + 1, createdAt: clock())
        return await send(SharedPost(kind: .task, task: task), to: room)
    }

    /// Changes a task's parts and posts it whole; the edit times make it merge with anyone else's change.
    @discardableResult
    public func change(_ taskID: UUID, in room: String, _ edit: (inout TaskItem) -> Void) async -> Bool {
        guard let current = list(room)?.tasks[taskID]?.task else { return false }
        var edited = current
        edit(&edited)
        guard edited != current else { return true }
        edited.noteChanges(from: current, at: clock())
        return await send(SharedPost(kind: .task, task: edited), to: room)
    }

    /// Ticks it off, or back on, for everyone in the list.
    public func toggle(_ taskID: UUID, in room: String) async {
        let now = clock()
        await change(taskID, in: room) { $0.completedAt = $0.isCompleted ? nil : now }
    }

    public func remove(task taskID: UUID, from room: String) async {
        await send(SharedPost(kind: .removeTask, taskID: taskID), to: room)
    }

    /// Gives a task to someone who can edit, or to nobody. `messageThem` also posts a line in your chat with
    /// them, which is off unless chosen because it sends a message.
    public func assign(_ taskID: UUID, in room: String, to username: String?, messageThem: Bool = false) async {
        guard let state = list(room), let shared = state.tasks[taskID] else { return }
        if let username, state.member(username)?.role.canEdit != true {
            notice = "Only people who can edit can be given a task."
            return
        }
        let post = SharedPost(kind: .task, task: shared.task, assignment: .init(username: username, at: clock()))
        guard await send(post, to: room), messageThem, let username, username != own, let rooms else { return }
        do {
            try await rooms.message("I gave you “\(shared.task.displayTitle)” in \(state.displayName), in Tasks.", to: username)
        } catch {
            notice = "The task is assigned, but the chat message didn't go."
        }
    }

    /// Anyone in the list can comment, viewers included.
    @discardableResult
    public func comment(_ text: String, on taskID: UUID, in room: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= SharedPost.commentLimit else {
            notice = "That comment is too long. Keep it under \(SharedPost.commentLimit) characters."
            return false
        }
        return await send(SharedPost(kind: .comment, taskID: taskID, text: trimmed), to: room)
    }

    /// A handle as typed, with any @ and spaces taken off, lowercased.
    public static func handle(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix("@") { text.removeFirst() }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }
}
