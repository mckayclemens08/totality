import Foundation
import Observation
import TotalityCore

/// A short Undo after an action: what to put back, and what to call it.
public struct MailUndo: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let label: String
    let marks: [UUID: MailMarks]
    var settings: MailSettings?
}

/// The Mail screens' state. Changes land on screen first, then go to the store, and a change the store
/// can't take because the device is offline waits here and says so.
@MainActor
@Observable
public final class MailModel {
    public enum Phase: Equatable {
        case loading(MailDownload?)
        case noKey, failed, ready
    }

    public private(set) var phase = Phase.loading(nil)
    public private(set) var mailbox = Mailbox()
    public private(set) var isOffline = false
    public private(set) var undo: MailUndo?
    public var notice: String?
    public var place = MailPlace.inbox {
        didSet { endSelecting() }
    }
    public var query = ""
    public var isSelecting = false
    public var selection = Set<UUID>()

    @ObservationIgnored public let store: any MailStore
    /// The module that keeps a saved attachment. It needs the content key, so it arrives after the key does.
    @ObservationIgnored public var receiver: (any ContentReceiver)?
    @ObservationIgnored public var onSentToReader: (() -> Void)?
    @ObservationIgnored public let rules = MailRules()

    private var waitingMarks: [UUID: MailMarks] = [:]
    private var waitingErase = Set<UUID>()
    private var settingsWait = false
    private let now: @Sendable () -> Date

    public init(store: any MailStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public var conversations: [MailConversation] {
        mailbox.conversations(in: place, matching: query)
    }

    public var placeName: String { mailbox.name(of: place) }
    public var today: Date { now() }

    /// How many changes are still on their way.
    public var waiting: Int {
        Set(waitingMarks.keys).union(waitingErase).count + (settingsWait ? 1 : 0)
    }

    public func load() async {
        if phase != .ready { phase = .loading(nil) }
        do {
            let opening = try await store.open { [weak self] download in
                Task { @MainActor in self?.showProgress(download) }
            }
            mailbox = opening.mailbox
            mailbox.apply(waitingMarks)
            mailbox.remove(waitingErase)
            isOffline = opening.isOffline
            phase = .ready
            await emptyTrash()
            if !isOffline { await sendWaiting() }
        } catch MailStoreError.noKey {
            phase = .noKey
        } catch {
            phase = .failed
        }
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
        undo = MailUndo(label: label(action, count: conversations.count), marks: previous(changed))
        endSelecting()
        mailbox.apply(changed)
        await keep(changed)
    }

    /// Opening a conversation reads it. That isn't an action, so it offers no Undo.
    public func markRead(_ conversation: MailConversation) async {
        let changed = mailbox.marks(after: .markRead, on: [conversation], now: now())
        guard !changed.isEmpty else { return }
        mailbox.apply(changed)
        await keep(changed)
    }

    public func block(_ sender: MailAddress) async {
        let changed = mailbox.marksAfterBlocking(sender)
        let before = mailbox.settings
        undo = MailUndo(label: "Blocked \(sender.displayName)", marks: previous(changed), settings: before)
        endSelecting()
        mailbox.apply(changed)
        mailbox.settings.blockedSenders.insert(sender.key)
        await keep(changed)
        await keep(mailbox.settings)
    }

    public func undoLast() async {
        guard let undo else { return }
        self.undo = nil
        mailbox.apply(undo.marks)
        await keep(undo.marks)
        if let settings = undo.settings {
            mailbox.settings = settings
            await keep(settings)
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
        await erase(ids)
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
        await keep(mailbox.settings)
    }

    public func rename(_ folder: MailOwnFolder, to name: String) async {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != folder.name.lowercased(),
              let name = usableName(name),
              let index = mailbox.settings.folders.firstIndex(of: folder)
        else { return }
        mailbox.settings.folders[index].name = name
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
        mailbox.apply(changed)
        mailbox.settings.folders.removeAll { $0.id == folder.id }
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
