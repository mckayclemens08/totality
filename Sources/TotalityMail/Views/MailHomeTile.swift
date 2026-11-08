import SwiftUI
import TotalityUI

/// Mail's big home tile: how much is unread, then the Inbox's newest conversations. Each opens itself.
/// Only the Inbox shows here, so nothing from Spam or Trash reaches the home page.
public struct MailHomeTile: View {
    private static let rows: [BigTileSize: Int] = [.medium: 1, .large: 3, .square: 5]

    private let model: MailModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Mail up after a conversation has been asked for.
    public init(model: MailModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private var conversations: [MailConversation] {
        model.homeConversations(Self.rows[size] ?? 1)
    }

    private var countLine: String {
        switch model.homeUnread {
        case 0: "No unread mail"
        case 1: "1 unread"
        case let count: "\(count) unread"
        }
    }

    public var body: some View {
        VStack(spacing: size == .medium ? Space.s3 : Space.s5) {
            header
            if conversations.isEmpty {
                Text("Your inbox is empty")
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
            } else {
                VStack(alignment: .leading, spacing: size == .square ? Space.s4 : Space.s3) {
                    ForEach(conversations) { conversation in
                        Row(conversation: conversation, me: model.mailbox.address, size: size)
                            .tileLink(label(for: conversation)) {
                                model.requestFromHome(conversation.id)
                                onOpen()
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        let theme = Theme.current
        let unread = model.homeUnread > 0
        return VStack(spacing: Space.s1) {
            Image(systemName: unread ? "envelope.badge" : "envelope")
                .font(.system(size: size == .medium ? Space.s5 : Space.s6))
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(countLine)
                .font(size == .medium ? Typeface.headline : Typeface.title)
                .foregroundStyle(unread ? theme.textPrimary.color : theme.textSecondary.color)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func label(for conversation: MailConversation) -> String {
        let who = conversation.heading(me: model.mailbox.address, showingRecipients: false)
        let place = conversation.latest.outsideAccount.map { ", in \($0.provider.name)" } ?? ""
        return (conversation.isUnread ? "Unread, \(who): \(conversation.subject)" : "\(who): \(conversation.subject)") + place
    }
}

private struct Row: View {
    let conversation: MailConversation
    let me: String
    let size: BigTileSize

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            // Unread shows as the one accent dot, so the row needs no other colour.
            Circle()
                .fill(conversation.isUnread ? theme.accent.color : Color.clear)
                .frame(width: Space.s2, height: Space.s2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(conversation.heading(me: me, showingRecipients: false))
                    .font(conversation.isUnread ? Typeface.headline : Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Text(subjectLine)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The subject, and which outside account it's in, as the issue's spec asks of a row.
    private var subjectLine: String {
        let subject = conversation.isUnreadable ? "Can't be opened" : conversation.subject
        guard let outside = conversation.latest.outsideAccount else { return subject }
        return "\(outside.provider.name) · \(subject)"
    }
}
