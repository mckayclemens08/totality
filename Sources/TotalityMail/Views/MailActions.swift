import SwiftUI
import TotalityUI

/// Which actions make sense where. Anything sitting in Trash or Spam goes back rather than further.
enum MailActions {
    static func canArchive(in place: MailPlace) -> Bool {
        switch place {
        case .folder(.archive), .folder(.sent), .folder(.drafts), .folder(.spam), .folder(.trash): false
        default: true
        }
    }

    /// Sent mail and drafts stay where they are, so there's nothing to move.
    static func canMove(in place: MailPlace) -> Bool {
        place != .folder(.sent) && place != .folder(.drafts)
    }

    static func canReportSpam(in place: MailPlace) -> Bool {
        switch place {
        case .folder(.spam), .folder(.trash), .folder(.sent), .folder(.drafts): false
        default: true
        }
    }

    static func canDeleteForever(in place: MailPlace) -> Bool {
        place == .folder(.trash) || place == .folder(.spam)
    }
}

/// Everywhere a conversation can go. Where it already is isn't offered.
struct MailMoveButtons: View {
    let model: MailModel
    let conversations: [MailConversation]

    var body: some View {
        let mailbox = model.mailbox
        let own = mailbox.settings.folders.map { MailFolder.own($0.id) }
        ForEach([MailFolder.inbox, .archive] + own, id: \.self) { folder in
            if model.place != .folder(folder) {
                Button(mailbox.name(of: folder)) {
                    Task { await model.perform(.move(folder), on: conversations) }
                }
            }
        }
    }
}

/// The full set, for context menus and the reader's More menu.
struct MailActionButtons: View {
    let model: MailModel
    let conversations: [MailConversation]
    var onDeleteForever: (() -> Void)?

    private func run(_ action: MailAction) {
        Task { await model.perform(action, on: conversations) }
    }

    private var sender: MailAddress? {
        guard conversations.count == 1, let conversation = conversations.first, !conversation.isUnreadable else { return nil }
        let sender = conversation.sender(me: model.mailbox.address)
        return sender.key == model.mailbox.address.lowercased() ? nil : sender
    }

    var body: some View {
        let place = model.place
        let anyUnread = conversations.contains(where: \.isUnread)
        let anyStarred = conversations.contains(where: \.isStarred)
        if MailActions.canArchive(in: place) {
            Button("Archive", systemImage: "archivebox") { run(.archive) }
        }
        if place == .folder(.trash) || place == .folder(.spam) {
            Button(place == .folder(.spam) ? "Not Spam" : "Restore", systemImage: "tray.and.arrow.down") { run(.move(.inbox)) }
        }
        Button(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: anyUnread ? "envelope.open" : "envelope.badge") {
            run(anyUnread ? .markRead : .markUnread)
        }
        Button(anyStarred ? "Remove Star" : "Star", systemImage: anyStarred ? "star.slash" : "star") {
            run(anyStarred ? .unstar : .star)
        }
        if MailActions.canMove(in: place) {
            Menu("Move to", systemImage: "folder") {
                MailMoveButtons(model: model, conversations: conversations)
            }
        }
        Divider()
        if MailActions.canReportSpam(in: place) {
            Button("Report Spam", systemImage: "exclamationmark.octagon") { run(.reportSpam) }
        }
        if let sender, !model.mailbox.settings.blockedSenders.contains(sender.key) {
            Button("Block \(sender.displayName)", systemImage: "hand.raised") {
                Task { await model.block(sender) }
            }
        }
        if place != .folder(.trash) {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { run(.trash) }
        }
        if MailActions.canDeleteForever(in: place), let onDeleteForever {
            Button("Delete Forever", systemImage: "trash.slash", role: .destructive, action: onDeleteForever)
        }
    }
}

/// The bar under an open conversation, and under a list while selecting. It offers the three things
/// people do most, and the menu holds the rest.
struct MailActionBar: View {
    let model: MailModel
    let conversations: [MailConversation]
    let onDone: () -> Void

    @State private var confirmingDelete = false

    private func run(_ action: MailAction) {
        Task {
            await model.perform(action, on: conversations)
            onDone()
        }
    }

    var body: some View {
        let theme = Theme.current
        let place = model.place
        let isEmpty = conversations.isEmpty
        HStack(spacing: Space.s2) {
            if model.isSelecting {
                Text(conversations.count == 1 ? "1 selected" : "\(conversations.count) selected")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if MailActions.canArchive(in: place) {
                control("archivebox", label: "Archive") { run(.archive) }
            } else if place == .folder(.trash) || place == .folder(.spam) {
                control("tray.and.arrow.down", label: place == .folder(.spam) ? "Not Spam" : "Restore") { run(.move(.inbox)) }
            }
            if place != .folder(.trash) {
                control("trash", label: "Move to Trash") { run(.trash) }
            } else {
                control("trash.slash", label: "Delete Forever") { confirmingDelete = true }
            }
            let starred = conversations.contains(where: \.isStarred)
            control(starred ? "star.fill" : "star", label: starred ? "Remove Star" : "Star") { run(starred ? .unstar : .star) }
            Spacer(minLength: 0)
            Menu {
                MailActionButtons(model: model, conversations: conversations) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(Typeface.body)
                    .frame(width: Space.s7, height: Space.s7)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.35 : 1)
        .foregroundStyle(theme.textPrimary.color)
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s1)
        .background(theme.bg.color)
        .confirmationDialog(
            conversations.count == 1 ? "Delete this forever?" : "Delete \(conversations.count) conversations forever?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                Task {
                    await model.deleteForever(conversations)
                    onDone()
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func control(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.body)
                .frame(width: Space.s7, height: Space.s7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
