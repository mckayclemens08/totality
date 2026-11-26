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
}
