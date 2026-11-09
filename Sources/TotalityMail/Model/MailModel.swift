import Foundation
import Observation
import TotalityCore

/// A short Undo after an action: what it changed, and what to call it. It takes back that change and
/// nothing made since.
public struct MailUndo: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let label: String
    let before: [UUID: MailMarks]
    let after: [UUID: MailMarks]
    /// A sender the action blocked, who wasn't blocked before it.
    var unblocks: String?
}

/// The Mail screens' state. Changes land on screen first, then go to the store, and a change the store
/// can't take because the device is offline waits here and says so.
@MainActor
@Observable
public final class MailModel {
    public enum Phase: Equatable {
        case loading(MailDownload?)
        case noKey, failed, ready
        case noAccount, waitingForBackup, keyConflict
    }

    public private(set) var phase = Phase.loading(nil)
    public private(set) var mailbox = Mailbox()
    public private(set) var isOffline = false
    /// Which outside account is downloading, and how far it's got. Nil when none is.
    public private(set) var outsideDownload: OutsideDownload?
    /// Totality mail coming down from the server, while it does.
    public private(set) var download: MailDownload?
    /// Totality's server is being asked for new mail, behind what's already showing.
    public private(set) var isChecking = false
    /// Totality's server couldn't be reached on the last check, while stored mail stayed on screen.
    public private(set) var checkFailed = false
    /// What went wrong with outside accounts on the last download, one line each.
    public private(set) var outsideProblems: [String] = []
    @ObservationIgnored private var isDownloadingOutside = false
    /// The sync under way, which anything else asking for one waits on.
    @ObservationIgnored private var syncing: Task<Void, Never>?
    /// Searching outside accounts for older mail: nil until asked, then how it went for `query`.
    public private(set) var outsideSearch: OutsideSearchState?
    public private(set) var undo: MailUndo?
    public var notice: String?
    public var place = MailPlace.inbox {
        didSet { endSelecting() }
    }
    public var query = ""
    /// A conversation the home page asked to open. Mail opens it in the Inbox and clears this.
    public var requestedConversation: UUID?
    public var isSelecting = false
    public var selection = Set<UUID>()

    @ObservationIgnored public let store: any MailStore
    /// The module that keeps a saved attachment. It needs the content key, so it arrives after the key does.
    @ObservationIgnored public var receiver: (any ContentReceiver)?
    @ObservationIgnored public var onSentToReader: (() -> Void)?
    @ObservationIgnored public let rules = MailRules()
    /// Outside accounts beside the Totality address, when the store can keep them.
    @ObservationIgnored public let outside: OutsideAccountsModel?

    /// What changed on this device while a fetch was out. The fetched copy is older, so these go on top.
    private struct Since {
        var marks: [UUID: MailMarks] = [:]
        var erased = Set<UUID>()
        var settings = false
        var drafts = false
    }

    private var waitingMarks: [UUID: MailMarks] = [:]
    private var waitingErase = Set<UUID>()
    private var settingsWait = false
    private var since: [UUID: Since] = [:]
    private let now: @Sendable () -> Date

    public init(store: any MailStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        outside = (store as? any OutsideAccountStore).map { OutsideAccountsModel(store: $0) }
    }

    public var conversations: [MailConversation] {
        mailbox.conversations(in: place, matching: query)
    }

    public var placeName: String { mailbox.name(of: place) }

    // MARK: The home page

    /// The Inbox's newest conversations, for the home tiles. Nothing outside the Inbox shows there.
    public func homeConversations(_ limit: Int) -> [MailConversation] {
        Array(mailbox.conversations(in: .inbox).prefix(limit))
    }

    public var homeUnread: Int { mailbox.unreadCount(in: .inbox) }

    /// How many senders the small tile lists under the count.
    static let glanceSenders = 3

    /// The small tile's lines: how much is unread, then who wrote the newest conversations, each of which
    /// opens. Mail loads from the home page, so it says it's checking until then. A problem with the key
    /// or the account is shown in Mail itself, never on the home page.
    public var glance: ModuleGlance {
        guard phase == .ready else {
            if case .loading = phase { return ModuleGlance(lines: ["Checking your mail"], isQuiet: true) }
            return ModuleGlance(lines: ["Open to check your mail"], isQuiet: true)
        }
        let unread = homeUnread
        let count = unread == 0 ? "No unread mail" : unread == 1 ? "1 unread" : "\(unread) unread"
        let senders = glanceConversations.map { $0.sender(me: mailbox.address).displayName }
        return ModuleGlance(lines: [count] + senders, isQuiet: unread == 0)
    }

    private var glanceConversations: [MailConversation] {
        Array(mailbox.conversations(in: .inbox).filter { !$0.isUnreadable }.prefix(Self.glanceSenders))
    }

    /// What a line of the small tile opens. The first line counts, so it opens Mail itself.
    public func glanceConversation(at line: Int) -> UUID? {
        guard phase == .ready, line > 0 else { return nil }
        let shown = glanceConversations
        return shown.indices.contains(line - 1) ? shown[line - 1].id : nil
    }

    /// Asked for from the home page. The Inbox is where it lives, so that's where it opens.
    public func requestFromHome(_ conversation: UUID) {
        place = .inbox
        query = ""
        requestedConversation = conversation
    }
    public var today: Date { now() }

    /// How many changes are still on their way.
    public var waiting: Int {
        Set(waitingMarks.keys).union(waitingErase).count + (settingsWait ? 1 : 0)
    }

    /// Brings Mail up to date: on opening, on coming back to the app, on a timer while it's open, and on
    /// a pull. One runs at a time, and asking while one is under way waits for it to finish.
    public func refresh() async {
        if let syncing {
            await syncing.value
            return
        }
        let task = Task { await self.load() }
        syncing = task
        await task.value
        syncing = nil
    }

    /// Whatever changed here while the fetch was out stays changed. What's already on the device shows
    /// first, so nothing waits on the network.
    public func load() async {
        var clock = MailClock("load")
        isChecking = true
        defer {
            clock.done()
            isChecking = false
        }
        if phase != .ready {
            if let cached = await store.cached() {
                mailbox = merged(cached, here: Since())
                phase = .ready
            } else {
                phase = .loading(nil)
            }
            clock.mark("stored mail shown")
        }
        let fetch = UUID()
        since[fetch] = Since()
        defer {
            since[fetch] = nil
            download = nil
        }
        do {
            let opening = try await store.open { [weak self] download in
                Task { @MainActor in self?.showProgress(download) }
            }
            mailbox = merged(opening.mailbox, here: since[fetch] ?? Since())
            isOffline = opening.isOffline
            phase = .ready
            checkFailed = false
            download = nil
            isChecking = false
            clock.mark("Totality mail")
            await emptyTrash()
            if !isOffline { await sendWaiting() }
            clock.mark("waiting changes")
            await downloadOutside()
            clock.mark("outside accounts")
        } catch MailStoreError.noKey {
            phase = .noKey
        } catch MailStoreError.noAccount {
            phase = .noAccount
        } catch MailStoreError.waitingForBackup {
            if mailbox.address.isEmpty, let address = await store.address() { mailbox.address = address }
            phase = .waitingForBackup
        } catch MailStoreError.keyConflict {
            phase = .keyConflict
        } catch {
            // Mail that's already showing stays, with a line saying the check didn't go through.
            if phase == .ready, !mailbox.messages.isEmpty {
                checkFailed = true
            } else {
                phase = .failed
            }
        }
    }

    /// What the store had, with every change made here since it was asked kept on top.
    private func merged(_ stored: Mailbox, here: Since) -> Mailbox {
        var fresh = stored
        fresh.apply(waitingMarks.merging(here.marks) { _, new in new })
        fresh.remove(waitingErase.union(here.erased))
        if here.settings || settingsWait { fresh.settings = mailbox.settings }
        if here.drafts { fresh.drafts = mailbox.drafts }
        return fresh
    }

    /// New mail from outside accounts, straight from each provider. Totality mail is already showing by
    /// now, so this never holds it up.
    private func downloadOutside() async {
        guard !isDownloadingOutside else { return }
        isDownloadingOutside = true
        defer {
            isDownloadingOutside = false
            outsideDownload = nil
        }
        let fetch = UUID()
        since[fetch] = Since()
        defer { since[fetch] = nil }
        guard let result = await store.downloadOutside(progress: { [weak self] download in
            Task { @MainActor in self?.outsideDownload = download }
        }) else {
            outsideProblems = []
            return
        }
        var fresh = merged(result.mailbox, here: since[fetch] ?? Since())
        fresh.isFull = mailbox.isFull
        mailbox = fresh
        outsideProblems = result.problems
    }

    /// Asks each outside account for older mail matching the search, from the person's press. What's
    /// found is downloaded and joins the mailbox; the search itself still runs on the device.
    public func searchOutside() async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, outsideSearch?.isSearching != true else { return }
        let before = Set(mailbox.messages.map(\.id))
        outsideSearch = OutsideSearchState(query: query, isSearching: true)
        let fetch = UUID()
        since[fetch] = Since()
        defer { since[fetch] = nil }
        guard let result = await store.searchOutside(query) else {
            outsideSearch = OutsideSearchState(query: query, isSearching: false)
            return
        }
        var fresh = merged(result.mailbox, here: since[fetch] ?? Since())
        fresh.isFull = mailbox.isFull
        mailbox = fresh
        let found = mailbox.messages.filter { !before.contains($0.id) }.count
        outsideSearch = OutsideSearchState(query: query, isSearching: false, found: found, problems: result.problems)
    }

    /// Starts over from the store, forgetting anything that was waiting.
    public func reopen() async {
        waitingMarks = [:]
        waitingErase = []
        settingsWait = false
        isOffline = false
        undo = nil
        phase = .loading(nil)
        await load()
    }

    private func showProgress(_ download: MailDownload) {
        self.download = download
        if case .loading = phase { phase = .loading(download) }
    }

    private func emptyTrash() async {
        let expired = mailbox.expired(at: now())
        if !expired.isEmpty { await eraseNow(expired) }
    }

    private func sendWaiting() async {
        guard waiting > 0 else { return }
        let marks = waitingMarks
        let erased = waitingErase
        let settings = settingsWait
        waitingMarks = [:]
        waitingErase = []
        settingsWait = false
        if !marks.isEmpty { await keep(marks) }
        if !erased.isEmpty { await erase(erased) }
        if settings { await keep(mailbox.settings) }
    }

    // MARK: Sorting

    public func perform(_ action: MailAction, on conversations: [MailConversation]) async {
        let changed = mailbox.marks(after: action, on: conversations, now: now())
        guard !changed.isEmpty else { return }
        undo = MailUndo(label: label(action, count: conversations.count), before: previous(changed), after: changed)
        endSelecting()
        change(changed)
        await keep(changed)
    }

    /// Opening a conversation reads it. That isn't an action, so it offers no Undo.
    public func markRead(_ conversation: MailConversation) async {
        let changed = mailbox.marks(after: .markRead, on: [conversation], now: now())
        guard !changed.isEmpty else { return }
        change(changed)
        await keep(changed)
    }

    public func block(_ sender: MailAddress) async {
        let changed = mailbox.marksAfterBlocking(sender)
        let isNew = !mailbox.settings.blockedSenders.contains(sender.key)
        undo = MailUndo(
            label: "Blocked \(sender.displayName)", before: previous(changed), after: changed,
            unblocks: isNew ? sender.key : nil
        )
        endSelecting()
        change(changed)
        mailbox.settings.blockedSenders.insert(sender.key)
        settingsChanged()
        await keep(changed)
        await keep(mailbox.settings)
    }

    /// Puts back what the action changed, where it's still as the action left it.
    public func undoLast() async {
        guard let undo else { return }
        self.undo = nil
        var restored: [UUID: MailMarks] = [:]
        for message in mailbox.messages {
            guard let before = undo.before[message.id], let after = undo.after[message.id] else { continue }
            let marks = message.marks.undoing(after, back: before)
            if marks != message.marks { restored[message.id] = marks }
        }
        change(restored)
        await keep(restored)
        if let sender = undo.unblocks, mailbox.settings.blockedSenders.contains(sender) {
            mailbox.settings.blockedSenders.remove(sender)
            settingsChanged()
            await keep(mailbox.settings)
        }
    }

    public func dismissUndo(_ shown: MailUndo.ID) {
        if undo?.id == shown { undo = nil }
    }

    /// Can't be undone, so the screens ask first.
    public func deleteForever(_ conversations: [MailConversation]) async {
        let ids = Set(conversations.flatMap { $0.messages.map(\.id) })
        guard !ids.isEmpty else { return }
        endSelecting()
        await eraseNow(ids)
    }

    private func eraseNow(_ ids: Set<UUID>) async {
        mailbox.remove(ids)
        for fetch in since.keys { since[fetch]?.erased.formUnion(ids) }
        await erase(ids)
    }

    private func change(_ marks: [UUID: MailMarks]) {
        mailbox.apply(marks)
        for fetch in since.keys { since[fetch]?.marks.merge(marks) { _, new in new } }
    }

    private func settingsChanged() {
        for fetch in since.keys { since[fetch]?.settings = true }
    }

    private func previous(_ changed: [UUID: MailMarks]) -> [UUID: MailMarks] {
        var before: [UUID: MailMarks] = [:]
        for message in mailbox.messages where changed[message.id] != nil { before[message.id] = message.marks }
        return before
    }

    private func label(_ action: MailAction, count: Int) -> String {
        let done = switch action {
        case .archive: "Archived"
        case .trash: "Moved to Trash"
        case .reportSpam: "Reported as spam"
        case .move(let folder): "Moved to \(mailbox.name(of: folder))"
        case .markRead: "Marked as read"
        case .markUnread: "Marked as unread"
        case .star: "Starred"
        case .unstar: "Star removed"
        }
        return count > 1 ? "\(done): \(count) conversations" : done
    }

    // MARK: Selecting

    public func beginSelecting(_ conversation: MailConversation? = nil) {
        isSelecting = true
        selection = conversation.map { [$0.id] } ?? []
    }

    public func endSelecting() {
        isSelecting = false
        selection = []
    }

    public func toggle(_ conversation: MailConversation) {
        if selection.remove(conversation.id) == nil { selection.insert(conversation.id) }
    }

    public var selected: [MailConversation] {
        conversations.filter { selection.contains($0.id) }
    }

    // MARK: Folders

    public func addFolder(named name: String) async {
        guard let name = usableName(name) else { return }
        mailbox.settings.folders.append(MailOwnFolder(name: name))
        settingsChanged()
        await keep(mailbox.settings)
    }

    public func rename(_ folder: MailOwnFolder, to name: String) async {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != folder.name.lowercased(),
              let name = usableName(name),
              let index = mailbox.settings.folders.firstIndex(of: folder)
        else { return }
        mailbox.settings.folders[index].name = name
        settingsChanged()
        await keep(mailbox.settings)
    }

    /// Its mail goes to Archive, so removing a folder never removes a message.
    public func remove(_ folder: MailOwnFolder) async {
        var changed: [UUID: MailMarks] = [:]
        for message in mailbox.messages where message.marks.folder == .own(folder.id) {
            var marks = message.marks
            marks.folder = .archive
            changed[message.id] = marks
        }
        if place == .folder(.own(folder.id)) { place = .inbox }
        change(changed)
        mailbox.settings.folders.removeAll { $0.id == folder.id }
        settingsChanged()
        await keep(changed)
        await keep(mailbox.settings)
    }

    private func usableName(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let taken = mailbox.settings.folders.map(\.name) + MailPlace.builtIn.map(mailbox.name(of:))
        guard !taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "You already have a folder called \(name)."
            return nil
        }
        return name
    }

    // MARK: Images and attachments

    public func alwaysLoadImages(from sender: MailAddress) async {
        mailbox.settings.alwaysLoadImages.insert(sender.key)
        settingsChanged()
        await keep(mailbox.settings)
    }

    public func data(of attachment: MailAttachment) async -> Data? {
        do {
            return try await store.data(of: attachment.id)
        } catch {
            notice = "\(attachment.name) didn't open. Try again."
            return nil
        }
    }

    public var canSaveToReader: Bool { receiver != nil }

    public func saveToReader(_ attachment: MailAttachment) async {
        guard let receiver, let data = await data(of: attachment) else { return }
        do {
            _ = try await receiver.receive(file: data, named: attachment.name)
            onSentToReader?()
            notice = "Saved \(attachment.name) to the Reader."
        } catch {
            notice = "\(attachment.name) didn't save to the Reader."
        }
    }

    // MARK: Writing

    /// Written under new messages from here on. Messages already written keep what they have.
    public func setSignature(_ signature: String) async {
        let signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard signature != mailbox.settings.signature else { return }
        mailbox.settings.signature = signature
        settingsChanged()
        await keep(mailbox.settings)
    }

    /// Kept sealed on this device, and synced. A draft with nothing in it isn't kept.
    public func save(_ draft: MailDraft) async {
        if draft.isEmpty {
            await discard(draft)
            return
        }
        mailbox.drafts.removeAll { $0.id == draft.id }
        mailbox.drafts.insert(draft, at: 0)
        draftsChanged()
        do {
            try await store.save(draft)
        } catch {
            notice = "Your draft didn't save. Copy anything you need before leaving it."
        }
    }

    public func discard(_ draft: MailDraft) async {
        mailbox.drafts.removeAll { $0.id == draft.id }
        draftsChanged()
        do {
            try await store.discard(draft: draft.id)
        } catch {
            notice = "That draft didn't delete. It'll come back when Mail next opens."
        }
    }

    /// Sends now. The screens give their few seconds of Undo before calling this, and only from a
    /// press. Whoever didn't get it stays on the draft, which is still here, and the result says why.
    public func send(_ draft: MailDraft) async throws -> MailSendResult {
        let result = try await store.send(draft)
        mailbox.drafts.removeAll { $0.id == draft.id }
        if let remaining = result.remaining { mailbox.drafts.insert(remaining, at: 0) }
        draftsChanged()
        await load()
        return result
    }

    private func draftsChanged() {
        for fetch in since.keys { since[fetch]?.drafts = true }
    }

    // MARK: The store

    private func keep(_ marks: [UUID: MailMarks]) async {
        guard !marks.isEmpty else { return }
        do {
            try await store.save(marks)
        } catch MailStoreError.offline {
            isOffline = true
            waitingMarks.merge(marks) { _, new in new }
        } catch {
            notice = "That didn't save. It'll look right again when Mail next opens."
        }
    }

    private func keep(_ settings: MailSettings) async {
        do {
            try await store.save(settings)
        } catch MailStoreError.offline {
            isOffline = true
            settingsWait = true
        } catch {
            notice = "That didn't save. It'll look right again when Mail next opens."
        }
    }

    private func erase(_ ids: Set<UUID>) async {
        do {
            try await store.erase(ids)
        } catch MailStoreError.offline {
            isOffline = true
            waitingErase.formUnion(ids)
        } catch {
            notice = "That didn't delete. It'll come back when Mail next opens."
        }
    }
}
