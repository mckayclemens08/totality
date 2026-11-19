import Foundation
import TotalityCore
@testable import TotalityTasks

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
    }

    var rooms: [String: Room] = [:]
    var people: Set<String> = []
    var chats: [String: [String]] = [:]
    var sentMessages: [(from: String, to: String, text: String)] = []
    private var count = 0
    var clock = Date(timeIntervalSince1970: 1_795_000_000)

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
    let me: String
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
        guard try room(id).levels[me] ?? 0 >= 100, try room(id).joined.contains(me) else { throw SharedRoomError.notAllowed }
    }

    private func changeLevels(_ id: String, _ change: (inout [String: Int]) -> Void) {
        change(&server.rooms[id]!.levels)
        server.rooms[id]!.events.append(.roles(server.rooms[id]!.levels))
    }

    func rooms() async throws -> [String] {
        server.rooms.filter { $0.value.joined.contains(me) }.keys.sorted()
    }

    func invites() async throws -> [SharedRoomInvite] {
        server.rooms.filter { $0.value.invited[me] != nil }.map {
            SharedRoomInvite(room: $0.key, inviter: $0.value.inviters[me], date: nil)
        }.sorted { $0.room < $1.room }
    }

    func create(inviting people: [String: SharedRole]) async throws -> String {
        let id = server.nextID("!room")
        server.rooms[id] = FakeServer.Room(joined: [me], everJoined: [me])
        changeLevels(id) { $0 = [me: 100] }
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
        changeLevels(id) { levels in
            levels[username] = role.rawValue
            if role == .owner { levels[self.me] = SharedRole.editor.rawValue }
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
        let members = room.joined.map { SharedRoomMember(username: $0, role: SharedRole(powerLevel: room.levels[$0] ?? 0)) }
            + room.invited.keys.sorted().map { SharedRoomMember(username: $0, role: SharedRole(powerLevel: room.levels[$0] ?? 0), isInvited: true) }
        return SharedRoomHistory(events: room.events, members: members, isEncrypted: true)
    }

    func post(_ body: String, to id: String) async throws {
        guard try room(id).joined.contains(me) else { throw SharedRoomError.notAllowed }
        server.rooms[id]!.events.append(.post(id: server.nextID("$e"), sender: me, date: server.tick(), body: body))
    }

    func chatPartners() async -> [String] { server.chats[me] ?? [] }

    func message(_ text: String, to username: String) async throws {
        server.sentMessages.append((me, username, text))
    }
}
