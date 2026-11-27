#if canImport(MatrixRustSDK)
import Foundation
@preconcurrency import MatrixRustSDK
import TotalityCore
import TotalityMessages

/// Shared task lists over Matrix: one end-to-end encrypted room per list (issue 123, step 6). It lives in the
/// app, which may import Messages, so Tasks sees only `SharedRooms`. Nothing here logs.
///
/// What the server sees: that a room exists with the fixed name and topic in `SharedRoomMarker`, who is in
/// it with which power level, and when each encrypted post was sent. Everything else, the list's name, its
/// tasks, assignments and comments, is encrypted on the device inside `m.room.message` events.
@MainActor
final class MatrixTaskRooms: SharedRooms {
    private let messages: MessagesModel
    /// Whose rooms these are: Tasks' shared lists, or Social's posts. Each only ever sees its own.
    private let marker: RoomMarker

    init(messages: MessagesModel, marker: RoomMarker = SharedRoomMarker.tasks) {
        self.messages = messages
        self.marker = marker
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = messages.phase { return reason }
        return nil
    }

    var ownUsername: String? {
        get async {
            guard let service = try? await service() else { return nil }
            return Self.handle(service.userID)
        }
    }

    private func service() async throws -> MatrixMessagesService {
        if messages.phase != .ready { await messages.connect() }
        guard let service = messages.connectedService as? MatrixMessagesService else {
            throw SharedRoomError.unavailable(unavailableReason ?? "Shared lists need Messages to connect. Open Messages to check, then try again.")
        }
        return service
    }

    private func room(_ id: String) async throws -> Room {
        guard let room = try await service().client.getRoom(roomId: id) else {
            throw SharedRoomError.failed("That list isn't on this device yet. Pull down to try again.")
        }
        return room
    }

    // MARK: Handles

    nonisolated private static func userID(_ handle: String) -> String {
        "@\(handle):\(MatrixMessagesService.serverName)"
    }

    /// A Matrix ID on Totality's own server as a handle. Anyone elsewhere is nil: federation is off.
    nonisolated static func handle(_ userID: String) -> String? {
        let suffix = ":" + MatrixMessagesService.serverName
        guard userID.hasPrefix("@"), userID.hasSuffix(suffix) else { return nil }
        return String(userID.dropFirst().dropLast(suffix.count))
    }

    nonisolated private static func level(_ power: PowerLevel) -> Int {
        switch power {
        case .infinite: SharedRole.owner.rawValue
        case .value(let value): Int(clamping: value)
        }
    }

    // MARK: Rooms and invites

    private func sharedRooms(_ membership: Membership) async throws -> [(Room, RoomInfo)] {
        var found: [(Room, RoomInfo)] = []
        for room in try await service().client.rooms() where room.membership() == membership {
            guard let info = try? await room.roomInfo(), marker.matches(name: info.rawName, topic: info.topic) else { continue }
            found.append((room, info))
        }
        return found
    }

    func rooms() async throws -> [String] {
        try await sharedRooms(.joined).map { $0.0.id() }
    }

    func invites() async throws -> [SharedRoomInvite] {
        try await sharedRooms(.invited).map { room, info in
            SharedRoomInvite(room: room.id(), inviter: info.inviter.flatMap { Self.handle($0.userId) }, date: nil)
        }
    }

    func create(inviting people: [String: SharedRole]) async throws -> String {
        let service = try await service()
        do {
            let invitees = people.filter { Self.userID($0.key) != service.userID }
            let names = invitees.keys.sorted()
            for name in names { try await requireAccount(name, service: service) }
            // Only the owner invites, removes, or changes the room; editors and viewers post. The server
            // enforces these. Whether a post is an edit is checked again by every device. Everyone asked in
            // now gets their role in the room's first power levels, which the server sets before it sends
            // any invite, so nobody ever holds more than they were given.
            // The creator isn't listed: Totality's server makes room version 12 rooms, where the creator
            // already outranks everyone and the server refuses power levels that name them
            // (M_INVALID_PARAM). `history` reads the creator from the room's `creators` instead.
            let users = Self.invitedPowerLevels(invitees.map { (Self.userID($0.key), $0.value) })
            let levels = PowerLevels(
                usersDefault: 0, eventsDefault: 0, stateDefault: Int32(SharedRole.owner.rawValue),
                ban: Int32(SharedRole.owner.rawValue), kick: Int32(SharedRole.owner.rawValue),
                redact: Int32(SharedRole.owner.rawValue), invite: Int32(SharedRole.owner.rawValue),
                notifications: nil, users: users, events: [:]
            )
            let id = try await service.client.createRoom(request: CreateRoomParameters(
                name: marker.name, topic: marker.topic, isEncrypted: true, isDirect: false,
                visibility: .private, preset: .privateChat,
                invite: names.isEmpty ? nil : names.map(Self.userID), powerLevelContentOverride: levels
            ))
            let arrived = try await MatrixWait.until(attempts: 50) { (try? service.client.getRoom(roomId: id)) != nil }
            guard arrived, let room = try service.client.getRoom(roomId: id) else {
                throw SharedRoomError.failed("The new list didn't arrive from the server. Try again.")
            }
            // The SDK knows the room as soon as the server answers, but its state, power levels included,
            // only comes with the next sync, and changing who's in it fails until then. Wait for it here so
            // the caller can. A slow sync isn't an error yet: the room exists, and `invite` waits again.
            _ = try await Self.powerLevelsArrived(in: room)
            return id
        } catch {
            throw Self.translate(error)
        }
    }

    func invite(_ username: String, as role: SharedRole, to id: String) async throws {
        let service = try await service()
        let person = Self.userID(username)
        guard person != service.userID else { return }
        do {
            try await requireAccount(username, service: service)
            let room = try await room(id)
            // The SDK changes power levels from its own copy of the room's state, so it can't until that
            // has synced, as for a room made a moment ago. The role has to be set before the invite.
            guard try await Self.powerLevelsArrived(in: room) else { throw Self.settingsNotHere }
            // The role is set before the invite, so they never hold more than they were given.
            try await room.updatePowerLevelsForUsers(updates: [UserPowerLevelUpdate(userId: person, powerLevel: Int64(Self.invitedLevel(role)))])
            try await room.inviteUserById(userId: person)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Throws `noSuchPerson` unless the handle has an account on Totality's server.
    private func requireAccount(_ username: String, service: MatrixMessagesService) async throws {
        do {
            _ = try await service.client.getProfile(userId: Self.userID(username))
        } catch let error as ClientError {
            if case .MatrixApi(_, let code, _, _) = error, code == "M_NOT_FOUND" { throw SharedRoomError.noSuchPerson(username) }
            throw error
        }
    }

    /// A new room's `users` power levels: only the people invited, never its creator (room version 12).
    nonisolated static func invitedPowerLevels(_ invitees: [(userID: String, role: SharedRole)]) -> [String: Int32] {
        Dictionary(invitees.map { ($0.userID, Int32(invitedLevel($0.role))) }, uniquingKeysWith: { first, _ in first })
    }

    /// An invite never hands over the room: someone asked in as owner joins as an editor until `setRole`.
    nonisolated private static func invitedLevel(_ role: SharedRole) -> Int {
        role == .owner ? SharedRole.editor.rawValue : role.rawValue
    }

    private static let settingsNotHere = SharedRoomError.failed("This room's settings haven't arrived from the server yet. Try again in a moment.")

    /// Whether the room's power levels are on this device yet, waiting up to 15 seconds for them.
    private static func powerLevelsArrived(in room: Room) async throws -> Bool {
        try await MatrixWait.until { (try? await room.roomInfo())?.powerLevels != nil }
    }

    func setRole(_ role: SharedRole, for username: String, in id: String) async throws {
        let service = try await service()
        do {
            let room = try await room(id)
            guard try await Self.powerLevelsArrived(in: room) else { throw Self.settingsNotHere }
            var updates = [UserPowerLevelUpdate(userId: Self.userID(username), powerLevel: Int64(role.rawValue))]
            // Handing over: one change, so the room always has exactly one owner.
            if role == .owner { updates.append(UserPowerLevelUpdate(userId: service.userID, powerLevel: Int64(SharedRole.editor.rawValue))) }
            try await room.updatePowerLevelsForUsers(updates: updates)
        } catch {
            throw Self.translate(error)
        }
    }

    func remove(_ username: String, from id: String) async throws {
        do { try await room(id).kickUser(userId: Self.userID(username), reason: nil) } catch { throw Self.translate(error) }
    }

    func accept(_ id: String) async throws {
        let room = try await room(id)
        do { try await room.join() } catch { throw Self.translate(error) }
        guard await room.isEncrypted() else {
            try? await room.leave()
            throw SharedRoomError.notEncrypted
        }
    }

    func decline(_ id: String) async throws {
        // Leaving an invite is all declining is: nothing is sent to the inviter.
        do { try await room(id).leave() } catch { throw Self.translate(error) }
    }

    func leave(_ id: String) async throws {
        do { try await room(id).leave() } catch { throw Self.translate(error) }
    }

    // MARK: History and posts

    func history(of id: String) async throws -> SharedRoomHistory {
        let room = try await room(id)
        guard room.membership() == .joined else { throw SharedRoomError.notAllowed }
        guard await room.isEncrypted() else { throw SharedRoomError.notEncrypted }
        do {
            let info = try await room.roomInfo()
            let timeline = try await room.timeline()
            let items = TimelineItems()
            let handle = await timeline.addListener(listener: TaskTimelineListener { items.apply($0) })
            defer { handle.cancel() }
            var reachedStart = false
            for _ in 0..<40 where !reachedStart {
                reachedStart = try await timeline.paginateBackwards(numEvents: 200)
            }
            // The listener hears the last pages a moment after paginating returns.
            try? await Task.sleep(for: .milliseconds(150))
            var events: [SharedRoomEvent] = []
            let (members, unlimited) = try await Self.members(of: room)
            // The room's creators, or, before the SDK has its create event, whoever holds unlimited power,
            // which in room version 12 only a creator can.
            let listed = (info.creators ?? []).compactMap { Self.handle($0) }
            let creators = listed.isEmpty ? unlimited : listed
            for item in items.snapshot() {
                guard let event = item.asEvent(), let sender = Self.handle(event.sender) else { continue }
                let eventID: String = switch event.eventOrTransactionId {
                case .eventId(let id): id
                case .transactionId(let id): id
                }
                let date = MatrixMessagesService.date(event.timestamp)
                switch event.content {
                case .msgLike(let like):
                    switch like.kind {
                    case .message(let content):
                        if case .other(let type, let body) = content.msgType, type == marker.messageType {
                            events.append(.post(id: eventID, sender: sender, date: date, body: body))
                        }
                    case .unableToDecrypt:
                        events.append(.unreadable(id: eventID, sender: sender, date: date))
                    default:
                        break
                    }
                case .state(_, .roomPowerLevels(_, _, let users, _, _, _)):
                    var levels: [String: Int] = [:]
                    for (user, level) in users { if let name = Self.handle(user) { levels[name] = Int(clamping: level) } }
                    events.append(.roles(levels))
                default:
                    break
                }
            }
            // The creators are added to every set of roles, and the oldest part, if it didn't load, counts
            // under today's roles rather than being dropped.
            return SharedRoomHistory.reading(timeline: events, creators: creators, members: members, reachedStart: reachedStart)
        } catch let error as SharedRoomError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    /// Who's in the room or invited, and who among them holds unlimited power.
    private static func members(of room: Room) async throws -> ([SharedRoomMember], [String]) {
        let iterator = try await room.members()
        var result: [SharedRoomMember] = []
        var unlimited: [String] = []
        while let chunk = iterator.nextChunk(chunkSize: 100) {
            for member in chunk {
                guard let name = handle(member.userId), member.membership == .join || member.membership == .invite else { continue }
                if case .infinite = member.powerLevel { unlimited.append(name) }
                result.append(SharedRoomMember(username: name, role: SharedRole(powerLevel: level(member.powerLevel)), isInvited: member.membership == .invite))
            }
        }
        return (result, unlimited)
    }

    func post(_ body: String, to id: String) async throws {
        let room = try await room(id)
        // A post goes only into an encrypted room, so the label stays true.
        guard await room.isEncrypted() else { throw SharedRoomError.notEncrypted }
        let content: [String: String] = ["msgtype": marker.messageType, "body": body]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
        do {
            _ = try await room.sendRaw(eventType: "m.room.message", content: json)
        } catch {
            throw Self.translate(error)
        }
    }

    func chatPartners() async -> [String] {
        guard let service = try? await service() else { return [] }
        var people: Set<String> = []
        for room in service.client.rooms() where room.membership() == .joined {
            guard let info = try? await room.roomInfo(), info.isDirect,
                  !SharedRoomMarker.isSharedRoom(name: info.rawName, topic: info.topic),
                  let other = info.heroes.first.flatMap({ Self.handle($0.userId) })
            else { continue }
            people.insert(other)
        }
        return people.sorted()
    }

    func message(_ text: String, to username: String) async throws {
        _ = try await service()
        guard let chat = await messages.startChat(with: username) else {
            throw SharedRoomError.failed(messages.notice ?? "That chat couldn't be started.")
        }
        let model = try await messages.open(chat)
        model.draft = text
        await model.send()
        model.close()
    }

    private static func translate(_ error: any Error) -> any Error {
        if let error = error as? SharedRoomError { return error }
        // Messages' wording, which only blames the connection when the network really failed.
        return SharedRoomError.failed((MatrixMessagesService.translate(error) as? MessagesError)?.message ?? "That didn't go through. Try again.")
    }
}

/// The timeline's items as its diffs arrive.
private final class TimelineItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []

    func apply(_ diffs: [TimelineDiff]) {
        lock.withLock { for diff in diffs { MatrixChat.change(diff).apply(to: &items) } }
    }

    func snapshot() -> [TimelineItem] { lock.withLock { items } }
}

private final class TaskTimelineListener: TimelineListener {
    let handle: @Sendable ([TimelineDiff]) -> Void
    init(_ handle: @escaping @Sendable ([TimelineDiff]) -> Void) { self.handle = handle }
    func onUpdate(diff: [TimelineDiff]) { handle(diff) }
}
#endif
