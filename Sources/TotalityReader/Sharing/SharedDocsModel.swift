import Foundation
import Observation
import TotalityCore

/// Docs shared with other Totality users (issue 228). Each lives in its own end-to-end encrypted room,
/// which the app hands over as `SharedRooms`, so the Reader never imports Messages. Nothing of a shared
/// doc is kept anywhere else: every device builds it from the room.
@MainActor
@Observable
public final class SharedDocsModel {
    public enum Phase: Equatable {
        case idle, loading, ready
        case unavailable(String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var docs: [SharedDocState] = []
    public private(set) var invites: [SharedRoomInvite] = []
    public private(set) var own: String?
    public private(set) var profiles: [String: PublicProfile] = [:]
    public var notice: String?

    @ObservationIgnored private let rooms: (any SharedRooms)?
    @ObservationIgnored public var directory: (any ProfileDirectory)?
    @ObservationIgnored private var refreshing = false
    /// Rooms this device has already asked a copy of, so it asks once per session.
    @ObservationIgnored private var asked: Set<String> = []

    public init(rooms: (any SharedRooms)?) {
        self.rooms = rooms
    }

    public var isAvailable: Bool {
        if case .unavailable = phase { return false }
        return rooms != nil
    }

    public func doc(_ room: String) -> SharedDocState? {
        docs.first { $0.room == room }
    }

    public func name(of username: String) -> String {
        if username == own { return "You" }
        return profiles[username]?.name ?? "@\(username)"
    }

    public func photo(of username: String) -> Data? {
        profiles[username]?.photo
    }

    private func role(in room: String) -> SharedRole? {
        guard let own else { return nil }
        return doc(room)?.member(own)?.role
    }

    public func canEdit(_ room: String) -> Bool { role(in: room)?.canEdit == true }
    public func isOwner(_ room: String) -> Bool { role(in: room) == .owner }

    // MARK: Loading

    public func refresh() async {
        guard let rooms, !refreshing else { return }
        if let reason = rooms.unavailableReason {
            phase = .unavailable(reason)
            return
        }
        refreshing = true
        defer { refreshing = false }
        if phase == .idle { phase = .loading }
        let now = await rooms.ownUsername
        if now != own {
            // Someone else is signed in to Messages now, so the last account's docs go.
            docs = []
            invites = []
            profiles = [:]
            asked = []
            notice = nil
        }
        own = now
        do {
            invites = try await rooms.invites()
            var loaded: [SharedDocState] = []
            for room in try await rooms.rooms() {
                do {
                    let state = try await read(room, rooms: rooms)
                    if state.isClosed {
                        try? await rooms.leave(room)
                        continue
                    }
                    loaded.append(state)
                } catch SharedRoomError.notEncrypted {
                    // Never shown: the label says end-to-end encrypted, so a room that isn't is left.
                    try? await rooms.leave(room)
                }
            }
            docs = loaded.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            phase = .ready
            await loadProfiles()
        } catch let error as SharedRoomError {
            if case .unavailable(let reason) = error { phase = .unavailable(reason) } else { show(error) }
        } catch {
            notice = "Shared docs couldn't be read. Pull down to try again."
            if phase == .loading { phase = .ready }
        }
    }

    /// Reads a room, then answers or makes a request for a copy if one is needed.
    private func read(_ room: String, rooms: any SharedRooms) async throws -> SharedDocState {
        var state = SharedDocState.build(room: room, history: try await rooms.history(of: room))
        guard !state.isClosed, let own else { return state }
        let mine = state.member(own)?.role
        if state.isComplete, mine?.canEdit == true, !state.waitingForCopy.subtracting([own]).isEmpty {
            // Someone joined after the doc was written and can't open its first posts. Send them all of it.
            if (try? await sendSnapshot(of: state, rooms: rooms)) == true {
                state = SharedDocState.build(room: room, history: try await rooms.history(of: room))
            }
        } else if !state.isComplete, !state.waitingForCopy.contains(own), !asked.contains(room) {
            asked.insert(room)
            if (try? await rooms.post(try SharedDocPost(kind: .askForCopy).encoded(), to: room)) != nil {
                state = SharedDocState.build(room: room, history: try await rooms.history(of: room))
            }
        }
        return state
    }

    private func sendSnapshot(of state: SharedDocState, rooms: any SharedRooms) async throws -> Bool {
        guard let id = state.docID else { return false }
        let first = SharedDocPost(kind: .snapshot, docID: id, title: state.title, titleRev: state.titleRev)
        guard let posts = try SharedDocPost.chunked(state.visibleBlocks, first: first, rest: .snapshot) else { return false }
        for post in posts { try await rooms.post(post, to: state.room) }
        return true
    }

    /// Reads one doc again, for the open screen.
    public func reload(_ room: String) async {
        guard let rooms else { return }
        do {
            let state = try await read(room, rooms: rooms)
            if state.isClosed {
                try? await rooms.leave(room)
                docs.removeAll { $0.room == room }
                return
            }
            if let index = docs.firstIndex(where: { $0.room == room }) { docs[index] = state } else { docs.append(state) }
        } catch let error as SharedRoomError {
            if error == .notAllowed {
                // Removed from it: it goes from this person's Reader.
                docs.removeAll { $0.room == room }
            }
            show(error)
        } catch {
            notice = "That doc couldn't be read. Pull down to try again."
        }
    }

    private func loadProfiles() async {
        guard let directory else { return }
        var people = Set(docs.flatMap { $0.members.map(\.username) })
        people.formUnion(invites.compactMap(\.inviter))
        if let own { people.remove(own) }
        guard !people.isEmpty, let found = try? await directory.profiles(of: Array(people).sorted(), photos: [:]) else { return }
        profiles.merge(found) { _, new in new }
    }

    private func show(_ error: any Error) {
        if let error = error as? SharedRoomError {
            notice = switch error {
            case .notEncrypted: "That doc isn't end-to-end encrypted, so the Reader won't open it."
            case .notAllowed: "Only the doc's owner can do that."
            default: error.message
            }
        } else {
            notice = "That didn't go through. Try again."
        }
    }

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

    // MARK: Sharing

    /// Makes the doc's room, posts the doc, then invites each person. Returns the room, after which the
    /// caller moves the private copy to Recently Deleted.
    public func share(title: String, text: String, with people: [String: SharedRole]) async -> String? {
        guard let rooms else { return nil }
        let blocks = DocBlocks.split(text).enumerated().map { SharedBlock(order: Double($0.offset + 1), text: $0.element) }
        let first = SharedDocPost(kind: .doc, docID: UUID(), title: String(title.prefix(SharedDocPost.titleLimit)), titleRev: 1)
        guard let posts = try? SharedDocPost.chunked(blocks, first: first, rest: .blocks) else {
            notice = "One paragraph is too long to share. Break it into shorter paragraphs and try again."
            return nil
        }
        let invitees = people.filter { $0.key != own && $0.value != .owner }
        do {
            // Nobody is invited until everything is in, so no one joins a half-made doc.
            let room = try await rooms.create(inviting: [:])
            for post in posts { try await rooms.post(post, to: room) }
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

    public func invite(_ typed: String, as role: SharedRole, to room: String) async -> Bool {
        let handle = Self.handle(typed)
        guard !handle.isEmpty, handle != own, role != .owner else { return false }
        return await perform(room) { try await $0.invite(handle, as: role, to: room) }
    }

    public func accept(_ invite: SharedRoomInvite) async {
        guard await perform(invite.room, { try await $0.accept(invite.room) }) else { return }
        invites.removeAll { $0.room == invite.room }
    }

    /// Quiet: whoever invited you isn't told.
    public func decline(_ invite: SharedRoomInvite) async {
        guard await perform(nil, { try await $0.decline(invite.room) }) else { return }
        invites.removeAll { $0.room == invite.room }
    }

    /// Owner only. The server enforces it too.
    public func setRole(_ role: SharedRole, for username: String, in room: String) async {
        guard role != .owner else { return }
        await perform(room) { try await $0.setRole(role, for: username, in: room) }
    }

    /// They stop getting changes. What they already saw stays on their devices.
    public func remove(_ username: String, from room: String) async {
        await perform(room) { try await $0.remove(username, from: room) }
    }

    /// Anyone but the owner can leave. The owner stops sharing instead, so a doc never loses its owner.
    public func leave(_ room: String) async -> Bool {
        guard !isOwner(room) else {
            notice = "You own this doc. Stop sharing it instead."
            return false
        }
        guard await perform(nil, { try await $0.leave(room) }) else { return false }
        docs.removeAll { $0.room == room }
        return true
    }

    /// Owner only: it goes from everyone's Reader. Returns the doc as it stood, for a private copy.
    public func stopSharing(_ room: String) async -> (title: String, text: String)? {
        guard let state = doc(room), isOwner(room) else {
            notice = "Only the doc's owner can do that."
            return nil
        }
        let kept = (state.title, state.text)
        let done = await perform(nil) { rooms in
            try await rooms.post(try SharedDocPost(kind: .close, docID: state.docID).encoded(), to: room)
            for member in state.members where member.username != self.own {
                try? await rooms.remove(member.username, from: room)
            }
            try await rooms.leave(room)
        }
        guard done else { return nil }
        docs.removeAll { $0.room == room }
        return kept
    }

    public func chatPartners() async -> [String] {
        await rooms?.chatPartners() ?? []
    }

    // MARK: Editing

    /// Posts what changed between `base` (the blocks the editor started from) and `text`. Returns the
    /// doc's blocks afterwards, which become the editor's new base, or nil when nothing was posted.
    public func save(_ room: String, base: [SharedBlock], text: String) async -> [SharedBlock]? {
        guard let state = doc(room) else { return nil }
        guard canEdit(room) else {
            notice = "You can view this doc. Ask its owner if you'd like to edit it."
            return nil
        }
        let changes = DocBlocks.changes(from: base, to: text, current: state.blocks)
        guard !changes.isEmpty else { return state.visibleBlocks }
        let first = SharedDocPost(kind: .blocks, docID: state.docID)
        guard let posts = try? SharedDocPost.chunked(changes, first: first, rest: .blocks) else {
            notice = "One paragraph is too long to share. Break it into shorter paragraphs."
            return nil
        }
        let done = await perform(room) { rooms in
            for post in posts { try await rooms.post(post, to: room) }
        }
        return done ? doc(room)?.visibleBlocks : nil
    }

    public func rename(_ room: String, to title: String) async {
        guard let state = doc(room), canEdit(room) else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SharedDocPost.titleLimit))
        guard trimmed != state.title else { return }
        let post = SharedDocPost(kind: .title, docID: state.docID, title: trimmed, titleRev: state.titleRev + 1)
        await perform(room) { try await $0.post(try post.encoded(), to: room) }
    }

    /// A handle as typed, with any @ and spaces taken off, lowercased.
    public static func handle(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix("@") { text.removeFirst() }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }
}
