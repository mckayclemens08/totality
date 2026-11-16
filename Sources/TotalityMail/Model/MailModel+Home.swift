import Foundation

/// Someone whose unread mail is in the Inbox, for the medium tile's faces.
public struct MailHomeSender: Identifiable, Equatable, Sendable {
    /// The address, lowercased.
    public let id: String
    public let name: String
    /// How many unread conversations they're the sender of.
    public let unread: Int
    /// Their newest unread conversation, which a tap opens.
    public let conversation: UUID
}

/// One account's unread count, for the chips on the medium tile and the strip on the square.
public struct MailHomeAccount: Identifiable, Equatable, Sendable {
    /// Nil for the Totality address.
    public let id: UUID?
    public let name: String
    public let unread: Int
}

/// What each size of Mail's home tile shows (issue 127). Only the Inbox reaches the home page, so
/// nothing from Spam or Trash is ever on it, and nothing here changes mail except what a press asks for.
extension MailModel {
    static let homeFaces = 4
    static let homeRows = 4
    static let homeQuietRows = 3
    /// How much of an email the square shows: its first paragraphs, up to this many characters.
    static let homeParagraphs = 3
    static let homeCharacters = 600

    /// The Inbox's unread conversations, newest first. One that can't be opened has nothing to show.
    public var homeUnreadConversations: [MailConversation] {
        mailbox.conversations(in: .inbox).filter { $0.isUnread && !$0.isUnreadable }
    }

    /// Up to four people with unread mail, newest first, with how many conversations each has unread.
    public var homeSenders: [MailHomeSender] {
        var order: [String] = []
        var found: [String: MailHomeSender] = [:]
        for conversation in homeUnreadConversations {
            let sender = conversation.sender(me: mailbox.address)
            if let seen = found[sender.key] {
                found[sender.key] = MailHomeSender(id: seen.id, name: seen.name, unread: seen.unread + 1, conversation: seen.conversation)
            } else {
                order.append(sender.key)
                found[sender.key] = MailHomeSender(id: sender.key, name: sender.displayName, unread: 1, conversation: conversation.id)
            }
        }
        return order.prefix(Self.homeFaces).compactMap { found[$0] }
    }

    /// Unread per account, once there's an outside account beside the Totality address. Alone, the
    /// Totality address is the only one, and the big count already says it.
    public var homeAccounts: [MailHomeAccount] {
        let accounts = mailbox.outsideAccounts
        guard !accounts.isEmpty else { return [] }
        let unread = homeUnreadConversations
        let own = unread.filter { $0.latest.outsideAccount == nil }.count
        return [MailHomeAccount(id: nil, name: "Totality", unread: own)] + accounts.map { account in
            MailHomeAccount(
                id: account.id, name: MailAccountChips.name(account, among: accounts),
                unread: unread.filter { $0.latest.outsideAccount?.id == account.id }.count
            )
        }
    }

    /// The large tile's rows: the newest unread, or with none, the most recent, shown quieter.
    public var homeRows: (conversations: [MailConversation], caughtUp: Bool) {
        let unread = homeUnreadConversations
        if unread.isEmpty { return (homeConversations(Self.homeQuietRows), true) }
        return (Array(unread.prefix(Self.homeRows)), false)
    }

    /// The email the square has open: the one Next moved to while it's still unread, or the newest.
    public var homeOpen: MailConversation? {
        let unread = homeUnreadConversations
        return unread.first { $0.id == homeShown } ?? unread.first
    }

    /// The unread conversation after the open one, going round to the newest. Nil when it's the only one.
    public var homeNext: MailConversation? {
        let unread = homeUnreadConversations
        guard unread.count > 1, let open = homeOpen, let index = unread.firstIndex(of: open) else { return nil }
        return unread[(index + 1) % unread.count]
    }

    public func showNextOnHome() {
        homeShown = homeNext?.id
    }

    /// What the square shows of an email: its first paragraphs as plain text, never its pictures or links.
    public static func opening(of message: MailMessage) -> String {
        let paragraphs = message.body.text
            .components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .prefix(homeParagraphs)
        let text = paragraphs.joined(separator: "\n\n")
        guard text.count > homeCharacters else { return text }
        return String(text.prefix(homeCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Reply pressed on the home page: Mail opens on the conversation with a reply started. Nothing is
    /// sent until the person presses Send there.
    public func requestReplyFromHome(_ conversation: UUID) {
        requestFromHome(conversation)
        requestedReply = conversation
    }

    /// Archive or Mark read from the home page, the same as in Mail, so Undo there takes it back.
    /// Deleting isn't offered on the home page at all.
    public func performFromHome(_ action: MailHomeAction, on conversation: MailConversation) async {
        switch action {
        case .archive: await perform(.archive, on: [conversation])
        case .markRead: await perform(.markRead, on: [conversation])
        }
    }
}

/// The only things a home tile can do to mail.
public enum MailHomeAction: Sendable {
    case archive, markRead
}
