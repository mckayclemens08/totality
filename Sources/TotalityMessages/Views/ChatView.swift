import PhotosUI
import SwiftUI
import TotalityUI

/// Opens a conversation and shows it, or says why it couldn't open.
struct ChatScreen: View {
    let messages: MessagesModel
    let chatID: String
    @Environment(\.dismiss) private var dismiss
    @State private var chat: ChatModel?
    @State private var problem: String?

    var body: some View {
        Group {
            if let chat {
                ChatView(model: chat, messages: messages) { dismiss() }
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
    let messages: MessagesModel
    /// Goes back to the list, after leaving the chat or blocking the person in it.
    let onGone: () -> Void
    @FocusState private var writing: Bool
    @State private var playing: ChatMessage?
    @State private var confirmingBlock = false
    /// A disappearing setting waiting for the person to confirm it.
    @State private var pendingSetting: Disappearing?
    @State private var confirmingLeave = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var viewing: ChatMessage?
    @State private var deleting: ChatMessage?
    @State private var showingCamera = false

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.s2) {
                        EncryptionNote()
                        if model.disappearing != .off {
                            DisappearingNote(setting: model.disappearing, changedBy: model.disappearingChangedBy)
                        }
                        if model.loaded && model.messages.isEmpty {
                            Text("No messages yet. Say hello.")
                                .font(Typeface.body)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.top, Space.s5)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            Bubble(
                                message: message,
                                model: model,
                                showsSender: !message.isOwn && (index == 0 || model.messages[index - 1].sender != message.sender),
                                showsSeen: message.seen && model.messages[(index + 1)...].allSatisfy { !$0.isOwn || !$0.seen },
                                onRetry: { Task { await model.retry(message) } },
                                onOpenPhoto: { if message.isVideo { playing = message } else { viewing = message } },
                                onReply: {
                                    model.replyingTo = message
                                    writing = true
                                },
                                onDelete: { deleting = message }
                            )
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
            if let reply = model.replyingTo {
                ReplyBar(message: reply) { model.replyingTo = nil }
            }
            composer
        }
        .background(theme.bg.color)
        .navigationTitle(model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.start() }
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            pickedPhoto = nil
            Task {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        await model.sendVideo(movie.url)
                    } else {
                        model.notice = "That video couldn't be opened."
                    }
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.sendPhoto(data)
                } else {
                    model.notice = "That photo couldn't be opened."
                }
            }
        }
        .sheet(item: $viewing) { message in
            PhotoViewer(message: message, model: model) { viewing = nil }
        }
        .sheet(item: $playing) { message in
            VideoViewer(message: message, model: model) { playing = nil }
        }
        .toolbar { chatMenu }
        .confirmationDialog(
            "Disappearing messages: \(pendingSetting?.label.lowercased() ?? "")?",
            isPresented: Binding(get: { pendingSetting != nil }, set: { if !$0 { pendingSetting = nil } }),
            titleVisibility: .visible,
            presenting: pendingSetting
        ) { setting in
            Button("Turn on for everyone here") { Task { await model.setDisappearing(setting) } }
            Button("Cancel", role: .cancel) {}
        } message: { setting in
            Text("\(setting.explanation) Everyone in this chat sees that you turned it on.")
        }
        .confirmationDialog(
            "Block \(model.otherPerson.map(MessagesUsername.display) ?? "them")?",
            isPresented: $confirmingBlock, titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                guard let person = model.otherPerson else { return }
                Task { if await messages.block(person: person, leaving: model.chatID) { onGone() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing more from them reaches you, and this chat closes. They aren't told. You can unblock them from Messages' menu.")
        }
        .confirmationDialog(
            model.isGroup ? "Leave this group?" : "Leave this chat?",
            isPresented: $confirmingLeave, titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { if await messages.leave(model.chatID) { onGone() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes from your list, and you won't get new messages from it unless someone adds you again.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { result in
                showingCamera = false
                switch result {
                case .photo(let data): Task { await model.sendPhoto(data) }
                case .video(let url): Task { await model.sendVideo(url) }
                case nil: break
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .confirmationDialog(
            "Delete this message for everyone?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { message in
            Button("Delete for everyone", role: .destructive) {
                Task { await model.delete(message) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from this chat on every device that still has it. Someone may already have seen it.")
        }
    }

    @ToolbarContentBuilder private var chatMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Disappearing messages", selection: Binding(
                    get: { model.disappearing },
                    set: { setting in
                        if setting == .off {
                            Task { await model.setDisappearing(.off) }
                        } else {
                            pendingSetting = setting
                        }
                    }
                )) {
                    ForEach(Disappearing.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                if model.otherPerson != nil {
                    Button("Block \(MessagesUsername.display(model.otherPerson ?? ""))", systemImage: "hand.raised", role: .destructive) {
                        confirmingBlock = true
                    }
                }
                Button(model.isGroup ? "Leave group" : "Leave chat", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    confirmingLeave = true
                }
            } label: {
                Image(systemName: model.disappearing == .off ? "ellipsis.circle" : "timer")
                    .font(Typeface.body)
                    .imageScale(.large)
            }
            .accessibilityLabel("Chat settings")
        }
    }

    private var composer: some View {
        let theme = Theme.current
        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = model.sendingPhoto || model.sendingVideo
        let accent = theme.accent.color
        return HStack(alignment: .bottom, spacing: Space.s3) {
            #if os(iOS)
            if CameraPicker.isAvailable {
                MessagesBarIcon("Camera", systemImage: "camera") { showingCamera = true }
                    .padding(.bottom, Space.s2)
            }
            #endif
            PhotosPicker(selection: $pickedPhoto, matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible) {
                Image(systemName: busy ? "hourglass" : "photo")
                    .font(Typeface.title)
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
            }
            .disabled(busy)
            .accessibilityLabel("Send a photo or video")
            .padding(.bottom, Space.s2)
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
        Label("End-to-end encrypted, photos too. The server can see who you talk to and when, but not what you send.", systemImage: "lock")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s3)
    }
}

/// Shown at the top of a chat while disappearing messages are on, with what it can't do.
private struct DisappearingNote: View {
    let setting: Disappearing
    let changedBy: String?

    var body: some View {
        let theme = Theme.current
        let who = changedBy.map { " Turned on by \(MessagesUsername.display($0))." } ?? ""
        Label("Disappearing messages: \(setting.label.lowercased()).\(who) \(setting.explanation) They can't stop a screenshot or another camera.", systemImage: "timer")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.s2)
    }
}

/// What the next message answers, above the box, with a way to stop replying.
private struct ReplyBar: View {
    let message: ChatMessage
    let onCancel: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(message.isOwn ? "Replying to yourself" : "Replying to \(MessagesUsername.display(message.sender))")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.accent.color)
                Text(message.body)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop replying")
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let model: ChatModel
    let showsSender: Bool
    let showsSeen: Bool
    let onRetry: () -> Void
    let onOpenPhoto: () -> Void
    let onReply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Space.s1) {
            if showsSender {
                Text(MessagesUsername.display(message.sender))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                if let reply = message.replyTo {
                    QuotedReply(reply: reply)
                }
                content
            }
            .contextMenu { menu }
            if !message.decrypted {
                Text("It will open once the sender's device shares the key, usually when they're next online.")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
            }
            if !message.reactions.isEmpty {
                Reactions(reactions: message.reactions) { key in
                    Task { await model.toggleReaction(key, on: message) }
                }
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: message.isOwn ? .trailing : .leading)
        .padding(message.isOwn ? .leading : .trailing, Space.s7)
    }

    @ViewBuilder private var content: some View {
        let theme = Theme.current
        switch message.kind {
        case .photo:
            PhotoBubble(message: message, model: model, onOpen: onOpenPhoto)
        case .video:
            VideoBubble(message: message, model: model, onOpen: onOpenPhoto)
        case .deleted:
            Text("Message deleted")
                .font(Typeface.caption)
                .italic()
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        case .text:
            Text(message.body)
                .font(message.decrypted ? Typeface.body : Typeface.caption)
                .italic(!message.decrypted)
                .foregroundStyle(message.decrypted ? theme.textPrimary.color : theme.textSecondary.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .background {
                    // Your own messages sit on the pale accent, everyone else's on the surface.
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(message.isOwn ? theme.highlight.color : theme.surface.color)
                }
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        }
    }

    @ViewBuilder private var menu: some View {
        if message.kind != .deleted && message.decrypted && message.state == .sent {
            ControlGroup {
                ForEach(QuickReactions.all, id: \.self) { key in
                    Button(key) { Task { await model.toggleReaction(key, on: message) } }
                }
            }
            .controlGroupStyle(.compactMenu)
        }
        if message.canReply && message.kind != .deleted {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
        }
        if let text = message.copyableText {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
        }
        if message.canDelete {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
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

/// The message a reply answers, small, above the reply.
private struct QuotedReply: View {
    let reply: ReplyPreview

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: 2) {
            if !reply.sender.isEmpty {
                Text(MessagesUsername.display(reply.sender))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.accent.color)
            }
            Text(reply.text)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(2)
        }
        .padding(.leading, Space.s2)
        .overlay(alignment: .leading) {
            Capsule().fill(theme.accent.color.opacity(0.5)).frame(width: 2)
        }
        .padding(.horizontal, Space.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to: \(reply.text)")
    }
}

/// Reactions under a message. Tapping one adds yours or takes it away.
private struct Reactions: View {
    let reactions: [ChatReaction]
    let onTap: (String) -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1) {
            ForEach(reactions, id: \.key) { reaction in
                Button { onTap(reaction.key) } label: {
                    HStack(spacing: 2) {
                        Text(reaction.key)
                        if reaction.count > 1 {
                            Text("\(reaction.count)").font(Typeface.micro).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(reaction.mine ? theme.highlight.color : theme.surface.color))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reaction.key), \(reaction.count)\(reaction.mine ? ", including you" : "")")
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
