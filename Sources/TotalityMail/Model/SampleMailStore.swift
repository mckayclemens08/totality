import Foundation

/// Stands in for the real mailbox until the server can list and fetch mail. Nothing here is the
/// person's, and the screens say so. It goes away with the real store, along with `MailSampleNote`.
public actor SampleMailStore: MailStore {
    /// Each state the screens have to show, so they can be looked at before real mail can cause them.
    public enum Scene: String, CaseIterable, Identifiable, Sendable {
        case normal = "Sample mail"
        case empty = "Empty mailbox"
        case download = "First download"
        case noKey = "No key on this device"
        case failed = "Mailbox can't be reached"
        case offline = "Offline"
        case full = "Mailbox full"

        public var id: String { rawValue }
    }

    public private(set) var scene: Scene
    private var mail: SampleMail
    private let pause: Duration

    public init(scene: Scene = .normal, now: Date = Date(), pause: Duration = .milliseconds(500)) {
        self.scene = scene
        self.pause = pause
        mail = SampleMail(now: now)
    }

    public func use(_ scene: Scene) {
        self.scene = scene
        mail = SampleMail(now: mail.now)
    }

    public func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        switch scene {
        case .noKey: throw MailStoreError.noKey
        case .failed: throw MailStoreError.unavailable
        case .empty: return MailOpening(mailbox: Mailbox(address: SampleMail.me.address, settings: mail.mailbox.settings))
        case .offline: return MailOpening(mailbox: mail.mailbox, isOffline: true)
        case .full:
            var mailbox = mail.mailbox
            mailbox.isFull = true
            return MailOpening(mailbox: mailbox)
        case .normal:
            return MailOpening(mailbox: mail.mailbox)
        case .download:
            let total = 1_284
            for step in 0...12 {
                progress(MailDownload(done: min(total, step * 107), total: total))
                try await Task.sleep(for: pause)
            }
            return MailOpening(mailbox: mail.mailbox)
        }
    }

    public func save(_ marks: [UUID: MailMarks]) async throws {
        if scene == .offline { throw MailStoreError.offline }
        mail.mailbox.apply(marks)
    }

    public func save(_ settings: MailSettings) async throws {
        if scene == .offline { throw MailStoreError.offline }
        mail.mailbox.settings = settings
    }

    public func erase(_ messages: Set<UUID>) async throws {
        if scene == .offline { throw MailStoreError.offline }
        mail.mailbox.remove(messages)
    }

    public func data(of attachment: UUID) async throws -> Data {
        guard let data = mail.attachments[attachment] else { throw MailStoreError.unavailable }
        return data
    }
}
