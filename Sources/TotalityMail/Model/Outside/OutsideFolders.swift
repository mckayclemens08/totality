import Foundation

/// iCloud's folders as places (issue 43, decision 3). The person's own folders show under the account in
/// Mailboxes, the way Gmail's labels do. Archive, Junk and Trash are Totality's own Archive, Spam and
/// Trash. A message is followed from folder to folder by its `Message-ID`, because IMAP gives a message a
/// new UID in every folder it lands in.
public enum OutsideFolders {
    /// What a folder is to Totality.
    public enum Kind: String, Codable, Sendable {
        case inbox, archive, spam, trash
        /// One the person made. Mail in it is archived here, and also shows in the place for it.
        case own

        var place: OutsidePlace {
            switch self {
            case .inbox: .inbox
            case .archive, .own: .archive
            case .spam: .spam
            case .trash: .trash
            }
        }
    }

    /// Each folder worth looking in, and what it is. Sent and Drafts are left out, because Totality keeps
    /// its own of each, and so are folders that can't be opened.
    static func kinds(_ listed: [(flags: Set<String>, name: String)]) -> [(name: String, kind: Kind)] {
        let special = specialNames(listed)
        var found: [(name: String, kind: Kind)] = []
        for (flags, name) in listed {
            if name.caseInsensitiveCompare("INBOX") == .orderedSame { continue }
            if !flags.isDisjoint(with: ["\\noselect", "\\nonexistent", "\\sent", "\\drafts", "\\all", "\\flagged"]) { continue }
            if ["Sent Messages", "Sent", "Drafts", "Notes"].contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
            let kind: Kind = if name == special[.archive] { .archive } else if name == special[.spam] { .spam }
                else if name == special[.trash] { .trash } else { .own }
            found.append((name, kind))
        }
        return found
    }

    /// The folders that Archive, Junk and Trash are, by their special-use flags, or their usual names.
    static func specialNames(_ listed: [(flags: Set<String>, name: String)]) -> [OutsidePlace: String] {
        var found: [OutsidePlace: String] = [:]
        for (flags, name) in listed {
            if flags.contains("\\archive") { found[.archive] = found[.archive] ?? name }
            if flags.contains("\\junk") { found[.spam] = found[.spam] ?? name }
            if flags.contains("\\trash") { found[.trash] = found[.trash] ?? name }
        }
        let names = listed.map(\.name)
        func named(_ options: [String]) -> String? {
            options.lazy.compactMap { option in names.first { $0.caseInsensitiveCompare(option) == .orderedSame } }.first
        }
        found[.archive] = found[.archive] ?? named(["Archive"])
        found[.spam] = found[.spam] ?? named(["Junk", "Spam"])
        found[.trash] = found[.trash] ?? named(["Deleted Messages", "Trash"])
        found[.inbox] = "INBOX"
        return found
    }

    /// The `Message-ID` in a message's header, without its angle brackets. Only the header is read.
    static func messageID(_ raw: Data) -> String? {
        var header = raw.prefix(64 * 1024)
        if let end = header.range(of: Data("\r\n\r\n".utf8)) ?? header.range(of: Data("\n\n".utf8)) {
            header = header[..<end.lowerBound]
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.lowercased().hasPrefix("message-id:") {
            var value = String(line.dropFirst(11))
            // Folded onto the next line.
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, index + 1 < lines.count { value = lines[index + 1] }
            return cleaned(value)
        }
        return nil
    }

    /// `<abc@example.com>` as `abc@example.com`, or nil when it's not one.
    static func cleaned(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            text = String(text[text.index(after: open)..<close])
        }
        guard (3...998).contains(text.count), text.contains("@"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }
}

extension OutsideIMAPLocation {
    /// Where a downloaded message was when it came. An Inbox message's ID is `validity.uid`, kept as it
    /// always was; one from another folder has the folder's name in front, after a tab, which no IMAP
    /// name Totality accepts can hold.
    static func downloaded(_ providerID: String) -> OutsideIMAPLocation? {
        var mailbox = "INBOX", rest = Substring(providerID)
        if let tab = providerID.firstIndex(of: "\t") {
            mailbox = String(providerID[..<tab])
            rest = providerID[providerID.index(after: tab)...]
            guard IMAPConnection.isMailboxName(mailbox) else { return nil }
        }
        let parts = rest.split(separator: ".")
        guard parts.count == 2, let validity = UInt32(parts[0]), let uid = UInt32(parts[1]) else { return nil }
        return OutsideIMAPLocation(mailbox: mailbox, validity: validity, uid: uid)
    }

    var providerID: String {
        mailbox == "INBOX" ? "\(validity).\(uid)" : "\(mailbox)\t\(validity).\(uid)"
    }
}

/// One iCloud folder as this open saw it: each message from `since`, by UID.
public struct OutsideIMAPFolder: Equatable, Sendable {
    public let name: String
    public let kind: OutsideFolders.Kind
    public let validity: UInt32
    public let entries: [UInt32: OutsideIMAPEntry]
    /// Every message since `since` was looked at.
    public let complete: Bool
}

public struct OutsideIMAPEntry: Equatable, Sendable {
    public let messageID: String?
    public let isUnread: Bool
    public let isStarred: Bool
}

extension IMAPConnection {
    /// Every folder iCloud has, with its flags lowercased.
    func folders() async throws -> [(flags: Set<String>, name: String)] {
        let tag = takeTag()
        try await reader.send("\(tag) LIST \"\" \"*\"")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        return untagged.compactMap(Self.listed)
    }

    /// Opens a folder read-only and returns its UIDVALIDITY.
    func examine(_ mailbox: String) async throws -> UInt32 {
        guard Self.isMailboxName(mailbox) else { throw OutsideMailProblem.unexpected }
        let tag = takeTag()
        try await reader.send("\(tag) EXAMINE \(Self.quoted(mailbox))")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            if let range = text.range(of: "[UIDVALIDITY ", options: .caseInsensitive),
               let value = UInt32(text[range.upperBound...].prefix { $0.isNumber }) { return value }
        }
        throw OutsideMailProblem.unexpected
    }

    /// Each message's flags and `Message-ID`, read from its header only and without marking it read.
    func entries(_ uids: [UInt32]) async throws -> [UInt32: OutsideIMAPEntry] {
        guard !uids.isEmpty else { return [:] }
        let tag = takeTag()
        try await reader.send("\(tag) UID FETCH \(Self.uidSet(uids)) (UID FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        var found: [UInt32: OutsideIMAPEntry] = [:]
        for line in untagged {
            guard let (uid, entry) = Self.entry(line) else { continue }
            found[uid] = entry
        }
        return found
    }

    /// One `* n FETCH (UID 5 FLAGS (\Seen) BODY[HEADER.FIELDS (MESSAGE-ID)] {40}\r\n...)` answer.
    static func entry(_ line: Data) -> (UInt32, OutsideIMAPEntry)? {
        let bytes = [UInt8](line)
        var head = bytes[...], messageID: String?
        if let open = bytes.firstIndex(of: UInt8(ascii: "{")), let close = bytes[open...].firstIndex(of: UInt8(ascii: "}")),
           let count = Int(String(decoding: bytes[(open + 1)..<close], as: UTF8.self)), close + 3 + count <= bytes.count {
            let literal = Data(bytes[(close + 3)..<(close + 3 + count)])
            messageID = OutsideFolders.messageID(literal + Data("\r\n\r\n".utf8))
            head = bytes[..<open] + bytes[(close + 3 + count)...]
        }
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("* "), text.uppercased().contains(" FETCH ("),
              let range = text.range(of: "UID ", options: .caseInsensitive),
              let uid = UInt32(text[range.upperBound...].prefix { $0.isNumber }) else { return nil }
        let flags: String
        if let start = text.range(of: "FLAGS (", options: .caseInsensitive) {
            flags = String(text[start.upperBound...].prefix { $0 != ")" }).lowercased()
        } else {
            flags = ""
        }
        return (uid, OutsideIMAPEntry(messageID: messageID, isUnread: !flags.contains("\\seen"), isStarred: flags.contains("\\flagged")))
    }
}
