import SwiftUI
import TotalityCore
import TotalityUI

/// Messages' first screen: requests, then conversations newest first, a search box, and New message.
/// Nothing else competes for space.
public struct MessagesHomeView: View {
    @Bindable private var model: MessagesModel
    private let onClose: (() -> Void)?

    @State private var opened: String?
    @State private var composing = false
    @State private var query = ""
    @State private var showingCamera = false
    /// What the camera took, waiting for its chat to be chosen.
    @State private var taken: TakenMedia?
    @State private var makingGroup = false
    @State private var showingBlocked = false
    @AppStorage(MessagesPreferences.shareReadAndTypingKey) private var shareReadAndTyping = true

    public init(model: MessagesModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    /// Opens a chat the home tile or search asked for.
    private func openRequested() {
        guard let chat = model.requestedChat else { return }
        model.requestedChat = nil
        opened = chat
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { result in
                showingCamera = false
                switch result {
                case .photo(let data): taken = .photo(data)
                case .video(let url): taken = .video(url)
                case nil: break
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .sheet(isPresented: Binding(get: { taken != nil }, set: { shown in
            // Swiped away: a video from the camera mustn't be left behind.
            if !shown, case .video(let url)? = taken { try? FileManager.default.removeItem(at: url) }
            if !shown { taken = nil }
        })) {
            ChooseChatView(model: model) { chat in
                let media = taken
                taken = nil
                switch (chat, media) {
                case (let chat?, .photo(let data)?):
                    Task { if await model.sendPhoto(data, to: chat) { opened = chat } }
                case (let chat?, .video(let url)?):
                    Task { if await model.sendVideo(url, to: chat) { opened = chat } }
                case (nil, .video(let url)?):
                    try? FileManager.default.removeItem(at: url)
                default:
                    break
                }
            }
        }
        .sheet(isPresented: $makingGroup) {
            NewGroupView(model: model) { chat in
                makingGroup = false
                if let chat { opened = chat }
            }
        }
        .sheet(isPresented: $showingBlocked) {
            BlockedView(model: model) { showingBlocked = false }
        }
        .task { await model.connect() }
        .onAppear(perform: openRequested)
        .onChange(of: model.requestedChat) { openRequested() }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { model.notice = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            MessagesStateView(systemImage: "bubble.left.and.bubble.right", title: "Getting your messages", detail: "Connecting to Totality's Matrix server. Your messages here are end-to-end encrypted.", busy: true)
        case .failed(let reason):
            MessagesStateView(systemImage: "exclamationmark.bubble", title: "Messages couldn't open", detail: reason, action: .init(label: "Try again") {
                Task { await model.connect() }
            })
        case .unavailable(let reason):
            MessagesStateView(systemImage: "bubble.left", title: "Messages isn't here yet", detail: reason)
        case .ready:
            list
                .pullsToRefresh(with: model.refresher)
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
                        Button { opened = chat.id } label: { ChatRow(chat: chat, messages: model) }
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
                        Button("New group", systemImage: "person.3") { makingGroup = true }
                        Button("Blocked people", systemImage: "hand.raised") { showingBlocked = true }
                        Toggle("Send read receipts and typing", isOn: $shareReadAndTyping)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(Typeface.body)
                            .imageScale(.large)
                            .frame(minWidth: Space.s6, minHeight: Space.s6)
                    }
                    .accessibilityLabel("Messages settings")
                    #if os(iOS)
                    if CameraPicker.isAvailable && !model.chats.isEmpty {
                        MessagesBarIcon("Camera", systemImage: "camera") { showingCamera = true }
                    }
                    #endif
                    MessagesBarIcon("New message", systemImage: "square.and.pencil") { composing = true }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    let messages: MessagesModel

    var body: some View {
        let theme = Theme.current
        let unread = chat.unread > 0
        HStack(spacing: Space.s3) {
            GroupAvatar(title: chat.title, location: chat.photo, messages: messages)
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

/// Where a photo from the camera goes: one of your chats.
struct ChooseChatView: View {
    let model: MessagesModel
    let onDone: (String?) -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Space.s3) {
                    ForEach(model.chats) { chat in
                        Button { onDone(chat.id) } label: { ChatRow(chat: chat, messages: model) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Send photo to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
            }
        }
        .tint(theme.accent.color)
    }
}

/// A photo or video from the camera on the chat list.
private enum TakenMedia {
    case photo(Data)
    case video(URL)
}

/// Starts a small group by usernames.
struct NewGroupView: View {
    let model: MessagesModel
    let onDone: (String?) -> Void
    @State private var usernames = ""
    @State private var groupName = ""
    @State private var photo: Data?
    @State private var working = false
    /// Kept here: the chat list clears its own notices after a moment.
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                TextField("Usernames, separated by commas", text: $usernames, axis: .vertical)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .font(Typeface.body)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(Space.s3)
                    .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityLabel("Their usernames")
                Text("Up to \(GroupMembers.limit) people, you included. Each of them gets a request to accept.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                GroupFields(name: $groupName, photo: $photo)
                if let problem {
                    Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("New group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Start", action: start)
                            .disabled(usernames.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear { focused = true }
        .onChange(of: usernames) { problem = nil }
    }

    private func start() {
        guard !working else { return }
        working = true
        Task {
            let chat = await model.startGroup(with: usernames, name: groupName, photo: photo)
            working = false
            if let chat {
                onDone(chat)
            } else {
                problem = model.notice
                model.notice = nil
            }
        }
    }
}

/// The people you've blocked, each with Unblock.
struct BlockedView: View {
    let model: MessagesModel
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s3) {
                    if let notice = model.notice {
                        Text(notice).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                    if model.blockedPeople.isEmpty {
                        MessagesStateView(systemImage: "hand.raised", title: "No one is blocked", detail: "When you block someone, nothing more from them reaches you.")
                    }
                    ForEach(model.blockedPeople, id: \.self) { person in
                        HStack {
                            Text(MessagesUsername.display(person)).font(Typeface.body)
                            Spacer()
                            Button("Unblock") { Task { await model.unblock(person) } }
                                .font(Typeface.callout)
                        }
                        .padding(Space.s3)
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Blocked people")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .tint(theme.accent.color)
        .task { await model.loadBlocked() }
    }
}
