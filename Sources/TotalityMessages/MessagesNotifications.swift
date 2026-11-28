import Foundation
import TotalityCore

/// Messages' part of the notifications system (issue 232). The homeserver wakes the phone through
/// `server/push` with nothing but "look again"; this reads the chats on the phone, where the messages are
/// decrypted, and writes the alert. Reply and Mark read work from the lock screen.
@MainActor
public final class MessagesNotifications: NotificationSource {
    public static let message = NotificationKind(module: .messages, key: "message", name: "New messages", detail: "Reply or mark read from the lock screen")
    public static let request = NotificationKind(module: .messages, key: "request", name: "Message requests", detail: "A first message from someone new")

    /// How long a wake waits for the first sync to bring the newest messages in.
    static let settle: Duration = .seconds(10)

    public let module = ModuleID.messages
    public let kinds = [message, request]

    private let model: MessagesModel
    private let cursor: NotificationCursor
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date

    public init(model: MessagesModel, defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = Date.init) {
        self.model = model
        self.defaults = defaults
        cursor = NotificationCursor("messages", defaults: defaults)
        self.clock = clock
    }

    /// Initializes the notification cursor on foreground startup so the first background push doesn't
    /// get dropped setting the baseline.
    public func primeCursorIfNeeded() {
        if cursor.date == nil { cursor.date = clock() }
    }

    public func newNotifications() async -> [AppNotification] {
        guard let since = cursor.date else {
            cursor.date = clock()
            return []
        }
        if model.phase != .ready { await model.connect() } else { await model.wakeSync() }
        guard model.phase == .ready else { return [] }
        // The sync that just started may take a moment to bring in what woke the phone.
        let deadline = ContinuousClock.now + Self.settle
        while Self.newest(model.chats + model.requests) <= since, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let notes = Self.notes(chats: model.chats, requests: model.requests, since: since, muted: MutedChats.all(defaults))
        cursor.date = max(since, Self.newest(model.chats + model.requests))
        return notes
    }

    static func newest(_ chats: [ChatSummary]) -> Date {
        chats.compactMap(\.lastActivity).max() ?? .distantPast
    }

    /// One alert per chat with something unread from someone else since `since`, and one per new request.
    static func notes(chats: [ChatSummary], requests: [ChatSummary], since: Date, muted: Set<String> = []) -> [AppNotification] {
        var notes: [AppNotification] = []
        for chat in chats {
            guard chat.unread > 0, !muted.contains(chat.id), let sender = chat.lastSender, let at = chat.lastActivity, at > since else { continue }
            let who = MessagesUsername.display(sender)
            let target = NotificationTarget(module: .messages, kind: "chat", item: chat.id)
            notes.append(AppNotification(
                id: "messages.\(chat.id).\(Int(at.timeIntervalSince1970 * 1000))", kind: message,
                title: chat.isGroup ? "\(who) in \(chat.title)" : chat.title, body: chat.lastLine ?? "New message",
                isPrivate: true, thread: chat.id, target: target, actions: [.reply, .markRead], date: at
            ))
        }
        for chat in requests {
            guard let at = chat.lastActivity, at > since else { continue }
            let who = chat.from.map(MessagesUsername.display) ?? chat.title
            notes.append(AppNotification(
                id: "messages.request.\(chat.id)", kind: request, title: "Message request from \(who)",
                body: "Open Messages to accept or decline.", thread: chat.id,
                target: NotificationTarget(module: .messages, kind: "chat", item: chat.id), date: at
            ))
        }
        return notes
    }

    public func badgeCount() -> Int { model.chats.reduce(0) { $0 + $1.unread } }

    public func prepareToOpen(_ target: NotificationTarget) {
        guard target.kind == "chat" else { return }
        model.requestedChat = target.item
    }

    public func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async {
        guard target.kind == "chat", action == .reply || action == .markRead else { return }
        if model.phase != .ready { await model.connect() }
        guard let service = model.connectedService, let channel = try? await service.openChat(target.item) else { return }
        defer { channel.close() }
        if action == .reply, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // Sent the same way as from the chat, so it's encrypted on the phone like any message.
            try? await channel.send(text, replyingTo: nil)
        }
        await channel.markRead(share: MessagesPreferences.shareReadAndTyping(defaults))
    }
}
