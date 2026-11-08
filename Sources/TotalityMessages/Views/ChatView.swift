import SwiftUI
import TotalityUI

/// Opens a conversation and shows it, or says why it couldn't open.
struct ChatScreen: View {
    let messages: MessagesModel
    let chatID: String
    @State private var chat: ChatModel?
    @State private var problem: String?

    var body: some View {
        Group {
            if let chat {
                ChatView(model: chat)
            } else if let problem {
                MessagesStateView(systemImage: "exclamationmark.bubble", title: "This chat couldn't open", detail: problem)
            } else {
                MessagesStateView(systemImage: "bubble.left", title: "Opening", detail: "", busy: true)
            }
        }
        .background(Theme.current.bg.color)
        .task(id: chatID) {
            do {
                chat = try await messages.open(chatID)
            } catch {
                problem = MessagesModel.describe(error)
            }
        }
        .onDisappear { chat?.close() }
    }
}

/// A conversation: messages oldest at the top, who's typing, and the box to write in.
struct ChatView: View {
    @Bindable var model: ChatModel
    @FocusState private var writing: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.s2) {
                        EncryptionNote()
                        if model.loaded && model.messages.isEmpty {
                            Text("No messages yet. Say hello.")
                                .font(Typeface.body)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.top, Space.s5)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            Bubble(
                                message: message,
                                showsSender: !message.isOwn && (index == 0 || model.messages[index - 1].sender != message.sender),
                                showsSeen: message.seen && model.messages[(index + 1)...].allSatisfy { !$0.isOwn || !$0.seen }
                            ) {
                                Task { await model.retry(message) }
                            }
                            .id(message.id)
                        }
                        if !model.typing.isEmpty {
                            Text(model.typing.count == 1 ? "\(model.typing[0]) is typing…" : "Several people are typing…")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messages.last?.id) {
                    guard let last = model.messages.last?.id else { return }
                    withAnimation(Motion.quick) { proxy.scrollTo(last, anchor: .bottom) }
                }
                .refreshable { await model.loadEarlier() }
            }
            if let notice = model.notice {
                Banner(text: notice).padding(.horizontal, Space.s4)
            }
            composer
        }
        .background(theme.bg.color)
        .navigationTitle(model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.start() }
    }

    private var composer: some View {
        let theme = Theme.current
        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: Space.s3) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .lineLimit(1...6)
                .focused($writing)
                .padding(Space.s3)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
                .onChange(of: model.draft) { Task { await model.draftChanged() } }
                .onSubmit { Task { await model.send() } }
            MessagesBarIcon("Send", systemImage: "arrow.up.circle.fill", isEnabled: !empty) {
                Task { await model.send() }
            }
            .padding(.bottom, Space.s2)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(theme.bg.color)
    }
}

/// Said once at the top of every chat, because it's literally true: the server only relays ciphertext.
private struct EncryptionNote: View {
    var body: some View {
        let theme = Theme.current
        Label("End-to-end encrypted. The server can see who you talk to and when, but not what you say.", systemImage: "lock")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s3)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let showsSender: Bool
    let showsSeen: Bool
    let onRetry: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Space.s1) {
            if showsSender {
                Text(MessagesUsername.display(message.sender))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Text(message.body)
                .font(message.decrypted ? Typeface.body : Typeface.caption)
                .italic(!message.decrypted)
                .foregroundStyle(message.decrypted ? theme.textPrimary.color : theme.textSecondary.color)
                .textSelection(.enabled)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .background {
                    // Your own messages sit on the pale accent, everyone else's on the surface.
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(message.isOwn ? theme.highlight.color : theme.surface.color)
                }
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
            if !message.decrypted {
                Text("It will open once the sender's device shares the key, usually when they're next online.")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: message.isOwn ? .trailing : .leading)
        .padding(message.isOwn ? .leading : .trailing, Space.s7)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        let theme = Theme.current
        switch message.state {
        case .sending:
            Text("Not sent yet")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
        case .failed(let canRetry):
            if canRetry {
                Button("Didn't send. Tap to try again", action: onRetry)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.danger.color)
                    .buttonStyle(.plain)
            } else {
                Text("Couldn't send")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.danger.color)
            }
        case .sent:
            if showsSeen {
                Text("Read")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            } else if message.isOwn {
                Text(MessagesTime.short(message.time))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
            }
        }
    }
}

/// Starts a conversation by username.
struct NewMessageView: View {
    let model: MessagesModel
    let onDone: (String?) -> Void
    @State private var username = ""
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s1) {
                    // The @ is already there, so people type only the name.
                    Text("@").foregroundStyle(theme.textSecondary.color).accessibilityHidden(true)
                    TextField("username", text: $username)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focused)
                        .onSubmit(start)
                        .accessibilityLabel("Their username")
                }
                .font(Typeface.body)
                .padding(Space.s3)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
                Text("If you haven't talked before, they'll see a request to accept first.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if let notice = model.notice {
                    Text(notice)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                }
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("New message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Chat", action: start)
                            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear {
            model.notice = nil
            focused = true
        }
    }

    private func start() {
        guard !working else { return }
        working = true
        Task {
            let chat = await model.startChat(with: username)
            working = false
            if let chat { onDone(chat) }
        }
    }
}
