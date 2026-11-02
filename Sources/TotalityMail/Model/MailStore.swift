import Foundation

public enum MailStoreError: Error, Equatable {
    /// This device has no content key, so nothing sealed can open.
    case noKey
    /// The change didn't reach the server. It's kept and tried again.
    case offline
    case unavailable
}

/// How far the first download has got.
public struct MailDownload: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// A mailbox and how it was reached.
public struct MailOpening: Sendable {
    public let mailbox: Mailbox
    /// What came back is what the device already had.
    public let isOffline: Bool

    public init(mailbox: Mailbox, isOffline: Bool = false) {
        self.mailbox = mailbox
        self.isOffline = isOffline
    }
}

/// All the screens need from wherever mail lives. The sample store stands in until step 4's list and
/// fetch paths exist on the server: the real one downloads and opens what's sealed, keeps it on the
/// device, and syncs marks and settings, and nothing above this line has to change.
public protocol MailStore: Sendable {
    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening
    func save(_ marks: [UUID: MailMarks]) async throws
    func save(_ settings: MailSettings) async throws
    /// For good. Nothing can bring these back.
    func erase(_ messages: Set<UUID>) async throws
    func data(of attachment: UUID) async throws -> Data
}
