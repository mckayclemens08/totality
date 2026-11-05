import SwiftUI
import TotalityUI

/// An open conversation. The newest message and anything unread start open, and the rest fold to a line.
struct MailConversationView: View {
    let id: UUID
    let model: MailModel
    let onOpenLink: (URL) -> Void
    let onWrite: (MailComposer) -> Void
    let onClose: () -> Void

    @State private var open = Set<UUID>()

    private var conversation: MailConversation? {
        model.mailbox.conversation(id, in: model.place)
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        if conversation.isUnreadable {
                            unreadable
                        } else {
                            Text(conversation.subject)
                                .font(Typeface.title)
                                .foregroundStyle(theme.textPrimary.color)
                                .textSelection(.enabled)
                                .padding(.horizontal, Space.s1)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(conversation.messages) { message in
                                MailMessageView(
                                    message: message, model: model, isOpen: open.contains(message.id),
                                    onToggle: { toggle(message) }, onOpenLink: onOpenLink
                                )
                            }
                            if conversation.latest.marks.folder != .drafts {
                                answers(to: conversation.latest)
                            }
                        }
                    }
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom) {
                    MailActionBar(model: model, conversations: [conversation], onDone: closeIfGone)
                }
                .task(id: conversation.id) {
                    open = Set(conversation.messages.filter { $0.marks.isUnread || $0.id == conversation.latest.id }.map(\.id))
                    await model.markRead(conversation)
                }
            } else {
                Color.clear.onAppear(perform: onClose)
            }
        }
        .background(theme.bg.color)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.bg.color, for: .navigationBar)
        #endif
    }

    private var unreadable: some View {
        MailStateView(
            systemImage: "lock.slash", title: "This message can't be opened",
            detail: "Its seal didn't open with this device's key, so Totality can't tell who sent it or what it says. It may have been damaged on the way."
        )
    }

    /// Reply, Reply All, and Forward, for the newest message. Reply All shows only when it would reach
    /// more than Reply does.
    private func answers(to message: MailMessage) -> some View {
        let me = model.mailbox.address
        let reachesMore = MailDraft.replyAll(to: message, me: me).recipients.count > MailDraft.reply(to: message, me: me).recipients.count
        return HStack(spacing: Space.s3) {
            answer("Reply", systemImage: "arrowshape.turn.up.left") { onWrite(.reply(to: message, all: false, in: model)) }
            if reachesMore {
                answer("Reply All", systemImage: "arrowshape.turn.up.left.2") { onWrite(.reply(to: message, all: true, in: model)) }
            }
            answer("Forward", systemImage: "arrowshape.turn.up.right") {
                Task { onWrite(await .forward(message, in: model)) }
            }
        }
        .padding(.top, Space.s2)
    }

    private func answer(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .frame(maxWidth: .infinity)
                .neumorphic(.subtle, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ message: MailMessage) {
        withAnimation(Motion.quick) {
            if open.remove(message.id) == nil { open.insert(message.id) }
        }
    }

    private func closeIfGone() {
        if conversation == nil { onClose() }
    }
}
