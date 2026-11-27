import Foundation

// The info screen of a group or broadcast channel, opened from its title: who's in it, who runs it, and
// the settings only some people may change. Plain types here, so the rules test on every platform. The
// Matrix server decides what's really allowed; these only decide what to offer.

/// One person in a group or channel, with the power level the room gives them.
public struct ChatMember: Equatable, Sendable, Identifiable {
    /// Their Matrix ID.
    public let id: String
    public let level: Int
    /// Invited, and hasn't accepted yet.
    public let invited: Bool

    public init(id: String, level: Int, invited: Bool = false) {
        self.id = id
        self.level = level
        self.invited = invited
    }

    public var isOwner: Bool { level >= ChannelPower.owner }
    /// An admin the owner picked: not the owner.
    public var isAdmin: Bool { level >= ChannelPower.admin && !isOwner }

    public var role: String { isOwner ? "Owner" : isAdmin ? "Admin" : invited ? "Invited" : "Member" }
}

/// What the person looking at the info screen is offered, from their own level in the room.
public struct ChatPermissions: Equatable, Sendable {
    public let isChannel: Bool
    public let level: Int

    public init(isChannel: Bool, level: Int) {
        self.isChannel = isChannel
        self.level = level
    }

    /// A channel's name and photo are the owner's. In a group, an admin can change them too.
    public var canRename: Bool { level >= (isChannel ? ChannelPower.settings : ChannelPower.admin) }
    /// A channel is invited to by its owner and admins. In a group, any member can add people.
    public var canAddPeople: Bool { isChannel ? ChannelPower.canInvite(level: level) : true }
    /// Only the owner changes who the admins are.
    public var canManageAdmins: Bool { level >= ChannelPower.owner }
    public var isOwner: Bool { level >= ChannelPower.owner }
    /// An owner leaving would leave nobody to run the room, so the screen says so first.
    public var leaveWarning: String? {
        isOwner ? "You made this \(isChannel ? "channel" : "group"). If you leave, nobody can change its name or admins." : nil
    }
}

/// The lists on the info screen.
public enum ChatRoster {
    /// Owner first, then admins, then everyone else by name. Invited people come last.
    public static func ordered(_ members: [ChatMember], name: (String) -> String) -> [ChatMember] {
        members.sorted { a, b in
            if a.invited != b.invited { return !a.invited }
            if a.level != b.level { return a.level > b.level }
            return name(a.id).localizedCaseInsensitiveCompare(name(b.id)) == .orderedAscending
        }
    }

    /// The people who run a room: its owner and admins.
    public static func admins(_ members: [ChatMember]) -> [ChatMember] {
        members.filter { ($0.isOwner || $0.isAdmin) && !$0.invited }
    }

    /// Your own level, from the list. A room that doesn't list you gives you none.
    public static func level(of own: String?, in members: [ChatMember]) -> Int {
        members.first { $0.id == own }?.level ?? ChannelPower.follower
    }
}

/// What the info screen says. Each line is literally true.
public enum ChatInfoLabels {
    public static let groupEncrypted = "Messages are end-to-end encrypted. Only the people in this group can read them."
    public static let channelEncrypted = ChannelLabels.encrypted
    public static let groupMembersVisible = "Everyone in a group can see who else is in it."
    public static let muteDetail = "Silences alerts for this chat on this phone only. Messages still arrive."
    public static let reportDetail = "Sends a report to the people who run Totality's server, with this chat's name. Messages stay encrypted, so they can't read them, and they aren't attached."
    public static func memberCount(_ count: Int) -> String { count == 1 ? "1 person" : "\(count) people" }
    public static func adminsNote(canManage: Bool) -> String {
        canManage ? "Admins can post and add people. Only you can change who they are." : "Admins can post and add people."
    }
}

/// Chats whose alerts are silenced on this phone. Totality's alerts are written on the phone, where the
/// messages are opened, so this is the whole of what muting needs.
public enum MutedChats {
    static let key = "messages.mutedChats"

    public static func all(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public static func isMuted(_ chat: String, _ defaults: UserDefaults = .standard) -> Bool {
        all(defaults).contains(chat)
    }

    public static func set(_ chat: String, muted: Bool, _ defaults: UserDefaults = .standard) {
        var chats = all(defaults)
        if muted { chats.insert(chat) } else { chats.remove(chat) }
        defaults.set(chats.sorted(), forKey: key)
    }
}

extension GroupMembers {
    /// Throws when adding `adding` people to a group of `current` would pass the limit.
    public static func check(current: Int, adding: Int) throws {
        let room = max(0, limit - current)
        guard adding <= room else {
            throw MessagesError.failed(room == 0
                ? "This group is full. A group can have up to \(limit) people."
                : "A group can have up to \(limit) people. There's room for \(room) more.")
        }
    }
}
