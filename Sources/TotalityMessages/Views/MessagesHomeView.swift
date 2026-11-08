import SwiftUI
import TotalityUI

/// Messages' first screen: requests, then conversations newest first, a search box, and New message.
/// Nothing else competes for space.
public struct MessagesHomeView: View {
    @Bindable private var model: MessagesModel
    private let onClose: (() -> Void)?

    @State private var opened: String?
    @State private var composing = false
    @State private var query = ""
    @AppStorage(MessagesPreferences.shareReadAndTypingKey) private var shareReadAndTyping = true

    public init(model: MessagesModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            content
                .background(theme.bg.color)
                .edgeSwipeBack(onClose)
                .toolbar { toolbar }
                .navigationTitle("Messages")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(theme.bg.color, for: .navigationBar)
                #endif
                .navigationDestination(item: $opened) { id in
                    ChatScreen(messages: model, chatID: id)
                }
        }
        .tint(theme.accent.color)
        .sheet(isPresented: $composing) {
            NewMessageView(model: model) { chat in
                composing = false
                if let chat { opened = chat }
            }
        }
        .task { await model.connect() }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { model.notice = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            MessagesStateView(systemImage: "bubble.left.and.bubble.right", title: "Getting your messages", detail: "Connecting to Totality's Matrix server. Everything here is end-to-end encrypted.", busy: true)
        case .failed(let reason):
            MessagesStateView(systemImage: "exclamationmark.bubble", title: "Messages couldn't open", detail: reason, action: .init(label: "Try again") {
                Task { await model.connect() }
            })
        case .unavailable(let reason):
            MessagesStateView(systemImage: "bubble.left", title: "Messages isn't here yet", detail: reason)
        case .ready:
            list
        }
    }

    private var list: some View {
        let theme = Theme.current
        let chats = model.filtered(query)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s3) {
                if model.connection == .offline {
                    Banner(text: "You're offline. Earlier messages still open, and new ones send when you're back.")
                }
                if let notice = model.notice {
                    Banner(text: notice)
                }
                SearchField(text: $query)
                if !model.requests.isEmpty && query.isEmpty {
                    SectionTitle("Requests")
                    ForEach(model.requests) { request in
                        RequestRow(request: request, model: model)
                    }
                    SectionTitle("Chats")
                }
                if model.chats.isEmpty {
                    MessagesStateView(
                        systemImage: "bubble.left.and.bubble.right",
                        title: "No conversations yet",
                        detail: "Message anyone on Totality by their username. Only the two of you can read it.",
                        action: .init(label: "New message") { composing = true }
                    )
                    .frame(minHeight: Space.s8 * 5)
                } else if chats.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.top, Space.s4)
                } else {
                    ForEach(chats) { chat in
                        Button { opened = chat.id } label: { ChatRow(chat: chat) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .animation(Motion.quick, value: model.requests)
            .animation(Motion.quick, value: model.connection)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                MessagesBarIcon("Home", systemImage: "circle.hexagongrid", action: onClose)
            }
        }
        if model.phase == .ready {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: Space.s3) {
                    Menu {
                        Toggle("Send read receipts and typing", isOn: $shareReadAndTyping)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(Typeface.body)
                            .imageScale(.large)
                            .frame(minWidth: Space.s6, minHeight: Space.s6)
                    }
                    .accessibilityLabel("Messages settings")
                    MessagesBarIcon("New message", systemImage: "square.and.pencil") { composing = true }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSummary

    var body: some View {
        let theme = Theme.current
        let unread = chat.unread > 0
        HStack(spacing: Space.s3) {
            Initial(name: chat.title)
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(unread ? Typeface.headline : Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: Space.s2)
                    if let time = chat.lastActivity {
                        Text(MessagesTime.short(time))
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.lastMessage ?? "No messages yet")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                    Spacer(minLength: Space.s2)
                    // Unread is the one accent dot, so the row needs no other colour.
                    Circle()
                        .fill(unread ? theme.accent.color : Color.clear)
                        .frame(width: Space.s2, height: Space.s2)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(Space.s3)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread ? "Unread, \(chat.title)" : chat.title)
    }
}

private struct RequestRow: View {
    let request: ChatSummary
    let model: MessagesModel
    @State private var confirmingBlock = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Initial(name: request.title)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("@\(request.title)")
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    Text("Wants to message you. They can't see anything about you until you accept.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            HStack(spacing: Space.s5) {
                Button("Accept") { Task { await model.accept(request) } }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                Button("Delete") { Task { await model.decline(request) } }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                Button("Block") { confirmingBlock = true }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.danger.color)
            }
            .buttonStyle(.plain)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        .confirmationDialog("Block @\(request.title)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await model.block(request) } }
        } message: {
            Text("Their request is deleted and nothing more arrives from them.")
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
        .font(Typeface.body)
        .padding(Space.s3)
        .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.headline)
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.top, Space.s2)
    }
}
