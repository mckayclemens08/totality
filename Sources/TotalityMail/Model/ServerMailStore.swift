import Foundation
import TotalityCore

/// One account's real mailbox: the server holds sealed files, and this device downloads each one once,
/// opens it with `MailKey`, and keeps it in the vault re-sealed with the content key. Marks and settings
/// live in the vault too, which syncs them. Nothing readable is held anywhere but in memory.
///
/// A mailbox's key can never be replaced, so the public key is published only once `canPublish` says
/// this device's key belongs to the signed-in account and has joined the key backup. A 409 means the
/// server holds another key, and it's remembered so it's never tried again in a loop.
public actor ServerMailStore: MailStore {
    private let account: String
    private let mailboxID: UUID
    private let key: MailKey
    private let vault: MailVault
    private let server: any MailServer
    private let canPublish: @Sendable () async -> Bool
    private let username: @Sendable () async -> String?
    private let now: @Sendable () -> Date

    /// What publishing answered for this store. `.alreadyThere` means the server's mailbox is the one
    /// mail was downloaded from, so what it no longer lists was deleted on purpose.
    private var publication: MailKeyPublication?
    private var hasConflict = false
    /// Which message each attachment came from, so its bytes are read back out of the vault when asked.
    private var attachmentSources: [UUID: UUID] = [:]

    /// `account` is the account's ID, which is also the server's name for its mailbox. It has to be the
    /// vault's account, or nothing would line up.
    public init(
        account: String, rootKey: ContentRootKey, vault: MailVault, server: any MailServer,
        canPublish: @escaping @Sendable () async -> Bool,
        username: @escaping @Sendable () async -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let mailboxID = UUID(uuidString: account), vault.account == account else { throw MailStoreError.noAccount }
        self.account = account
        self.mailboxID = mailboxID
        key = try MailKey(root: rootKey)
        self.vault = vault
        self.server = server
        self.canPublish = canPublish
        self.username = username
        self.now = now
    }

    // MARK: Opening

    public func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        if hasConflict { throw MailStoreError.keyConflict }
        guard await canPublish() else { throw MailStoreError.waitingForBackup }

        do {
            try await publishIfNeeded()
            let unkept = try await keepWhatWaits()
            let list = try await server.list()
            let downloaded = try await download(list, progress: progress)
            if publication == .alreadyThere { try await pruneDeletedElsewhere(listed: Set(list.messages.map(\.id)).union(unkept)) }
            var mailbox = try await stored()
            mailbox.isFull = list.isFull
            return MailOpening(mailbox: mailbox, isOffline: !downloaded)
        } catch MailServerError.keyConflict {
            hasConflict = true
            throw MailStoreError.keyConflict
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            // A sign-in token that can't refresh is almost always a missing network: the store is only
            // made for the account that's signed in. What's here still opens.
            return MailOpening(mailbox: try await stored(), isOffline: true)
        } catch is MailServerError {
            throw MailStoreError.unavailable
        }
    }

    private func publishIfNeeded() async throws {
        guard publication == nil else { return }
        publication = try await server.publish(publicKey: try key.publicKey())
    }

    /// Sent copies the server didn't take when they were sent go to it now. What still won't go stays
    /// on this device, marked, and is returned so nothing prunes it.
    private func keepWhatWaits() async throws -> Set<UUID> {
        var waiting = Set<UUID>()
        for id in try await vault.unkept() {
            guard let stored = try await vault.message(id), let raw = stored.raw else {
                try await vault.kept(id)
                continue
            }
            do {
                try await server.keep(id: id, sealed: try key.sealOwn(raw, mailbox: mailboxID, message: id))
                try await vault.kept(id)
            } catch is MailServerError {
                waiting.insert(id)
            }
        }
        return waiting
    }

    /// Only what isn't here yet, one at a time. False when the network went away partway, and what came
    /// before that is kept.
    private func download(_ list: MailServerList, progress: @Sendable (MailDownload) -> Void) async throws -> Bool {
        var missing: [MailServerEntry] = []
        for entry in list.messages {
            if try await !vault.hasMessage(entry.id) { missing.append(entry) }
        }
        guard !missing.isEmpty else { return true }
        progress(MailDownload(done: 0, total: missing.count))
        for (index, entry) in missing.enumerated() {
            try Task.checkCancellation()
            let sealed: Data
            do {
                sealed = try await server.message(entry.id)
            } catch let error as MailServerError where error == .offline || error == .signedOut {
                return false
            } catch MailServerError.unavailable {
                // Gone between the list and the fetch, or the server stumbled. The next open tries again.
                continue
            }
            // A seal that won't open is kept with no contents, so it shows as unreadable instead of
            // vanishing, and isn't fetched again and again.
            let opened = try? key.open(sealed, mailbox: mailboxID, message: entry.id)
            try await vault.keep(MailStoredMessage(id: entry.id, received: entry.received, raw: opened))
            progress(MailDownload(done: index + 1, total: missing.count))
        }
        return true
    }

    /// Another device deleted these for good: the server no longer lists them, and it's the same mailbox
    /// they came from. A mailbox the server had to make afresh proves nothing, so then all is kept.
    private func pruneDeletedElsewhere(listed: Set<UUID>) async throws {
        let gone = Set(try await vault.messages().map(\.id)).subtracting(listed)
        if !gone.isEmpty { try await vault.erase(gone) }
    }

    /// Everything the vault holds, read and with its marks and settings applied.
    private func stored() async throws -> Mailbox {
        let settings = try await vault.settings() ?? MailSettings()
        let marks = try await vault.marks()
        let me = await username()
        var sources: [UUID: UUID] = [:]
        var messages: [MailMessage] = []
        for stored in try await vault.messages() {
            var message = read(stored, me: me).message
            if let synced = marks[stored.id] {
                message.marks = synced
            } else if message.marks.folder == .inbox, settings.blockedSenders.contains(message.from.key) {
                // The server can't read a sender, so Block Sender is applied here, as mail arrives.
                message.marks.folder = .spam
            }
            for attachment in message.attachments { sources[attachment.id] = stored.id }
            messages.append(message)
        }
        attachmentSources = sources
        return Mailbox(
            address: me.map(MailDomain.address(for:)) ?? "", messages: messages, settings: settings, drafts: try await vault.drafts()
        )
    }

    /// What a kept message says, and what the path it took proves about it.
    ///
    /// - Mail from outside is as the parser reads it, proved or not by Cloudflare's checks.
    /// - Mail from another Totality account is sealed again inside, to this key, naming the sender the
    ///   server vouched for, this account, and the server's ID for it. It's proved only when its one
    ///   From address is that sender's, ignoring case and any `+tag`. Otherwise it claims to be from
    ///   someone else, and says who really sent it.
    /// - A Sent copy is this account's own, sealed by its own device.
    private func read(_ stored: MailStoredMessage, me: String?) -> ParsedMail {
        guard let raw = stored.raw else {
            return ParsedMail(message: .unreadable(id: stored.id, date: stored.received, marks: MailMarks(isUnread: true)), attachments: [:])
        }
        guard let envelope = MailParser.envelope(raw), envelope.from != nil || envelope.sent else {
            return MailParser.parse(raw, id: stored.id, now: stored.received)
        }
        let received = envelope.received ?? stored.received
        if let sender = envelope.from?.lowercased() {
            guard let me, let inner = try? key.openDirect(envelope.rest, from: sender, recipient: (envelope.to ?? me).lowercased(), message: stored.id) else {
                return ParsedMail(message: .unreadable(id: stored.id, date: received, marks: envelope.marks), attachments: [:])
            }
            let parsed = MailParser.parseMessage(inner, id: stored.id, received: received, marks: envelope.marks)
            guard !parsed.message.isUnreadable else { return parsed }
            let proved = parsed.fromLines == 1 && parsed.senders.count == 1 && parsed.senders[0].totalityName == sender
            let message = parsed.message.travelled(
                .betweenAccounts, proof: proved ? .proved : .unproved, sentBy: MailAddress(address: MailDomain.address(for: sender))
            )
            return ParsedMail(message: message, attachments: parsed.attachments, senders: parsed.senders, fromLines: parsed.fromLines)
        }
        let parsed = MailParser.parseMessage(envelope.rest, id: stored.id, received: received, marks: envelope.marks)
        guard !parsed.message.isUnreadable else { return parsed }
        let message = parsed.message
        // Until outside sending exists, everything sent goes between accounts. Once it does, a copy
        // that went to anyone outside says so.
        let everyone = message.to + message.cc + message.bcc
        let route: MailRoute = everyone.allSatisfy { $0.totalityName != nil } ? .betweenAccounts : .outside
        return ParsedMail(message: message.travelled(route, proof: .proved), attachments: parsed.attachments)
    }

    public func address() async -> String? {
        await username().map(MailDomain.address(for:))
    }

    // MARK: Changes

    public func save(_ marks: [UUID: MailMarks]) async throws {
        try await vault.save(marks, at: now())
    }

    public func save(_ settings: MailSettings) async throws {
        try await vault.save(settings, at: now())
    }

    /// From the server first, so a message can't come back on the next download. Offline, nothing is
    /// touched and the model keeps it waiting.
    public func erase(_ messages: Set<UUID>) async throws {
        guard !messages.isEmpty else { return }
        do {
            _ = try await server.delete(messages)
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            throw MailStoreError.offline
        } catch {
            throw MailStoreError.unavailable
        }
        try await vault.erase(messages)
        for (attachment, source) in attachmentSources where messages.contains(source) { attachmentSources[attachment] = nil }
    }

    public func data(of attachment: UUID) async throws -> Data {
        guard let source = attachmentSources[attachment], let stored = try await vault.message(source),
              let data = read(stored, me: await username()).attachments[attachment]
        else { throw MailStoreError.unavailable }
        return data
    }

    // MARK: Drafts

    public func save(_ draft: MailDraft) async throws {
        try await vault.save(draft, at: now())
    }

    public func discard(draft: UUID) async throws {
        try await vault.deleteDraft(draft)
    }

    // MARK: Sending

    /// Sends once, now. Only ever called from a press, and the screens' few seconds of Undo happen
    /// before this, so nothing here waits.
    ///
    /// Each Totality recipient gets their own copy, sealed on this device to their key, naming this
    /// account as the sender and them as the recipient, under a fresh ID. Anyone else is reported as
    /// not sent yet. When anyone got it, a Sent copy, Bcc included, is sealed to this account's own key
    /// and kept on the server and here. The draft goes once everyone has it; otherwise it stays, with
    /// only the people who didn't.
    public func send(_ draft: MailDraft) async throws -> MailSendResult {
        try draft.checkRecipients()
        if hasConflict { throw MailStoreError.keyConflict }
        guard await canPublish() else { throw MailStoreError.waitingForBackup }
        guard let me = await username()?.lowercased() else { throw MailSendError.noAddress }
        let messageID = UUID()
        let date = now()
        let raw = MailWriter.write(draft, from: me, message: messageID, date: date)
        guard raw.count <= MailDraft.maxBytes else { throw MailSendError.tooBig }
        do {
            // The Sent copy needs this account's own mailbox to exist.
            try await publishIfNeeded()
        } catch MailServerError.keyConflict {
            hasConflict = true
            throw MailStoreError.keyConflict
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            throw MailStoreError.offline
        } catch is MailServerError {
            throw MailStoreError.unavailable
        }

        var outcomes: [MailSendResult.Recipient] = []
        for address in draft.recipients {
            outcomes.append(MailSendResult.Recipient(address: address, outcome: await deliver(raw, to: address, from: me)))
        }

        let delivered = Set(outcomes.filter { $0.outcome == .delivered }.map(\.address.key))
        var sent: UUID?
        var keptCopy = false
        if !delivered.isEmpty {
            let id = UUID()
            let copy = MailWriter.write(draft, from: me, message: messageID, date: date, keepingBcc: true)
            let facts = #"{"version":1,"received":"\#(Self.iso(date))","spam":null,"sent":true}"#
            let opened = Data(facts.utf8) + Data([0x0A]) + copy
            let stored = MailStoredMessage(id: id, received: date, raw: opened)
            do {
                try await server.keep(id: id, sealed: try key.sealOwn(opened, mailbox: mailboxID, message: id))
                try await vault.keep(stored)
                keptCopy = true
            } catch is MailServerError {
                // Kept here and marked, so the next open tries the server again instead of pruning it.
                try await vault.keepUnkept(stored)
                keptCopy = false
            }
            sent = id
        }

        var remaining: MailDraft?
        if delivered.count == outcomes.count {
            try await vault.deleteDraft(draft.id)
        } else {
            var rest = draft
            rest.to.removeAll { delivered.contains($0.key) }
            rest.cc.removeAll { delivered.contains($0.key) }
            rest.bcc.removeAll { delivered.contains($0.key) }
            try await vault.save(rest, at: now())
            remaining = rest
        }
        return MailSendResult(recipients: outcomes, sent: sent, keptCopy: keptCopy, remaining: remaining)
    }

    private func deliver(_ raw: Data, to address: MailAddress, from me: String) async -> MailSendResult.Outcome {
        guard address.isWellFormed else { return .notAnAddress }
        guard let name = address.totalityName else { return .outsideNotYet }
        do {
            guard let recipientKey = try await server.recipientKey(name) else { return .noSuchAddress }
            let id = UUID()
            let sealed = try MailKey.sealDirect(raw, to: recipientKey, from: me, recipient: name, message: id)
            switch try await server.deliver(to: name, id: id, sealed: sealed) {
            case .delivered: return .delivered
            case .noSuchAddress: return .noSuchAddress
            case .tooBig: return .tooBig
            case .recipientFull: return .recipientFull
            }
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            return .offline
        } catch {
            return .failed
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
