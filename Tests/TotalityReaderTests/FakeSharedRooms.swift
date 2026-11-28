import Foundation
import TotalityCore
@testable import TotalityReader

/// A stand-in for the Matrix server: rooms with members, power levels and posts. It enforces what the
/// real server enforces (membership, and power levels for invites, roles and removal), and nothing the
/// server can't see, such as whether a post is an edit or a comment. Devices have to check that.
@MainActor
final class FakeServer {
    struct Room {
        var levels: [String: Int] = [:]
        var joined: [String] = []
        var invited: [String: SharedRole] = [:]
        var inviters: [String: String] = [:]
        var events: [SharedRoomEvent] = []
        var isEncrypted = true
        var everJoined: Set<String> = []
        var creator = ""
        /// For each post, who could open it: those in the room or invited when it was sent. Matrix shares a
        /// room's key with them, from that post on, and never with anyone later.
        var readers: [String: Set<String>] = [:]
    }

    var rooms: [String: Room] = [:]
    /// Posts before an index that one person can't open, as Matrix may for someone who joined later.
    var hidden: [String: (before: Int, person: String)] = [:]
    var people: Set<String> = []
    /// Makes the next read of the room list fail, as a connection that's still starting can.
    var failNextRooms = false
    var chats: [String: [String]] = [:]
    var sentMessages: [(from: String, to: String, text: String)] = []
    private var count = 0
    var clock = Date(timeIntervalSince1970: 1_795_000_000)
    /// Room version 12, as Totality's server makes: the creator outranks everyone without being listed in
    /// the power levels.
    var roomVersion12 = false
    /// Posts are readable only to those in the room, or invited, when they were sent, as with Matrix keys.
    var keysFromInvite = false
    /// Power levels never reach the timeline, as when the room's first state comes with sync instead.
    var rolesMissingFromTimeline = false
    /// How many reads of a room pass before someone's own post shows in it, as it only comes back with
    /// the next sync.
    var ownPostLag = 0
    var reads: [String: Int] = [:]
    var sentAtRead: [String: Int] = [:]

    func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    func nextID(_ prefix: String) -> String {
        count += 1
        return "\(prefix)\(count)"
    }

    func device(for username: String) -> FakeRooms {
        people.insert(username)
        return FakeRooms(server: self, me: username)
    }
}

@MainActor
final class FakeRooms: SharedRooms {
    let server: FakeServer
    var me: String
    var unavailableReason: String?

    init(server: FakeServer, me: String) {
        self.server = server
        self.me = me
    }

    var ownUsername: String? { get async { me } }

    private func room(_ id: String) throws -> FakeServer.Room {
        guard let room = server.rooms[id] else { throw SharedRoomError.failed("No such room") }
        return room
    }

    private func requireOwner(_ id: String) throws {
        let room = try room(id)
        guard level(of: me, in: room) >= 100, room.joined.contains(me) else { throw SharedRoomError.notAllowed }
    }

    private func level(of person: String, in room: FakeServer.Room) -> Int {
        server.roomVersion12 && person == room.creator ? 100 : room.levels[person] ?? 0
    }

    private func changeLevels(_ id: String, _ change: (inout [String: Int]) -> Void) {
        change(&server.rooms[id]!.levels)
        server.rooms[id]!.events.append(.roles(server.rooms[id]!.levels))
    }

    func rooms() async throws -> [String] {
        if server.failNextRooms {
            server.failNextRooms = false
            throw SharedRoomError.failed("Not connected yet")
        }
        return server.rooms.filter { $0.value.joined.contains(me) }.keys.sorted()
    }

    func invites() async throws -> [SharedRoomInvite] {
        server.rooms.filter { $0.value.invited[me] != nil }.map {
            SharedRoomInvite(room: $0.key, inviter: $0.value.inviters[me], date: nil)
        }.sorted { $0.room < $1.room }
    }

    func create(inviting people: [String: SharedRole]) async throws -> String {
        let id = server.nextID("!room")
        server.rooms[id] = FakeServer.Room(joined: [me], everJoined: [me], creator: me)
        let v12 = server.roomVersion12
        changeLevels(id) { $0 = v12 ? [:] : [me: 100] }
        for (person, role) in people { try await invite(person, as: role, to: id) }
        return id
    }

    func invite(_ username: String, as role: SharedRole, to id: String) async throws {
        try requireOwner(id)
        guard server.people.contains(username) else { throw SharedRoomError.noSuchPerson(username) }
        server.rooms[id]!.invited[username] = role
        server.rooms[id]!.inviters[username] = me
        changeLevels(id) { $0[username] = role.rawValue }
    }

    func setRole(_ role: SharedRole, for username: String, in id: String) async throws {
        try requireOwner(id)
        let r = try room(id)
        if server.roomVersion12, username == r.creator, role != .owner {
            throw SharedRoomError.failed("The original creator stays an owner unless they leave.")
        }
        changeLevels(id) { levels in
            if !(server.roomVersion12 && username == r.creator) {
                levels[username] = role.rawValue
            }
            if role == .owner, !(server.roomVersion12 && self.me == r.creator) {
                levels[self.me] = SharedRole.editor.rawValue
            }
        }
    }

    func remove(_ username: String, from id: String) async throws {
        try requireOwner(id)
        server.rooms[id]!.joined.removeAll { $0 == username }
        server.rooms[id]!.invited[username] = nil
    }

    func accept(_ id: String) async throws {
        guard try room(id).invited[me] != nil else { throw SharedRoomError.notAllowed }
        server.rooms[id]!.invited[me] = nil
        server.rooms[id]!.joined.append(me)
        server.rooms[id]!.everJoined.insert(me)
        guard server.rooms[id]!.isEncrypted else {
            server.rooms[id]!.joined.removeAll { $0 == me }
            throw SharedRoomError.notEncrypted
        }
    }

    func decline(_ id: String) async throws {
        server.rooms[id]!.invited[me] = nil
    }

    func leave(_ id: String) async throws {
        server.rooms[id]?.joined.removeAll { $0 == me }
    }

    func history(of id: String) async throws -> SharedRoomHistory {
        let room = try room(id)
        guard room.joined.contains(me) else { throw SharedRoomError.notAllowed }
        guard room.isEncrypted else { throw SharedRoomError.notEncrypted }
        let members = room.joined.map { SharedRoomMember(username: $0, role: SharedRole(powerLevel: level(of: $0, in: room))) }
            + room.invited.keys.sorted().map { SharedRoomMember(username: $0, role: SharedRole(powerLevel: level(of: $0, in: room)), isInvited: true) }
        let read = server.reads[me + id, default: 0] + 1
        server.reads[me + id] = read
        var events: [SharedRoomEvent] = room.events.compactMap { event in
            switch event {
            case .roles where server.rolesMissingFromTimeline:
                return nil
            case .post(let eventID, let sender, let date, _):
                if sender == me, let sent = server.sentAtRead[eventID], read - sent <= server.ownPostLag { return nil }
                if server.keysFromInvite, room.readers[eventID]?.contains(me) == false {
                    return .unreadable(id: eventID, sender: sender, date: date)
                }
                return event
            default:
                return event
            }
        }
        if let hide = server.hidden[id], hide.person == me {
            for index in events.indices where index < hide.before {
                if case .post(let eventID, let sender, let date, _) = events[index] { events[index] = .unreadable(id: eventID, sender: sender, date: date) }
            }
        }
        // Read the way the app reads a Matrix room's timeline.
        return SharedRoomHistory.reading(
            timeline: events, creators: server.roomVersion12 ? [room.creator] : [], members: members, reachedStart: true
        )
    }

    func post(_ body: String, to id: String) async throws {
        guard try room(id).joined.contains(me) else { throw SharedRoomError.notAllowed }
        let eventID = server.nextID("$e")
        let room = server.rooms[id]!
        server.rooms[id]!.readers[eventID] = Set(room.joined).union(room.invited.keys)
        server.sentAtRead[eventID] = server.reads[me + id, default: 0]
        server.rooms[id]!.events.append(.post(id: eventID, sender: me, date: server.tick(), body: body))
    }

    func chatPartners() async -> [String] { server.chats[me] ?? [] }

    func message(_ text: String, to username: String) async throws {
        server.sentMessages.append((me, username, text))
    }
}
