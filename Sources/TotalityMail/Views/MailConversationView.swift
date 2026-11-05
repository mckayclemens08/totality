import SwiftUI
import TotalityUI

/// An open conversation. The newest message and anything unread start open, and the rest fold to a line.
struct MailConversationView: View {
    let id: UUID
    let model: MailModel
    let onOpenLink: (URL) -> Void
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

    private func toggle(_ message: MailMessage) {
        withAnimation(Motion.quick) {
            if open.remove(message.id) == nil { open.insert(message.id) }
        }
    }

    private func closeIfGone() {
        if conversation == nil { onClose() }
    }
}
