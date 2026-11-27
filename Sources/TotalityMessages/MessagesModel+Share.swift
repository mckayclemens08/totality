import Foundation
import TotalityCore

/// How a send to several chats went: which got it, and why the others didn't.
public struct ShareResult: Equatable, Sendable {
    public var sent: [String] = []
    public var failed: [String: String] = [:]

    public init(sent: [String] = [], failed: [String: String] = [:]) {
        self.sent = sent
        self.failed = failed
    }

    public var allSent: Bool { failed.isEmpty }
}

public extension ChatSummary {
    /// The chat list's line for the last message: a shared item reads as "Shared a post", not its link.
    var lastLine: String? { lastMessage.map { SharedContentLink.summary(of: $0) ?? $0 } }
}

extension MessagesModel {
    /// The chats a shared item can go to, newest first: people, groups and channels. Requests aren't in it.
    /// A channel is only a target when you can post there, which `postableChannels()` finds out.
    public var shareTargets: [ChatSummary] { chats }

    /// Which broadcast channels you own or help run, so the picker offers only those. A follower can't post.
    public func postableChannels() async -> Set<String> {
        guard let service else { return [] }
        var postable = Set<String>()
        for chat in chats where chat.isChannel {
            guard let channel = try? await service.openChat(chat.id) else { continue }
            if channel.channelAccess?.canPost == true { postable.insert(chat.id) }
            channel.close()
        }
        return postable
    }

    /// Sends a shared item to each chat as an end-to-end encrypted message, then the note as an ordinary message
    /// under it. At most `ShareLimits.maxTargets` chats. A chat that fails doesn't stop the others.
    public func share(_ request: ShareRequest, note: String, to chats: [String]) async -> ShareResult {
        var result = ShareResult()
        guard let service else {
            for chat in ShareLimits.limited(chats) { result.failed[chat] = MessagesError.notSignedIn.message }
            return result
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        for chat in ShareLimits.limited(chats) {
            do {
                let channel = try await service.openChat(chat)
                defer { channel.close() }
                if let access = channel.channelAccess, !access.canPost { throw MessagesError.failed(ChannelLabels.followerNote) }
                try await channel.send(request.messageText, replyingTo: nil)
                if !note.isEmpty { try await channel.send(note, replyingTo: nil) }
                result.sent.append(chat)
            } catch {
                result.failed[chat] = Self.describe(error)
            }
        }
        return result
    }
}
