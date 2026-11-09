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
    private let sentKey: MailSentKey
    private let vault: MailVault
    private let server: any MailServer
    private let canPublish: @Sendable () async -> Bool
    private let username: @Sendable () async -> String?
    private let now: @Sendable () -> Date
    private let outsideCheck: OutsideSignInCheck
    /// Nil when this build has no Google sign-in, so Gmail can't be added.
    private let google: GoogleOAuth?
    /// How long the key backup check may take before what's here opens without it.
    private let backupCheckLimit: Duration

    /// What publishing answered for this store. `.alreadyThere` means the server's mailbox is the one
    /// mail was downloaded from, so what it no longer lists was deleted on purpose.
    private var publication: MailKeyPublication?
    private var hasConflict = false
    /// Which message each attachment came from, so its bytes are read back out of the vault when asked.
    private var attachmentSources: [UUID: UUID] = [:]
    /// Messages downloaded from outside accounts, which live apart from Totality mail.
    private var fetchedIDs = Set<UUID>()
    /// Downloaded mail already read and parsed this session, by the ID it shows under.
    private var fetchedCache: [UUID: FetchedEntry] = [:]
    /// The last change sync with outside accounts, so the next waits for it instead of interleaving.
    private var outsideSync: Task<Void, Never>?
    /// Whether this store has offered its Gmail sign-ins to the shared Google connections yet.
    private var hasSharedGoogle = false

    /// `account` is the account's ID, which is also the server's name for its mailbox. It has to be the
    /// vault's account, or nothing would line up.
    public init(
        account: String, rootKey: ContentRootKey, vault: MailVault, server: any MailServer,
        canPublish: @escaping @Sendable () async -> Bool,
        username: @escaping @Sendable () async -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        outsideCheck: OutsideSignInCheck = OutsideSignInCheck(),
        google: GoogleOAuth? = nil,
        backupCheckLimit: Duration = .seconds(10)
    ) throws {
        guard let mailboxID = UUID(uuidString: account), vault.account == account else { throw MailStoreError.noAccount }
        self.account = account
        self.mailboxID = mailboxID
        key = try MailKey(root: rootKey)
        sentKey = MailSentKey(root: rootKey)
        self.vault = vault
        self.server = server
        self.canPublish = canPublish
        self.username = username
        self.now = now
        self.outsideCheck = outsideCheck
        self.google = google
        self.backupCheckLimit = backupCheckLimit
    }

    // MARK: Opening

    public func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        if hasConflict { throw MailStoreError.keyConflict }
        var clock = MailClock("open")
        defer { clock.done() }
        let publicKey = try key.publicKey()
        // A key this device has seen published is already the mailbox's for good, so the backup check,
        // which only guards publishing, isn't waited on again.
        let wasPublished = await vault.isPublished(publicKey)
        if !wasPublished {
            let canPublish = canPublish
            let allowed = await mailAnswer(within: backupCheckLimit) { await canPublish() }
            clock.mark("backup check")
            switch allowed {
            case true?: break
            case false?: throw MailStoreError.waitingForBackup
            case nil: return MailOpening(mailbox: try await stored(), isOffline: true)
            }
        }

        do {
            if !wasPublished {
                try await publishIfNeeded(publicKey)
                clock.mark("publish")
            }
            let unkept = try await keepWhatWaits()
            let list: MailServerList
            do {
                list = try await server.list()
            } catch MailServerError.unavailable where wasPublished {
                // Maybe the server lost the mailbox: the next open publishes again before listing.
                try? await vault.forgetPublished()
                throw MailServerError.unavailable
            }
            clock.mark("list")
            let downloaded = try await download(list, progress: progress)
            clock.mark("download")
            // Pruning needs the server to say it's the same mailbox, so the publish still happens, after
            // the mail is in.
            if wasPublished {
                try await publishIfNeeded(publicKey)
                clock.mark("publish")
            }
            if publication == .alreadyThere { try await pruneDeletedElsewhere(listed: Set(list.messages.map(\.id)).union(unkept)) }
            var mailbox = try await stored()
            mailbox.isFull = list.isFull
            clock.mark("read stored mail")
            return MailOpening(mailbox: mailbox, isOffline: !downloaded)
        } catch MailServerError.keyConflict {
            hasConflict = true
            try? await vault.forgetPublished()
            throw MailStoreError.keyConflict
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            // A sign-in token that can't refresh is almost always a missing network: the store is only
            // made for the account that's signed in. What's here still opens.
            return MailOpening(mailbox: try await stored(), isOffline: true)
        } catch is MailServerError {
            throw MailStoreError.unavailable
        }
    }

    public func cached() async -> Mailbox? {
        var clock = MailClock("cached")
        defer { clock.done() }
        guard !hasConflict, let mailbox = try? await stored(), !mailbox.messages.isEmpty else { return nil }
        clock.mark("read stored mail")
        return mailbox
    }

    private func publishIfNeeded(_ publicKey: Data) async throws {
        guard publication == nil else { return }
        publication = try await server.publish(publicKey: publicKey)
        try? await vault.notePublished(publicKey)
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
                try await server.keep(id: id, sealed: try sentKey.seal(raw, account: mailboxID, message: id))
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
            // vanishing, and isn't fetched again and again. A Sent copy has its own seal, which only
            // this person's devices can make; everything else is in the seal anyone can make.
            let stored: MailStoredMessage
            if sealed.first == MailSentKey.version {
                let opened = try? sentKey.open(sealed, account: mailboxID, message: entry.id)
                stored = MailStoredMessage(id: entry.id, received: entry.received, raw: opened, ownCopy: true)
            } else {
                let opened = try? key.open(sealed, mailbox: mailboxID, message: entry.id)
                let check: SenderCheck
                do {
                    check = try await checkSender(opened, message: entry.id)
                } catch let error as MailServerError where error == .offline || error == .signedOut {
                    return false
                } catch is MailServerError {
                    // The sender's key couldn't be fetched just now, and nothing was pinned to fall
                    // back on. The next open tries again.
                    continue
                }
                stored = MailStoredMessage(
                    id: entry.id, received: entry.received, raw: opened, senderKey: check.key, senderKeyChanged: check.changed
                )
            }
            try await vault.keep(stored)
            progress(MailDownload(done: index + 1, total: missing.count))
        }
        return true
    }

    private struct SenderCheck {
        var key: Data?
        var changed = false
    }

    /// For mail from another Totality account: the key its inner seal opens with, and whether that's
    /// the key this account pinned for the sender. The inner seal is HPKE in auth mode, so it opens only
    /// with the public key of whoever sealed it, and the server can't make one for anyone else's key.
    ///
    /// - With a pin, the pin is tried first. If the server now gives a different key, or only that
    ///   different key opens it, the message isn't proved and says the key changed.
    /// - A name pinned to two different keys, by two devices or two answers from the server, is
    ///   disputed, and nothing from it is proved again.
    /// - Without a pin, the server's key is pinned once it opens the message. The pin goes through the
    ///   vault's one serialised path, so if another task pinned a different key meanwhile, that one
    ///   stays and this message isn't proved.
    /// - Nothing opening means no key is kept, so the message shows as unreadable.
    ///
    /// Throws only when the key can't be fetched and there's no pin to use instead.
    private func checkSender(_ opened: Data?, message: UUID) async throws -> SenderCheck {
        guard let opened, let envelope = MailParser.envelope(opened, ownCopy: false), let sender = envelope.from?.lowercased(),
              let me = await username()?.lowercased()
        else { return SenderCheck() }
        let recipient = (envelope.to ?? me).lowercased()
        func opens(_ senderKey: Data) -> Bool {
            (try? key.openDirect(envelope.rest, senderKey: senderKey, from: sender, recipient: recipient, message: message)) != nil
        }
        let pins = try await vault.pins()
        let pinned = pins.key(for: sender)
        let disputed = pins.isDisputed(sender)
        let fetched: Data?
        do {
            fetched = try await server.recipientKey(sender)
        } catch let error as MailServerError where pinned != nil && error != .offline && error != .signedOut {
            fetched = nil
        }
        if let pinned {
            if opens(pinned) { return SenderCheck(key: pinned, changed: disputed || (fetched.map { $0 != pinned } ?? false)) }
            if let fetched, fetched != pinned, opens(fetched) { return SenderCheck(key: fetched, changed: true) }
            return SenderCheck(changed: true)
        }
        guard let fetched, opens(fetched) else { return SenderCheck() }
        let after = try await vault.pin(sender, key: fetched, at: now())
        return SenderCheck(key: fetched, changed: after.key(for: sender) != fetched || after.isDisputed(sender))
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
        let pins = try await vault.pins()
        var sources: [UUID: UUID] = [:]
        var messages: [MailMessage] = []
        for stored in try await vault.messages() {
            var message = read(stored, me: me, pins: pins).message
            if let synced = marks[stored.id] {
                message.marks = synced
            } else if message.marks.folder == .inbox, settings.blockedSenders.contains(message.from.key) {
                // The server can't read a sender, so Block Sender is applied here, as mail arrives.
                message.marks.folder = .spam
            }
            for attachment in message.attachments { sources[attachment.id] = stored.id }
            messages.append(message)
        }
        var fetched = Set<UUID>()
        let outside = Dictionary(try await vault.outsideAccounts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var places: [UUID: OutsideAccountPlaces] = [:]
        for account in outside.keys { places[account] = try await vault.places(of: account) }
        for (id, entry) in try await fetchedEntries(outside) {
            let stored = entry.info
            guard let account = outside[stored.outside] else { continue }
            var message = entry.message
            message.outsideAccount = OutsideAccountLabel(id: account.id, provider: account.provider, address: account.address)
            if account.provider == .gmail {
                let known = places[account.id]?.labels(of: stored.providerID, received: stored.received)
                let labels = known ?? Set(stored.labels)
                message.outsideLabels = labels.subtracting(["INBOX", "UNREAD", "STARRED", "IMPORTANT", "DRAFT", "CATEGORY_PERSONAL"])
                // Gmail archives by taking INBOX away, so mail it holds without INBOX is archived here.
                if known != nil || !stored.labels.isEmpty, !labels.contains("INBOX") { message.marks.folder = .archive }
            } else {
                // iCloud: the person's own folders it's in, by its Message-ID.
                if let known = places[account.id], let messageID = message.messageID {
                    message.outsideLabels = Set(known.membership[messageID] ?? [])
                }
                // Downloaded from a folder other than the Inbox, so it starts out archived.
                if !stored.labels.isEmpty, !stored.labels.contains("SENT") { message.marks.folder = .archive }
            }
            if stored.labels.contains("SENT") {
                // Sent from here through the provider: this device's own copy of it.
                message.outsideLabels.insert("SENT")
                message.marks.folder = .sent
            }
            if let synced = marks[id] {
                message.marks = synced
            } else if message.marks.folder == .inbox, settings.blockedSenders.contains(message.from.key) {
                message.marks.folder = .spam
            }
            for attachment in message.attachments { sources[attachment.id] = id }
            fetched.insert(id)
            messages.append(message)
        }
        fetchedIDs = fetched
        attachmentSources = sources
        var mailbox = Mailbox(
            address: me.map(MailDomain.address(for:)) ?? "", messages: messages, settings: settings, drafts: try await vault.drafts()
        )
        mailbox.outsideAccounts = outside.values.sorted { $0.address < $1.address }
            .map { OutsideAccountLabel(id: $0.id, provider: $0.provider, address: $0.address) }
        mailbox.senders = outside.values.filter(\.canSend).sorted { $0.address < $1.address }
            .map { OutsideAccountLabel(id: $0.id, provider: $0.provider, address: $0.address) }
        mailbox.outsidePlaces = outside.values.sorted { $0.address < $1.address }.compactMap { account in
            guard let known = places[account.id] else { return nil }
            let label = OutsideAccountLabel(id: account.id, provider: account.provider, address: account.address)
            let used = Set(messages.filter { $0.outsideAccount?.id == account.id }.flatMap(\.outsideLabels))
            // A tab shows once it holds something, since Gmail hides the ones turned off. Labels always show.
            let shown = known.labels.filter { !$0.isTab || used.contains($0.id) }
            return shown.isEmpty ? nil : OutsidePlaces(account: label, labels: shown)
        }
        return mailbox
    }

    /// What a kept message says, and what the path it took proves about it.
    ///
    /// - Mail from outside is as the parser reads it, proved or not by Cloudflare's checks.
    /// - Mail from another Totality account is sealed again inside, to this key, naming the sender the
    ///   server vouched for, this account, and the server's ID for it. It's proved only when its one
    ///   From address is that sender's, ignoring case and any `+tag`. Otherwise it claims to be from
    ///   someone else, and says who really sent it.
    /// - A Sent copy is this account's own, sealed by its own device with a key only its devices hold.
    ///   Nothing in the standard seal is ever taken for one, since anyone can seal to a public key.
    ///
    /// The proof is worked out each time it's shown, against the pins as they are now. Pins that arrive
    /// by sync after a message was kept can show its sender's key was never the pinned one, or that the
    /// name is disputed, and then it stops being proved.
    private func read(_ stored: MailStoredMessage, me: String?, pins: MailPins) -> ParsedMail {
        guard let raw = stored.raw else {
            return ParsedMail(message: .unreadable(id: stored.id, date: stored.received, marks: MailMarks(isUnread: true)), attachments: [:])
        }
        guard let envelope = MailParser.envelope(raw, ownCopy: stored.ownCopy), envelope.from != nil || envelope.sent else {
            return MailParser.parse(raw, id: stored.id, now: stored.received, ownCopy: stored.ownCopy)
        }
        let received = envelope.received ?? stored.received
        if let sender = envelope.from?.lowercased() {
            guard let me, let senderKey = stored.senderKey,
                  let inner = try? key.openDirect(
                      envelope.rest, senderKey: senderKey, from: sender, recipient: (envelope.to ?? me).lowercased(), message: stored.id
                  )
            else {
                return ParsedMail(message: .unreadable(id: stored.id, date: received, marks: envelope.marks), attachments: [:])
            }
            let parsed = MailParser.parseMessage(inner, id: stored.id, received: received, marks: envelope.marks)
            guard !parsed.message.isUnreadable else { return parsed }
            let keyChanged = stored.senderKeyChanged || pins.isDisputed(sender) || pins.key(for: sender) != senderKey
            let proved = !keyChanged && parsed.fromLines == 1 && parsed.senders.count == 1
                && parsed.senders[0].totalityName == sender
            let message = parsed.message.travelled(
                .betweenAccounts, proof: proved ? .proved : .unproved, sentBy: MailAddress(address: MailDomain.address(for: sender)),
                senderKeyChanged: keyChanged
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

    /// One downloaded message as it shows, read once and kept in memory: the store only ever adds or
    /// removes these, so each is decrypted and parsed only the first time it's needed.
    struct FetchedEntry: Sendable {
        /// The download as stored, without its raw bytes, which the parsed message already holds.
        let info: OutsideFetchedMessage
        let messageID: String?
        let message: MailMessage
    }

    /// Every downloaded message from these accounts. Only files not read before are opened.
    private func fetchedEntries(_ accounts: [UUID: OutsideAccount]) async throws -> [UUID: FetchedEntry] {
        let ids = Set(try await vault.fetchedIDs())
        fetchedCache = fetchedCache.filter { ids.contains($0.key) }
        let unread = ids.filter { fetchedCache[$0] == nil }
        if !unread.isEmpty {
            let providers = Dictionary(try await vault.outsideAccounts().map { ($0.id, $0.provider) }, uniquingKeysWith: { first, _ in first })
            for (id, stored) in try await vault.fetched(Array(unread)) {
                guard let provider = providers[stored.outside] else { continue }
                fetchedCache[id] = FetchedEntry(
                    info: OutsideFetchedMessage(
                        outside: stored.outside, providerID: stored.providerID, received: stored.received, raw: Data(),
                        isUnread: stored.isUnread, isStarred: stored.isStarred, labels: stored.labels
                    ),
                    messageID: OutsideFolders.messageID(stored.raw),
                    message: readFetched(stored, id: id, provider: provider).message
                )
            }
        }
        return fetchedCache.filter { accounts[$0.value.info.outside] != nil }
    }

    /// Downloaded mail is read as the provider gave it. Only the provider's own checks at the top can
    /// prove its sender.
    private func readFetched(_ stored: OutsideFetchedMessage, id: UUID, provider: OutsideProvider) -> ParsedMail {
        if stored.labels.contains("SENT") {
            // Written and sent on this device, so there's nothing to prove about who sent it.
            let parsed = MailParser.parseMessage(stored.raw, id: id, received: stored.received, marks: MailMarks(folder: .sent))
            guard !parsed.message.isUnreadable else { return parsed }
            return ParsedMail(message: parsed.message.travelled(.outside, proof: .proved), attachments: parsed.attachments)
        }
        return MailParser.parseMessage(
            stored.raw, id: id, received: stored.received, marks: MailMarks(isUnread: stored.isUnread, isStarred: stored.isStarred),
            checkedBy: OutsideReading.checkedBy(provider)
        )
    }

    public func address() async -> String? {
        await username().map(MailDomain.address(for:))
    }

    // MARK: Outside accounts' mail

    public func downloadOutside(progress: @escaping @Sendable (OutsideDownload) -> Void) async -> OutsideDownloadResult? {
        guard let accounts = try? await vault.outsideAccounts(), !accounts.isEmpty else { return nil }
        let reader = OutsideReader(maker: outsideCheck.maker, google: google)
        let since = OutsideReading.since(now())
        var problems: [String] = []
        var views: [UUID: OutsideProviderView] = [:]
        for account in accounts {
            guard !Task.isCancelled else { break }
            guard let credential = try? await vault.credential(for: account.id) else {
                problems.append("\(account.address): \(OutsideWording.problem(.notFound, provider: account.provider))")
                continue
            }
            let vault = vault, counter = OutsideCounter(), view = OutsideViewBox()
            // What the last open saw, so this one asks only for what's changed since.
            let previous = try? await vault.places(of: account.id)
            let isFirst = previous == nil
            // Each Message-ID already here from this account, so mail moved between iCloud's folders isn't kept twice.
            let known: Set<String> = account.provider == .gmail ? [] : Set(
                ((try? await fetchedEntries([account.id: account])) ?? [:]).values.filter { $0.info.outside == account.id }.compactMap(\.messageID)
            )
            defer { if let seen = view.value { views[account.id] = seen } }
            do {
                try await reader.download(
                    account, credential: credential, since: since,
                    have: { try await vault.hasFetched(account.id, providerID: $0) },
                    keep: { message in
                        try await vault.keepFetched(message)
                        // Only an account's first download says how it's going. After that it's quiet.
                        let done = counter.next()
                        if isFirst { progress(OutsideDownload(address: account.address, done: done)) }
                    },
                    seen: { seen in
                        view.value = seen
                        switch seen {
                        case .gmail(let places): try await vault.keepPlaces(places)
                        case .imap(let folders): try await vault.keepPlaces(folders.places(of: account.id))
                        }
                    },
                    haveMessage: { known.contains($0) },
                    previous: previous, now: now()
                )
            } catch is CancellationError {
                break
            } catch {
                let problem = (error as? OutsideAccountError) ?? .problem(OutsideMailProblem.from(error))
                guard problem != .cancelled else { continue }
                problems.append("\(account.address): \(OutsideWording.problem(problem, provider: account.provider))")
            }
        }
        // Changes made at each provider come in, and changes made here go out, before it's shown.
        if !Task.isCancelled { await syncOutside(views) }
        guard let mailbox = try? await stored() else { return nil }
        return OutsideDownloadResult(mailbox: mailbox, problems: problems)
    }

    // MARK: Changes

    public func save(_ marks: [UUID: MailMarks]) async throws {
        try await vault.save(marks, at: now())
        if !fetchedIDs.isDisjoint(with: marks.keys) { await syncOutside([:]) }
    }

    public func searchOutside(_ query: String) async -> OutsideDownloadResult? {
        guard let words = OutsideSearch.words(query), let accounts = try? await vault.outsideAccounts(), !accounts.isEmpty else { return nil }
        let reader = OutsideReader(maker: outsideCheck.maker, google: google)
        var problems: [String] = []
        for account in accounts {
            guard !Task.isCancelled else { break }
            guard let credential = try? await vault.credential(for: account.id) else { continue }
            let vault = vault
            do {
                try await reader.search(
                    words, account: account, credential: credential,
                    have: { try await vault.hasFetched(account.id, providerID: $0) },
                    keep: { try await vault.keepFetched($0) }
                )
            } catch is CancellationError {
                break
            } catch {
                let problem = (error as? OutsideAccountError) ?? .problem(OutsideMailProblem.from(error))
                guard problem != .cancelled else { continue }
                problems.append("\(account.address): \(OutsideWording.problem(problem, provider: account.provider))")
            }
        }
        guard let mailbox = try? await stored() else { return nil }
        return OutsideDownloadResult(mailbox: mailbox, problems: problems)
    }

    // MARK: Changes to outside accounts' mail

    /// One sync at a time: each waits for the one before.
    private func syncOutside(_ views: [UUID: OutsideProviderView]) async {
        let previous = outsideSync
        let task = Task { await previous?.value; await self.syncingOutside(views) }
        outsideSync = task
        await task.value
    }

    /// For each outside account: what changed at the provider comes into Totality's marks, and what
    /// changed in Totality goes to the provider. Best effort: anything that doesn't go waits for the next try.
    private func syncingOutside(_ views: [UUID: OutsideProviderView]) async {
        guard let accounts = try? await vault.outsideAccounts(), let marks = try? await vault.marks(),
              let fetched = try? await fetchedEntries(Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        else { return }
        let writer = OutsideWriter(maker: outsideCheck.maker, google: google)
        var pulls: [UUID: MailMarks] = [:]
        for account in accounts {
            guard !Task.isCancelled else { break }
            var record = (try? await vault.remote(of: account.id)) ?? OutsideRemoteRecord(outside: account.id)
            // Already in the provider's Trash: nothing left to do for it.
            record.erased = record.erased.filter { $0.value.place != .trash }
            let view = views[account.id]
            var changes: [OutsideWriter.Change] = []
            var states: [String: OutsideRemoteState] = [:]
            for (id, entry) in fetched where entry.info.outside == account.id {
                let stored = entry.info
                let base = record.states[stored.providerID] ?? OutsideRemoteState(downloaded: stored)
                let mine = marks[id].map { OutsideRemoteState($0, location: base.location) }
                let seen: OutsideSeen = switch view {
                case .gmail(let places): places.seen(stored.providerID, received: stored.received)
                case .imap(let inbox):
                    inbox.seen(
                        providerID: stored.providerID, location: base.location, received: stored.received,
                        messageID: entry.messageID
                    )
                case nil: .unknown
                }
                var outcome = OutsideReconcile.outcome(base: base, mine: mine, seen: seen)
                if let moved = seen.location {
                    // Moved at iCloud: followed to its new folder, or lost when it went somewhere not looked in.
                    outcome.agreed.location = moved
                    outcome.agreedIfPushFails.location = moved
                    if moved.mailbox == "INBOX" { try? await vault.noteFetchedAlias(account.id, providerID: moved.providerID) }
                }
                if let pull = outcome.pull {
                    let shown = marks[id] ?? MailMarks(folder: Self.folder(base.place), isUnread: base.isUnread, isStarred: base.isStarred)
                    pulls[id] = OutsideReconcile.marks(shown, after: pull, now: now())
                }
                if outcome.push != nil {
                    changes.append(.init(providerID: stored.providerID, from: outcome.agreedIfPushFails, to: outcome.agreed))
                }
                states[stored.providerID] = outcome.agreedIfPushFails
            }
            // Deleted here: moved to the provider's Trash, never deleted for good there.
            for (providerID, state) in record.erased {
                var trashed = state
                trashed.place = .trash
                changes.append(.init(providerID: providerID, from: state, to: trashed))
            }
            if !changes.isEmpty, let credential = try? await vault.credential(for: account.id) {
                for (providerID, outcome) in await writer.push(account, credential: credential, changes: changes) {
                    switch outcome {
                    case .done(let after):
                        if record.erased[providerID] != nil { record.erased[providerID] = nil; continue }
                        states[providerID] = after
                        if let moved = after.location, moved != .lost {
                            try? await vault.noteFetchedAlias(account.id, providerID: moved.providerID)
                        }
                    case .lost:
                        if record.erased[providerID] != nil { record.erased[providerID] = nil; continue }
                        // Nothing changed at iCloud, so the agreement stays as it was. Once it's found again by
                        // its Message-ID, Totality's change goes through.
                        if var kept = changes.first(where: { $0.providerID == providerID })?.from { kept.location = .lost; states[providerID] = kept }
                    }
                }
            }
            record.states = states
            try? await vault.keepRemote(record)
        }
        if !pulls.isEmpty { try? await vault.save(pulls, at: now()) }
    }

    private static func folder(_ place: OutsidePlace) -> MailFolder {
        switch place {
        case .inbox: .inbox
        case .archive: .archive
        case .spam: .spam
        case .trash: .trash
        }
    }

    /// Pins aren't settings, so the screens' copy can't touch them.
    public func save(_ settings: MailSettings) async throws {
        try await vault.save(settings, at: now())
    }

    /// From the server first, so a message can't come back on the next download. Offline, nothing is
    /// touched and the model keeps it waiting.
    public func erase(_ messages: Set<UUID>) async throws {
        // Downloaded mail goes from this device, and to the provider's Trash, where the provider deletes
        // it in its own time. Nothing is deleted for good at the provider.
        let fetched = messages.intersection(fetchedIDs)
        if !fetched.isEmpty {
            await noteErased(fetched)
            try await vault.eraseFetched(fetched)
            try await vault.erase(fetched)
            fetchedIDs.subtract(fetched)
            await syncOutside([:])
        }
        let messages = messages.subtracting(fetched)
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
        if let source = attachmentSources[attachment], fetchedIDs.contains(source) {
            guard let stored = try await vault.fetchedMessage(source),
                  let account = try await vault.outsideAccounts().first(where: { $0.id == stored.outside }),
                  let data = readFetched(stored, id: source, provider: account.provider).attachments[attachment]
            else { throw MailStoreError.unavailable }
            return data
        }
        guard let source = attachmentSources[attachment], let stored = try await vault.message(source),
              let data = read(stored, me: await username(), pins: try await vault.pins()).attachments[attachment]
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
        if let from = draft.from { return try await send(draft, through: from) }
        if hasConflict { throw MailStoreError.keyConflict }
        guard await canPublish() else { throw MailStoreError.waitingForBackup }
        guard let me = await username()?.lowercased() else { throw MailSendError.noAddress }
        let messageID = UUID()
        let date = now()
        let raw = MailWriter.write(draft, from: me, message: messageID, date: date)
        guard raw.count <= MailDraft.maxBytes else { throw MailSendError.tooBig }
        do {
            // The Sent copy needs this account's own mailbox to exist.
            try await publishIfNeeded(try key.publicKey())
        } catch MailServerError.keyConflict {
            hasConflict = true
            throw MailStoreError.keyConflict
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            throw MailStoreError.offline
        } catch is MailServerError {
            throw MailStoreError.unavailable
        }

        var outcomes: [MailSendResult.Recipient] = []
        let outside = draft.recipients.filter { $0.isWellFormed && $0.totalityName == nil }
        let outsideOutcome = outside.isEmpty ? nil : await sendOutside(draft, message: messageID)
        for address in draft.recipients {
            let outcome = if let outsideOutcome, address.isWellFormed, address.totalityName == nil {
                outsideOutcome
            } else {
                await deliver(raw, to: address, from: me)
            }
            outcomes.append(MailSendResult.Recipient(address: address, outcome: outcome))
        }

        let delivered = Set(outcomes.filter(\.outcome.left).map(\.address.key))
        var sent: UUID?
        var keptCopy = false
        if !delivered.isEmpty {
            let id = UUID()
            let copy = MailWriter.write(draft, from: me, message: messageID, date: date, keepingBcc: true)
            let facts = #"{"version":1,"received":"\#(Self.iso(date))","spam":null,"sent":true}"#
            let opened = Data(facts.utf8) + Data([0x0A]) + copy
            let stored = MailStoredMessage(id: id, received: date, raw: opened, ownCopy: true)
            do {
                try await server.keep(id: id, sealed: try sentKey.seal(opened, account: mailboxID, message: id))
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

    /// From an outside account: one ordinary message to everyone, Totality addresses included, through
    /// that provider. Nothing goes through Totality's server. The Sent copy is the provider's, and this
    /// device keeps its own sealed copy of it, labelled as sent through the provider.
    private func send(_ draft: MailDraft, through id: UUID) async throws -> MailSendResult {
        guard let account = try await vault.outsideAccounts().first(where: { $0.id == id }), account.canSend,
              let credential = try await vault.credential(for: id) else { throw MailSendError.cannotSendFrom }
        if case .google(let grant) = credential, !grant.canSend { throw MailSendError.cannotSendFrom }
        let messageID = UUID(), date = now()
        let withBcc = MailWriter.write(draft, fromAddress: account.address, message: messageID, date: date, keepingBcc: true)
        guard withBcc.count <= MailDraft.maxBytes else { throw MailSendError.tooBig }
        let recipients = draft.recipients.filter(\.isWellFormed)
        let sender = OutsideSender(maker: outsideCheck.maker, google: google)
        let result = await sender.send(account, credential: credential, raw: withBcc, sentCopy: withBcc, recipients: recipients.map(\.address))
        var outcomes: [MailSendResult.Recipient] = []
        for address in draft.recipients {
            let outcome = address.isWellFormed ? result.outcomes[address.address.lowercased()] ?? .failed : .notAnAddress
            outcomes.append(MailSendResult.Recipient(address: address, outcome: outcome))
        }
        if outcomes.allSatisfy({ $0.outcome == .offline }) { throw MailStoreError.offline }
        let delivered = Set(outcomes.filter(\.outcome.left).map(\.address.key))
        var sent: UUID?
        if !delivered.isEmpty {
            let providerID = result.providerID ?? "sent.\(messageID.uuidString.lowercased())"
            let copy = OutsideFetchedMessage(
                outside: id, providerID: providerID, received: date, raw: withBcc, isUnread: false, labels: ["SENT"]
            )
            try await vault.keepFetched(copy)
            sent = MailVault.fetchedID(id, providerID: providerID, account: self.account)
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
        return MailSendResult(recipients: outcomes, sent: sent, keptCopy: true, remaining: remaining)
    }

    /// Everyone outside Totality gets one ordinary message, in the same To, Cc, and Bcc places as the
    /// draft. It goes readable, through the server, which sets From from the sign-in. It lists only
    /// the outside people, because Totality people get their own sealed copy and listing them would
    /// send them a second, unsealed one. One answer covers them all, since it's one message.
    private func sendOutside(_ draft: MailDraft, message: UUID) async -> MailSendResult.Outcome {
        let outside = { (list: [MailAddress]) in list.filter { $0.isWellFormed && $0.totalityName == nil }.map(\.address) }
        var inReplyTo: String?
        var references: [String]?
        if let origin = draft.origin, origin.kind == .reply, let answered = origin.messageID.flatMap(MailWriter.cleanID) {
            inReplyTo = "<\(answered)>"
            references = (origin.references.compactMap(MailWriter.cleanID) + [answered])
                .reduce(into: [String]()) { list, id in if !list.contains(id) { list.append(id) } }
                .suffix(20)
                .map { "<\($0)>" }
        }
        let request = MailOutsideMessage(
            id: message, to: outside(draft.to), cc: outside(draft.cc), bcc: outside(draft.bcc),
            subject: MailWriter.oneLine(draft.subject), text: draft.body, inReplyTo: inReplyTo, references: references,
            attachments: draft.attachments.map {
                let name = MailWriter.oneLine($0.name).trimmingCharacters(in: .whitespaces)
                return MailOutsideMessage.file(named: name.isEmpty ? "attachment" : String(name.prefix(255)), type: MailWriter.mimeType($0), data: $0.data)
            }
        )
        do {
            switch try await server.sendOutside(request) {
            case .sent: return .sentOutside
            case .off: return .outsideNotYet
            case .newAccount: return .newAccount
            case .dailyLimit: return .dailyLimit
            case .monthLimit: return .monthLimit
            case .busy: return .busy
            case .refused: return .refused
            case .tooBig: return .tooBig
            case .unknown: return .mayHaveSent
            case .failed: return .failed
            }
        } catch let error as MailServerError where error == .offline || error == .signedOut {
            return .offline
        } catch {
            return .failed
        }
    }

    /// A recipient's key is pinned the first time. A different key later is refused, never sent to:
    /// it could be the server's own, put there to read the message. So is a name that's disputed. The
    /// pins are read again after the key arrives, and the pin goes through the vault's one serialised
    /// path, so a pin `open` made meanwhile is neither lost nor ignored.
    private func deliver(_ raw: Data, to address: MailAddress, from me: String) async -> MailSendResult.Outcome {
        guard address.isWellFormed else { return .notAnAddress }
        guard let name = address.totalityName?.lowercased() else { return .failed }
        do {
            guard let recipientKey = try await server.recipientKey(name) else { return .noSuchAddress }
            let known = try await vault.pins()
            if let pinned = known.key(for: name), pinned != recipientKey { return .keyChanged }
            let pins = try await vault.pin(name, key: recipientKey, at: now())
            guard pins.key(for: name) == recipientKey, !pins.isDisputed(name) else { return .keyChanged }
            let id = UUID()
            let sealed = try key.sealDirect(raw, to: recipientKey, from: me, recipient: name, message: id)
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

// MARK: Outside accounts

extension ServerMailStore: OutsideAccountStore {
    public func outsideAccounts() async throws -> [OutsideAccount] {
        let accounts = try await vault.outsideAccounts()
        if !hasSharedGoogle, google != nil {
            // Gmail accounts from before Google sign-in was shared become this device's connections, so
            // Calendar and Photos don't ask the person to sign in again. It runs on its own and nothing
            // waits for it: Mail keeps using its own grant whether or not this lands.
            hasSharedGoogle = true
            let gmail = accounts.filter(\.provider.signsInWithGoogle)
            if !gmail.isEmpty { Task { await self.shareGoogle(gmail) } }
        }
        return accounts
    }

    private func shareGoogle(_ accounts: [OutsideAccount]) async {
        guard let google else { return }
        for outside in accounts {
            if case .google(let grant) = try? await vault.credential(for: outside.id) { google.share(outside.address, grant) }
        }
    }

    public func addOutside(_ signIn: OutsideSignIn) async throws -> OutsideAccount {
        let candidate = OutsideAccount(provider: signIn.provider, address: signIn.address, addedAt: now())
        try await checkRoom(for: candidate)
        if let problem = await outsideCheck.checkReading(signIn) { throw OutsideAccountError.problem(problem) }
        // Checked again after the wait, in case another add landed meanwhile.
        try await checkRoom(for: candidate)
        try await vault.save(candidate, credential: .appPassword(signIn.appPassword), at: now())
        return candidate
    }

    public func googleSignIn(for id: UUID?, sending: Bool) async throws -> GoogleSignInRequest {
        guard let google else { throw OutsideAccountError.notSetUp }
        guard let id else {
            guard try await vault.outsideAccounts().count < OutsideAccountLimits.most else { throw OutsideAccountError.tooMany }
            return google.request(.add)
        }
        guard let outside = try await vault.outsideAccounts().first(where: { $0.id == id }),
              outside.provider.signsInWithGoogle else { throw OutsideAccountError.notFound }
        // An account that already sends keeps sending when it's asked to allow changes.
        return google.request(sending || outside.canSend ? .send(outside.address) : .change(outside.address))
    }

    public func addGoogle(_ request: GoogleSignInRequest, callback: URL) async throws -> OutsideAccount {
        guard let google else { throw OutsideAccountError.notSetUp }
        guard request.purpose == .add else { throw OutsideAccountError.notFound }
        let tokens = try await googleAnswer { try await google.finish(request, callback: callback) }
        let address = try await googleAnswer { try await google.address(accessToken: tokens.accessToken) }
        let candidate = OutsideAccount(provider: .gmail, address: address, addedAt: now())
        // An account already here keeps its own token. Taking this one back at Google would take back
        // the other's too, so it's just dropped.
        try await checkRoom(for: candidate)
        try await vault.save(candidate, credential: .google(GoogleGrant(refreshToken: tokens.refreshToken, canSend: false)), at: now())
        google.share(address, tokens)
        return candidate
    }

    public func allowGoogleSending(_ id: UUID, _ request: GoogleSignInRequest, callback: URL) async throws {
        guard request.purpose.sends else { throw OutsideAccountError.notFound }
        try await regrant(id, request, callback: callback)
    }

    /// Never turns sending on: a request that sends is only taken for an account that already sends.
    public func allowGoogleChanges(_ id: UUID, _ request: GoogleSignInRequest, callback: URL) async throws {
        guard request.purpose != .add else { throw OutsideAccountError.notFound }
        if request.purpose.sends {
            guard try await vault.outsideAccounts().first(where: { $0.id == id })?.canSend == true else { throw OutsideAccountError.notFound }
        }
        try await regrant(id, request, callback: callback)
    }

    /// Swaps an account's Google token for a new one, for the same Google account only.
    private func regrant(_ id: UUID, _ request: GoogleSignInRequest, callback: URL) async throws {
        guard let google else { throw OutsideAccountError.notSetUp }
        guard var outside = try await vault.outsideAccounts().first(where: { $0.id == id }), outside.provider.signsInWithGoogle,
              request.purpose.address?.lowercased() == outside.address.lowercased()
        else { throw OutsideAccountError.notFound }
        let tokens = try await googleAnswer { try await google.finish(request, callback: callback) }
        let address = try await googleAnswer { try await google.address(accessToken: tokens.accessToken) }
        // The page lets the person pick any Google account, and only this one's mail is being changed.
        guard address.lowercased() == outside.address.lowercased() else { throw OutsideAccountError.differentAccount }
        outside.canSend = request.purpose.sends
        try await vault.save(outside, credential: .google(GoogleGrant(refreshToken: tokens.refreshToken, canSend: request.purpose.sends)), at: now())
        google.share(address, tokens)
    }

    /// Takes the sign-in off every device. A Google account's access is taken back at Google too,
    /// which is the one change at the provider: no mail there is touched. That ends the account's
    /// connection for Calendar and Photos as well, which the screen says before it's done.
    public func removeOutside(_ id: UUID) async throws {
        let credential = try? await vault.credential(for: id)
        let address = try? await vault.outsideAccounts().first(where: { $0.id == id })?.address
        try await vault.removeOutside(id)
        if case .google(let grant) = credential, let google {
            await google.revoke(grant.refreshToken)
            if let address { google.unshare(address) }
        }
    }

    /// What else uses this Gmail account's Google connection on this device, for the screen to say
    /// before removing it. Empty when nothing else does.
    public func googleSharing(_ id: UUID) async -> Set<GoogleUse> {
        guard let google, let address = try? await vault.outsideAccounts().first(where: { $0.id == id })?.address,
              let connection = try? google.accounts?.connection(address) else { return [] }
        return GoogleUse.uses(of: connection.granted)
    }

    public func setOutsideSending(_ id: UUID, on: Bool) async throws {
        guard var outside = try await vault.outsideAccounts().first(where: { $0.id == id }) else { throw OutsideAccountError.notFound }
        guard outside.canSend != on else { return }
        if on {
            // Google asks the person first, on its own page.
            guard !outside.provider.signsInWithGoogle else { throw OutsideAccountError.notFound }
            guard let signIn = try await vault.signIn(for: id) else { throw OutsideAccountError.notFound }
            if let problem = await outsideCheck.checkSending(signIn) { throw OutsideAccountError.problem(problem) }
        }
        outside.canSend = on
        try await vault.update(outside, at: now())
    }

    private func checkRoom(for candidate: OutsideAccount) async throws {
        let existing = try await vault.outsideAccounts()
        guard !existing.contains(where: { $0.isSameMailbox(as: candidate) }) else { throw OutsideAccountError.alreadyAdded }
        guard existing.count < OutsideAccountLimits.most else { throw OutsideAccountError.tooMany }
    }

    /// Google's problems become the account's, and closing the page stays a close.
    private func googleAnswer<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let problem as OutsideMailProblem {
            throw OutsideAccountError.problem(problem)
        }
    }
}

/// Counts what one account has downloaded so far, for the progress line.
private final class OutsideCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

extension ServerMailStore {
    /// Remembers which provider messages were deleted here, so they go to the provider's Trash.
    fileprivate func noteErased(_ ids: Set<UUID>) async {
        var records: [UUID: OutsideRemoteRecord] = [:]
        let marks = (try? await vault.marks()) ?? [:]
        for id in ids {
            guard let stored = try? await vault.fetchedMessage(id) else { continue }
            if records[stored.outside] == nil {
                records[stored.outside] = (try? await vault.remote(of: stored.outside)) ?? OutsideRemoteRecord(outside: stored.outside)
            }
            let agreed = records[stored.outside]?.states[stored.providerID] ?? OutsideRemoteState(downloaded: stored)
            // Where it is at the provider as far as Totality knows, so the move starts from there.
            var state = agreed
            if let mine = marks[id] { state.isUnread = mine.isUnread; state.isStarred = mine.isStarred }
            records[stored.outside]?.states[stored.providerID] = nil
            records[stored.outside]?.erased[stored.providerID] = state
        }
        for record in records.values { try? await vault.keepRemote(record) }
    }
}

/// What one provider showed during a download, handed back from the reader's callback.
private final class OutsideViewBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: OutsideProviderView?

    var value: OutsideProviderView? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}
