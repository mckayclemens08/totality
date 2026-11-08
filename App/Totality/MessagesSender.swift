import Foundation
import TotalityCore
import TotalityMessages

/// Carries what Photos shares into an encrypted Messages chat. It lives in the app, which may import
/// both, so Photos and Messages never import each other: Photos sees only `PersonSender`.
@MainActor
final class MessagesSender: PersonSender {
    private let messages: MessagesModel

    init(messages: MessagesModel) {
        self.messages = messages
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = messages.phase { return reason }
        return nil
    }

    var longestVideo: Double { VideoPrep.longest }

    func send(
        _ items: [@Sendable () async throws -> OutgoingItem],
        note: String?,
        to username: String,
        progress: @MainActor (Int) -> Void
    ) async -> PersonSendResult {
        if messages.phase != .ready { await messages.connect() }
        guard messages.phase == .ready else {
            if let unavailableReason { return PersonSendResult(failed: items.count, problem: unavailableReason) }
            return PersonSendResult(failed: items.count, problem: "Messages couldn't connect. Open Messages to check, then try again.")
        }
        guard let chat = await messages.startChat(with: username) else {
            return PersonSendResult(failed: items.count, problem: messages.notice ?? "That chat couldn't be started.")
        }
        var result = PersonSendResult()
        // An album's name goes just before its first photo that opens, so a share with nothing to send sends no name.
        var pendingNote = note
        for load in items {
            let item: OutgoingItem
            do {
                item = try await load()
            } catch {
                result.failed += 1
                result.problem = result.problem ?? "Something couldn't be opened on this device."
                continue
            }
            if let note = pendingNote {
                pendingNote = nil
                do {
                    let model = try await messages.open(chat)
                    model.draft = note
                    await model.send()
                    model.close()
                } catch {
                    // The photos still go. Only the album's name is missing.
                }
            }
            let sent: Bool
            switch item {
            case .photo(let data):
                sent = await messages.sendPhoto(data, to: chat)
            case .video(let file):
                // Messages removes the file either way.
                sent = await messages.sendVideo(file, to: chat)
            }
            if sent {
                result.sent += 1
                progress(result.sent)
            } else {
                result.failed += 1
                result.problem = result.problem ?? messages.notice
            }
        }
        return result
    }
}
