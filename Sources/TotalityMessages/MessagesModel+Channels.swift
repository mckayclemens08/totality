import Foundation

extension MessagesModel {
    /// Starts a broadcast channel. Its ID, or nil with `notice` saying why not. Admins are people who can
    /// post alongside you; everyone else you invite later follows.
    public func startChannel(name: String, admins typed: String = "") async -> String? {
        guard let service else { return nil }
        do {
            notice = nil
            guard let name = GroupName.clean(name) else {
                notice = "Give the channel a name."
                return nil
            }
            let admins = try ChannelPeople.parse(typed, own: MessagesUsername.display(service.userID))
            try ChannelLimits.check(members: 1, adding: admins.count)
            // The admins are invited when the channel is made, so the same rule applies.
            if let refusal = await followerRefusal(admins) {
                notice = refusal
                return nil
            }
            if let blocked = await notReachable(admins) {
                notice = blocked
                return nil
            }
            let chat = try await service.startChannel(name: name, admins: admins)
            await applyNewChatDefault(to: chat)
            return chat
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    /// Adds people to a group by username, from its info screen. `current` is how many are in it now.
    /// True once they're asked; each gets a request to accept.
    public func addPeople(_ typed: String, toGroup chat: String, current: Int) async -> Bool {
        guard let service else { return false }
        do {
            notice = nil
            let names = try ChannelPeople.parse(typed, own: MessagesUsername.display(service.userID))
            guard !names.isEmpty else {
                notice = "Type at least one username."
                return false
            }
            try GroupMembers.check(current: current, adding: names.count)
            if let blocked = await notReachable(names) {
                notice = blocked
                return false
            }
            try await service.invite(names, toChannel: chat)
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Invites followers by username. True once they're asked.
    public func invite(_ typed: String, toChannel chat: String) async -> Bool {
        guard let service else { return false }
        do {
            notice = nil
            let names = try ChannelPeople.parse(typed, own: MessagesUsername.display(service.userID))
            guard !names.isEmpty else {
                notice = "Type at least one username."
                return false
            }
            if let refusal = await followerRefusal(names) {
                notice = refusal
                return false
            }
            if let blocked = await notReachable(names) {
                notice = blocked
                return false
            }
            try await service.invite(names, toChannel: chat)
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// A channel invites only people who follow you (owner, 2026-11-26). Nil when everyone does. The server
    /// enforces it too, so a modified app can't skip this.
    func followerRefusal(_ names: [String]) async -> String? {
        guard !names.isEmpty else { return nil }
        return ChannelInviteRule.refusal(inviting: names, followers: await people.whoFollowsMe(among: names))
    }
}
