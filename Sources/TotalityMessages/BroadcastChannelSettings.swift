import Foundation

/// The room settings a channel is created with, as plain numbers so a test can check them.
public enum ChannelSettings {
    /// Events followers may send even though plain messages need `ChannelPower.post`. Taking a reaction
    /// back is a redaction, so followers need that one too; `redact` below still stops them deleting posts.
    public static let followerEvents: [String: Int] = ["m.reaction": ChannelPower.react, "m.room.redaction": ChannelPower.react]
    public static let eventsDefault = ChannelPower.post
    public static let usersDefault = ChannelPower.follower
    public static let stateDefault = ChannelPower.settings
    public static let invite = ChannelPower.admin
    public static let redact = ChannelPower.admin
    public static let kick = ChannelPower.admin
    public static let ban = ChannelPower.admin

    /// Each admin's level. The creator isn't listed: in the room versions Totality's server makes, the
    /// creator already outranks everyone and the server refuses power levels that name them.
    public static func users(admins: [String]) -> [String: Int] {
        Dictionary(admins.map { ($0, ChannelPower.admin) }, uniquingKeysWith: { a, _ in a })
    }

    /// What a Matrix server does with an event from someone at `level`.
    public static func allows(_ eventType: String, level: Int) -> Bool {
        level >= (followerEvents[eventType] ?? eventsDefault)
    }
}
