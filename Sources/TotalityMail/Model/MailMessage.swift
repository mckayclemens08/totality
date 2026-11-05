import Foundation

public struct MailAddress: Hashable, Codable, Sendable {
    public let name: String
    public let address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    public var displayName: String { name.isEmpty ? address : name }
    /// How a sender is remembered. Case doesn't change who an address belongs to.
    public var key: String { address.lowercased() }
    /// The part after the @, which is what a sender claims to be.
    public var domain: String { key.split(separator: "@").last.map(String.init) ?? key }
}

public enum MailFolder: Hashable, Codable, Sendable {
    case inbox, archive, sent, drafts, spam, trash
    case own(UUID)
}

public struct MailOwnFolder: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// What can change about a message after it arrives. This is what syncs between devices, sealed.
public struct MailMarks: Hashable, Codable, Sendable {
    public var folder: MailFolder
    public var isUnread: Bool
    public var isStarred: Bool
    public var trashedAt: Date?
    /// Sent mail and drafts go back where they came from, not to the Inbox.
    public var trashedFrom: MailFolder?

    public init(folder: MailFolder = .inbox, isUnread: Bool = false, isStarred: Bool = false, trashedAt: Date? = nil, trashedFrom: MailFolder? = nil) {
        self.folder = folder
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.trashedAt = trashedAt
        self.trashedFrom = trashedFrom
    }
}

extension MailMarks {
    /// Takes back one change and nothing made since: each part goes back only while it's still what
    /// that change left. Where a message is, with when and from where it was trashed, is one part.
    func undoing(_ after: MailMarks, back before: MailMarks) -> MailMarks {
        var marks = self
        if (folder, trashedAt, trashedFrom) == (after.folder, after.trashedAt, after.trashedFrom) {
            (marks.folder, marks.trashedAt, marks.trashedFrom) = (before.folder, before.trashedAt, before.trashedFrom)
        }
        if isUnread == after.isUnread { marks.isUnread = before.isUnread }
        if isStarred == after.isStarred { marks.isStarred = before.isStarred }
        return marks
    }
}

/// How a message travelled, which decides what can honestly be said about it. It comes from the path
/// the message took and never from its address: anyone can write a Totality address in a From line.
public enum MailRoute: Sendable, Hashable {
    case betweenAccounts, outside
}

/// Whether the sender's domain vouched for the message, from the checks written into its headers.
public enum MailProof: Sendable, Hashable {
    case proved, unproved
}

public enum MailDelivery: Sendable, Hashable {
    case fine
    /// It never left. The reason says why, and the text stays where it is.
    case notSent(String)
    /// It left, and the other end refused it.
    case bounced(String)
}

public enum MailBody: Sendable, Hashable {
    case plain(String)
    /// `text` is what the message says with no markup, for search and for when the page can't be shown.
    case html(String, text: String)
    /// Its seal didn't open, so nothing about it is known here.
    case unreadable

    var text: String {
        switch self {
        case .plain(let text), .html(_, let text): text
        case .unreadable: ""
        }
    }
}

public struct MailAttachment: Identifiable, Hashable, Sendable {
    public enum Preview: Sendable {
        case image, pdf, text
    }

    public let id: UUID
    public let name: String
    public let mimeType: String
    public let size: Int64

    public init(id: UUID = UUID(), name: String, mimeType: String, size: Int64) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }

    /// Only kinds the system opens in memory with nothing able to run. Anything else, HTML and SVG
    /// included, can still be saved. It's never drawn here.
    public var preview: Preview? {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/png", "image/gif", "image/heic", "image/webp": .image
        case "application/pdf": .pdf
        case "text/plain": .text
        default: nil
        }
    }
}

public struct MailMessage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let from: MailAddress
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let subject: String
    public let date: Date
    public let body: MailBody
    public let attachments: [MailAttachment]
    public let route: MailRoute?
    public let proof: MailProof
    public let delivery: MailDelivery
    public var marks: MailMarks

    public init(
        id: UUID = UUID(), conversationID: UUID, from: MailAddress, to: [MailAddress], cc: [MailAddress] = [],
        subject: String, date: Date, body: MailBody, attachments: [MailAttachment] = [],
        route: MailRoute?, proof: MailProof = .proved, delivery: MailDelivery = .fine, marks: MailMarks
    ) {
        self.id = id
        self.conversationID = conversationID
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.body = body
        self.attachments = attachments
        self.route = route
        self.proof = proof
        self.delivery = delivery
        self.marks = marks
    }

    /// A stored message whose seal won't open. Its date is the only thing the server keeps.
    public static func unreadable(id: UUID = UUID(), date: Date, marks: MailMarks) -> MailMessage {
        MailMessage(
            id: id, conversationID: id, from: MailAddress(address: ""), to: [], subject: "", date: date,
            body: .unreadable, route: nil, marks: marks
        )
    }

    public var isUnreadable: Bool { body == .unreadable }

    var preview: String {
        body.text.split(whereSeparator: \.isWhitespace).prefix(30).joined(separator: " ")
    }
}

/// Messages that belong together, as seen from one place, oldest first.
public struct MailConversation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let messages: [MailMessage]

    init(id: UUID, messages: [MailMessage]) {
        self.id = id
        self.messages = messages.sorted { $0.date < $1.date }
    }

    public var latest: MailMessage { messages[messages.count - 1] }
    public var subject: String { latest.subject.isEmpty ? "No subject" : latest.subject }
    public var isUnread: Bool { messages.contains { $0.marks.isUnread } }
    public var isStarred: Bool { messages.contains { $0.marks.isStarred } }
    public var hasAttachments: Bool { messages.contains { !$0.attachments.isEmpty } }
    public var isUnreadable: Bool { latest.isUnreadable }

    public var problem: MailDelivery {
        messages.reversed().map(\.delivery).first { $0 != .fine } ?? .fine
    }

    /// The other person, which is the reader's own address only when nobody else is involved.
    public func sender(me: String) -> MailAddress {
        messages.reversed().first { $0.from.key != me.lowercased() }?.from ?? latest.from
    }

    /// Who the row names: the sender, or who it went to when the reader wrote it.
    public func heading(me: String, showingRecipients: Bool) -> String {
        if isUnreadable { return "Can't be opened" }
        guard showingRecipients else { return sender(me: me).displayName }
        let mine = messages.reversed().first { $0.from.key == me.lowercased() } ?? latest
        let people = mine.to.map(\.displayName)
        return people.isEmpty ? "No recipients yet" : "To \(ListFormatter.localizedString(byJoining: people))"
    }

    func matches(_ query: String) -> Bool {
        messages.contains { message in
            let people = ([message.from] + message.to + message.cc).flatMap { [$0.name, $0.address] }
            let names = message.attachments.map(\.name)
            return ([message.subject, message.body.text] + people + names).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
