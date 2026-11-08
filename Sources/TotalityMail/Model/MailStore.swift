import Foundation

public enum MailStoreError: Error, Equatable {
    /// This device has no content key, so nothing sealed can open.
    case noKey
    /// The change didn't reach the server. It's kept and tried again.
    case offline
    case unavailable
    /// Nobody this device's key belongs to is signed in, so there's no mailbox to show.
    case noAccount
    /// The device's key hasn't joined the key backup yet. A mailbox's key can never be replaced, so
    /// nothing is published, and no mail can arrive, until it has.
    case waitingForBackup
    /// The server holds a different key for this mailbox. Only the server's owner can put that right,
    /// so it's shown as a problem with the account and never tried again on its own.
    case keyConflict
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

/// What a pass over the outside accounts left: everything stored, with the new mail in it, and what
/// went wrong with any account, worded for the screen.
public struct OutsideDownloadResult: Sendable {
    public let mailbox: Mailbox
    public let problems: [String]

    public init(mailbox: Mailbox, problems: [String]) {
        self.mailbox = mailbox
        self.problems = problems
    }
}

/// How far downloading from one outside account has got.
public struct OutsideDownload: Equatable, Sendable {
    public let address: String
    public let done: Int

    public init(address: String, done: Int) {
        self.address = address
        self.done = done
    }
}

/// All the screens need from wherever mail lives. `ServerMailStore` is the real one: it downloads and
/// opens what's sealed, keeps it on the device, and syncs marks and settings. `SampleMailStore` stands
/// in for previews and tests.
public protocol MailStore: Sendable {
    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening
    func save(_ marks: [UUID: MailMarks]) async throws
    func save(_ settings: MailSettings) async throws
    /// For good. Nothing can bring these back.
    func erase(_ messages: Set<UUID>) async throws
    func data(of attachment: UUID) async throws -> Data
    /// The person's own address, even before any mail can open, so they can hand it out.
    func address() async -> String?
    /// Kept sealed, and synced. Saving the same draft again replaces it.
    func save(_ draft: MailDraft) async throws
    func discard(draft: UUID) async throws
    /// One send, right now, only ever from a press. The screens hold it for their few seconds of Undo
    /// before calling this. Throws `MailSendError` when it can't start; otherwise the result says how
    /// it went for each person.
    func send(_ draft: MailDraft) async throws -> MailSendResult
    /// Downloads new mail from each outside account, straight from the provider, then returns everything
    /// stored. Nil when there are no outside accounts. A problem with one account never stops the others.
    func downloadOutside(progress: @escaping @Sendable (OutsideDownload) -> Void) async -> OutsideDownloadResult?
    /// Searches each outside account at its provider for older mail and downloads what's found, then
    /// returns everything stored. Only from the person's press. Nil when there are no outside accounts.
    func searchOutside(_ query: String) async -> OutsideDownloadResult?
    /// What's already on this device, read without the network, so Mail shows it at once. Nil when
    /// nothing can be read yet.
    func cached() async -> Mailbox?
}

extension MailStore {
    public func cached() async -> Mailbox? { nil }
    public func address() async -> String? { nil }
    public func downloadOutside(progress: @escaping @Sendable (OutsideDownload) -> Void) async -> OutsideDownloadResult? { nil }
    public func searchOutside(_ query: String) async -> OutsideDownloadResult? { nil }
}

/// A mailbox that can't be reached at all, for the reason it gives. Every call says the same thing.
public struct UnavailableMailStore: MailStore {
    public let reason: MailStoreError

    public init(_ reason: MailStoreError) {
        self.reason = reason
    }

    public func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening { throw reason }
    public func save(_ marks: [UUID: MailMarks]) async throws { throw reason }
    public func save(_ settings: MailSettings) async throws { throw reason }
    public func erase(_ messages: Set<UUID>) async throws { throw reason }
    public func data(of attachment: UUID) async throws -> Data { throw reason }
    public func save(_ draft: MailDraft) async throws { throw reason }
    public func discard(draft: UUID) async throws { throw reason }
    public func send(_ draft: MailDraft) async throws -> MailSendResult { throw reason }
}
