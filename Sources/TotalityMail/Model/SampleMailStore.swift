import Foundation

/// Stands in for the real mailbox in previews and tests. Nothing here is the person's, and the screens
/// say so through `MailSampleNote`. The app itself uses `ServerMailStore`.
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

    public func save(_ draft: MailDraft) async throws {
        mail.mailbox.drafts.removeAll { $0.id == draft.id }
        mail.mailbox.drafts.insert(draft, at: 0)
    }

    public func discard(draft: UUID) async throws {
        mail.mailbox.drafts.removeAll { $0.id == draft }
    }

    /// Totality addresses get it and anyone else waits for outside sending, as with the real store.
    /// The Sent copy is made here from the draft, with nothing written or sealed.
    public func send(_ draft: MailDraft) async throws -> MailSendResult {
        try draft.checkRecipients()
        if scene == .offline { throw MailStoreError.offline }
        let outcomes = draft.recipients.map { address in
            MailSendResult.Recipient(
                address: address,
                outcome: !address.isWellFormed ? .notAnAddress : address.totalityName == nil ? .outsideNotYet : .delivered
            )
        }
        let delivered = Set(outcomes.filter { $0.outcome == .delivered }.map(\.address.key))
        var sent: UUID?
        if !delivered.isEmpty {
            let copy = MailMessage(
                conversationID: UUID(), from: SampleMail.me, to: draft.to, cc: draft.cc, subject: draft.subject, date: mail.now,
                body: .plain(draft.body), route: .betweenAccounts, marks: MailMarks(folder: .sent), bcc: draft.bcc
            )
            mail.mailbox.messages.append(copy)
            sent = copy.id
        }
        mail.mailbox.drafts.removeAll { $0.id == draft.id }
        var remaining: MailDraft?
        if delivered.count < outcomes.count {
            var rest = draft
            rest.to.removeAll { delivered.contains($0.key) }
            rest.cc.removeAll { delivered.contains($0.key) }
            rest.bcc.removeAll { delivered.contains($0.key) }
            mail.mailbox.drafts.insert(rest, at: 0)
            remaining = rest
        }
        return MailSendResult(recipients: outcomes, sent: sent, keptCopy: sent != nil, remaining: remaining)
    }

    public func data(of attachment: UUID) async throws -> Data {
        guard let data = mail.attachments[attachment] else { throw MailStoreError.unavailable }
        return data
    }
}
