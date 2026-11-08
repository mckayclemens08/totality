import Foundation
import TotalityCore

/// A file waiting to go with a draft. The bytes are part of the draft, sealed with it.
public struct MailDraftAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

/// The message a draft answers or passes on.
public struct MailDraftOrigin: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case reply, forward
    }

    public let kind: Kind
    /// The original's ID on this device, so the screens can show it.
    public let message: UUID
    /// The original's `Message-ID` and the thread before it, which a reply carries on.
    public let messageID: String?
    public let references: [String]

    public init(kind: Kind, message: UUID, messageID: String?, references: [String]) {
        self.kind = kind
        self.message = message
        self.messageID = messageID
        self.references = references
    }
}

/// Something being written. It's saved sealed and syncs between devices, and it only leaves when the
/// person presses Send.
public struct MailDraft: Identifiable, Hashable, Codable, Sendable {
    /// As the spec agreed in issue 37: To, Cc, and Bcc together.
    public static let maxRecipients = 10
    /// Messages stop at 25 MB, written out.
    public static let maxBytes = 25 * 1_024 * 1_024

    public let id: UUID
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var body: String
    public var attachments: [MailDraftAttachment]
    public var origin: MailDraftOrigin?
    /// The outside account it goes from, through that provider. Nil is the Totality address.
    public var from: UUID?

    public init(
        id: UUID = UUID(), to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [], subject: String = "",
        body: String = "", attachments: [MailDraftAttachment] = [], origin: MailDraftOrigin? = nil, from: UUID? = nil
    ) {
        self.from = from
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.origin = origin
    }

    /// Everyone it goes to, once each, in the order they were written.
    public var recipients: [MailAddress] {
        var seen = Set<String>()
        return (to + cc + bcc).filter { seen.insert($0.key).inserted }
    }

    /// Someone to send to, and no more than ten.
    public func checkRecipients() throws {
        let count = recipients.count
        guard count > 0 else { throw MailSendError.noRecipients }
        guard count <= Self.maxRecipients else { throw MailSendError.tooManyRecipients(count) }
    }

    public var isEmpty: Bool {
        recipients.isEmpty && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    // MARK: Replying and forwarding

    /// To whoever wrote the original, or where they asked replies to go. Replying to your own message
    /// goes to the people it went to.
    public static func reply(to message: MailMessage, me: String) -> MailDraft {
        var draft = answering(message)
        draft.to = primary(message, me: me)
        return draft
    }

    /// Everyone on the original except you.
    public static func replyAll(to message: MailMessage, me: String) -> MailDraft {
        var draft = answering(message)
        let to = primary(message, me: me)
        var seen = Set(to.map(\.key))
        var others = (message.to + message.cc).filter { !isMe($0, me) && seen.insert($0.key).inserted }
        if to.isEmpty, !others.isEmpty { draft.to = [others.removeFirst()] } else { draft.to = to }
        draft.cc = others
        return draft
    }

    /// The original's text below a short header, with whichever of its files the screens pass along.
    public static func forward(_ message: MailMessage, attachments: [MailDraftAttachment] = []) -> MailDraft {
        var lines = ["", "", "---------- Forwarded message ----------", "From: \(describe(message.from))"]
        lines.append("Date: \(written(message.date))")
        lines.append("Subject: \(message.subject)")
        if !message.to.isEmpty { lines.append("To: \(message.to.map(describe).joined(separator: ", "))") }
        if !message.cc.isEmpty { lines.append("Cc: \(message.cc.map(describe).joined(separator: ", "))") }
        lines += ["", message.body.text]
        return MailDraft(
            subject: prefixed("Fwd", message.subject), body: lines.joined(separator: "\n"), attachments: attachments,
            origin: MailDraftOrigin(kind: .forward, message: message.id, messageID: message.messageID, references: message.references)
        )
    }

    private static func answering(_ message: MailMessage) -> MailDraft {
        let quoted = message.body.text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        let body = "\n\nOn \(written(message.date)), \(message.from.displayName) wrote:\n" + quoted
        return MailDraft(
            subject: prefixed("Re", message.subject), body: body,
            origin: MailDraftOrigin(kind: .reply, message: message.id, messageID: message.messageID, references: message.references)
        )
    }

    private static func primary(_ message: MailMessage, me: String) -> [MailAddress] {
        if isMe(message.from, me) { return message.to.filter { !isMe($0, me) } }
        return message.replyTo.isEmpty ? [message.from] : message.replyTo
    }

    /// Your own address in any case and with any `+tag`.
    static func isMe(_ address: MailAddress, _ me: String) -> Bool {
        let mine = MailAddress(address: me)
        if let name = mine.totalityName { return address.totalityName == name }
        return address.key == mine.key
    }

    /// `Re: ` once, never `Re: Re: `, and the same for forwarding. Other languages' prefixes count too.
    static func prefixed(_ prefix: String, _ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let pattern = prefix == "Re" ? /^(re|aw|sv|vs|antw)(\[\d+\])?\s*:/.ignoresCase() : /^(fwd?|wg|tr|rv)(\[\d+\])?\s*:/.ignoresCase()
        if trimmed.prefixMatch(of: pattern) != nil { return trimmed }
        return "\(prefix): \(trimmed)"
    }

    private static func describe(_ address: MailAddress) -> String {
        address.name.isEmpty ? address.address : "\(address.name) <\(address.address)>"
    }

    private static func written(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// How a send went, for each person it was meant for. Nothing fails quietly: someone it couldn't
/// reach is named here with why.
public struct MailSendResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case delivered
        /// Nobody has this Totality address, or they haven't opened Mail yet.
        case noSuchAddress
        /// Outside sending is switched off on the server, so this one wasn't sent.
        case outsideNotYet
        /// Handed to the outside world. What happens after is up to the other end, and a bounce comes
        /// back as mail.
        case sentOutside
        /// Accounts under seven days old can only mail other Totality accounts.
        case newAccount
        /// Today's twenty outside recipients are used.
        case dailyLimit
        /// Totality's outside sending for the month is used up.
        case monthLimit
        /// Too much was sending at once, or the service was busy. Nothing went.
        case busy
        /// The sending service turned this address down.
        case refused
        /// It may have gone. Sending again could send it twice.
        case mayHaveSent
        case notAnAddress
        case recipientFull
        case tooBig
        case offline
        case failed
        /// The server gave a different key for this person than the one pinned for them, so nothing went.
        case keyChanged

        /// It left, or may have, so it comes off the draft and goes in Sent: sending it again could
        /// send it twice.
        public var left: Bool { self == .delivered || self == .sentOutside || self == .mayHaveSent }
    }

    public struct Recipient: Equatable, Sendable {
        public let address: MailAddress
        public let outcome: Outcome

        public init(address: MailAddress, outcome: Outcome) {
            self.address = address
            self.outcome = outcome
        }
    }

    public let recipients: [Recipient]
    /// The Sent copy, when anyone got it.
    public let sent: UUID?
    /// False when the Sent copy couldn't be kept on the server. It's in Sent on this device, and the
    /// next open tries the server again, so it isn't lost.
    public let keptCopy: Bool
    /// What's left to send, when some didn't get it: the draft stays, with only those people on it.
    public let remaining: MailDraft?

    public init(recipients: [Recipient], sent: UUID?, keptCopy: Bool, remaining: MailDraft?) {
        self.recipients = recipients
        self.sent = sent
        self.keptCopy = keptCopy
        self.remaining = remaining
    }

    public var deliveredToEveryone: Bool { recipients.allSatisfy(\.outcome.left) }
}

public enum MailSendError: Error, Equatable {
    case noRecipients
    case tooManyRecipients(Int)
    /// Written out, it's over 25 MB.
    case tooBig
    /// The account's username isn't known yet, so there's no From address to send as.
    case noAddress
    /// The outside account it's from was removed, or its Send switch is off.
    case cannotSendFrom
}
