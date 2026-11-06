#if canImport(MatrixRustSDK)
import Foundation
@preconcurrency import MatrixRustSDK
import TotalityCore

/// The trial's whole use of matrix-rust-sdk. Nothing here logs, and the Matrix access token only ever
/// sits in the Keychain and inside the SDK.
final class MatrixEngine: @unchecked Sendable {
    static let homeserver = "https://matrix.usetotality.com"
    static let serverName = "usetotality.com"

    let client: Client
    let sync: SyncService
    let userID: String
    let deviceID: String
    private let collector: Collector
    private var watcher: Task<Void, Never>?

    private init(client: Client, sync: SyncService, collector: Collector) throws {
        self.client = client
        self.sync = sync
        self.collector = collector
        userID = try client.userId()
        deviceID = try client.deviceId()
    }

    deinit { watcher?.cancel() }

    static func open(
        account: String,
        paths: MessagesStorePaths,
        keys: any KeyStore,
        pass: @Sendable () async throws -> String,
        onMessages: @escaping @Sendable ([TrialMessage]) -> Void
    ) async throws -> MatrixEngine {
        let sessionName = "\(account).session"
        let keyName = "\(account).store-key"
        // A reinstall empties the container but keeps the Keychain. An old session with no store
        // behind it would reuse a device whose keys are gone, so it's dropped and a new device signs in.
        let storeIsEmpty = (try? FileManager.default.contentsOfDirectory(atPath: paths.data.path).isEmpty) ?? true
        if storeIsEmpty { try keys.delete(sessionName) }
        let storeKey: Data
        if let saved = try keys.load(keyName), !storeIsEmpty {
            storeKey = saved
        } else {
            storeKey = try randomKey()
            try keys.save(storeKey, as: keyName)
        }

        let client = try await ClientBuilder()
            .homeserverUrl(url: homeserver)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: paths.data.path, cachePath: paths.cache.path).key(key: storeKey))
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()

        if let saved = try keys.load(sessionName), let session = try? JSONDecoder().decode(StoredSession.self, from: saved) {
            try await client.restoreSession(session: session.sdk)
        } else {
            try await client.customLoginWithJwt(jwt: try await pass(), initialDeviceName: deviceName, deviceId: nil)
            try keys.save(try JSONEncoder().encode(StoredSession(try client.session())), as: sessionName)
        }

        let sync = try await client.syncService().finish()
        await sync.start()
        let engine = try MatrixEngine(client: client, sync: sync, collector: Collector(onChange: onMessages))
        engine.watchRooms()
        return engine
    }

    /// Joins invites (the trial has no request screen yet) and listens to every joined room's timeline.
    private func watchRooms() {
        watcher = Task { [client, collector] in
            var watched: [String: (Timeline, TaskHandle)] = [:]
            while !Task.isCancelled {
                for room in client.rooms() {
                    let id = room.id()
                    switch room.membership() {
                    case .invited:
                        try? await room.join()
                    case .joined where watched[id] == nil:
                        guard let timeline = try? await room.timeline() else { continue }
                        let handle = await timeline.addListener(listener: collector.listener(for: id))
                        watched[id] = (timeline, handle)
                        _ = try? await timeline.paginateBackwards(numEvents: 20)
                    default:
                        break
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
            for (_, handle) in watched.values { handle.cancel() }
        }
    }

    func send(_ text: String, to username: String) async throws {
        let other = "@\(username):\(Self.serverName)"
        guard other != userID else { throw TrialError.sameAccount }
        let room: Room
        if let existing = try client.getDmRoom(userId: other) {
            room = existing
        } else {
            let id = try await client.createRoom(request: CreateRoomParameters(
                name: nil, isEncrypted: true, isDirect: true, visibility: .private, preset: .trustedPrivateChat, invite: [other]
            ))
            room = try await waitForRoom(id)
        }
        guard await room.isEncrypted() else { throw TrialError.notEncrypted }
        let timeline = try await room.timeline()
        _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
    }

    private func waitForRoom(_ id: String) async throws -> Room {
        for _ in 0..<50 {
            if let room = try client.getRoom(roomId: id) { return room }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TrialError.roomNeverArrived
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ClientError:
            switch error {
            case .Generic(let msg, _): return msg
            case .MatrixApi(_, let code, let msg, _): return "\(code): \(msg)"
            default: return "The Matrix SDK failed."
            }
        case let error as TrialError: return error.rawValue
        default: return "Something went wrong."
        }
    }

    private static var deviceName: String {
        #if os(iOS)
        "Totality on iPhone"
        #else
        "Totality"
        #endif
    }

    private static func randomKey() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TrialError.noRandom }
        return bytes
    }
}

enum TrialError: String, Error {
    case sameAccount = "That's your own username."
    case notEncrypted = "That chat isn't end-to-end encrypted, so nothing was sent."
    case roomNeverArrived = "The new chat didn't arrive from the server."
    case noRandom = "The device couldn't make a store key."
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

/// Keeps each room's timeline items as the SDK's diffs describe them, and reports the messages.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [String: [TimelineItem]] = [:]
    private let onChange: @Sendable ([TrialMessage]) -> Void

    init(onChange: @escaping @Sendable ([TrialMessage]) -> Void) {
        self.onChange = onChange
    }

    func listener(for room: String) -> TimelineListener {
        RoomListener { [weak self] diffs in self?.apply(diffs, room: room) }
    }

    private func apply(_ diffs: [TimelineDiff], room: String) {
        let messages: [TrialMessage] = lock.withLock {
            var items = rooms[room] ?? []
            for diff in diffs {
                switch diff {
                case .append(let values): items += values
                case .clear: items = []
                case .pushFront(let value): items.insert(value, at: 0)
                case .pushBack(let value): items.append(value)
                case .popFront: if !items.isEmpty { items.removeFirst() }
                case .popBack: if !items.isEmpty { items.removeLast() }
                case .insert(let index, let value): items.insert(value, at: min(Int(index), items.count))
                case .set(let index, let value): if Int(index) < items.count { items[Int(index)] = value }
                case .remove(let index): if Int(index) < items.count { items.remove(at: Int(index)) }
                case .truncate(let length): items = Array(items.prefix(Int(length)))
                case .reset(let values): items = values
                }
            }
            rooms[room] = items
            return rooms.values.flatMap { $0.compactMap(Self.message) }
        }
        onChange(messages)
    }

    private static func message(from item: TimelineItem) -> TrialMessage? {
        guard let event = item.asEvent(), case .msgLike(let content) = event.content else { return nil }
        let id = item.uniqueId().id
        switch content.kind {
        case .message(let message):
            return TrialMessage(id: id, sender: event.sender, body: message.body, decrypted: true, isOwn: event.isOwn)
        case .unableToDecrypt:
            return TrialMessage(id: id, sender: event.sender, body: "Waiting for this message's key", decrypted: false, isOwn: event.isOwn)
        default:
            return nil
        }
    }
}

private final class RoomListener: TimelineListener {
    private let handle: @Sendable ([TimelineDiff]) -> Void

    init(_ handle: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.handle = handle
    }

    func onUpdate(diff: [TimelineDiff]) {
        handle(diff)
    }
}
#endif
