import Foundation

/// Something to hand to another person: a photo's bytes, or a video file the sender may remove once it's
/// queued. The carrying module re-encodes both on the device and drops where, when and on what they were
/// taken before anything leaves it.
public enum OutgoingItem: Sendable {
    case photo(Data)
    case video(URL)
}

/// What came of sending to a person.
public struct PersonSendResult: Equatable, Sendable {
    public var sent: Int
    public var failed: Int
    /// The first thing that went wrong, in words for the person, or nil if everything went.
    public var problem: String?

    public init(sent: Int = 0, failed: Int = 0, problem: String? = nil) {
        self.sent = sent
        self.failed = failed
        self.problem = problem
    }
}

/// A module that delivers content to another person end to end encrypted. Photos shares through it
/// without knowing which module carries the content, so neither imports the other. The app hands one to
/// a module that shares, and only on builds where the carrying module runs.
@MainActor
public protocol PersonSender: AnyObject {
    /// Why nothing can be sent right now, or nil when it can.
    var unavailableReason: String? { get }
    /// The longest video it carries, in seconds.
    var longestVideo: Double { get }
    /// Finds or starts the encrypted chat with `username`, sends `note` first when there is one, then
    /// each item in order. `progress` is told how many have gone.
    func send(
        _ items: [@Sendable () async throws -> OutgoingItem],
        note: String?,
        to username: String,
        progress: @MainActor (Int) -> Void
    ) async -> PersonSendResult
}
