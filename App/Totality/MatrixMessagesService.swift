#if canImport(MatrixRustSDK)
import Foundation
@preconcurrency import MatrixRustSDK
import TotalityCore
import TotalityMessages

/// Messages over Totality's Matrix server, through matrix-rust-sdk. Nothing here logs, and the Matrix
/// access token only ever sits in the Keychain and inside the SDK. It lives in the app rather than the
/// TotalityMessages package because the SDK ships for iPhone only, and the package's tests run on the Mac.
final class MatrixMessagesService: MessagesService, @unchecked Sendable {
    static let homeserver = "https://matrix.usetotality.com"
    static let serverName = "usetotality.com"

    let account: String
    let userID: String
    private let client: Client
    private let sync: SyncService
    private let lock = NSLock()
    private var handles: [TaskHandle] = []
    private var roomList: RoomList?
    private var roomListResult: RoomListEntriesWithDynamicAdaptersResult?
    private var rooms: [Room] = []
    private var summaryRound = 0

    private init(account: String, client: Client, sync: SyncService) throws {
        self.account = account
        self.client = client
        self.sync = sync
        userID = try client.userId()
    }

    /// Opens this account's stores, signs in with a fresh one-minute pass if there's no saved session,
    /// and starts syncing.
    static func connect(
        account: String,
        keys: any KeyStore = KeychainKeyStore(service: "app.totality.messages"),
        pass: @Sendable () async throws -> String
    ) async throws -> MatrixMessagesService {
        do {
            let paths = try MessagesStorePaths(account: account)
            let secrets = MessagesSecrets(keys: keys, account: account)
            let storeKey = try secrets.storeKey(for: paths)
            let client = try await ClientBuilder()
                .homeserverUrl(url: homeserver)
                .sqliteStore(config: SqliteStoreBuilder(dataPath: paths.data.path, cachePath: paths.cache.path).key(key: storeKey))
                .slidingSyncVersionBuilder(versionBuilder: .native)
                // This device gets its own cross-signing on first sign-in, and older messages are fetched
                // from the backup when one can't be opened.
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
                .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
                .build()
            if let saved = try keys.load(secrets.sessionName), let session = try? JSONDecoder().decode(StoredSession.self, from: saved) {
                try await client.restoreSession(session: session.sdk)
            } else {
                try await client.customLoginWithJwt(jwt: try await pass(), initialDeviceName: deviceName, deviceId: nil)
                try keys.save(try JSONEncoder().encode(StoredSession(try client.session())), as: secrets.sessionName)
            }
            let sync = try await client.syncService().withOfflineMode().finish()
            await sync.start()
            return try MatrixMessagesService(account: account, client: client, sync: sync)
        } catch {
            throw Self.translate(error)
        }
    }

    func stop() async {
        let old = lock.withLock {
            defer { handles = []; roomListResult = nil; roomList = nil; rooms = [] }
            return handles
        }
        old.forEach { $0.cancel() }
        await sync.stop()
    }

    // MARK: Connection

    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void) {
        let client = client
        let handle = sync.state(listener: SyncStateListener { state in
            switch state {
            case .running:
                onChange(.online)
                // A queue that hit an error while offline stays paused until it's switched back on.
                Task { await client.enableAllSendQueues(enable: true) }
            case .offline, .error: onChange(.offline)
            case .idle, .terminated: onChange(.connecting)
            }
        })
        lock.withLock { handles.append(handle) }
    }

    // MARK: Chats and requests

    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws {
        do {
            let list = try await sync.roomListService().allRooms()
            let result = list.entriesWithDynamicAdapters(pageSize: 500, listener: RoomsListener { [weak self] updates in
                self?.roomsChanged(updates, onChange: onChange)
            })
            _ = result.controller().setFilter(kind: .all(filters: [.nonLeft, .nonSpace]))
            let stream = result.entriesStream()
            lock.withLock {
                roomList = list
                roomListResult = result
                handles.append(stream)
            }
        } catch {
            throw Self.translate(error)
        }
    }

    private func roomsChanged(_ updates: [RoomListEntriesUpdate], onChange: @escaping @Sendable ([ChatSummary]) -> Void) {
        let (snapshot, round) = lock.withLock {
            for update in updates { Self.change(update).apply(to: &rooms) }
            summaryRound += 1
            return (rooms, summaryRound)
        }
        Task {
            var summaries: [ChatSummary] = []
            for room in snapshot {
                if let summary = await Self.summary(of: room) { summaries.append(summary) }
            }
            // Only the newest round is shown, so a slow older one can't put back a stale list.
            guard lock.withLock({ round == summaryRound }) else { return }
            onChange(summaries)
        }
    }

    private static func summary(of room: Room) async -> ChatSummary? {
        guard let info = try? await room.roomInfo(), !info.isSpace else { return nil }
        switch info.membership {
        case .invited:
            let inviter = info.inviter?.userId
            let name = inviter.map(MessagesUsername.display) ?? info.displayName ?? "Someone"
            return ChatSummary(
                id: info.id,
                title: info.isDirect ? name : "Group from \(name)",
                isRequest: true, from: inviter, lastActivity: nil, isGroup: !info.isDirect
            )
        case .joined:
            // Messages only shows end-to-end encrypted chats, so its label stays true.
            guard await room.isEncrypted() else { return nil }
            let (text, time) = preview(await room.latestEvent())
            let title = info.displayName ?? info.heroes.first.map { MessagesUsername.display($0.userId) } ?? "Chat"
            let unread = Int(info.numUnreadMessages) + (info.isMarkedUnread ? 1 : 0)
            // A group's photo is shown once you've joined, never on a request: fetching it would tell
            // the server, and so whoever invited you, that the request was looked at.
            return ChatSummary(
                id: info.id, title: title, lastMessage: text, lastActivity: time, unread: unread,
                isGroup: !info.isDirect, photo: info.isDirect ? nil : info.avatarUrl
            )
        default:
            return nil
        }
    }

    private static func preview(_ latest: LatestEventValue) -> (String?, Date?) {
        switch latest {
        case .none, .remoteInvite: (nil, nil)
        case .remote(let timestamp, _, let isOwn, _, let content):
            (preview(content).map { isOwn ? "You: \($0)" : $0 }, date(timestamp))
        case .local(let timestamp, _, _, let content, _):
            (preview(content).map { "You: \($0)" }, date(timestamp))
        }
    }

    static func preview(_ content: TimelineItemContent) -> String? {
        guard case .msgLike(let like) = content else { return nil }
        switch like.kind {
        case .message(let message):
            switch message.msgType {
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return "Audio"
            case .file: return "File"
            case .location: return "Location"
            default: return message.body
            }
        case .unableToDecrypt: return "Waiting for this message's key"
        case .redacted: return "Message deleted"
        case .sticker: return "Sticker"
        default: return nil
        }
    }

    static func date(_ timestamp: Timestamp) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }

    func accept(_ chat: String) async throws {
        let room: Room
        do {
            room = try self.room(chat)
            try await room.join()
        } catch {
            throw Self.translate(error)
        }
        // A chat that isn't end-to-end encrypted is left again rather than shown.
        guard await room.isEncrypted() else {
            try? await room.leave()
            throw MessagesError.failed("That chat isn't end-to-end encrypted, so Messages left it.")
        }
    }

    func decline(_ chat: String) async throws {
        do { try await room(chat).leave() } catch { throw Self.translate(error) }
    }

    func block(_ chat: String) async throws {
        do {
            let room = try room(chat)
            if let inviter = try await room.inviter()?.userId {
                try await client.ignoreUser(userId: inviter)
            }
            try await room.leave()
        } catch {
            throw Self.translate(error)
        }
    }

    func block(person: String, leaving chat: String?) async throws {
        do {
            try await client.ignoreUser(userId: person)
            if let chat { try await room(chat).leave() }
        } catch {
            throw Self.translate(error)
        }
    }

    func blocked() async throws -> [String] {
        do { return try await client.ignoredUsers() } catch { throw Self.translate(error) }
    }

    func unblock(_ person: String) async throws {
        do { try await client.unignoreUser(userId: person) } catch { throw Self.translate(error) }
    }

    func leave(_ chat: String) async throws {
        do { try await room(chat).leave() } catch { throw Self.translate(error) }
    }

    private func room(_ id: String) throws -> Room {
        guard let room = try client.getRoom(roomId: id) else { throw MessagesError.failed("That chat isn't on this device yet.") }
        return room
    }

    // MARK: Key backup and this device's verification

    func settleKeys(recoverySecret secret: String?) async -> MessageKeys {
        let encryption = client.encryption()
        var state = encryption.recoveryState()
        for _ in 0..<50 where state == .unknown {
            try? await Task.sleep(for: .milliseconds(200))
            state = encryption.recoveryState()
        }
        guard let secret else {
            return state == .enabled && encryption.verificationState() == .verified ? .backedUp : .needsRecoveryKey
        }
        do {
            switch state {
            case .enabled:
                break
            case .disabled:
                // The first device with the recovery key: sets up secret storage and the backup under it.
                _ = try await encryption.enableRecovery(waitForBackupsToUpload: false, passphrase: secret, progressListener: RecoveryProgress())
            case .incomplete:
                // Another device set it up: opening it brings the keys here and verifies this device.
                do {
                    try await encryption.recover(recoveryKey: secret)
                } catch {
                    return .doesntOpen
                }
            case .unknown:
                return .failed("Messages couldn't check its key backup. It'll try again next time.")
            }
        } catch {
            return .failed("Messages couldn't set up its key backup. It'll try again next time.")
        }
        return .backedUp
    }

    // MARK: Starting and opening chats

    func startChat(with username: String) async throws -> String {
        let other = "@\(username):\(Self.serverName)"
        guard other != userID else { throw MessagesError.ownUsername }
        do {
            // Reused only while it's still just the two of you: anyone in a chat can invite a third
            // person, and everything sent after that would reach them.
            if let existing = try client.getDmRoom(userId: other),
               await existing.isEncrypted(),
               DirectChatRule.isJustTheTwoOfYou(members: await Self.activeMembers(of: existing), own: userID, other: other) {
                return existing.id()
            }
            do {
                _ = try await client.getProfile(userId: other)
            } catch let error as ClientError {
                if case .MatrixApi(_, let code, _, _) = error, code == "M_NOT_FOUND" { throw MessagesError.noSuchPerson }
                throw error
            }
            let id = try await client.createRoom(request: CreateRoomParameters(
                name: nil, isEncrypted: true, isDirect: true, visibility: .private, preset: .trustedPrivateChat, invite: [other]
            ))
            for _ in 0..<50 {
                if try client.getRoom(roomId: id) != nil { return id }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw MessagesError.failed("The new chat didn't arrive from the server. Try again.")
        } catch {
            throw Self.translate(error)
        }
    }

    func groupPhoto(_ location: String) async throws -> Data {
        // Only this server's own media: federation is off, and a link elsewhere is never fetched.
        guard location.hasPrefix("mxc://\(Self.serverName)/") else { throw MessagesError.failed("That group photo isn't on Totality's server.") }
        do {
            return try await client.getMediaContent(mediaSource: try MediaSource.fromUrl(url: location))
        } catch {
            throw Self.translate(error)
        }
    }

    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String {
        let people = usernames.map { "@\($0):\(Self.serverName)" }.filter { $0 != userID }
        do {
            for person in people {
                do {
                    _ = try await client.getProfile(userId: person)
                } catch let error as ClientError {
                    if case .MatrixApi(_, let code, _, _) = error, code == "M_NOT_FOUND" {
                        throw MessagesError.failed("There's no one called \(MessagesUsername.display(person)).")
                    }
                    throw error
                }
            }
            // The name and photo are outside Matrix's encryption, which the screen says where they're set.
            let id = try await client.createRoom(request: CreateRoomParameters(
                name: name, isEncrypted: true, isDirect: false, visibility: .private, preset: .privateChat, invite: people
            ))
            for _ in 0..<50 {
                if let room = try client.getRoom(roomId: id) {
                    if let photo {
                        // The group exists either way. A photo that didn't go up can be added from the chat.
                        try? await room.uploadAvatar(mimeType: "image/jpeg", data: photo.data, mediaInfo: Self.imageInfo(photo))
                    }
                    return id
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw MessagesError.failed("The new group didn't arrive from the server. Try again.")
        } catch {
            throw Self.translate(error)
        }
    }

    func openChat(_ chat: String) async throws -> any ChatChannel {
        do {
            let room = try room(chat)
            guard await room.isEncrypted() else { throw MessagesError.notEncrypted }
            let info = try? await room.roomInfo()
            let title = info?.displayName ?? room.displayName() ?? "Chat"
            let isGroup = !(info?.isDirect ?? true)
            let other = isGroup ? nil : info?.heroes.first?.userId
            let extra = isGroup ? [] : DirectChatRule.extraPeople(members: await Self.activeMembers(of: room), own: userID, other: other)
            return MatrixChat(
                client: client, room: room, timeline: try await room.timeline(), title: title, ownUserID: userID,
                isGroup: isGroup, otherPerson: other, extraPeople: extra, photo: isGroup ? info?.avatarUrl : nil
            )
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: Helpers

    static func imageInfo(_ photo: GroupPhoto) -> ImageInfo {
        ImageInfo(
            height: UInt64(photo.height), width: UInt64(photo.width), mimetype: "image/jpeg", size: UInt64(photo.data.count),
            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: false
        )
    }

    /// Everyone joined or invited. On any failure it lists nobody, which never passes as "just the two of you".
    static func activeMembers(of room: Room) async -> [String] {
        guard let iterator = try? await room.members() else { return [] }
        var members: [String] = []
        while let chunk = iterator.nextChunk(chunkSize: 100) {
            members += chunk.filter { $0.membership == .join || $0.membership == .invite }.map(\.userId)
        }
        return members
    }

    static func translate(_ error: any Error) -> any Error {
        switch error {
        case let error as MessagesError: return error
        case let error as ClientError:
            if case .MatrixApi(_, let code, _, _) = error, code == "M_FORBIDDEN" {
                return MessagesError.failed("The Matrix server refused that.")
            }
            return MessagesError.failed("Messages couldn't reach the server. Check your connection and try again.")
        case is URLError: return MessagesError.offline
        default: return MessagesError.failed("Something went wrong. Try again.")
        }
    }

    static func change(_ update: RoomListEntriesUpdate) -> ListChange<Room> {
        switch update {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }

    private static var deviceName: String {
        #if os(iOS)
        "Totality on iPhone"
        #else
        "Totality"
        #endif
    }
}

/// One open conversation, backed by the SDK's timeline.
final class MatrixChat: ChatChannel, @unchecked Sendable {
    let title: String
    private let client: Client
    private let room: Room
    private let timeline: Timeline
    private let ownUserID: String
    private let lock = NSLock()
    private var items: [TimelineItem] = []
    /// What each shown message is to the SDK, so actions on it reach the right event.
    private var sendIDs: [String: EventOrTransactionId] = [:]
    private var photoSources: [String: (full: MediaSource, thumbnail: MediaSource?)] = [:]
    private var videoSources: [String: MediaSource] = [:]
    private var handles: [TaskHandle] = []
    let isGroup: Bool
    let otherPerson: String?
    var id: String { room.id() }

    let photo: String?
    let extraPeople: [String]

    init(client: Client, room: Room, timeline: Timeline, title: String, ownUserID: String, isGroup: Bool, otherPerson: String?, extraPeople: [String], photo: String?) {
        self.photo = photo
        self.extraPeople = extraPeople
        self.client = client
        self.room = room
        self.timeline = timeline
        self.title = title
        self.ownUserID = ownUserID
        self.isGroup = isGroup
        self.otherPerson = otherPerson
    }

    // MARK: Disappearing messages

    private static let retention = "m.room.retention"

    func observeDisappearing(_ onChange: @escaping @Sendable (DisappearingState) -> Void) async {
        let own = ownUserID
        // The event's server time is when the setting began. Only messages after it are affected,
        // and without one, none are.
        let state: @Sendable (RoomStateEvent) -> DisappearingState = { event in
            DisappearingState(
                setting: Disappearing(stateJSON: event.contentJson),
                since: event.timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                changedBy: event.sender == own ? nil : event.sender
            )
        }
        if let current = try? await room.stateEvents(eventType: .roomRetention).first(where: { $0.stateKey.isEmpty }) {
            onChange(state(current))
        }
        let handle = room.subscribeToStateEvents(eventType: .roomRetention, listener: StateListener { events in
            if let event = events.last(where: { $0.stateKey.isEmpty }) { onChange(state(event)) }
        })
        lock.withLock { handles.append(handle) }
    }

    func rename(_ name: String?) async throws {
        guard isGroup else { return }
        do {
            try await room.setName(name: name ?? "")
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func setPhoto(_ photo: GroupPhoto?) async throws {
        guard isGroup else { return }
        do {
            if let photo {
                try await room.uploadAvatar(mimeType: "image/jpeg", data: photo.data, mediaInfo: MatrixMessagesService.imageInfo(photo))
            } else {
                try await room.removeAvatar()
            }
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func setDisappearing(_ setting: Disappearing) async throws {
        do {
            _ = try await room.sendStateEventRaw(eventType: Self.retention, stateKey: "", content: setting.stateJSON)
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func observe(messages: @escaping @Sendable ([ChatMessage]) -> Void, typing: @escaping @Sendable ([String]) -> Void) async {
        let own = ownUserID
        let timelineHandle = await timeline.addListener(listener: TimelineDiffListener { [weak self] diffs in
            guard let self else { return }
            messages(self.apply(diffs))
        })
        let typingHandle = room.subscribeToTypingNotifications(listener: TypingListener { ids in
            typing(ids.filter { $0 != own })
        })
        lock.withLock { handles += [timelineHandle, typingHandle] }
    }

    private func apply(_ diffs: [TimelineDiff]) -> [ChatMessage] {
        lock.withLock {
            for diff in diffs { Self.change(diff).apply(to: &items) }
            var result: [ChatMessage] = []
            var readUpTo: Int?
            for item in items {
                guard let event = item.asEvent(), let message = message(item, event) else { continue }
                result.append(message)
                sendIDs[message.id] = event.eventOrTransactionId
                if event.readReceipts.keys.contains(where: { $0 != ownUserID }) { readUpTo = result.count - 1 }
            }
            return ChatMessage.markingSeen(result, readUpTo: readUpTo)
        }
    }

    private func message(_ item: TimelineItem, _ event: EventTimelineItem) -> ChatMessage? {
        guard case .msgLike(let like) = event.content else { return nil }
        let id = item.uniqueId().id
        var decrypted = true
        var kind = ChatMessage.Kind.text
        let body: String
        switch like.kind {
        case .unableToDecrypt:
            decrypted = false
            body = "Waiting for this message's key"
        case .redacted:
            kind = .deleted
            body = "Message deleted"
        case .message(let content):
            if case .image(let image) = content.msgType {
                kind = .photo(width: image.info?.width.map { Int(clamping: $0) }, height: image.info?.height.map { Int(clamping: $0) })
                body = "Photo"
                photoSources[id] = (image.source, image.info?.thumbnailSource)
            } else if case .video(let video) = content.msgType {
                kind = .video(seconds: video.info?.duration)
                body = "Video"
                videoSources[id] = video.source
                photoSources[id] = video.info?.thumbnailSource.map { ($0, nil) }
            } else {
                guard let text = MatrixMessagesService.preview(event.content) else { return nil }
                body = text
            }
        default:
            guard let text = MatrixMessagesService.preview(event.content) else { return nil }
            body = text
        }
        let state: ChatMessage.State = switch event.localSendState {
        case nil, .sent: .sent
        case .notSentYet: .sending
        case .sendingFailed(_, let recoverable): .failed(canRetry: recoverable)
        }
        let reactions = kind == .deleted ? [] : event.reactions.map {
            ChatReaction(key: $0.key, count: $0.senders.count, mine: $0.senders.contains { $0.senderId == ownUserID })
        }
        return ChatMessage(
            id: id, sender: event.sender, body: body, isOwn: event.isOwn,
            time: MatrixMessagesService.date(event.timestamp), state: state, decrypted: decrypted,
            kind: kind, reactions: reactions, replyTo: like.inReplyTo.flatMap(Self.reply), canReply: event.canBeRepliedTo
        )
    }

    private static func reply(_ details: InReplyToDetails) -> ReplyPreview? {
        switch details.event() {
        case .ready(let content, let sender, _, _, _):
            ReplyPreview(sender: sender, text: MatrixMessagesService.preview(content) ?? "Message")
        case .pending, .unavailable:
            ReplyPreview(sender: "", text: "Loading the message this replies to")
        case .error:
            ReplyPreview(sender: "", text: "The message this replies to isn't available")
        }
    }

    /// The server's event ID for a shown message, needed to reply to it.
    private func eventID(_ message: String) -> String? {
        guard case .eventId(let id)? = lock.withLock({ sendIDs[message] }) else { return nil }
        return id
    }

    private func itemID(_ message: String) throws -> EventOrTransactionId {
        guard let id = lock.withLock({ sendIDs[message] }) else { throw MessagesError.failed("That message isn't here any more.") }
        return id
    }

    func loadEarlier() async {
        _ = try? await timeline.paginateBackwards(numEvents: 40)
    }

    func send(_ text: String, replyingTo: String?) async throws {
        do {
            if !room.isSendQueueEnabled() { room.enableSendQueue(enable: true) }
            let content = try messageEventContentNew(msgtype: .text(content: TextMessageContent(body: text, formatted: nil)))
            if let replyingTo, let event = eventID(replyingTo) {
                _ = try await timeline.sendReply(msg: content, eventId: event)
            } else {
                _ = try await timeline.send(msg: content)
            }
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func sendPhoto(_ photo: OutgoingPhoto, replyingTo: String?) async throws {
        // The room is end-to-end encrypted (openChat checks), so the SDK encrypts the file and its
        // thumbnail on this device and uploads only ciphertext. The keys go inside the encrypted event.
        guard await room.isEncrypted() else { throw MessagesError.notEncrypted }
        do {
            if !room.isSendQueueEnabled() { room.enableSendQueue(enable: true) }
            let info = ImageInfo(
                height: UInt64(photo.height), width: UInt64(photo.width), mimetype: "image/jpeg",
                size: UInt64(photo.data.count),
                thumbnailInfo: ThumbnailInfo(
                    height: UInt64(photo.thumbnailHeight), width: UInt64(photo.thumbnailWidth),
                    mimetype: "image/jpeg", size: UInt64(photo.thumbnail.count)
                ),
                thumbnailSource: nil, blurhash: nil, isAnimated: false
            )
            let params = UploadParameters(
                source: .data(bytes: photo.data, filename: "photo.jpg"), caption: nil, formattedCaption: nil,
                mentions: nil, inReplyTo: replyingTo.flatMap(eventID)
            )
            let handle = try timeline.sendImage(
                params: params, thumbnailSource: .data(bytes: photo.thumbnail, filename: "thumbnail.jpg"), imageInfo: info
            )
            try await handle.join()
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func sendVideo(_ video: OutgoingVideo, replyingTo: String?) async throws {
        guard await room.isEncrypted() else { throw MessagesError.notEncrypted }
        do {
            if !room.isSendQueueEnabled() { room.enableSendQueue(enable: true) }
            let size = (try? FileManager.default.attributesOfItem(atPath: video.file.path)[.size] as? NSNumber)?.uint64Value
            let info = VideoInfo(
                duration: video.seconds, height: UInt64(video.height), width: UInt64(video.width), mimetype: "video/mp4",
                size: size,
                thumbnailInfo: ThumbnailInfo(
                    height: UInt64(video.thumbnailHeight), width: UInt64(video.thumbnailWidth),
                    mimetype: "image/jpeg", size: UInt64(video.thumbnail.count)
                ),
                thumbnailSource: nil, blurhash: nil
            )
            // Read into memory so the plain file can go as soon as this returns.
            let data = try Data(contentsOf: video.file)
            let params = UploadParameters(
                source: .data(bytes: data, filename: "video.mp4"), caption: nil, formattedCaption: nil,
                mentions: nil, inReplyTo: replyingTo.flatMap(eventID)
            )
            let handle = try timeline.sendVideo(
                params: params, thumbnailSource: .data(bytes: video.thumbnail, filename: "thumbnail.jpg"), videoInfo: info
            )
            try await handle.join()
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func video(_ message: String) async throws -> Data {
        guard let source = lock.withLock({ videoSources[message] }) else { throw MessagesError.failed("That video isn't here any more.") }
        do { return try await client.getMediaContent(mediaSource: source) } catch { throw MatrixMessagesService.translate(error) }
    }

    func toggleReaction(_ key: String, on message: String) async throws {
        do {
            _ = try await timeline.toggleReaction(itemId: try itemID(message), key: key)
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func delete(_ message: String) async throws {
        do {
            try await timeline.redactEvent(eventOrTransactionId: try itemID(message), reason: nil)
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func photo(_ message: String, thumbnail: Bool) async throws -> Data {
        guard let sources = lock.withLock({ photoSources[message] }) else { throw MessagesError.failed("That photo isn't here any more.") }
        do {
            // The SDK downloads the ciphertext and opens it with the key from the message.
            if thumbnail, let small = sources.thumbnail { return try await client.getMediaContent(mediaSource: small) }
            return try await client.getMediaContent(mediaSource: sources.full)
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func retry(_ message: String) async throws {
        guard let id = lock.withLock({ sendIDs[message] }) else { return }
        do {
            room.enableSendQueue(enable: true)
            _ = try await timeline.retrySend(itemId: id, target: .event)
        } catch {
            throw MatrixMessagesService.translate(error)
        }
    }

    func markRead(share: Bool) async {
        try? await timeline.markAsRead(receiptType: share ? .read : .readPrivate)
    }

    func setTyping(_ typing: Bool) async {
        try? await room.typingNotice(isTyping: typing)
    }

    func close() {
        let old = lock.withLock {
            defer { handles = [] }
            return handles
        }
        old.forEach { $0.cancel() }
    }

    static func change(_ diff: TimelineDiff) -> ListChange<TimelineItem> {
        switch diff {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

/// The SDK's session, in a form the Keychain can hold.
private struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let userId: String
    let deviceId: String
    let homeserverUrl: String
    let nativeSlidingSync: Bool

    init(_ session: Session) {
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        deviceId = session.deviceId
        homeserverUrl = session.homeserverUrl
        nativeSlidingSync = session.slidingSyncVersion == .native
    }

    var sdk: Session {
        Session(
            accessToken: accessToken, refreshToken: refreshToken, userId: userId, deviceId: deviceId,
            homeserverUrl: homeserverUrl, oauthData: nil, slidingSyncVersion: nativeSlidingSync ? .native : .none
        )
    }
}

private final class RoomsListener: RoomListEntriesListener {
    let handle: @Sendable ([RoomListEntriesUpdate]) -> Void
    init(_ handle: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) { self.handle = handle }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { handle(roomEntriesUpdate) }
}

private final class TimelineDiffListener: TimelineListener {
    let handle: @Sendable ([TimelineDiff]) -> Void
    init(_ handle: @escaping @Sendable ([TimelineDiff]) -> Void) { self.handle = handle }
    func onUpdate(diff: [TimelineDiff]) { handle(diff) }
}

private final class StateListener: RoomStateEventsListener {
    let handle: @Sendable ([RoomStateEvent]) -> Void
    init(_ handle: @escaping @Sendable ([RoomStateEvent]) -> Void) { self.handle = handle }
    func onUpdate(events: [RoomStateEvent]) { handle(events) }
}

private final class TypingListener: TypingNotificationsListener {
    let handle: @Sendable ([String]) -> Void
    init(_ handle: @escaping @Sendable ([String]) -> Void) { self.handle = handle }
    func call(typingUserIds: [String]) { handle(typingUserIds) }
}

private final class SyncStateListener: SyncServiceStateObserver {
    let handle: @Sendable (SyncServiceState) -> Void
    init(_ handle: @escaping @Sendable (SyncServiceState) -> Void) { self.handle = handle }
    func onUpdate(state: SyncServiceState) { handle(state) }
}
#endif

private final class RecoveryProgress: EnableRecoveryProgressListener {
    func onUpdate(status: EnableRecoveryProgress) {}
}
