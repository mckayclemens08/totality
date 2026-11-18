import SwiftUI
import TotalityUI

/// Messages' home tile at each size (redesign, 2026-11-17). Small shows faces of who's written, and the
/// newest chat with how many are new. Medium lists the two newest chats, and large as many as fit, each
/// with its face, last line, time and the accent dot when something's unread. Faces come from the
/// people's public profiles, through `MessagesPeople`. Looking at the tile doesn't mark anything read,
/// and nothing is sent from it.
public struct MessagesHomeTile: View {
    private static let mostRows = 8
    private static let smallFaces = 3

    private let model: MessagesModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Messages up after a chat has been asked for.
    public init(model: MessagesModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if model.chats.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    TileHeader("Messages", systemImage: "bubble.left")
                    MessagesTileEmpty(hasRequests: !model.requests.isEmpty)
                }
            } else {
                switch size {
                case .small: small
                case .medium: list(rows: 2)
                case .large: list(rows: Self.mostRows)
                }
            }
        }
        .tilePadding()
    }

    private func open(_ chat: ChatSummary) {
        model.requestedChat = chat.id
        onOpen()
    }

    private func photo(of chat: ChatSummary) -> Data? {
        chat.otherPerson.flatMap { model.people.profile(ofMatrixID: $0)?.photo }
    }

    private static func newLine(_ count: Int) -> String {
        count == 1 ? "1 new message" : "\(count) new messages"
    }

    // MARK: Small: faces and the newest

    private var small: some View {
        let theme = Theme.current
        let faces = model.homeFaces
        let lead = faces.chats.first
        return VStack(alignment: .leading, spacing: 0) {
            TileHeader("Messages", systemImage: "bubble.left")
            HStack(spacing: -Space.s3) {
                // Overlapped, the newest on top, each on a ring of the tile's own surface.
                ForEach(Array(faces.chats.prefix(Self.smallFaces).enumerated()), id: \.element.id) { index, chat in
                    PersonFace(photo: photo(of: chat), name: chat.title, diameter: Space.s6 + Space.s1)
                        .padding(Space.s1 / 2)
                        .background(Circle().fill(theme.surface.color))
                        .zIndex(Double(-index))
                        .tileLink(chat.title) { open(chat) }
                }
            }
            .padding(.top, Space.s3)
            .padding(.leading, Space.s1 / 2)
            Spacer(minLength: Space.s2)
            if let lead {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lead.title)
                        .font(Typeface.caption.weight(.bold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text(lead.unread > 0 ? Self.newLine(lead.unread) : (model.homeLastLine(of: lead) ?? ""))
                        .font(Typeface.tileDetail.weight(lead.unread > 0 ? .semibold : .regular))
                        .foregroundStyle(lead.unread > 0 ? theme.accent.color : theme.textSecondary.color)
                }
                .lineLimit(1)
                .tileLink(lead.unread > 0 ? "\(lead.title), \(Self.newLine(lead.unread))" : lead.title) { open(lead) }
            }
        }
    }

    // MARK: Medium and large: the newest chats

    private func list(rows: Int) -> some View {
        let shown = Array(model.chats.prefix(rows))
        return VStack(alignment: .leading, spacing: Metric.tileRowGap) {
            TileHeader("Messages", systemImage: "bubble.left")
            TileList(shown) { chat in
                MessagesTileRow(chat: chat, photo: photo(of: chat), line: line(for: chat))
                    .tileLink(label(chat)) { open(chat) }
            }
        }
    }

    private func line(for chat: ChatSummary) -> String {
        chat.unread > 0 ? Self.newLine(chat.unread) : (model.homeLastLine(of: chat) ?? " ")
    }

    private func label(_ chat: ChatSummary) -> String {
        let line = model.homeLastLine(of: chat).map { ": \($0)" } ?? ""
        return (chat.unread > 0 ? "Unread, \(chat.title)" : chat.title) + line
    }
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
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// One chat: its face, its name, the accent dot and line when something's new, and when.
private struct MessagesTileRow: View {
    let chat: ChatSummary
    let photo: Data?
    let line: String

    var body: some View {
        let theme = Theme.current
        let isUnread = chat.unread > 0
        HStack(spacing: Metric.tileItemGap) {
            PersonFace(photo: photo, name: chat.title, diameter: Space.s6 + Space.s1)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.title)
                    .font(Typeface.tileRow.weight(isUnread ? .bold : .semibold))
                    .foregroundStyle(theme.textPrimary.color)
                HStack(spacing: Space.s1 + Space.s1 / 2) {
                    if isUnread {
                        Circle()
                            .fill(theme.accent.color)
                            .frame(width: Space.s2, height: Space.s2)
                            .accessibilityHidden(true)
                    }
                    Text(line)
                        .font(Typeface.tileDetail.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(isUnread ? theme.accent.color : theme.textSecondary.color)
                }
            }
            .lineLimit(1)
            Spacer(minLength: Space.s1)
            if let time = chat.lastActivity {
                Text(MessagesTime.short(time))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
