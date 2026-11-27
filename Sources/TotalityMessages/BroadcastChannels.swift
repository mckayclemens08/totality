import Foundation

// Broadcast channels (owner, 2026-11-21): you post, followers read and react, and anyone can message you
// privately instead. A channel is an ordinary end-to-end encrypted Matrix room whose power levels let only
// the owner and the admins they pick send messages. The Matrix server enforces that, so a modified app
// can't post either. Plain types here, so the rules test on every platform.

/// The Matrix power levels a channel uses. The creator already outranks everyone in a room version 12 room.
public enum ChannelPower {
    /// The owner, who made the channel.
    public static let owner = 100
    /// An admin the owner picked: can post, invite and delete posts.
    public static let admin = 50
    /// Everyone else who joined.
    public static let follower = 0
    /// What a plain message needs. Followers sit below it, so they can't post.
    public static let post = 50
    /// Reactions need no level, so followers can react.
    public static let react = 0
    /// Changing the name, photo, who's an admin or the settings below.
    public static let settings = 100

    /// A room is a channel when posting needs more than a follower has. Ordinary chats and groups
    /// let everyone post.
    public static func isChannel(eventsDefault: Int) -> Bool { eventsDefault >= post }

    public static func canPost(level: Int) -> Bool { level >= post }
    public static func canReact(level: Int) -> Bool { level >= react }
    public static func canInvite(level: Int) -> Bool { level >= admin }
}

/// Size limits. Every member needs the room's message keys, so a very large encrypted room gets slow, and
/// Matrix has no member cap of its own: the app stops invites past this number.
public enum ChannelLimits {
    public static let maxMembers = 500

    public static func room(members: Int) -> Int { max(0, maxMembers - members) }

    /// Throws when inviting `adding` more people would pass the limit.
    public static func check(members: Int, adding: Int) throws {
        guard adding <= room(members: members) else {
            let left = room(members: members)
            throw MessagesError.failed(left == 0
                ? "This channel is full. A channel holds up to \(maxMembers) people."
                : "A channel holds up to \(maxMembers) people. There's room for \(left) more.")
        }
    }
}

/// What the screens say about a channel. Each line is literally true.
public enum ChannelLabels {
    public static let encrypted = "Posts are end-to-end encrypted. Only you and the admins you pick can post; followers can read and react."
    public static let nameNotEncrypted = "The channel's name isn't end-to-end encrypted, and neither is the fact that it's a channel. The server can see both."
    /// Matrix shows a room's member list to everyone in it, so this doesn't claim followers are hidden.
    public static let followersVisible = "Totality only shows followers a count. Everyone in a channel can be listed by Matrix, so don't count on staying unseen."
    public static let inviteOnly = "Channels are invite-only. You invite people by username, and they accept to join."
    public static func followers(_ count: Int) -> String { count == 1 ? "1 follower" : "\(count) followers" }
    public static func messageOwner(_ name: String) -> String { "Message \(name) privately" }
    public static let followerNote = "Only the owner and admins post here. You can react, or message them privately."
}

/// Who may do what in a channel, for the person looking at it. The room's own power levels decide.
public struct ChannelAccess: Equatable, Sendable {
    public let level: Int

    public init(level: Int) { self.level = level }

    public var canPost: Bool { ChannelPower.canPost(level: level) }
    public var canReact: Bool { ChannelPower.canReact(level: level) }
    public var canInvite: Bool { ChannelPower.canInvite(level: level) }
    public var isOwner: Bool { level >= ChannelPower.owner }
    public var title: String { isOwner ? "Owner" : canPost ? "Admin" : "Follower" }
}

/// Follower counts. Matrix holds invited people in the room too, and the size cap counts them, but only
/// people who accepted are followers.
public enum ChannelCounts {
    /// People who joined, not counting the owner. `members` is joined plus invited, as the cap counts it.
    public static func followers(members: Int, invited: Int) -> Int { max(0, members - max(0, invited) - 1) }
}

/// How a channel shows itself on an invite, before it's accepted. Matrix sends an invitee only a room's name,
/// topic and photo, so the topic carries the mark.
public enum ChannelMarker {
    public static let topic = "Totality broadcast channel"

    public static func isChannel(topic: String?) -> Bool { topic == Self.topic }

    /// What a request from someone's invite is called.
    public static func requestTitle(from name: String, isChannel: Bool) -> String {
        isChannel ? "Channel from \(name)" : "Group from \(name)"
    }
}

/// Usernames typed for a channel's invites or admins, separated by commas or spaces. One person is fine.
public enum ChannelPeople {
    public static func parse(_ typed: String, own: String) throws -> [String] {
        let parts = typed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        var names: [String] = []
        for part in parts {
            guard let name = MessagesUsername.normalized(part) else { throw MessagesError.failed("“\(part)” isn't a Totality username.") }
            if name != own && !names.contains(name) { names.append(name) }
        }
        return names
    }
}
