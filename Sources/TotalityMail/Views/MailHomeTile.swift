import SwiftUI
import TotalityUI

/// Mail's home tile at each size (redesign, 2026-11-17). Small is the unread count and the newest
/// sender. Medium lists the two newest, and large as many as fit: unread first with the accent dot,
/// then the most recent read ones. Only the Inbox shows, so nothing from Spam or Trash reaches the home
/// page, and nothing is sent or deleted from here.
///
/// Senders show as initials. Mail carries no pictures of people, and looking a sender up in the profile
/// directory would tell it who writes to whom.
public struct MailHomeTile: View {
    private static let mostRows = 8

    private let model: MailModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Mail up after a conversation has been asked for.
    public init(model: MailModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private var unread: [MailConversation] {
        model.homeUnreadConversations
    }

    private var header: String {
        let count = unread.count
        return count == 0 ? "Mail" : "Mail · \(count) new"
    }

    public var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium: list(rows: 2)
            case .large: list(rows: Self.mostRows)
            }
        }
        .tilePadding()
    }

    private func open(_ conversation: MailConversation) {
        model.requestFromHome(conversation.id)
        onOpen()
    }

    // MARK: Small: the count and who it's from

    private var small: some View {
        let theme = Theme.current
        let count = unread.count
        let newest = unread.first ?? model.homeRows.conversations.first
        return VStack(alignment: .leading, spacing: 0) {
            TileHeader("Mail", systemImage: "envelope")
            Text("\(count)")
                .font(Typeface.display)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? theme.textSecondary.color : theme.textPrimary.color)
                .padding(.top, Space.s2)
            Text(count == 0 ? "All caught up" : count == 1 ? "new message" : "new messages")
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: Space.s2)
            if let newest {
                VStack(alignment: .leading, spacing: 0) {
                    Text(newest.heading(me: model.mailbox.address, showingRecipients: false))
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text(newest.isUnreadable ? "Can't be opened" : newest.subject)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .lineLimit(1)
                .tileLink(mailTileLabel(newest, in: model)) { open(newest) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Medium and large: the newest, unread first

    /// Unread first, then the most recent of the rest, so a large tile is full even when little is new.
    private func conversations(_ count: Int) -> [MailConversation] {
        let fresh = Array(unread.prefix(count))
        guard fresh.count < count else { return fresh }
        let seen = Set(fresh.map(\.id))
        let rest = model.homeConversations(count).filter { !seen.contains($0.id) }
        return fresh + rest.prefix(count - fresh.count)
    }

    private func list(rows: Int) -> some View {
        let theme = Theme.current
        let shown = conversations(rows)
        return VStack(alignment: .leading, spacing: Metric.tileRowGap) {
            TileHeader(header, systemImage: "envelope")
            if shown.isEmpty {
                Text("Your inbox is empty")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textSecondary.color)
            }
            TileList(shown, isCentered: true) { row($0) }
        }
    }

    private func row(_ conversation: MailConversation) -> some View {
        MailTileRow(conversation: conversation, me: model.mailbox.address)
            .contentShape(Rectangle())
            .onTapGesture { open(conversation) }
            .contextMenu {
                if conversation.isUnread {
                    Button("Mark read", systemImage: "envelope.open") {
                        Task { await model.performFromHome(.markRead, on: conversation) }
                    }
                }
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.performFromHome(.archive, on: conversation) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mailTileLabel(conversation, in: model))
            .accessibilityAddTraits(.isButton)
            .tileControl()
    }
}

/// The unread count as the tile's words, for the count and for VoiceOver.
func mailCountLine(_ count: Int) -> String {
    switch count {
    case 0: "No unread mail"
    case 1: "1 unread"
    default: "\(count) unread"
    }
}

/// What VoiceOver reads for a conversation on a tile.
@MainActor
func mailTileLabel(_ conversation: MailConversation, in model: MailModel) -> String {
    let who = conversation.heading(me: model.mailbox.address, showingRecipients: false)
    let place = conversation.latest.outsideAccount.map { ", in \($0.provider.name)" } ?? ""
    return (conversation.isUnread ? "Unread, \(who): \(conversation.subject)" : "\(who): \(conversation.subject)") + place
}

/// One conversation: the unread dot, the sender's initials, who, when, and the subject.
private struct MailTileRow: View {
    let conversation: MailConversation
    let me: String

    var body: some View {
        let theme = Theme.current
        let sender = conversation.sender(me: me)
        HStack(spacing: Metric.tileItemGap) {
            // Laid out like the Messages tile (owner, 2026-11-18: "make mail like messages").
            MailAvatar(name: sender.displayName, size: Space.s6 + Space.s1, isToned: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.heading(me: me, showingRecipients: false))
                    .font(Typeface.tileRow.weight(conversation.isUnread ? .bold : .semibold))
                    .foregroundStyle(theme.textPrimary.color)
                HStack(spacing: Space.s1 + Space.s1 / 2) {
                    // Unread shows as the one accent dot, so the row needs no other colour.
                    if conversation.isUnread {
                        Circle()
                            .fill(theme.accent.color)
                            .frame(width: Space.s2, height: Space.s2)
                            .accessibilityHidden(true)
                    }
                    Text(conversation.isUnreadable ? "Can't be opened" : conversation.subject)
                        .font(Typeface.tileDetail.weight(conversation.isUnread ? .semibold : .regular))
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .lineLimit(1)
            Spacer(minLength: Space.s1)
            Text(MailDate.short(conversation.latest.date, now: Date()))
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
