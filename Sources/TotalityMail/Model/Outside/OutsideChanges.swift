import Foundation

/// Where a message is at its provider, in the terms both Gmail and iCloud share.
public enum OutsidePlace: String, Codable, Sendable {
    case inbox, archive, spam, trash

    /// Totality's own folders have no match at the provider, so they're archived there.
    init(_ folder: MailFolder) {
        switch folder {
        case .inbox: self = .inbox
        case .spam: self = .spam
        case .trash: self = .trash
        default: self = .archive
        }
    }
}

/// Where an iCloud message is now, once Totality has moved it out of the Inbox it was downloaded from.
public struct OutsideIMAPLocation: Codable, Equatable, Sendable {
    public let mailbox: String
    public let validity: UInt32
    public let uid: UInt32

    /// Moved somewhere it can't be followed: its new UID wasn't given, or its folder's UIDs started over.
    static let lost = OutsideIMAPLocation(mailbox: "", validity: 0, uid: 0)
}

/// A downloaded message as Totality and the provider last agreed on it.
public struct OutsideRemoteState: Codable, Equatable, Sendable {
    public var place: OutsidePlace
    public var isUnread: Bool
    public var isStarred: Bool
    /// iCloud only, and only once moved: nil means still where it was downloaded from.
    public var location: OutsideIMAPLocation?

    init(place: OutsidePlace, isUnread: Bool, isStarred: Bool, location: OutsideIMAPLocation? = nil) {
        self.place = place
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.location = location
    }

    /// What was true when it was downloaded.
    init(downloaded message: OutsideFetchedMessage) {
        let place: OutsidePlace = message.labels.isEmpty || message.labels.contains("INBOX") ? .inbox : .archive
        self.init(place: place, isUnread: message.isUnread, isStarred: message.isStarred)
    }

    init(_ marks: MailMarks, location: OutsideIMAPLocation?) {
        self.init(place: OutsidePlace(marks.folder), isUnread: marks.isUnread, isStarred: marks.isStarred, location: location)
    }
}

/// What the provider shows now, as far as this open could tell. Nil is unknown.
public struct OutsideSeen: Equatable, Sendable {
    public var place: OutsidePlace?
    public var isUnread: Bool?
    public var isStarred: Bool?

    public static let unknown = OutsideSeen()
}

/// Each downloaded message's agreed state, by the provider's ID, and messages deleted in Totality still
/// to be moved to the provider's Trash. On this device only, sealed, and never synced.
public struct OutsideRemoteRecord: Codable, Equatable, Sendable {
    public let outside: UUID
    public var states: [String: OutsideRemoteState] = [:]
    public var erased: [String: OutsideRemoteState] = [:]

    public init(outside: UUID) { self.outside = outside }
}

/// Works out, field by field, what goes to the provider and what comes back from it.
enum OutsideReconcile {
    struct Outcome: Equatable {
        /// What the provider should be changed to, when Totality changed something.
        var push: OutsideRemoteState?
        /// What Totality should show, when the provider changed something.
        var pull: OutsideRemoteState?
        /// The new agreement if the push works, or with no push.
        var agreed: OutsideRemoteState
        /// The agreement if the push fails: what was pulled, and nothing that was pushed.
        var agreedIfPushFails: OutsideRemoteState
    }

    /// `mine` is Totality's marks for it, nil when nothing was changed here. A field changed in Totality
    /// wins over the same field changed at the provider.
    static func outcome(base: OutsideRemoteState, mine: OutsideRemoteState?, seen: OutsideSeen) -> Outcome {
        let mine = mine ?? base
        var agreed = base, failed = base, pushed = false, pulled = false
        func settle<T: Equatable>(_ field: WritableKeyPath<OutsideRemoteState, T>, seen: T?) {
            if mine[keyPath: field] != base[keyPath: field] {
                agreed[keyPath: field] = mine[keyPath: field]
                pushed = true
            } else if let seen, seen != base[keyPath: field] {
                agreed[keyPath: field] = seen
                failed[keyPath: field] = seen
                pulled = true
            }
        }
        settle(\.place, seen: seen.place)
        settle(\.isUnread, seen: seen.isUnread)
        settle(\.isStarred, seen: seen.isStarred)
        return Outcome(push: pushed ? agreed : nil, pull: pulled ? agreed : nil, agreed: agreed, agreedIfPushFails: failed)
    }

    /// Totality's marks after the provider's change, keeping a folder of Totality's own while it's
    /// still archived at the provider.
    static func marks(_ marks: MailMarks, after state: OutsideRemoteState, now: Date) -> MailMarks {
        var marks = marks
        marks.isUnread = state.isUnread
        marks.isStarred = state.isStarred
        guard OutsidePlace(marks.folder) != state.place else { return marks }
        let before = marks.folder
        switch state.place {
        case .inbox: marks.folder = .inbox
        case .archive: marks.folder = .archive
        case .spam: marks.folder = .spam
        case .trash:
            marks.folder = .trash
            marks.trashedAt = now
            marks.trashedFrom = before
        }
        if state.place != .trash {
            marks.trashedAt = nil
            marks.trashedFrom = nil
        }
        return marks
    }
}

// MARK: - Gmail

extension GoogleOAuth {
    /// Makes Gmail match: Trash, labels for read and starred, and INBOX and SPAM for where it is. False
    /// when Gmail no longer has it, so there's nothing left to change.
    func change(_ id: String, from: OutsideRemoteState, to: OutsideRemoteState, accessToken: String) async throws -> Bool {
        guard Self.isGmailID(id) else { throw OutsideMailProblem.unexpected }
        let message = Self.messagesURL.appendingPathComponent(id)
        struct Ignored: Decodable {}
        do {
            if from.place == .trash, to.place != .trash {
                let _: Ignored = try await gmail(message.appendingPathComponent("untrash"), accessToken: accessToken, posting: [:])
            }
            if to.place == .trash, from.place != .trash {
                let _: Ignored = try await gmail(message.appendingPathComponent("trash"), accessToken: accessToken, posting: [:])
            }
            var add: [String] = [], remove: [String] = []
            if to.isUnread != from.isUnread {
                if to.isUnread { add.append("UNREAD") } else { remove.append("UNREAD") }
            }
            if to.isStarred != from.isStarred {
                if to.isStarred { add.append("STARRED") } else { remove.append("STARRED") }
            }
            if to.place != from.place {
                switch to.place {
                case .inbox: add.append("INBOX"); remove.append("SPAM")
                case .archive: remove += ["INBOX", "SPAM"]
                case .spam: add.append("SPAM"); remove.append("INBOX")
                case .trash: break
                }
            }
            if !add.isEmpty || !remove.isEmpty {
                let _: Ignored = try await gmail(
                    message.appendingPathComponent("modify"), accessToken: accessToken,
                    posting: ["addLabelIds": add, "removeLabelIds": remove]
                )
            }
            return true
        } catch GmailMissing.message {
            return false
        }
    }
}

// MARK: - iCloud

extension IMAPConnection {
    /// The folders that Archive, Junk and Trash go to, by their special-use flags, or their usual names.
    func specialMailboxes() async throws -> [OutsidePlace: String] {
        let tag = takeTag()
        try await reader.send("\(tag) LIST \"\" \"*\"")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        var found: [OutsidePlace: String] = [:], names: [String] = []
        for line in untagged {
            guard let (flags, name) = Self.listed(line) else { continue }
            names.append(name)
            if flags.contains("\\archive") { found[.archive] = found[.archive] ?? name }
            if flags.contains("\\junk") { found[.spam] = found[.spam] ?? name }
            if flags.contains("\\trash") { found[.trash] = found[.trash] ?? name }
        }
        func named(_ options: [String]) -> String? { options.lazy.compactMap { option in names.first { $0.caseInsensitiveCompare(option) == .orderedSame } }.first }
        found[.archive] = found[.archive] ?? named(["Archive"])
        found[.spam] = found[.spam] ?? named(["Junk", "Spam"])
        found[.trash] = found[.trash] ?? named(["Deleted Messages", "Trash"])
        found[.inbox] = "INBOX"
        return found
    }

    /// `* LIST (\HasNoChildren \Trash) "/" "Deleted Messages"`: its flags, lowercased, and its name.
    static func listed(_ line: Data) -> (flags: Set<String>, name: String)? {
        var text = String(decoding: line, as: UTF8.self)
        guard text.uppercased().hasPrefix("* LIST ("), let close = text.firstIndex(of: ")") else { return nil }
        let flags = Set(text[text.index(text.startIndex, offsetBy: 8)..<close].lowercased().split(separator: " ").map(String.init))
        text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        // The delimiter: a quoted character or NIL.
        if text.hasPrefix("\"") {
            guard text.count >= 3 else { return nil }
            let after = text.index(text.startIndex, offsetBy: text.dropFirst().hasPrefix("\\") ? 4 : 3)
            guard after <= text.endIndex else { return nil }
            text = String(text[after...])
        } else if text.uppercased().hasPrefix("NIL") {
            text = String(text.dropFirst(3))
        } else { return nil }
        text = text.trimmingCharacters(in: .whitespaces)
        let name: String
        if text.hasPrefix("\"") {
            var out = "", escaped = false
            for character in text.dropFirst() {
                if escaped { out.append(character); escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break } else { out.append(character) }
            }
            name = out
        } else if text.hasPrefix("{"), let end = text.range(of: "}\r\n") {
            name = String(text[end.upperBound...])
        } else {
            name = text
        }
        guard isMailboxName(name) else { return nil }
        return (flags, name)
    }

    /// Printable ASCII only, as IMAP's own names are: anything else never goes into a command.
    static func isMailboxName(_ name: String) -> Bool {
        (1...200).contains(name.count) && name.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }
    }

    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Opens a folder to change it, and returns its UIDVALIDITY.
    func select(_ mailbox: String) async throws -> UInt32 {
        guard Self.isMailboxName(mailbox) else { throw OutsideMailProblem.unexpected }
        let tag = takeTag()
        try await reader.send("\(tag) SELECT \(Self.quoted(mailbox))")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            if let range = text.range(of: "[UIDVALIDITY ", options: .caseInsensitive), let value = UInt32(text[range.upperBound...].prefix { $0.isNumber }) {
                return value
            }
        }
        throw OutsideMailProblem.unexpected
    }

    func setFlag(_ flag: String, on: Bool, uid: UInt32) async throws {
        precondition(flag == "\\Seen" || flag == "\\Flagged")
        let tag = takeTag()
        try await reader.send("\(tag) UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
        let (_, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
    }

    /// Moves one message out of the open folder, and returns its UID in the other one, when the server says.
    func move(_ uid: UInt32, to mailbox: String) async throws -> (validity: UInt32, uid: UInt32)? {
        guard Self.isMailboxName(mailbox) else { throw OutsideMailProblem.unexpected }
        let tag = takeTag()
        try await reader.send("\(tag) UID MOVE \(uid) \(Self.quoted(mailbox))")
        let (untagged, answer) = try await readUntilTagged(tag)
        if answer.status == .ok {
            return Self.copied(answer.code) ?? untagged.lazy.compactMap { Self.copied(fromLine: $0) }.first
        }
        guard answer.status == .bad else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        // No MOVE: copy it, then take it out of here.
        let copy = takeTag()
        try await reader.send("\(copy) UID COPY \(uid) \(Self.quoted(mailbox))")
        let (_, copied) = try await readUntilTagged(copy)
        guard copied.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(copied.text)) }
        let mark = takeTag()
        try await reader.send("\(mark) UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try await readUntilTagged(mark)
        let expunge = takeTag()
        try await reader.send("\(expunge) UID EXPUNGE \(uid)")
        _ = try await readUntilTagged(expunge)
        return Self.copied(copied.code)
    }

    /// `COPYUID 1690000000 512 1033`: the other folder's UIDVALIDITY and the message's new UID there.
    static func copied(_ code: String?) -> (validity: UInt32, uid: UInt32)? {
        guard let parts = code?.split(separator: " "), parts.count == 4, parts[0].uppercased() == "COPYUID",
              let validity = UInt32(parts[1]), let uid = UInt32(parts[3]) else { return nil }
        return (validity, uid)
    }

    static func copied(fromLine line: Data) -> (validity: UInt32, uid: UInt32)? {
        let text = String(decoding: line, as: UTF8.self)
        guard text.uppercased().hasPrefix("* OK ["), let close = text.firstIndex(of: "]") else { return nil }
        return copied(String(text[text.index(text.startIndex, offsetBy: 6)..<close]))
    }

    /// The flags of Inbox messages by UID, without reading them.
    func flags(_ uids: [UInt32]) async throws -> [UInt32: (isUnread: Bool, isStarred: Bool)] {
        guard !uids.isEmpty else { return [:] }
        let tag = takeTag()
        try await reader.send("\(tag) UID FETCH \(Self.uidSet(uids)) (UID FLAGS)")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        var found: [UInt32: (isUnread: Bool, isStarred: Bool)] = [:]
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("* "), text.uppercased().contains(" FETCH ("),
                  let range = text.range(of: "UID ", options: .caseInsensitive),
                  let uid = UInt32(text[range.upperBound...].prefix { $0.isNumber }),
                  let open = text.range(of: "FLAGS (", options: .caseInsensitive) else { continue }
            let flags = text[open.upperBound...].prefix { $0 != ")" }.lowercased()
            found[uid] = (!flags.contains("\\seen"), flags.contains("\\flagged"))
        }
        return found
    }

    /// `1:4,7,9:12`, so a long run of UIDs stays a short command.
    static func uidSet(_ uids: [UInt32]) -> String {
        var runs: [String] = []
        var sorted = Set(uids).sorted()[...]
        while let first = sorted.first {
            var last = first
            sorted = sorted.dropFirst()
            while let next = sorted.first, next == last + 1 { last = next; sorted = sorted.dropFirst() }
            runs.append(first == last ? "\(first)" : "\(first):\(last)")
        }
        return runs.joined(separator: ",")
    }
}

/// What an iCloud Inbox showed on this open: its UIDVALIDITY, and the flags of each message from `since`.
public struct OutsideIMAPInbox: Equatable, Sendable {
    let validity: UInt32
    let since: Date
    let flags: [UInt32: OutsideFlags]
    /// Every message since `since` was looked at, so one that isn't here has left the Inbox.
    let complete: Bool

    struct OutsideFlags: Equatable, Sendable {
        let isUnread: Bool
        let isStarred: Bool
    }

    /// What it shows for one message that's where it was downloaded, or at `location` in the Inbox.
    func seen(providerID: String, location: OutsideIMAPLocation?, received: Date) -> OutsideSeen {
        let validity: UInt32, uid: UInt32
        if let location {
            guard location.mailbox == "INBOX" else { return .unknown }
            (validity, uid) = (location.validity, location.uid)
        } else {
            let parts = providerID.split(separator: ".")
            guard parts.count == 2, let v = UInt32(parts[0]), let u = UInt32(parts[1]) else { return .unknown }
            (validity, uid) = (v, u)
        }
        guard validity == self.validity else { return .unknown }
        if let found = flags[uid] { return OutsideSeen(place: .inbox, isUnread: found.isUnread, isStarred: found.isStarred) }
        // Gone from the Inbox at iCloud. Where to isn't known, so it's archived here.
        return complete && received >= since ? OutsideSeen(place: .archive) : .unknown
    }
}

/// Puts Totality's changes to downloaded iCloud mail into iCloud, over one connection.
struct OutsideIMAPWriter {
    let connection: IMAPConnection
    private var mailboxes: [OutsidePlace: String]?
    private var selected: (name: String, validity: UInt32)?

    init(connection: IMAPConnection) { self.connection = connection }

    /// Returns where it is afterwards, or nil when it can't be found to change.
    mutating func change(
        providerID: String, from: OutsideRemoteState, to: OutsideRemoteState
    ) async throws -> OutsideRemoteState? {
        let location: OutsideIMAPLocation
        if let moved = from.location {
            location = moved
        } else {
            let parts = providerID.split(separator: ".")
            guard parts.count == 2, let validity = UInt32(parts[0]), let uid = UInt32(parts[1]) else { return nil }
            location = OutsideIMAPLocation(mailbox: "INBOX", validity: validity, uid: uid)
        }
        guard location != .lost else { return nil }
        if selected?.name != location.mailbox {
            selected = (location.mailbox, try await connection.select(location.mailbox))
        }
        // The folder's UIDs started over, so this UID isn't this message any more.
        guard selected?.validity == location.validity else { return nil }
        if to.isUnread != from.isUnread { try await connection.setFlag("\\Seen", on: !to.isUnread, uid: location.uid) }
        if to.isStarred != from.isStarred { try await connection.setFlag("\\Flagged", on: to.isStarred, uid: location.uid) }
        var after = to
        after.location = from.location
        guard to.place != from.place else { return after }
        if mailboxes == nil { mailboxes = try await connection.specialMailboxes() }
        // No such folder at iCloud: it stays where it is there.
        guard let target = mailboxes?[to.place], target != location.mailbox else { return after }
        if let moved = try await connection.move(location.uid, to: target) {
            after.location = OutsideIMAPLocation(mailbox: target, validity: moved.validity, uid: moved.uid)
        } else {
            // Moved, but the server didn't say its new UID, so it can't be followed any further.
            after.location = .lost
        }
        return after
    }
}

// MARK: - Sending changes

/// Puts Totality's changes to downloaded mail into each provider.
struct OutsideWriter: Sendable {
    let maker: any OutsideWireMaker
    let google: GoogleOAuth?

    struct Change: Sendable {
        let providerID: String
        let from: OutsideRemoteState
        let to: OutsideRemoteState
    }

    enum Outcome: Sendable, Equatable {
        /// Done, and this is where it is now.
        case done(OutsideRemoteState)
        /// It isn't where it was any more, so nothing more can be changed for it.
        case lost
    }

    /// Each change that went through, by provider ID. One the provider turns down is skipped; losing the
    /// connection or the sign-in stops the rest, which wait for the next open. A Gmail added when
    /// Totality could only read changes nothing until the person allows changes.
    func push(_ account: OutsideAccount, credential: OutsideCredential, changes: [Change]) async -> [String: Outcome] {
        guard !changes.isEmpty else { return [:] }
        var outcomes: [String: Outcome] = [:]
        switch credential {
        case .google(let grant):
            guard grant.canChange, let google, let token = try? await google.accessToken(for: grant) else { return [:] }
            for change in changes {
                do {
                    let found = try await google.change(change.providerID, from: change.from, to: change.to, accessToken: token)
                    outcomes[change.providerID] = found ? .done(change.to) : .lost
                } catch {
                    guard Self.isOnlyThisOne(error) else { break }
                }
            }
        case .appPassword(let password):
            guard let signIn = OutsideSignIn(provider: account.provider, address: account.address, appPassword: password),
                  let connection = try? await IMAPConnection.signIn(signIn, with: maker) else { return [:] }
            var writer = OutsideIMAPWriter(connection: connection)
            for change in changes {
                do {
                    if let after = try await writer.change(providerID: change.providerID, from: change.from, to: change.to) {
                        outcomes[change.providerID] = .done(after)
                    } else {
                        outcomes[change.providerID] = .lost
                    }
                } catch {
                    guard Self.isOnlyThisOne(error) else { break }
                }
            }
            await connection.signOut()
        }
        return outcomes
    }

    /// The provider turned this one change down, and the rest can still go.
    private static func isOnlyThisOne(_ error: any Error) -> Bool {
        switch error as? OutsideMailProblem {
        case .refused, .unexpected: true
        default: false
        }
    }
}
