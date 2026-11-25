import Foundation

/// What someone may do in a shared room. It is the room's power level, which the Matrix server enforces
/// for membership and roles, and which every device checks again before it applies a change.
public enum SharedRole: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Reads and comments.
    case viewer = 0
    /// Adds, ticks off, edits, assigns and comments.
    case editor = 50
    /// Everything an editor can, plus inviting, changing roles and removing people. There is one.
    case owner = 100

    /// The role a power level gives. Anything between two roles rounds down.
    public init(powerLevel: Int) {
        if powerLevel >= SharedRole.owner.rawValue {
            self = .owner
        } else if powerLevel >= SharedRole.editor.rawValue {
            self = .editor
        } else {
            self = .viewer
        }
    }

    public static func < (a: SharedRole, b: SharedRole) -> Bool { a.rawValue < b.rawValue }

    public var canEdit: Bool { self >= .editor }

    public var name: String {
        switch self {
        case .viewer: "Can view"
        case .editor: "Can edit"
        case .owner: "Owner"
        }
    }
}

/// Someone in a shared room, or invited to it.
public struct SharedRoomMember: Hashable, Sendable, Identifiable {
    /// Their Totality handle, without the @.
    public let username: String
    public let role: SharedRole
    /// Invited and not joined yet.
    public let isInvited: Bool

    public var id: String { username }

    public init(username: String, role: SharedRole, isInvited: Bool = false) {
        self.username = username
        self.role = role
        self.isInvited = isInvited
    }
}

/// An invitation to a shared room that hasn't been answered.
public struct SharedRoomInvite: Hashable, Sendable, Identifiable {
    public let room: String
    /// Who sent it, by handle, when the server says.
    public let inviter: String?
    public let date: Date?

    public var id: String { room }

    public init(room: String, inviter: String?, date: Date?) {
        self.room = room
        self.inviter = inviter
        self.date = date
    }
}

/// One thing in a shared room's history, oldest first. The body was opened on this device: it travels
/// end-to-end encrypted inside the room.
public enum SharedRoomEvent: Equatable, Sendable {
    /// A module's own message. `sender` is the handle the server and the room's encryption vouch for, never
    /// one written inside the body.
    case post(id: String, sender: String, date: Date, body: String)
    /// Everyone's power level by handle, as of this point in the history.
    case roles([String: Int])
    /// A post this device couldn't open, such as one sent before it joined.
    case unreadable(id: String, sender: String, date: Date)
}

/// A shared room as this device has it now.
public struct SharedRoomHistory: Equatable, Sendable {
    public let events: [SharedRoomEvent]
    public let members: [SharedRoomMember]
    /// Checked on this device before the history was read. A room that isn't is never read.
    public let isEncrypted: Bool

    public init(events: [SharedRoomEvent], members: [SharedRoomMember], isEncrypted: Bool) {
        self.events = events
        self.members = members
        self.isEncrypted = isEncrypted
    }
}

public enum SharedRoomError: Error, Equatable, Sendable {
    case unavailable(String)
    case noSuchPerson(String)
    case notEncrypted
    case notAllowed
    case failed(String)

    public var message: String {
        switch self {
        case .unavailable(let reason): reason
        case .noSuchPerson(let name): "There's no one called @\(name)."
        case .notEncrypted: "That list isn't end-to-end encrypted, so Tasks won't open it."
        case .notAllowed: "Only the owner can do that."
        case .failed(let reason): reason
        }
    }
}

/// End-to-end encrypted rooms that a module keeps shared content in, such as a shared task list. Messages
/// carries them over Matrix, and the app hands one to a module that shares, so the module never imports
/// Messages. Each room is end-to-end encrypted; who is in it, and when they post, is visible to the server.
/// Rooms made through this are kept out of Messages' chat list.
@MainActor
public protocol SharedRooms: AnyObject {
    /// Why nothing can be shared right now, or nil when it can.
    var unavailableReason: String? { get }
    /// The signed-in person's handle, once connected.
    var ownUsername: String? { get async }
    /// Shared rooms this person has joined.
    func rooms() async throws -> [String]
    /// Invitations waiting for an answer.
    func invites() async throws -> [SharedRoomInvite]
    /// Makes a new end-to-end encrypted room with you as its owner, and invites each person with their role.
    func create(inviting people: [String: SharedRole]) async throws -> String
    /// Owner only.
    func invite(_ username: String, as role: SharedRole, to room: String) async throws
    /// Owner only. Making someone the owner hands it over: they get the owner's level and you become an editor.
    func setRole(_ role: SharedRole, for username: String, in room: String) async throws
    /// Owner only. They stop getting anything new.
    func remove(_ username: String, from room: String) async throws
    /// Joins, then leaves again if the room isn't end-to-end encrypted.
    func accept(_ room: String) async throws
    /// Quiet: the inviter isn't told.
    func decline(_ room: String) async throws
    func leave(_ room: String) async throws
    /// Everything this device can read of the room, in order. Refuses a room that isn't encrypted.
    func history(of room: String) async throws -> SharedRoomHistory
    /// Sends a module message into the room, encrypted on this device.
    func post(_ body: String, to room: String) async throws
    /// Handles of the people you have one-to-one chats with, for picking someone to share with.
    func chatPartners() async -> [String]
    /// Sends a plain chat message to someone, in your encrypted chat with them.
    func message(_ text: String, to username: String) async throws
}

/// How a module's rooms are told apart from chats and from each other's. The room's name and topic aren't
/// end-to-end encrypted, so they are fixed words that say only which module the room is for, never what's in it.
public struct RoomMarker: Hashable, Sendable {
    public let name: String
    public let topic: String
    /// The message type a module's posts go out as, inside `m.room.message`, so they're encrypted like a chat message.
    public let messageType: String

    public init(name: String, topic: String, messageType: String) {
        self.name = name
        self.topic = topic
        self.messageType = messageType
    }

    /// Whether a room is this module's. The name alone is enough, since an invite may not carry the topic.
    public func matches(name: String?, topic: String?) -> Bool {
        name == self.name || topic == self.topic
    }
}

/// How a shared room is told apart from a chat. The room's name and topic aren't end-to-end encrypted, so
/// they are fixed words that say only that it's a shared list, never which one: the list's own name
/// travels inside the encrypted room.
public enum SharedRoomMarker {
    /// Tasks' shared lists (issue 123, step 6).
    public static let tasks = RoomMarker(name: "Totality shared list", topic: "app.totality.tasks.v1", messageType: "app.totality.tasks")
    /// Social's Friends and Close-friends posts (issue 149). Which audience a room is for travels inside it.
    public static let social = RoomMarker(name: "Totality posts", topic: "app.totality.social.v1", messageType: "app.totality.social")
    /// The Reader's shared docs (issue 228). The doc's title and text travel inside the encrypted room.
    public static let reader = RoomMarker(name: "Totality shared doc", topic: "app.totality.reader.v1", messageType: "app.totality.reader")
    /// Every module's marker, so Messages can leave all of them out of its chats.
    public static let all = [tasks, social, reader]

    public static var name: String { tasks.name }
    public static var topic: String { tasks.topic }
    public static var messageType: String { tasks.messageType }

    /// A room Messages leaves out of its chats and requests: any module's shared room.
    public static func isSharedRoom(name: String?, topic: String?) -> Bool {
        all.contains { $0.matches(name: name, topic: topic) }
    }
}
