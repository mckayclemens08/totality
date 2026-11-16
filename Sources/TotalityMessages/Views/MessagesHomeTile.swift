import SwiftUI
import TotalityUI

/// Messages' big home tiles, one job for each size (issue 127). Medium is a glance: faces with what's
/// unread from each. Large lists the three most recent chats. The square is a workspace: one chat's last
/// few messages with a Reply button that opens the chat ready to write, and faces across the top to switch
/// chat. Faces come from the people's public profiles, through `MessagesPeople`. Looking at the square
/// doesn't mark anything read, and nothing is sent from it but a heart the person double-tapped.
public struct MessagesHomeTile: View {
    private let model: MessagesModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Messages up after a chat has been asked for.
    public init(model: MessagesModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if model.chats.isEmpty {
                MessagesTileEmpty(hasRequests: !model.requests.isEmpty)
            } else {
                switch size {
                case .medium: MessagesFacesTile(model: model, onOpen: onOpen)
                case .large: MessagesListTile(model: model, onOpen: onOpen)
                case .square: MessagesDeskTile(model: model, onOpen: onOpen)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Opens a chat in Messages.
@MainActor
private func openChat(_ id: String, in model: MessagesModel, then onOpen: @MainActor () -> Void) {
    model.requestedChat = id
    onOpen()
}

/// A chat's face: the other person's profile photo, or initials for them or a group.
@MainActor
private func chatFace(_ chat: ChatSummary, in model: MessagesModel, count: Int = 0, diameter: CGFloat) -> TileFace {
    let photo = chat.otherPerson.flatMap { model.people.profile(ofMatrixID: $0)?.photo }
    return TileFace(photo: photo, name: chat.title, count: count, diameter: diameter)
}

private struct MessagesTileEmpty: View {
    let hasRequests: Bool

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(hasRequests ? "A message request is waiting" : "No conversations yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(hasRequests ? "Open Messages to see who it's from." : "Start one with someone's username.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: Medium

private struct MessagesFacesTile: View {
    let model: MessagesModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let faces = model.homeFaces
        let unread = model.chats.reduce(0) { $0 + $1.unread }
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(faces.hasUnread ? (unread == 1 ? "1 unread message" : "\(unread) unread messages") : "All caught up")
                .font(Typeface.callout)
                .foregroundStyle(faces.hasUnread ? theme.textPrimary.color : theme.textSecondary.color)
            HStack(spacing: Space.s3) {
                ForEach(faces.chats) { chat in
                    chatFace(chat, in: model, count: chat.unread, diameter: Space.s7)
                        .tileLink(chat.unread > 0 ? "\(chat.title), \(chat.unread) unread" : chat.title) {
                            openChat(chat.id, in: model, then: onOpen)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: Large

private struct MessagesListTile: View {
    let model: MessagesModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(model.homeRows) { chat in
                MessagesTileRow(chat: chat, model: model)
                    .tileLink(label(chat)) { openChat(chat.id, in: model, then: onOpen) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ chat: ChatSummary) -> String {
        let line = model.homeLastLine(of: chat).map { ": \($0)" } ?? ""
        return (chat.unread > 0 ? "Unread, \(chat.title)" : chat.title) + line
    }
}

private struct MessagesTileRow: View {
    let chat: ChatSummary
    let model: MessagesModel

    var body: some View {
        let theme = Theme.current
        let isUnread = chat.unread > 0
        HStack(spacing: Space.s3) {
            // The name is beside the face here, so the face goes without one under it.
            PersonFace(
                photo: chat.otherPerson.flatMap { model.people.profile(ofMatrixID: $0)?.photo }, name: chat.title,
                diameter: Space.s6 + Space.s2
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(chat.title)
                        .font(isUnread ? Typeface.headline : Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: Space.s1)
                    if let time = chat.lastActivity {
                        Text(MessagesTime.short(time))
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    // Unread shows as the one accent dot.
                    Circle()
                        .fill(isUnread ? theme.accent.color : Color.clear)
                        .frame(width: Space.s2, height: Space.s2)
                        .accessibilityHidden(true)
                }
                Text(model.homeLastLine(of: chat) ?? " ")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Square

private struct MessagesDeskTile: View {
    let model: MessagesModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            switcher
            if let target = model.homeTarget {
                HStack {
                    Text(target.title)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .tileLink("Open \(target.title)") { openChat(target.id, in: model, then: onOpen) }
                bubbles(target)
                Spacer(minLength: 0)
                // Writing happens in the chat itself: tiles never hold a text box (owner, issue 127).
                TileButton("Reply", systemImage: "arrowshape.turn.up.left", isProminent: true) {
                    model.requestedWriting = target.id
                    openChat(target.id, in: model, then: onOpen)
                }
                .tileControl()
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.homeTarget?.id) { await model.showOnHome() }
        .onDisappear { model.closeHome() }
    }

    private var switcher: some View {
        HStack(spacing: Space.s2) {
            ForEach(model.homeSwitcher) { chat in
                let isShown = chat.id == model.homeTarget?.id
                Button {
                    withAnimation(Motion.quick) { model.homePicked = chat.id }
                } label: {
                    chatFace(chat, in: model, count: chat.unread, diameter: Space.s6 + Space.s2)
                        .opacity(isShown ? 1 : 0.6)
                }
                .buttonStyle(TilePress())
                .accessibilityLabel(chat.unread > 0 ? "\(chat.title), \(chat.unread) unread" : chat.title)
                .accessibilityAddTraits(isShown ? .isSelected : [])
                .tileControl()
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder private func bubbles(_ target: ChatSummary) -> some View {
        let theme = Theme.current
        if let chat = model.homeChat, chat.chatID == target.id, chat.loaded {
            let shown = model.homeBubbles
            if shown.isEmpty {
                Text("No messages yet")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            } else {
                VStack(spacing: Space.s2) {
                    ForEach(shown) { message in
                        MessagesTileBubble(message: message, chat: chat, isGroup: target.isGroup, people: model.people) {
                            openChat(target.id, in: model, then: onOpen)
                        }
                        .tileControl()
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Getting the conversation")
        }
    }
}

/// One message on the square. A tap opens the chat; a double tap hearts it, as in the chat.
private struct MessagesTileBubble: View {
    let message: ChatMessage
    let chat: ChatModel
    let isGroup: Bool
    let people: MessagesPeople
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let hearted = message.reactions.contains { $0.key == QuickReactions.heart && $0.mine }
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 0) {
            if isGroup, !message.isOwn {
                Text(TileNames.first(people.name(ofMatrixID: message.sender)))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Text(text)
                .font(Typeface.caption)
                .italic(!message.decrypted || message.kind == .deleted)
                .foregroundStyle(message.decrypted ? theme.textPrimary.color : theme.textSecondary.color)
                .lineLimit(2)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1 + Space.s1 / 2)
                .background {
                    // Your own sit on the pale accent, everyone else's on the surface, as in the chat.
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(message.isOwn ? theme.highlight.color : theme.surface.color)
                }
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(alignment: message.isOwn ? .bottomLeading : .bottomTrailing) {
                    if hearted {
                        Text(QuickReactions.heart)
                            .font(Typeface.micro)
                            .offset(x: message.isOwn ? -Space.s2 : Space.s2, y: Space.s2)
                            .accessibilityHidden(true)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: message.isOwn ? .trailing : .leading)
        .padding(message.isOwn ? .leading : .trailing, Space.s6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { heart() }
        .onTapGesture { onOpen() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((message.isOwn ? "You: " : "") + text + (hearted ? ", hearted" : ""))
        .accessibilityAction(named: "Heart") { heart() }
        .accessibilityAction { onOpen() }
    }

    private var text: String {
        switch message.kind {
        case .deleted: "Message deleted"
        case .photo: "Photo"
        case .video: "Video"
        case .text: message.decrypted ? message.body : LockedMessage.placeholder(isOwn: message.isOwn)
        }
    }

    private func heart() {
        guard ChatScroll.canHeart(message) else { return }
        Task { await chat.toggleReaction(QuickReactions.heart, on: message) }
    }
}
