import SwiftUI
import TotalityUI

/// The conversations in the current place, and the bars that speak for the mailbox as a whole.
struct MailListView: View {
    let model: MailModel
    let opened: UUID?
    let onOpen: (MailConversation) -> Void

    var body: some View {
        let theme = Theme.current
        let conversations = model.conversations
        VStack(spacing: Space.s2) {
            MailSampleNote(model: model)
            MailMailboxNotes(model: model)
            if conversations.isEmpty {
                empty
            } else {
                List {
                    if model.place == .folder(.trash) {
                        Text("Mail here is deleted for good after 30 days.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(conversations) { conversation in
                        row(conversation)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting {
                MailActionBar(model: model, conversations: model.selected, onDone: {})
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = MailWording.empty(model.place)
            MailStateView(systemImage: "tray", title: words.title, detail: words.detail)
        } else {
            MailStateView(
                systemImage: "magnifyingglass", title: "No mail matches",
                detail: "Search covers the mail on this device, and nothing you type leaves it."
            )
        }
    }

    private func row(_ conversation: MailConversation) -> some View {
        let theme = Theme.current
        let isSelected = model.selection.contains(conversation.id)
        return MailRow(
            conversation: conversation, heading: conversation.heading(me: model.mailbox.address, showingRecipients: model.place.showsRecipients),
            date: MailDate.short(conversation.latest.date, now: model.today),
            isSelecting: model.isSelecting, isSelected: isSelected, isOpen: opened == conversation.id
        )
        .tappable {
            if model.isSelecting { model.toggle(conversation) } else { onOpen(conversation) }
        }
        .listRowInsets(EdgeInsets(top: Space.s2, leading: Space.s4, bottom: Space.s2, trailing: Space.s4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading) {
            if conversation.isUnread {
                Button("Read", systemImage: "envelope.open") { run(.markRead, conversation) }
                    .tint(theme.accent.color)
            } else {
                Button("Unread", systemImage: "envelope.badge") { run(.markUnread, conversation) }
                    .tint(theme.accent.color)
            }
            if conversation.isStarred {
                Button("Unstar", systemImage: "star.slash") { run(.unstar, conversation) }
                    .tint(theme.textSecondary.color)
            } else {
                Button("Star", systemImage: "star") { run(.star, conversation) }
                    .tint(theme.textSecondary.color)
            }
        }
        .swipeActions(edge: .trailing) {
            if model.place != .folder(.trash) {
                Button("Trash", systemImage: "trash") { run(.trash, conversation) }
                    .tint(theme.danger.color)
            }
            if MailActions.canArchive(in: model.place) {
                Button("Archive", systemImage: "archivebox") { run(.archive, conversation) }
                    .tint(theme.textSecondary.color)
            }
            if MailActions.canMove(in: model.place) {
                Menu {
                    MailMoveButtons(model: model, conversations: [conversation])
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(theme.textTertiary.color)
            }
        }
        .contextMenu {
            Button("Select", systemImage: "checkmark.circle") { model.beginSelecting(conversation) }
            Divider()
            MailActionButtons(model: model, conversations: [conversation])
        }
    }

    private func run(_ action: MailAction, _ conversation: MailConversation) {
        Task { await model.perform(action, on: [conversation]) }
    }
}

/// One conversation on a list. Unread mail carries a dot and heavier type, so it reads without colour.
struct MailRow: View {
    let conversation: MailConversation
    let heading: String
    let date: String
    let isSelecting: Bool
    let isSelected: Bool
    let isOpen: Bool

    private var problem: String? {
        switch conversation.problem {
        case .fine: nil
        case .notSent: "Not sent"
        case .bounced: "Couldn't be delivered"
        }
    }

    var body: some View {
        let theme = Theme.current
        let isUnread = conversation.isUnread
        HStack(alignment: .top, spacing: Space.s3) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Typeface.body)
                    .foregroundStyle(isSelected ? theme.accent.color : theme.textSecondary.color)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    if isUnread {
                        Circle()
                            .fill(theme.accent.color)
                            .frame(width: Space.s2, height: Space.s2)
                    }
                    Text(heading)
                        .font(isUnread ? Typeface.headline : Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    if conversation.messages.count > 1 {
                        Text("\(conversation.messages.count)")
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer(minLength: Space.s2)
                    Text(date)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                if conversation.isUnreadable {
                    Text("This message's seal didn't open on this device.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                        Text(conversation.subject)
                            .font(isUnread ? Typeface.callout : Typeface.body)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if conversation.hasAttachments {
                            Image(systemName: "paperclip")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .accessibilityLabel("Has an attachment")
                        }
                        if conversation.isStarred {
                            Image(systemName: "star.fill")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.accent.color)
                                .accessibilityLabel("Starred")
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    } else {
                        Text(conversation.latest.preview)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(isOpen || isSelected ? .pressed : .subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "")
    }
}

/// Offline, a full mailbox: anything that's true of all the mail at once.
struct MailMailboxNotes: View {
    let model: MailModel

    private var offline: String {
        switch model.waiting {
        case 0: "You're offline. Your stored mail still opens."
        case 1: "You're offline. 1 change is waiting, and it'll go through when you're back."
        default: "You're offline. \(model.waiting) changes are waiting, and they'll go through when you're back."
        }
    }

    var body: some View {
        let theme = Theme.current
        if model.isOffline {
            Label(offline, systemImage: "wifi.slash")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
        }
        if model.mailbox.isFull {
            Label("Your mailbox is full, so new mail is going back to its senders. Delete some mail to make room.", systemImage: "externaldrive.badge.exclamationmark")
                .font(Typeface.caption)
                .foregroundStyle(theme.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
        }
    }
}

/// Says this isn't real mail, and shows each state the real thing can land in. It goes away with the
/// sample store.
struct MailSampleNote: View {
    let model: MailModel

    @State private var scene = SampleMailStore.Scene.normal

    var body: some View {
        let theme = Theme.current
        if let sample = model.store as? SampleMailStore {
            HStack(spacing: Space.s2) {
                Text("Sample mail. Your real mailbox isn't connected yet.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
                Menu("Try a state") {
                    Picker("State", selection: picked(sample)) {
                        ForEach(SampleMailStore.Scene.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .font(Typeface.caption)
                .fixedSize()
            }
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s2)
            .task { scene = await sample.scene }
        }
    }

    /// Reopens only on a pick. This view comes back after every reopen, and catching up with the store
    /// then mustn't count as one.
    private func picked(_ sample: SampleMailStore) -> Binding<SampleMailStore.Scene> {
        Binding {
            scene
        } set: { new in
            scene = new
            Task {
                await sample.use(new)
                await model.reopen()
            }
        }
    }
}
