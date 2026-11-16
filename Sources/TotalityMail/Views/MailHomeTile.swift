import SwiftUI
import TotalityUI

/// Mail's big home tiles, one job for each size (issue 127). Medium is a glance: how much is unread and
/// from whom. Large is a list of the newest unread. The square is a workspace with the newest unread
/// email open on it. Only the Inbox shows, so nothing from Spam or Trash reaches the home page, and
/// nothing is sent from here: Reply opens compose in Mail, where Send is still the person's press.
///
/// Senders show as initials. Mail carries no pictures of people, and looking a sender up in the profile
/// directory would tell it who writes to whom.
public struct MailHomeTile: View {
    private let model: MailModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Mail up after a conversation has been asked for.
    public init(model: MailModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch size {
            case .medium: MailGlanceTile(model: model, onOpen: onOpen)
            case .large: MailListTile(model: model, onOpen: onOpen)
            case .square: MailDeskTile(model: model, onOpen: onOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

// MARK: Medium

/// The count, big, with up to four faces of who it's from and each account's share.
private struct MailGlanceTile: View {
    let model: MailModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let unread = model.homeUnreadConversations.count
        let senders = model.homeSenders
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .center, spacing: Space.s4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(unread == 0 ? "0" : "\(unread)")
                        .font(Typeface.display)
                        .monospacedDigit()
                        .foregroundStyle(unread == 0 ? theme.textSecondary.color : theme.textPrimary.color)
                    Text(unread == 0 ? "All caught up" : "unread")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mailCountLine(unread))
                Spacer(minLength: 0)
                HStack(spacing: Space.s1) {
                    ForEach(senders) { sender in
                        TileFace(photo: nil, name: sender.name, count: sender.unread, diameter: Space.s6 + Space.s2)
                            .tileLink("\(sender.name), \(sender.unread) unread") {
                                model.requestFromHome(sender.conversation)
                                onOpen()
                            }
                    }
                }
            }
            if !model.homeAccounts.isEmpty {
                HStack(spacing: Space.s2) {
                    ForEach(model.homeAccounts) { account in
                        TileChip(account.name, count: account.unread)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: Large

/// The four newest unread, each with who, what, a line of it, when and where. Holding a row offers
/// Mark read or Archive; deleting is never on the home page.
private struct MailListTile: View {
    let model: MailModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let rows = model.homeRows
        VStack(alignment: .leading, spacing: Space.s2) {
            if rows.caughtUp {
                Text(rows.conversations.isEmpty ? "Your inbox is empty" : "All caught up")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textSecondary.color)
            }
            ForEach(rows.conversations) { conversation in
                MailTileRow(conversation: conversation, me: model.mailbox.address, isQuiet: rows.caughtUp)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.requestFromHome(conversation.id)
                        onOpen()
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MailTileRow: View {
    let conversation: MailConversation
    let me: String
    let isQuiet: Bool

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            // Unread shows as the one accent dot, so the row needs no other colour.
            Circle()
                .fill(conversation.isUnread ? theme.accent.color : Color.clear)
                .frame(width: Space.s2, height: Space.s2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(conversation.heading(me: me, showingRecipients: false))
                        .font(isQuiet ? Typeface.callout : Typeface.headline)
                        .foregroundStyle(isQuiet ? theme.textSecondary.color : theme.textPrimary.color)
                        .lineLimit(1)
                    if let outside = conversation.latest.outsideAccount {
                        Text(outside.provider.name)
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textTertiary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.s1)
                    Text(MailDate.short(conversation.latest.date, now: Date()))
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                let subject = Text(conversation.isUnreadable ? "Can't be opened" : conversation.subject).foregroundStyle(theme.textPrimary.color)
                let tail = Text(previewTail).foregroundStyle(theme.textSecondary.color)
                Text("\(subject)\(tail)")
                    .font(Typeface.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewTail: String {
        let preview = conversation.latest.preview
        return preview.isEmpty || conversation.isUnreadable ? "" : " — " + preview
    }
}

// MARK: Square

/// The newest unread email open on the tile, with Reply, Archive and Next, and a strip of each account's
/// unread above it. Reading it here doesn't mark it read: only Mark read, Archive or opening it does.
private struct MailDeskTile: View {
    let model: MailModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            strip
                .layoutPriority(1)
            if let conversation = model.homeOpen {
                letter(conversation)
                Spacer(minLength: 0)
                actions(conversation)
                    .layoutPriority(1)
            } else {
                // Nothing unread: the large tile's quiet list says so, with the most recent under it.
                MailListTile(model: model, onOpen: onOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var strip: some View {
        let accounts = model.homeAccounts
        if accounts.isEmpty {
            Text(mailCountLine(model.homeUnreadConversations.count))
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
        } else {
            HStack(spacing: Space.s2) {
                ForEach(accounts) { TileChip($0.name, count: $0.unread) }
            }
        }
    }

    private func letter(_ conversation: MailConversation) -> some View {
        let theme = Theme.current
        let sender = conversation.sender(me: model.mailbox.address)
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                MailAvatar(name: sender.displayName)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sender.displayName)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text(MailDate.short(conversation.latest.date, now: Date()))
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Text(conversation.subject)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(2)
            Text(MailModel.opening(of: conversation.latest))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tileLink(mailTileLabel(conversation, in: model)) {
            model.requestFromHome(conversation.id)
            onOpen()
        }
    }

    private func actions(_ conversation: MailConversation) -> some View {
        HStack(spacing: Space.s2) {
            TileButton("Reply", systemImage: "arrowshape.turn.up.left", isProminent: true) {
                model.requestReplyFromHome(conversation.id)
                onOpen()
            }
            .tileControl()
            TileButton("Archive", systemImage: "archivebox") {
                Task { await model.performFromHome(.archive, on: conversation) }
            }
            .tileControl()
            Spacer(minLength: 0)
            if model.homeNext != nil {
                TileButton("Next", systemImage: "chevron.right") {
                    withAnimation(Motion.quick) { model.showNextOnHome() }
                }
                .tileControl()
            }
        }
    }
}
