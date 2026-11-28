import Foundation
import TotalityCore

/// One paragraph of a shared doc (issue 228). Each is a last-writer-wins register: the higher revision
/// wins, and between equal revisions the change later in the room does.
public struct SharedBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Where it sits. Blocks are shown by order, then by ID, so every device lays them out alike.
    public var order: Double
    public var text: String
    public var rev: Int
    /// A tombstone, so a later copy of an older revision can't bring it back.
    public var deleted: Bool

    public init(id: UUID = UUID(), order: Double, text: String, rev: Int = 1, deleted: Bool = false) {
        self.id = id
        self.order = order
        self.text = text
        self.rev = rev
        self.deleted = deleted
    }
}

/// One change to a shared doc, as it travels inside the doc's end-to-end encrypted room. Who sent it is
/// never read from here: the room says, and the sender's role at that point decides whether it counts.
public struct SharedDocPost: Codable, Sendable, Equatable {
    public static let version = 1
    /// The most a post's body may be, in UTF-8 bytes. Matrix refuses events over 64 KB, and encryption
    /// makes the body about a third bigger, so this leaves room.
    public static let byteLimit = 30_000
    public static let titleLimit = 300

    public enum Kind: String, Codable, Sendable {
        /// The owner's first post: the doc's ID, its title and its first blocks.
        case doc
        /// Changed, added or deleted blocks.
        case blocks
        case title
        /// From someone who can't read the doc yet, such as a member who joined after it was written.
        case askForCopy
        /// The whole doc as one editor has it, in answer to an ask. It never beats an equal revision.
        case snapshot
        /// The owner stopped sharing it.
        case close
    }

    public var v: Int
    public var kind: Kind
    public var docID: UUID?
    public var title: String?
    public var titleRev: Int?
    public var blocks: [SharedBlock]?

    public init(kind: Kind, docID: UUID? = nil, title: String? = nil, titleRev: Int? = nil, blocks: [SharedBlock]? = nil) {
        v = Self.version
        self.kind = kind
        self.docID = docID
        self.title = title
        self.titleRev = titleRev
        self.blocks = blocks
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Nil for anything that isn't a post this version can read.
    public static func decode(_ body: String) -> SharedDocPost? {
        guard body.utf8.count <= byteLimit * 2,
              let post = try? JSONDecoder().decode(SharedDocPost.self, from: Data(body.utf8)), post.v >= 1
        else { return nil }
        return post
    }

    /// Posts carrying `blocks`, each under the size limit. The first is `kind`; the rest are `rest`.
    /// Nil when one block alone is too big to send.
    public static func chunked(
        _ blocks: [SharedBlock], first: SharedDocPost, rest: Kind
    ) throws -> [String]? {
        var posts: [String] = []
        var current = first
        current.blocks = []
        for block in blocks {
            var trial = current
            trial.blocks?.append(block)
            if try trial.encoded().utf8.count <= byteLimit {
                current = trial
                continue
            }
            guard current.blocks?.isEmpty == false else { return nil }
            posts.append(try current.encoded())
            current = SharedDocPost(kind: rest, docID: first.docID, blocks: [block])
            guard try current.encoded().utf8.count <= byteLimit else { return nil }
        }
        posts.append(try current.encoded())
        return posts
    }
}

/// A shared doc as its room's history makes it. Every device builds the same state from the same history,
/// so nothing of it is stored outside the room.
public struct SharedDocState: Sendable, Equatable, Identifiable {
    public let room: String
    public private(set) var docID: UUID?
    public private(set) var title = ""
    public private(set) var titleRev = 0
    public private(set) var blocks: [UUID: SharedBlock] = [:]
    /// Who last changed each block, and when, from the room.
    public private(set) var editors: [UUID: (String, Date)] = [:]
    public private(set) var members: [SharedRoomMember] = []
    /// The doc's first post, or a snapshot, has been read, so this device has all of it.
    public private(set) var isComplete = false
    public private(set) var isClosed = false
    /// People who asked for a copy and haven't had a snapshot since.
    public private(set) var waitingForCopy: Set<String> = []
    public private(set) var unreadable = 0
    /// Posts dropped because their sender wasn't allowed to make them.
    public private(set) var refused = 0
    public private(set) var lastChange: Date?
    /// When the room's first post was sent, readable or not: about when the doc was shared.
    public private(set) var started: Date?
    public let isEncrypted: Bool
    private var roles: [String: Int] = [:]

    public var id: String { room }

    public init(room: String, isEncrypted: Bool = true) {
        self.room = room
        self.isEncrypted = isEncrypted
    }

    public static func == (a: SharedDocState, b: SharedDocState) -> Bool {
        a.room == b.room && a.docID == b.docID && a.title == b.title && a.titleRev == b.titleRev && a.blocks == b.blocks
            && a.members == b.members && a.isComplete == b.isComplete && a.isClosed == b.isClosed
            && a.waitingForCopy == b.waitingForCopy && a.unreadable == b.unreadable && a.refused == b.refused
            && a.editors.mapValues(\.0) == b.editors.mapValues(\.0) && a.lastChange == b.lastChange
    }

    public static func build(room: String, history: SharedRoomHistory, seed: SharedDocState? = nil) -> SharedDocState {
        var state = SharedDocState(room: room, isEncrypted: history.isEncrypted)
        for event in history.events { state.apply(event) }
        state.members = history.members
        if !state.isComplete, !state.isClosed, let seed {
            var live = seed
            live.members = history.members
            live.unreadable = state.unreadable
            live.refused = state.refused
            for event in history.events { live.apply(event) }
            return live
        }
        return state
    }

    /// Creates an immediately editable local state for a newly shared doc so the sharer's device never
    /// depends on reading its own initial posts back from the room.
    public static func seeded(
        room: String, docID: UUID, title: String, blocks: [SharedBlock], owner: String,
        invitees: [String: SharedRole], date: Date = Date(), isEncrypted: Bool = true
    ) -> SharedDocState {
        var state = SharedDocState(room: room, isEncrypted: isEncrypted)
        state.docID = docID
        state.title = String(title.prefix(SharedDocPost.titleLimit))
        state.titleRev = 1
        state.blocks = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        state.roles = [owner: SharedRole.owner.rawValue]
        var list = [SharedRoomMember(username: owner, role: .owner)]
        for (person, role) in invitees.sorted(by: { $0.key < $1.key }) {
            let effective = role == .owner ? .editor : role
            state.roles[person] = effective.rawValue
            list.append(SharedRoomMember(username: person, role: effective, isInvited: true))
        }
        state.members = list
        state.isComplete = true
        state.started = date
        state.lastChange = date
        return state
    }

    public mutating func apply(_ event: SharedRoomEvent) {
        switch event {
        case .roles(let levels):
            roles = levels
        case .unreadable(_, _, let date):
            unreadable += 1
            if started == nil { started = date }
        case .post(_, let sender, let date, let body):
            if started == nil { started = date }
            guard let post = SharedDocPost.decode(body) else { return }
            if !apply(post, sender: sender, date: date) { refused += 1 }
        }
    }

    /// The sender's role at this point in the history.
    public func role(of username: String) -> SharedRole? {
        roles[username].map(SharedRole.init(powerLevel:))
    }

    @discardableResult
    public mutating func apply(_ post: SharedDocPost, sender: String, date: Date) -> Bool {
        guard let role = role(of: sender), !isClosed else { return false }
        switch post.kind {
        case .doc:
            // Only the owner starts a doc, and only once: a later one can't swap in another.
            guard role == .owner, docID == nil, let id = post.docID else { return false }
            docID = id
            take(title: post.title, rev: post.titleRev ?? 1, strict: false)
            take(post.blocks ?? [], sender: sender, date: date, strict: false)
            isComplete = true
        case .blocks:
            guard role.canEdit, matches(post.docID) else { return false }
            take(post.blocks ?? [], sender: sender, date: date, strict: false)
        case .title:
            guard role.canEdit, matches(post.docID) else { return false }
            take(title: post.title, rev: post.titleRev ?? 0, strict: false)
        case .snapshot:
            guard role.canEdit, let id = post.docID, docID == nil || docID == id else { return false }
            docID = id
            take(title: post.title, rev: post.titleRev ?? 0, strict: true)
            take(post.blocks ?? [], sender: sender, date: date, strict: true)
            isComplete = true
            waitingForCopy = []
            return true
        case .askForCopy:
            waitingForCopy.insert(sender)
            return true
        case .close:
            guard role == .owner else { return false }
            isClosed = true
            return true
        }
        lastChange = date
        return true
    }

    /// A post for another doc can't change this one. Before the ID is known, any is taken.
    private func matches(_ id: UUID?) -> Bool {
        docID == nil || id == nil || id == docID
    }

    private mutating func take(title incoming: String?, rev: Int, strict: Bool) {
        guard let incoming else { return }
        let wins = strict ? rev > titleRev : rev >= titleRev
        guard wins else { return }
        title = String(incoming.prefix(SharedDocPost.titleLimit))
        titleRev = rev
    }

    private mutating func take(_ incoming: [SharedBlock], sender: String, date: Date, strict: Bool) {
        for block in incoming where block.order.isFinite {
            if let current = blocks[block.id] {
                let wins = strict ? block.rev > current.rev : block.rev >= current.rev
                guard wins, block != current else { continue }
            }
            blocks[block.id] = block
            if !strict { editors[block.id] = (sender, date) }
        }
    }

    // MARK: Reading it

    /// The blocks that show, in order.
    public var visibleBlocks: [SharedBlock] {
        blocks.values.filter { !$0.deleted }.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
    }

    public var text: String { DocBlocks.join(visibleBlocks.map(\.text)) }

    public var displayTitle: String { title.isEmpty ? "Untitled" : title }

    public func member(_ username: String) -> SharedRoomMember? {
        members.first { $0.username == username }
    }

    public var owner: SharedRoomMember? {
        members.first { $0.role == .owner }
    }

    /// Who last changed a block, other than `me`, for the "Jonah edited this" line.
    public func lastEditor(of block: UUID) -> (username: String, date: Date)? {
        editors[block].map { ($0.0, $0.1) }
    }
}

/// How a doc's Markdown is split into blocks and put back. A block is the text between blank lines, and a
/// fenced code block stays whole, blank lines and all.
public enum DocBlocks {
    public static func split(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var fence: Substring?
        func flush() {
            if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
            current = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                current.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                current.append(line)
                continue
            }
            if line.allSatisfy(\.isWhitespace) {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    public static func join(_ blocks: [String]) -> String {
        blocks.joined(separator: "\n\n")
    }

    /// The new blocks a save should post: what changed between `base`, the blocks the editor started
    /// from, and `text`, what's in it now. Blocks the person didn't touch aren't posted, so someone else's
    /// change to them still stands. `current` gives each block's latest revision, so an edit outranks
    /// every revision this device has seen.
    public static func changes(from base: [SharedBlock], to text: String, current: [UUID: SharedBlock]) -> [SharedBlock] {
        let old = base.map(\.text)
        let new = split(text)
        let diff = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        func next(_ block: SharedBlock) -> Int { max(block.rev, current[block.id]?.rev ?? 0) + 1 }

        // Each new block, in order: the base block it came from (kept or edited), or none (added).
        var layout: [(from: SharedBlock?, text: String)] = []
        var deleted: [SharedBlock] = []
        var pending: [SharedBlock] = []
        var index = 0
        func gatherRemoved() {
            while index < base.count, removed.contains(index) {
                pending.append(base[index])
                index += 1
            }
        }
        for (offset, line) in new.enumerated() {
            gatherRemoved()
            if inserted.contains(offset) {
                // A paragraph changed in place reads as one removed and one added: keep its ID.
                layout.append((pending.isEmpty ? nil : pending.removeFirst(), line))
            } else {
                deleted += pending
                pending = []
                layout.append((base[index], line))
                index += 1
            }
        }
        gatherRemoved()
        deleted += pending

        var out: [SharedBlock] = []
        // Orders: kept and edited blocks keep theirs, which are still in order; added ones go between.
        var position = 0
        while position < layout.count {
            if let from = layout[position].from {
                if from.text != layout[position].text {
                    var edited = from
                    edited.text = layout[position].text
                    edited.order = current[from.id]?.order ?? from.order
                    edited.rev = next(from)
                    edited.deleted = false
                    out.append(edited)
                }
                position += 1
                continue
            }
            var end = position
            while end < layout.count, layout[end].from == nil { end += 1 }
            let before = position > 0 ? layout[position - 1].from.map { current[$0.id]?.order ?? $0.order } : nil
            let after = end < layout.count ? layout[end].from.map { current[$0.id]?.order ?? $0.order } : nil
            let count = end - position
            for step in 0..<count {
                let order: Double = switch (before, after) {
                case let (low?, high?): low + (high - low) * Double(step + 1) / Double(count + 1)
                case let (low?, nil): low + Double(step + 1)
                case let (nil, high?): high - Double(count - step)
                case (nil, nil): Double(step + 1)
                }
                out.append(SharedBlock(order: order, text: layout[position + step].text))
            }
            position = end
        }
        for block in deleted {
            var gone = block
            gone.deleted = true
            gone.text = ""
            gone.rev = next(block)
            out.append(gone)
        }
        return out
    }
}
