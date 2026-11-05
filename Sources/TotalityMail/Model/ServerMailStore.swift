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
            let list = try await server.list()
            let downloaded = try await download(list, progress: progress)
            if publication == .alreadyThere { try await pruneDeletedElsewhere(listed: Set(list.messages.map(\.id))) }
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
        var sources: [UUID: UUID] = [:]
        var messages: [MailMessage] = []
        for stored in try await vault.messages() {
            var message: MailMessage
            if let raw = stored.raw {
                message = MailParser.parse(raw, id: stored.id, now: stored.received).message
            } else {
                message = .unreadable(id: stored.id, date: stored.received, marks: MailMarks(isUnread: true))
            }
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
        return Mailbox(address: await address() ?? "", messages: messages, settings: settings)
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
        guard let source = attachmentSources[attachment],
              let stored = try await vault.message(source), let raw = stored.raw,
              let data = MailParser.parse(raw, id: source, now: stored.received).attachments[attachment]
        else { throw MailStoreError.unavailable }
        return data
    }
}
