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
    /// Rooms this device has already asked for, so it asks once per session.
    @ObservationIgnored private var asked: Set<String> = []
    /// Docs created on this device, seeded locally so the sharer never depends on reading their own
    /// initial posts back from the room.
    @ObservationIgnored private var seeded: [String: SharedDocState] = [:]
    /// Used when polling non-seeded reloads if tests want zero pause.
    @ObservationIgnored public var confirmPause = Duration.milliseconds(500)
    @ObservationIgnored public var confirmAttempts = 20

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

    /// The line under a doc in the Shared list: who else it's with, then whose it is. "With Carter Nielson ·
    /// You're the owner", or "With Carter Nielson · Owner: Carter · You can edit".
    public func detail(of doc: SharedDocState) -> String {
        let others = doc.members.filter { $0.username != own }.map { name(of: $0.username) }
        var parts = [others.isEmpty ? "Just you" : "With " + Self.list(others)]
        let mine = own.flatMap { doc.member($0)?.role }
        if mine == .owner {
            parts.append("You're the owner")
        } else {
            if let owner = doc.owner { parts.append("Owner: \(firstName(of: owner.username))") }
            switch mine {
            case .editor: parts.append("You can edit")
            case .viewer: parts.append("You can view")
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "Carter", from a profile's name, or the handle when there's no profile.
    public func firstName(of username: String) -> String {
        let full = name(of: username)
        guard profiles[username] != nil, let first = full.split(separator: " ").first else { return full }
        return String(first)
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown
    }
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
            seeded = [:]
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

    /// Reads a room, then answers or makes an ask for the doc if a late joiner still needs it.
    private func read(_ room: String, rooms: any SharedRooms) async throws -> SharedDocState {
        var state = SharedDocState.build(room: room, history: try await rooms.history(of: room), seed: seeded[room])
        guard !state.isClosed, let own else { return state }
        let mine = state.member(own)?.role
        if state.isComplete, mine?.canEdit == true, !state.waitingForCopy.subtracting([own]).isEmpty {
            // Someone joined after the doc was written and can't open its first posts. Send them the doc.
            if (try? await sendSnapshot(of: state, rooms: rooms)) == true {
                state = SharedDocState.build(room: room, history: try await rooms.history(of: room), seed: seeded[room])
            }
        } else if !state.isComplete, !state.waitingForCopy.contains(own), !asked.contains(room) {
            asked.insert(room)
            if (try? await rooms.post(try SharedDocPost(kind: .askForCopy).encoded(), to: room)) != nil {
                state = SharedDocState.build(room: room, history: try await rooms.history(of: room), seed: seeded[room])
            }
        }
        return state
    }

    private func sendSnapshot(of state: SharedDocState, rooms: any SharedRooms) async throws -> Bool {
        guard let id = state.docID else { return false }
        return try await sendSnapshot(docID: id, title: state.title, titleRev: state.titleRev, blocks: state.visibleBlocks, to: state.room, rooms: rooms)
    }

    /// The whole doc as one post or more. Matrix hands someone invited later the room's key only from the
    /// next post on, never the earlier ones, so this is what lets them read it without waiting for an answer.
    private func sendSnapshot(
        docID: UUID, title: String, titleRev: Int, blocks: [SharedBlock], to room: String, rooms: any SharedRooms
    ) async throws -> Bool {
        let first = SharedDocPost(kind: .snapshot, docID: docID, title: title, titleRev: titleRev)
        guard let posts = try SharedDocPost.chunked(blocks, first: first, rest: .snapshot) else { return false }
        for post in posts { try await rooms.post(post, to: room) }
        return true
    }

    /// Updates `seeded[room]` (if this device originated the doc) and `docs` with a locally posted event.
    private func applyLocally(_ post: SharedDocPost, room: String, sender: String) {
        let now = Date()
        if var seed = seeded[room] {
            _ = seed.apply(post, sender: sender, date: now)
            seeded[room] = seed
        }
        if let index = docs.firstIndex(where: { $0.room == room }) {
            var current = docs[index]
            if current.apply(post, sender: sender, date: now) {
                docs[index] = current
            }
        }
    }

    /// Reads one doc again, for the open screen.
    public func reload(_ room: String) async {
        guard let rooms else { return }
        if own == nil { own = await rooms.ownUsername }
        do {
            let state = try await read(room, rooms: rooms)
            if state.isClosed {
                try? await rooms.leave(room)
                seeded[room] = nil
                docs.removeAll { $0.room == room }
                return
            }
            if let index = docs.firstIndex(where: { $0.room == room }) { docs[index] = state } else { docs.append(state) }
        } catch let error as SharedRoomError {
            if error == .notAllowed {
                // Removed from it: it goes from this person's Reader.
                seeded[room] = nil
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
        if own == nil { own = await rooms.ownUsername }
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

    /// Makes the doc's room with all invitees, posts the doc, and immediately seeds live collaborative
    /// state locally so the sharer's device never waits on or depends on reading its own posts back.
    public func share(title: String, text: String, with people: [String: SharedRole]) async -> String? {
        guard let rooms else { return nil }
        if own == nil { own = await rooms.ownUsername }
        let docID = UUID()
        let trimmedTitle = String(title.prefix(SharedDocPost.titleLimit))
        let blocks = DocBlocks.split(text).enumerated().map { SharedBlock(order: Double($0.offset + 1), text: $0.element) }
        let first = SharedDocPost(kind: .doc, docID: docID, title: trimmedTitle, titleRev: 1)
        guard let posts = try? SharedDocPost.chunked(blocks, first: first, rest: .blocks) else {
            notice = "One paragraph is too long to share. Break it into shorter paragraphs and try again."
            return nil
        }
        let invitees = people.filter { $0.key != own && $0.value != .owner }
        do {
            // Invite at room creation so the room's first posts encrypt for every invitee immediately
            // and handle-only shares go through in one server round-trip.
            let room = try await rooms.create(inviting: invitees)
            for post in posts { try await rooms.post(post, to: room) }
            if let me = own {
                let state = SharedDocState.seeded(
                    room: room, docID: docID, title: trimmedTitle, blocks: blocks, owner: me, invitees: invitees
                )
                seeded[room] = state
                if let index = docs.firstIndex(where: { $0.room == room }) { docs[index] = state } else { docs.append(state) }
            }
            if phase == .idle || phase == .loading { phase = .ready }
            return room
        } catch {
            show(error)
            return nil
        }
    }

    public func invite(_ typed: String, as role: SharedRole, to room: String) async -> Bool {
        let handle = Self.handle(typed)
        guard !handle.isEmpty, handle != own, role != .owner else { return false }
        return await perform(room) { rooms in
            try await rooms.invite(handle, as: role, to: room)
            // As when sharing: they get the room's key from the next post on, so the doc goes again for them.
            if let state = self.doc(room), state.isComplete, self.canEdit(room) {
                _ = try? await self.sendSnapshot(of: state, rooms: rooms)
            }
        }
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
        await perform(room) { try await $0.setRole(role, for: username, in: room) }
    }

    /// They stop getting changes. What they already saw stays on their devices.
    public func remove(_ username: String, from room: String) async {
        await perform(room) { try await $0.remove(username, from: room) }
    }

    /// Leaves a shared doc. The owner must either hand ownership to someone else first or stop sharing,
    /// unless another joined owner already exists.
    public func leave(_ room: String) async -> Bool {
        let otherOwner = doc(room)?.members.contains { !$0.isInvited && $0.username != own && $0.role == .owner } ?? false
        guard !isOwner(room) || otherOwner else {
            notice = "You own this doc. Make someone else the owner first, or stop sharing it."
            return false
        }
        guard await perform(nil, { try await $0.leave(room) }) else { return false }
        seeded[room] = nil
        docs.removeAll { $0.room == room }
        return true
    }

    /// Makes `username` the owner and leaves the shared doc.
    public func handOverAndLeave(_ room: String, to username: String) async -> Bool {
        guard let state = doc(room), state.member(username)?.role.canEdit == true else {
            notice = "Only someone who can edit can become the owner."
            return false
        }
        guard await perform(room, { try await $0.setRole(.owner, for: username, in: room) }) else { return false }
        return await leave(room)
    }

    /// Owner only: it goes from everyone else's Reader. Returns the doc as it stood.
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
        seeded[room] = nil
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
            if let sender = self.own {
                self.applyLocally(SharedDocPost(kind: .blocks, docID: state.docID, blocks: changes), room: room, sender: sender)
            }
        }
        return done ? doc(room)?.visibleBlocks : nil
    }

    public func rename(_ room: String, to title: String) async {
        guard let state = doc(room), canEdit(room) else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SharedDocPost.titleLimit))
        guard trimmed != state.title else { return }
        let post = SharedDocPost(kind: .title, docID: state.docID, title: trimmed, titleRev: state.titleRev + 1)
        await perform(room) {
            try await $0.post(try post.encoded(), to: room)
            if let sender = self.own { self.applyLocally(post, room: room, sender: sender) }
        }
    }

    /// A handle as typed, with any @ and spaces taken off, lowercased.
    public static func handle(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix("@") { text.removeFirst() }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }
}
