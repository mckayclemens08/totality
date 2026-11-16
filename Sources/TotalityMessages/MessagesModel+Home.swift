import Foundation

/// What each size of the Messages home tile shows (issue 127). The tile shows message text, which the
/// owner agreed to in the issue; search still never does. Nothing is sent from the home page except a
/// heart the person double-tapped. Replies are written in the chat, which Reply opens.
extension MessagesModel {
    static let homeFaceCount = 4
    static let homeRowCount = 3
    static let homeBubbleCount = 4
    static let homeSwitcherCount = 5

    /// The medium tile's faces: chats with something unread, or with none, the most recent. Totality
    /// keeps no count of who you talk to most, so the most recent stand in for them.
    public var homeFaces: (chats: [ChatSummary], hasUnread: Bool) {
        let unread = chats.filter { $0.unread > 0 }
        if unread.isEmpty { return (Array(chats.prefix(Self.homeFaceCount)), false) }
        return (Array(unread.prefix(Self.homeFaceCount)), true)
    }

    /// The large tile's rows: the three most recent chats.
    public var homeRows: [ChatSummary] {
        Array(chats.prefix(Self.homeRowCount))
    }

    /// The chat the square shows: the one picked from its faces, or the newest with something unread,
    /// or the newest.
    public var homeTarget: ChatSummary? {
        chats.first { $0.id == homePicked } ?? chats.first { $0.unread > 0 } ?? chats.first
    }

    /// The faces across the top of the square: unread chats first, then the most recent.
    public var homeSwitcher: [ChatSummary] {
        let unread = chats.filter { $0.unread > 0 }
        let rest = chats.filter { $0.unread == 0 }
        return Array((unread + rest).prefix(Self.homeSwitcherCount))
    }

    /// A row's last line. A group's names who said it, unless it was you.
    public func homeLastLine(of chat: ChatSummary) -> String? {
        guard let text = chat.lastMessage else { return nil }
        guard chat.isGroup, let sender = chat.lastSender else { return text }
        return "\(TileNames.first(people.name(ofMatrixID: sender))): \(text)"
    }

    /// The square's last few messages.
    public var homeBubbles: [ChatMessage] {
        Array((homeChat?.messages ?? []).suffix(Self.homeBubbleCount))
    }

    /// Opens the square's chat to look at, without marking it read. Opening another closes the last.
    public func showOnHome() async {
        guard phase == .ready, let target = homeTarget else { return closeHome() }
        if homeChat?.chatID == target.id { return }
        closeHome()
        guard let chat = try? await open(target.id) else { return }
        // Another chat may have been asked for while this one opened.
        guard homeChat == nil, homeTarget?.id == target.id else { return chat.close() }
        homeChat = chat
        await chat.start(markingRead: false)
    }

    public func closeHome() {
        homeChat?.close()
        homeChat = nil
    }
}

/// A first name, for a group's last line.
enum TileNames {
    static func first(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }
}
