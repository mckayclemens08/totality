#if canImport(MatrixRustSDK)
import Foundation
@preconcurrency import MatrixRustSDK
import TotalityMessages

// Broadcast channels on the Matrix SDK (owner, 2026-11-21).

extension MatrixMessagesService {
    /// An encrypted room where only the owner and the admins named here can post. The server enforces the
    /// power levels, so a modified app can't post either. Followers are invited afterwards.
    func startChannel(name: String, admins: [String]) async throws -> String {
        let people = admins.map { "@\($0):\(Self.serverName)" }.filter { $0 != userID }
        do {
            for person in people {
                do {
                    _ = try await client.getProfile(userId: person)
                } catch let error as ClientError {
                    if case .MatrixApi(_, let code, _, _) = error, code == "M_NOT_FOUND" {
                        throw MessagesError.failed("There's no one called \(MessagesUsername.display(person)).")
                    }
                    throw error
                }
            }
            let levels = PowerLevels(
                usersDefault: Int32(ChannelSettings.usersDefault), eventsDefault: Int32(ChannelSettings.eventsDefault),
                stateDefault: Int32(ChannelSettings.stateDefault), ban: Int32(ChannelSettings.ban),
                kick: Int32(ChannelSettings.kick), redact: Int32(ChannelSettings.redact),
                invite: Int32(ChannelSettings.invite), notifications: nil,
                users: ChannelSettings.users(admins: people).mapValues(Int32.init),
                events: ChannelSettings.followerEvents.mapValues(Int32.init)
            )
            let id = try await client.createRoom(request: CreateRoomParameters(
                name: name, topic: ChannelMarker.topic, isEncrypted: true, isDirect: false, visibility: .private, preset: .privateChat,
                invite: people.isEmpty ? nil : people, powerLevelContentOverride: levels
            ))
            for _ in 0..<50 {
                if try client.getRoom(roomId: id) != nil { return id }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw MessagesError.failed("The new channel didn't arrive from the server. Try again.")
        } catch {
            throw Self.translate(error)
        }
    }

    func invite(_ usernames: [String], toChannel chat: String) async throws {
        do {
            guard let room = try client.getRoom(roomId: chat) else { throw MessagesError.failed("That channel isn't on this device yet.") }
            let info = try await room.roomInfo()
            try ChannelLimits.check(members: Int(info.joinedMembersCount + info.invitedMembersCount), adding: usernames.count)
            for name in usernames {
                try await room.inviteUserById(userId: "@\(name):\(Self.serverName)")
            }
        } catch {
            throw Self.translate(error)
        }
    }

    /// What this person can do in a room, when it's a channel.
    static func channelAccess(of room: Room, info: RoomInfo?) -> ChannelAccess? {
        guard let info, !info.isDirect, let levels = info.powerLevels,
              ChannelPower.isChannel(eventsDefault: Int(levels.values().eventsDefault)) else { return nil }
        let level = levels.canOwnUserSendState(stateEvent: .roomPowerLevels) ? ChannelPower.owner
            : levels.canOwnUserSendMessage(message: .roomMessage) ? ChannelPower.admin : ChannelPower.follower
        return ChannelAccess(level: level)
    }
}
#endif
