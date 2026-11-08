import Foundation
import Observation
import TotalityCore

/// The conversation list and requests for whoever is signed in. A different sign-in gets a fresh
/// connection with its own stores, so one account never sees another's chats.
@MainActor
@Observable
public final class MessagesModel {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Signing in and doing the first sync.
        case loading
        case ready
        case failed(String)
        /// This build can't run Messages, with the reason.
        case unavailable(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var chats: [ChatSummary] = []
    public private(set) var requests: [ChatSummary] = []
    public private(set) var connection: Connection = .connecting
    /// The last thing that went wrong with an action, shown until the next one.
    public var notice: String?

    private let account: @Sendable () async -> String?
    private let connector: MessagesConnector?
    private let unavailableReason: String?
    private var service: (any MessagesService)?
    /// Bumped on every connect, so a slow old connection can't write into a newer one's lists.
    private var generation = 0

    public init(
        account: @escaping @Sendable () async -> String?,
        connector: MessagesConnector?,
        unavailableReason: String? = nil
    ) {
        self.account = account
        self.connector = connector
        self.unavailableReason = unavailableReason
    }

    public var userID: String? { service?.userID }

    /// Connects for the signed-in account, or reconnects when the account has changed.
    public func connect() async {
        if let unavailableReason {
            phase = .unavailable(unavailableReason)
            return
        }
        guard let connector else {
            phase = .unavailable("This build has no backend settings, so Messages can't connect.")
            return
        }
        let current = await account()
        if let service, service.account == current, phase == .ready { return }
        await disconnect()
        guard let current else {
            phase = .failed(MessagesError.notSignedIn.message)
            return
        }
        generation += 1
        let mine = generation
        phase = .loading
        do {
            let service = try await connector(current)
            guard mine == generation else { return await service.stop() }
            self.service = service
            service.observeConnection { [weak self] state in
                Task { @MainActor in
                    guard let self, mine == self.generation else { return }
                    self.connection = state
                }
            }
            try await service.observeChats { [weak self] all in
                Task { @MainActor in
                    guard let self, mine == self.generation else { return }
                    self.show(all)
                }
            }
            if mine == generation { phase = .ready }
        } catch {
            if mine == generation { phase = .failed(Self.describe(error)) }
        }
    }

    /// Stops this account's connection once someone else, or no one, is signed in, so a signed-out
    /// account's chats don't keep syncing or showing.
    public func checkAccount() async {
        guard let service else { return }
        if await account() != service.account { await disconnect() }
    }

    /// Stops syncing and forgets the lists. The stores stay on the device for next time.
    public func disconnect() async {
        generation += 1
        chats = []
        requests = []
        connection = .connecting
        if let service {
            self.service = nil
            await service.stop()
        }
        phase = .idle
    }

    public func accept(_ request: ChatSummary) async { await act { try await $0.accept(request.id) } }
    public func decline(_ request: ChatSummary) async { await act { try await $0.decline(request.id) } }
    public func block(_ request: ChatSummary) async { await act { try await $0.block(request.id) } }

    /// The chat's ID, ready to open, or nil with `notice` saying why not.
    public func startChat(with typed: String) async -> String? {
        guard let username = MessagesUsername.normalized(typed) else {
            notice = MessagesError.notAUsername.message
            return nil
        }
        guard let service else { return nil }
        if MessagesUsername.display(service.userID) == username {
            notice = MessagesError.ownUsername.message
            return nil
        }
        do {
            notice = nil
            return try await service.startChat(with: username)
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    public func open(_ chat: String) async throws -> ChatModel {
        guard let service else { throw MessagesError.notSignedIn }
        return ChatModel(channel: try await service.openChat(chat))
    }

    /// Sends a photo from the camera straight into a chat, without opening it. True once it's queued.
    public func sendPhoto(_ original: Data, to chat: String) async -> Bool {
        guard let service else { return false }
        do {
            notice = nil
            let photo = try await Task.detached(priority: .userInitiated) { try PhotoPrep.prepare(original) }.value
            let channel = try await service.openChat(chat)
            defer { channel.close() }
            try await channel.sendPhoto(photo, replyingTo: nil)
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// The home tile: requests and unread chats first, then who they're from. Never message text,
    /// so nothing private shows on the home screen.
    public var glance: ModuleGlance {
        guard phase == .ready else {
            if phase == .loading { return ModuleGlance(lines: ["Getting your messages"], isQuiet: true) }
            return ModuleGlance(lines: ["Open to see your messages"], isQuiet: true)
        }
        let unread = chats.filter { $0.unread > 0 }
        var lines: [String] = []
        if !requests.isEmpty { lines.append(requests.count == 1 ? "1 request" : "\(requests.count) requests") }
        lines.append(unread.isEmpty ? "No unread messages" : unread.count == 1 ? "1 unread chat" : "\(unread.count) unread chats")
        lines += (unread.isEmpty ? chats : unread).prefix(3).map(\.title)
        return ModuleGlance(lines: lines, isQuiet: unread.isEmpty && requests.isEmpty)
    }

    public func filtered(_ query: String) -> [ChatSummary] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return chats }
        return chats.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.lastMessage?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func show(_ all: [ChatSummary]) {
        requests = all.filter(\.isRequest).sorted(by: ChatSummary.newestFirst)
        chats = all.filter { !$0.isRequest }.sorted(by: ChatSummary.newestFirst)
    }

    private func act(_ work: (any MessagesService) async throws -> Void) async {
        guard let service else { return }
        do {
            notice = nil
            try await work(service)
        } catch {
            notice = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? MessagesError)?.message ?? "Something went wrong. Try again."
    }
}

/// One open conversation: its messages, who's typing, and sending.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var typing: [String] = []
    public private(set) var loaded = false
    public var draft = ""
    public var notice: String?
    /// The message the next one answers, shown above the box until it's sent or cancelled.
    public var replyingTo: ChatMessage?
    /// A photo is being prepared and queued.
    public private(set) var sendingPhoto = false
    private let photos = PhotoMemory()

    public let title: String
    private let channel: any ChatChannel
    private var typingSent = false
    private let defaults: UserDefaults

    init(channel: any ChatChannel, defaults: UserDefaults = .standard) {
        self.channel = channel
        self.title = channel.title
        self.defaults = defaults
    }

    private var share: Bool { MessagesPreferences.shareReadAndTyping(defaults) }

    public func start() async {
        await channel.observe(
            messages: { [weak self] messages in
                Task { @MainActor in
                    guard let self else { return }
                    let grew = messages.last?.id != self.messages.last?.id
                    self.messages = messages
                    self.loaded = true
                    if grew { await self.channel.markRead(share: self.share) }
                }
            },
            typing: { [weak self] names in
                Task { @MainActor in self?.typing = names.map(MessagesUsername.display) }
            }
        )
        await channel.loadEarlier()
        loaded = true
        await channel.markRead(share: share)
    }

    public func loadEarlier() async { await channel.loadEarlier() }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reply = replyingTo
        draft = ""
        replyingTo = nil
        await draftChanged()
        do {
            notice = nil
            try await channel.send(text, replyingTo: reply?.id)
        } catch {
            draft = text
            replyingTo = reply
            notice = MessagesModel.describe(error)
        }
    }

    /// Prepares a photo off the main thread, then queues it. It's sealed by the SDK before upload.
    public func sendPhoto(_ original: Data) async {
        guard !sendingPhoto else { return }
        sendingPhoto = true
        defer { sendingPhoto = false }
        let reply = replyingTo
        replyingTo = nil
        do {
            notice = nil
            let photo = try await Task.detached(priority: .userInitiated) { try PhotoPrep.prepare(original) }.value
            try await channel.sendPhoto(photo, replyingTo: reply?.id)
        } catch {
            replyingTo = reply
            notice = MessagesModel.describe(error)
        }
    }

    public func toggleReaction(_ key: String, on message: ChatMessage) async {
        do {
            notice = nil
            try await channel.toggleReaction(key, on: message.id)
        } catch {
            notice = MessagesModel.describe(error)
        }
    }

    /// Only ever called after the person confirmed it.
    public func delete(_ message: ChatMessage) async {
        guard message.canDelete else { return }
        do {
            notice = nil
            if replyingTo?.id == message.id { replyingTo = nil }
            try await channel.delete(message.id)
        } catch {
            notice = MessagesModel.describe(error)
        }
    }

    /// A photo opened on this device, kept in memory while the chat is open.
    public func photo(_ message: ChatMessage, thumbnail: Bool) async -> Data? {
        let key = "\(message.id)|\(thumbnail)"
        if let cached = photos[key] { return cached }
        guard let data = try? await channel.photo(message.id, thumbnail: thumbnail) else { return nil }
        photos[key] = data
        return data
    }

    public func retry(_ message: ChatMessage) async {
        do {
            notice = nil
            try await channel.retry(message.id)
        } catch {
            notice = MessagesModel.describe(error)
        }
    }

    /// Tells the other person you're typing, only while the switch allows it and only on a change.
    public func draftChanged() async {
        let typingNow = share && !draft.isEmpty
        guard typingNow != typingSent else { return }
        typingSent = typingNow
        await channel.setTyping(typingNow)
    }

    public func close() {
        photos.removeAll()
        let wasTyping = typingSent
        typingSent = false
        Task { [channel] in
            if wasTyping { await channel.setTyping(false) }
            channel.close()
        }
    }
}
