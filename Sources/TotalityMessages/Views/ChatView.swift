import SwiftUI
import TotalityCore
import TotalityUI

/// Opens a conversation and shows it, or says why it couldn't open.
struct ChatScreen: View {
    let messages: MessagesModel
    let chatID: String
    /// Opens Account, where the recovery key is entered.
    var onOpenAccount: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var chat: ChatModel?
    @State private var problem: String?

    var body: some View {
        Group {
            if let chat {
                ChatView(model: chat, messages: messages, onOpenAccount: onOpenAccount) { dismiss() }
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
    var onOpenAccount: (() -> Void)? = nil
    /// Goes back to the list, after leaving the chat or blocking the person in it.
    let onGone: () -> Void
    @Environment(\.askTotality) private var askTotality
    @FocusState private var writing: Bool
    @State private var playing: ChatMessage?
    /// A message being added to Tasks (step 4).
    @State private var taskDraft: TaskDraft?
    @State private var confirmingBlock = false
    /// A disappearing setting waiting for the person to confirm it.
    @State private var pendingSetting: Disappearing?
    @State private var confirmingLeave = false
    @State private var editingGroup = false
    @State private var invitingToChannel = false
    @State private var showingInfo = false
    @State private var viewing: ChatMessage?
    @State private var viewingOnce: ChatMessage?
    /// Choosing how to send a photo that opens once.
    @State private var choosingOnce = false
    @State private var cameraOnce = false
    @State private var showingOncePhotos = false
    @State private var deleting: ChatMessage?
    @State private var showingCamera = false
    @State private var showingPhotos = false
    /// The newest message is on screen. New ones scroll into view only then, so reading back isn't interrupted.
    @State private var atBottom = true
    /// The chat has been shown at its newest message once, after it first loaded.
    @State private var startedAtBottom = false
    /// Whose profile is open, by Matrix ID.
    @State private var showingPerson: ShownPerson?

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.s2) {
                        if let access = model.channelAccess {
                            ChannelNote(access: access, followers: model.channelFollowers, invited: model.channelInvited)
                        } else {
                            EncryptionNote(isGroup: model.isGroup)
                        }
                        if !model.extraPeople.isEmpty {
                            ExtraPeopleNote(people: model.extraPeople, with: model.otherPerson)
                        }
                        if model.disappearing != .off {
                            DisappearingNote(setting: model.disappearing, changedBy: model.disappearingChangedBy)
                        }
                        if model.loaded && model.messages.isEmpty {
                            Text(model.channelAccess == nil ? "No messages yet. Say hello." : "No posts yet.")
                                .font(Typeface.body)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.top, Space.s5)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            bubble(message, at: index)
                                .id(message.id)
                        }
                        if !model.typing.isEmpty {
                            Text(model.typing.count == 1 ? "\(model.typing[0]) is typing…" : "Several people are typing…")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("typing")
                        }
                        // Seen only while the bottom of the chat is on screen.
                        Color.clear
                            .frame(height: 1)
                            .id(ChatScroll.bottom)
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messages.last?.id) {
                    guard let last = model.messages.last else { return }
                    if !startedAtBottom {
                        // The first messages arrive a few at a time: land on the newest without animating,
                        // and again once the list has laid itself out.
                        startedAtBottom = true
                        proxy.scrollTo(ChatScroll.bottom, anchor: .bottom)
                        Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            proxy.scrollTo(ChatScroll.bottom, anchor: .bottom)
                        }
                    } else if ChatScroll.follows(atBottom: atBottom, newestIsOwn: last.isOwn) {
                        withMotion(Motion.snappy) { proxy.scrollTo(ChatScroll.bottom, anchor: .bottom) }
                    }
                }
                .onChange(of: model.typing.isEmpty) {
                    if atBottom { withMotion(Motion.snappy) { proxy.scrollTo(ChatScroll.bottom, anchor: .bottom) } }
                }
                .refreshable { await model.loadEarlier() }
            }
            if let notice = model.notice {
                Banner(text: notice).padding(.horizontal, Space.s4)
            }
            if let reply = model.replyingTo {
                ReplyBar(message: reply) { model.replyingTo = nil }
            }
            if let access = model.channelAccess, !access.canPost {
                ChannelFollowerBar(owner: model.channelOwner) { messageOwner() }
            } else {
                composer
            }
        }
        .background(theme.bg.color)
        .navigationTitle(chatTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Reply on the home square opens the chat ready to write.
            if messages.requestedWriting == model.chatID {
                messages.requestedWriting = nil
                writing = true
            }
            await model.start()
        }
        .task(id: otherSenders) {
            // Group members' names and photos; the one other person in a chat is fetched by the list.
            guard model.isGroup else { return }
            await messages.people.want(matrixIDs: Array(otherSenders))
        }
        .sheet(item: $showingPerson) { personSheet($0) }
        .photoChooser(isPresented: $showingPhotos, kinds: .photosAndVideos) { media in
            switch media.first {
            case .video(let url)?: await model.sendVideo(url)
            case .photo(let data, _)?: await model.sendPhoto(data)
            case nil: model.notice = "That photo couldn't be opened."
            }
        }
        .sheet(item: $viewing) { message in
            PhotoViewer(message: message, model: model) { viewing = nil }
        }
        .sheet(item: $viewingOnce) { message in
            OnceViewer(message: message, model: model) { viewingOnce = nil }
        }
        .photoChooser(isPresented: $showingOncePhotos) { media in
            if case .photo(let data, _)? = media.first {
                await model.sendPhoto(data, viewOnce: true)
            } else {
                model.notice = "That photo couldn't be opened."
            }
        }
        .confirmationDialog("Send a photo that opens once?", isPresented: $choosingOnce, titleVisibility: .visible) {
            Button("Choose from your library") { showingOncePhotos = true }
            if camera {
                Button("Take a photo") {
                    cameraOnce = true
                    showingCamera = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ViewOnce.explanation)
        }
        .sheet(item: $playing) { message in
            VideoViewer(message: message, model: model) { playing = nil }
        }
        .addToTasksSheet($taskDraft, maker: messages.taskMaker) { made in model.notice = made.line }
        .toolbar { chatMenu }
        .sheet(isPresented: $invitingToChannel) {
            InviteToChannelView(model: messages, chat: model.chatID, members: model.channelMembers, invited: model.channelInvited) { invitingToChannel = false }
        }
        .sheet(isPresented: $showingInfo) {
            ChatInfoView(chat: model, messages: messages, onLeft: { showingInfo = false; onGone() }, onDone: { showingInfo = false })
        }
        .sheet(isPresented: $editingGroup) {
            GroupDetailsView(chat: model, messages: messages) { editingGroup = false }
        }
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
                let once = cameraOnce
                cameraOnce = false
                switch result {
                case .photo(let data): Task { await model.sendPhoto(data, viewOnce: once) }
                case .video(let url):
                    if once {
                        try? FileManager.default.removeItem(at: url)
                        model.notice = "Only photos can open once. A video wasn't sent."
                    } else {
                        Task { await model.sendVideo(url) }
                    }
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

    private func bubble(_ message: ChatMessage, at index: Int) -> some View {
        let people = messages.people
        let opensSender = model.isGroup && MessagesPeople.handle(of: message.sender) != nil
        return Bubble(
            message: message,
            model: model,
            showsSender: !message.isOwn && (index == 0 || model.messages[index - 1].sender != message.sender),
            senderName: people.name(ofMatrixID: message.sender),
            senderPhoto: model.isGroup ? people.profile(ofMatrixID: message.sender)?.photo : nil,
            onOpenSender: opensSender ? { showingPerson = ShownPerson(id: message.sender) } : nil,
            showsSeen: message.seen && model.messages[(index + 1)...].allSatisfy { !$0.isOwn || !$0.seen },
            onRetry: { Task { await model.retry(message) } },
            onOpenPhoto: {
                if message.viewOnce { viewingOnce = message } else if message.isVideo { playing = message } else { viewing = message }
            },
            onReply: {
                model.replyingTo = message
                writing = true
            },
            onDelete: { deleting = message },
            onAddToTasks: messages.taskMaker == nil || message.kind == .deleted ? nil : { taskDraft = draft(for: message) },
            onAskTotality: askTotality == nil || message.kind == .deleted ? nil : {
                let who = message.isOwn ? "You" : people.name(ofMatrixID: message.sender)
                let when = message.time.formatted(date: .abbreviated, time: .shortened)
                askTotality?(AIAskContext(
                    id: "\(model.chatID):\(message.id)",
                    module: .messages,
                    title: model.title,
                    detail: "\(who) · \(when)",
                    body: message.copyableText ?? "",
                    date: message.time
                ))
            },
            keys: messages.keys,
            onRestore: onOpenAccount
        )
    }

    /// Only the title the person writes and a link to this chat go to Tasks. The message's words aren't
    /// copied (decision 4).
    private func draft(for message: ChatMessage) -> TaskDraft {
        let who = message.isOwn ? "You" : messages.people.name(ofMatrixID: message.sender)
        let when = message.time.formatted(date: .abbreviated, time: .shortened)
        return TaskDraft(
            title: "",
            source: TaskSource(module: .messages, itemID: model.chatID, title: model.title, detail: "\(who) · \(when)")
        )
    }

    private func personSheet(_ shown: ShownPerson) -> some View {
        // From the header it's this chat; from a group it's a chat with just them.
        let isThisChat = shown.id == model.otherPerson && !model.isGroup
        return PersonSheet(matrixID: shown.id, people: messages.people) {
            showingPerson = nil
            guard !isThisChat else { return }
            Task {
                if let chat = await messages.startChat(with: MessagesUsername.display(shown.id)) {
                    messages.requestedChat = chat
                }
            }
        }
    }

    /// The group members whose names and photos are needed.
    private var otherSenders: Set<String> {
        Set(model.messages.lazy.filter { !$0.isOwn }.map(\.sender))
    }

    /// A chat with one person goes by their profile's name once it's known.
    private var chatTitle: String {
        guard !model.isGroup, let person = model.otherPerson else { return model.title }
        return messages.people.profile(ofMatrixID: person)?.name ?? model.title
    }

    /// A follower's way to the owner: their private chat, which then shows in the list.
    private func messageOwner() {
        guard let owner = model.channelOwner else { return }
        Task {
            if await messages.startChat(with: MessagesUsername.display(owner)) != nil { onGone() }
            else { model.notice = messages.notice; messages.notice = nil }
        }
    }

    @ToolbarContentBuilder private var chatMenu: some ToolbarContent {
        if let access = model.channelAccess, access.canInvite {
            ToolbarItem(placement: .primaryAction) {
                Button { invitingToChannel = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Invite followers")
            }
        }
        if !model.isGroup, let person = model.otherPerson, MessagesPeople.handle(of: person) != nil {
            ToolbarItem(placement: .principal) {
                Button { showingPerson = ShownPerson(id: person) } label: {
                    HStack(spacing: Space.s2) {
                        PersonFace(photo: messages.people.profile(ofMatrixID: person)?.photo, name: chatTitle, diameter: Space.s6)
                        Text(chatTitle)
                            .font(Typeface.headline)
                            .foregroundStyle(Theme.current.textPrimary.color)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chatTitle), view profile")
            }
        }
        if model.isGroup {
            ToolbarItem(placement: .principal) {
                Button { showingInfo = true } label: {
                    HStack(spacing: Space.s2) {
                        if model.channelAccess != nil {
                            Image(systemName: "megaphone.fill").foregroundStyle(Theme.current.accent.color)
                        }
                        Text(model.title)
                            .font(Typeface.headline)
                            .foregroundStyle(Theme.current.textPrimary.color)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(Typeface.micro)
                            .foregroundStyle(Theme.current.textSecondary.color)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.title), \(model.channelAccess != nil ? "channel" : "group") info")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            TimerChip(
                setting: model.disappearing,
                choose: { setting in
                    if setting == .off {
                        Task { await model.setDisappearing(.off) }
                    } else if setting != model.disappearing {
                        pendingSetting = setting
                    }
                }
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if model.otherPerson != nil {
                    Button("Block \(MessagesUsername.display(model.otherPerson ?? ""))", systemImage: "hand.raised", role: .destructive) {
                        confirmingBlock = true
                    }
                }
                if model.isGroup {
                    Button("Name and photo", systemImage: "pencil") { editingGroup = true }
                }
                Button(model.isGroup ? "Leave group" : "Leave chat", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    confirmingLeave = true
                }
            } label: {
                ToolbarGlyph(systemImage: "ellipsis")
            }
            .accessibilityLabel("Chat settings")
        }
    }

    private var camera: Bool {
        #if os(iOS)
        CameraPicker.isAvailable
        #else
        false
        #endif
    }

    private var composer: some View {
        ChatComposer(
            draft: $model.draft, writing: $writing,
            busy: model.sendingPhoto || model.sendingVideo, canUseCamera: camera,
            onCamera: { showingCamera = true }, onPhotos: { showingPhotos = true },
            onOnce: { choosingOnce = true },
            onSend: { Task { await model.send() } },
            onDraftChanged: { Task { await model.draftChanged() } }
        )
    }
}

/// The bar at the bottom of a chat: one raised capsule holding a single attach button, the message, and
/// send. The owner chose it on 2026-11-10 over a field with separate outlined camera and photo icons.
struct ChatComposer: View {
    @Binding var draft: String
    var writing: FocusState<Bool>.Binding
    let busy: Bool
    let canUseCamera: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    var onOnce: (() -> Void)? = nil
    let onSend: () -> Void
    let onDraftChanged: () -> Void

    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let theme = Theme.current
        ComposerBar(canSend: !empty, onSend: onSend) {
            Menu {
                if canUseCamera {
                    Button("Take a photo or video", systemImage: "camera", action: onCamera)
                }
                Button("Choose from your library", systemImage: "photo.on.rectangle", action: onPhotos)
                if let onOnce {
                    Button("Photo that opens once", systemImage: "1.circle", action: onOnce)
                }
            } label: {
                ComposerBar<EmptyView, EmptyView>.attachGlyph(busy: busy)
            }
            .disabled(busy)
            .accessibilityLabel(busy ? "Sending a photo or video" : "Add a photo or video")
        } field: {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1...6)
                .focused(writing)
                .onChange(of: draft) { onDraftChanged() }
                .onSubmit(onSend)
        }
    }
}

/// The composer's layout on its own: attach, the field, and send in one raised capsule. Kept apart from
/// the menu and text field so a render can draw it with stand-ins for those system controls.
struct ComposerBar<Attach: View, Field: View>: View {
    let canSend: Bool
    let onSend: () -> Void
    @ViewBuilder let attach: Attach
    @ViewBuilder let field: Field

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .bottom, spacing: Space.s2) {
            attach
            field
                .padding(.vertical, Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(Typeface.callout.weight(.bold))
                    .foregroundStyle(canSend ? theme.accentOn.color : theme.textTertiary.color)
                    .frame(width: ToolbarGlyph.diameter, height: ToolbarGlyph.diameter)
                    .background(Circle().fill(canSend ? theme.accent.color : theme.surfaceSunken.color))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(Space.s1 + Space.s1 / 2)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s3)
        .background(theme.bg.color)
    }

    /// The single attach button's face.
    static func attachGlyph(busy: Bool) -> some View {
        let theme = Theme.current
        return Image(systemName: busy ? "hourglass" : "plus")
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(theme.textSecondary.color)
            .frame(width: ToolbarGlyph.diameter, height: ToolbarGlyph.diameter)
            .background(Circle().fill(theme.surfaceSunken.color))
            .contentShape(Circle())
    }
}

/// The chat's disappearing timer, always in the header: what it's set to, and one tap to change it.
/// Changing it asks first (the sheet says what it does), except turning it off.
struct TimerChip: View {
    let setting: Disappearing
    let choose: (Disappearing) -> Void

    var body: some View {
        let theme = Theme.current
        let on = setting != .off
        Menu {
            Section("Disappearing messages") {
                ForEach(Disappearing.allCases) { option in
                    Button {
                        choose(option)
                    } label: {
                        if option == setting {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Space.s1) {
                Image(systemName: "timer")
                Text(on ? setting.short : "Off")
            }
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(on ? theme.accentOn.color : theme.textSecondary.color)
            .padding(.horizontal, Space.s3)
            .frame(height: ToolbarGlyph.diameter)
            .background(Capsule().fill(on ? theme.accent.color : theme.surface.color))
            .neumorphic(.subtle, in: Capsule())
        }
        .accessibilityLabel(on ? "Disappearing messages: \(setting.label.lowercased())" : "Disappearing messages: off")
        .accessibilityHint("Changes how long messages in this chat last")
    }
}

/// Said once at the top of every chat, because it's literally true: the server only relays ciphertext.
private struct EncryptionNote: View {
    let isGroup: Bool

    var body: some View {
        let theme = Theme.current
        let group = isGroup ? " \(GroupLabels.notEncrypted)" : ""
        Label("Messages are end-to-end encrypted, photos too. The server can see who you talk to and when, but not what you send.\(group)", systemImage: "lock")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s3)
    }
}

/// A one-to-one chat that someone else has been added to. Said plainly, because what you send reaches them.
private struct ExtraPeopleNote: View {
    let people: [String]
    let with: String?

    var body: some View {
        let theme = Theme.current
        let names = people.map(MessagesUsername.display).formatted(.list(type: .and))
        let fresh = with.map { " To talk to \(MessagesUsername.display($0)) alone, start a new chat with them." } ?? ""
        Label("\(names) \(people.count == 1 ? "is" : "are") also in this chat. Anything you send here reaches them too.\(fresh)", systemImage: "person.2.badge.plus")
            .font(Typeface.caption)
            .foregroundStyle(theme.danger.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.s2)
            .accessibilityAddTraits(.isHeader)
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

struct Bubble: View {
    let message: ChatMessage
    let model: ChatModel
    let showsSender: Bool
    /// The sender's profile name, or their handle.
    var senderName: String = ""
    /// Shown beside a group member's name once their profile has a photo.
    var senderPhoto: Data? = nil
    /// Opens the sender's profile, in groups.
    var onOpenSender: (() -> Void)? = nil
    let showsSeen: Bool
    let onRetry: () -> Void
    let onOpenPhoto: () -> Void
    let onReply: () -> Void
    let onDelete: () -> Void
    var onAddToTasks: (() -> Void)? = nil
    var onAskTotality: (() -> Void)? = nil
    /// Whether this account's message keys are backed up here, which decides what a locked message offers.
    var keys: MessageKeys = .checking
    var onRestore: (() -> Void)? = nil

    var body: some View {
        let theme = Theme.current
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Space.s1) {
            if showsSender {
                let name = senderName.isEmpty ? MessagesUsername.display(message.sender) : senderName
                let label = HStack(spacing: Space.s1) {
                    if onOpenSender != nil {
                        PersonFace(photo: senderPhoto, name: name, diameter: Space.s5)
                    }
                    Text(name)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                }
                if let onOpenSender {
                    Button(action: onOpenSender) { label }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name), view profile")
                } else {
                    label
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                if let reply = message.replyTo {
                    QuotedReply(reply: reply)
                }
                content
            }
            .contextMenu { menu }
            .onTapGesture(count: 2) { heart() }
            .accessibilityAction(named: "Heart") { heart() }
            if !message.decrypted {
                Text(LockedMessage.note(isOwn: message.isOwn))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
                    .multilineTextAlignment(message.isOwn ? .trailing : .leading)
                if LockedMessage.offersRestore(isOwn: message.isOwn, keys: keys), let onRestore {
                    Button(LockedMessage.restoreLabel, action: onRestore)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                        .buttonStyle(.plain)
                }
            }
            if let marker = model.marker(for: message) {
                Label(marker, systemImage: "timer")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel(marker)
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
        case .photo where message.viewOnce:
            OnceTile(message: message, onOpen: onOpenPhoto)
        case .photo:
            PhotoBubble(message: message, model: model, onOpen: onOpenPhoto, onDoubleTap: heart)
        case .video:
            VideoBubble(message: message, model: model, onOpen: onOpenPhoto, onDoubleTap: heart)
        case .deleted:
            Text("Message deleted")
                .font(Typeface.caption)
                .italic()
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        case .text where message.decrypted && SharedContentLink.parse(message.body) != nil:
            if let shared = SharedContentLink.parse(message.body) {
                SharedContentBubble(shared: shared, hooks: model.sharedContent)
            }
        case .text:
            Text(message.decrypted ? message.body : LockedMessage.placeholder(isOwn: message.isOwn))
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

    /// A double tap puts a heart on the message, or takes yours off again.
    private func heart() {
        guard ChatScroll.canHeart(message) else { return }
        Task { await model.toggleReaction(QuickReactions.heart, on: message) }
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
        if let onAskTotality {
            Button("Ask Totality", systemImage: "sparkles", action: onAskTotality)
        }
        if let onAddToTasks {
            Button("Add to Tasks", systemImage: "checkmark.circle", action: onAddToTasks)
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

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                UsernameField(people: model.people, text: $username, autofocus: true, onSubmit: start)
                Text("If you haven't talked before, they'll see a request to accept first.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                RequestOffer(model: model)
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
            model.needsRequest = nil
            model.sentRequestTo = nil
        }
        .onChange(of: username) {
            model.needsRequest = nil
            model.sentRequestTo = nil
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

/// Where a chat's list scrolls to, and when.
enum ChatScroll {
    static let bottom = "chat-bottom"

    /// A new message scrolls into view when you were already at the newest one, or it's one you just sent.
    static func follows(atBottom: Bool, newestIsOwn: Bool) -> Bool { atBottom || newestIsOwn }

    /// Only a message that's on the server and opened can take a reaction.
    static func canHeart(_ message: ChatMessage) -> Bool {
        message.state == .sent && message.decrypted && message.kind != .deleted && message.canReply
    }
}

/// Whose profile is shown from a chat, by Matrix ID.
struct ShownPerson: Identifiable, Equatable {
    let id: String
}

/// Someone's public profile over a chat, fetched if it isn't saved or is more than a day old.
struct PersonSheet: View {
    let matrixID: String
    let people: MessagesPeople
    let onMessage: () -> Void

    var body: some View {
        let username = MessagesPeople.handle(of: matrixID) ?? MessagesUsername.display(matrixID)
        ScrollView {
            PersonProfileView(
                username: username, phase: people.phase(of: username), onMessage: onMessage,
                onRetry: { Task { await people.reload(username) } }
            )
        }
        .background(Theme.current.bg.color)
        .presentationDetents([.medium, .large])
        .task { await people.want(matrixIDs: [matrixID]) }
    }
}
