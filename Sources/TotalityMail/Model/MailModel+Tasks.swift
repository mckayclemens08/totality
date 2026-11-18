import Foundation
import TotalityCore

// MARK: - Tasks (issue 123, step 4)

extension MailModel {
    public var canAddToTasks: Bool { taskMaker != nil }

    /// "Add to Tasks" titles the task from the subject and keeps a link back. "Waiting for reply" also
    /// ticks itself off when anyone else answers in this conversation. Both go straight to the Inbox.
    public func addToTasks(_ conversation: MailConversation, waiting: Bool) async {
        guard let taskMaker, !conversation.isUnreadable else { return }
        let sender = conversation.sender(me: mailbox.address)
        let when = conversation.latest.date.formatted(date: .abbreviated, time: .shortened)
        let source = TaskSource(
            module: .mail, itemID: conversation.id.uuidString, title: conversation.subject,
            detail: "\(sender.displayName) · \(when)",
            waiting: waiting ? TaskSource.Waiting(since: max(today, conversation.latest.date)) : nil
        )
        let title = waiting ? "Hear back from \(sender.displayName): \(conversation.subject)" : conversation.subject
        do {
            let made = try await taskMaker.makeTask(TaskDraft(title: title, source: source))
            notice = made.line
        } catch {
            notice = "That didn't make it to Tasks. Try again."
        }
    }

    /// For each conversation asked about, the first message after the date that someone else sent. Sent
    /// mail and drafts are the person's own, so they never count.
    public func replies(to waiting: [String: Date]) -> [String: Reply] {
        let me = mailbox.address.lowercased()
        var found: [String: Reply] = [:]
        for message in mailbox.messages {
            let key = message.conversationID.uuidString
            guard let since = waiting[key], message.date > since, !message.isUnreadable,
                  message.marks.folder != .sent, message.marks.folder != .drafts, message.from.key != me
            else { continue }
            if let earlier = found[key], earlier.at <= message.date { continue }
            found[key] = Reply(at: message.date, from: message.from.displayName)
        }
        return found
    }

    /// Whether a task's conversation is still on this device. Unknown until Mail has loaded.
    public func hasConversation(_ id: String) -> Bool? {
        guard phase == .ready else { return nil }
        guard let uuid = UUID(uuidString: id) else { return false }
        return mailbox.messages.contains { $0.conversationID == uuid && $0.marks.folder != .trash }
    }
}
