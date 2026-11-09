import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// A store that remembers what reached it, and can pretend the device is offline.
private actor FakeStore: MailStore {
    var mailbox: Mailbox
    var failure: MailStoreError?
    var isOffline = false
    private(set) var saved: [[UUID: MailMarks]] = []
    private(set) var savedSettings: [MailSettings] = []
    private(set) var erased: [Set<UUID>] = []

    init(_ mailbox: Mailbox, failure: MailStoreError? = nil) {
        self.mailbox = mailbox
        self.failure = failure
    }

    func set(offline: Bool) { isOffline = offline }
    func set(failure: MailStoreError?) { self.failure = failure }

    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        if let failure { throw failure }
        return MailOpening(mailbox: mailbox, isOffline: isOffline)
    }

    func save(_ marks: [UUID: MailMarks]) async throws {
        if isOffline { throw MailStoreError.offline }
        saved.append(marks)
    }

    func save(_ settings: MailSettings) async throws {
        if isOffline { throw MailStoreError.offline }
        savedSettings.append(settings)
    }

    func erase(_ messages: Set<UUID>) async throws {
        if isOffline { throw MailStoreError.offline }
        erased.append(messages)
    }

    func data(of attachment: UUID) async throws -> Data { Data() }
    func save(_ draft: MailDraft) async throws {}
    func discard(draft: UUID) async throws {}
    func send(_ draft: MailDraft) async throws -> MailSendResult {
        MailSendResult(recipients: [], sent: nil, keptCopy: false, remaining: nil)
    }
}

private actor FakeReader: ContentReceiver {
    nonisolated let module = ModuleID.reader
    nonisolated let kinds: Set<ContentKind> = [.file]
    private(set) var files: [String] = []

    func attachable() async throws -> [ContentRef] { [] }
    func current(_ ref: ContentRef) async throws -> ContentRef? { nil }
    func receive(noteTitled title: String, body: String) async throws -> ContentRef { try ref(title) }
    func receive(file data: Data, named filename: String) async throws -> ContentRef {
        files.append(filename)
        return try ref(filename)
    }

    private func ref(_ title: String) throws -> ContentRef {
        ContentRef(module: .reader, kind: .file, id: UUID(), keyRef: .plain, preview: .init(title: title))
    }
}

/// Holds every fetch after the first until it's let go, like a slow connection. What it hands back
/// is what it held when Mail opened, so it knows nothing saved since.
private actor SlowStore: MailStore {
    let mailbox: Mailbox
    private var opens = 0
    private var held: CheckedContinuation<Void, Never>?

    init(_ mailbox: Mailbox) { self.mailbox = mailbox }

    var isHolding: Bool { held != nil }

    func letGo() {
        held?.resume()
        held = nil
    }

    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        opens += 1
        if opens > 1 { await withCheckedContinuation { held = $0 } }
        return MailOpening(mailbox: mailbox)
    }

    func save(_ marks: [UUID: MailMarks]) async throws {}
    func save(_ settings: MailSettings) async throws {}
    func erase(_ messages: Set<UUID>) async throws {}
    func data(of attachment: UUID) async throws -> Data { Data() }
    func save(_ draft: MailDraft) async throws {}
    func discard(draft: UUID) async throws {}
    func send(_ draft: MailDraft) async throws -> MailSendResult {
        MailSendResult(recipients: [], sent: nil, keptCopy: false, remaining: nil)
    }
}

/// Which accounts a store was made for, in order.
@MainActor private final class Made {
    var accounts: [String?] = []
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
private let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")

private func message(_ marks: MailMarks = MailMarks()) -> MailMessage {
    MailMessage(
        conversationID: UUID(), from: dana, to: [MailAddress(address: "mckay@usetotality.com")], subject: "Saturday",
        date: now, body: .plain("Are we still on?"), route: .betweenAccounts, marks: marks
    )
}

@MainActor
@Suite struct MailModelTests {
    private func opened(_ messages: [MailMessage], settings: MailSettings = MailSettings()) async -> (MailModel, FakeStore) {
        let store = FakeStore(Mailbox(address: "mckay@usetotality.com", messages: messages, settings: settings))
        let model = MailModel(store: store, now: { now })
        await model.load()
        return (model, store)
    }

    @Test func aMissingKeyAndAFailureAreDifferentScreens() async {
        let noKey = MailModel(store: FakeStore(Mailbox(), failure: .noKey))
        await noKey.load()
        #expect(noKey.phase == .noKey)
        let failed = MailModel(store: FakeStore(Mailbox(), failure: .unavailable))
        await failed.load()
        #expect(failed.phase == .failed)
    }

    @Test func mailAlreadyShowingStaysWhenACheckFails() async {
        let message = MailMessage(
            conversationID: UUID(), from: sam, to: [MailAddress(address: "mckay@usetotality.com")], subject: "Deck plans",
            date: now, body: .plain("Attached."), route: .outside, marks: MailMarks()
        )
        let (model, store) = await opened([message])
        await store.set(failure: .unavailable)
        await model.refresh()
        #expect(model.phase == .ready)
        #expect(model.checkFailed)
        #expect(model.mailbox.messages.count == 1)
        #expect(!model.isChecking)
        await store.set(failure: nil)
        await model.refresh()
        #expect(!model.checkFailed)
    }

    // MARK: The home page

    @Test func theSmallTileSaysWhatsUnreadAndWhoWroteLast() async {
        let older = MailMessage(
            conversationID: UUID(), from: sam, to: [MailAddress(address: "mckay@usetotality.com")], subject: "Deck plans",
            date: now.addingTimeInterval(-3_600), body: .plain("Attached."), route: .outside, marks: MailMarks(isUnread: true)
        )
        let (model, _) = await opened([message(MailMarks(isUnread: true)), older])
        #expect(model.glance == ModuleGlance(lines: ["2 unread", "Dana Whitfield", sam.displayName]))
        let newest = model.homeConversations(5)
        #expect(newest.map(\.subject) == ["Saturday", "Deck plans"])
        #expect(model.glanceConversation(at: 1) == newest.first?.id)
        #expect(model.glanceConversation(at: 2) == newest.last?.id)
        #expect(model.glanceConversation(at: 3) == nil)
        #expect(model.glanceConversation(at: 0) == nil)
    }

    @Test func aQuietInboxSaysSoWithoutRaisingItsVoice() async {
        let (model, _) = await opened([message(MailMarks(isUnread: false))])
        #expect(model.glance == ModuleGlance(lines: ["No unread mail", "Dana Whitfield"], isQuiet: true))
        let (empty, _) = await opened([])
        #expect(empty.glance == ModuleGlance(lines: ["No unread mail"], isQuiet: true))
        #expect(empty.glanceConversation(at: 1) == nil)
    }

    @Test func beforeMailOpensTheTileOnlyInvitesYouIn() async {
        let model = MailModel(store: FakeStore(Mailbox(), failure: .noKey))
        #expect(model.glance == ModuleGlance(lines: ["Checking your mail"], isQuiet: true))
        await model.load()
        #expect(model.glance == ModuleGlance(lines: ["Open to check your mail"], isQuiet: true), "A key problem is shown in Mail, not on the home page")
        #expect(model.glanceConversation(at: 1) == nil)
    }

    @Test func onlyTheInboxReachesTheHomePage() async {
        let spam = MailMessage(
            conversationID: UUID(), from: sam, to: [MailAddress(address: "mckay@usetotality.com")], subject: "You won a prize",
            date: now.addingTimeInterval(60), body: .plain("Click here."), route: .outside, marks: MailMarks(folder: .spam, isUnread: true)
        )
        let (model, _) = await opened([message(MailMarks(isUnread: false)), spam])
        #expect(model.homeConversations(5).map { $0.subject } == ["Saturday"])
        #expect(model.homeUnread == 0)
    }

    @Test func aConversationTappedOnTheHomePageOpensInTheInbox() async {
        let (model, _) = await opened([message()])
        model.place = .folder(.sent)
        model.query = "plans"
        let id = model.homeConversations(1)[0].id
        model.requestFromHome(id)
        #expect(model.place == .inbox)
        #expect(model.query.isEmpty)
        #expect(model.requestedConversation == id)
    }

    @Test func anActionShowsAtOnceAndReachesTheStore() async {
        let (model, store) = await opened([message()])
        await model.perform(.archive, on: model.conversations)
        #expect(model.conversations.isEmpty)
        #expect(model.undo?.label == "Archived")
        #expect(await store.saved.count == 1)
    }

    @Test func undoPutsEverythingBackAndTellsTheStore() async {
        let (model, store) = await opened([message(MailMarks(isUnread: true))])
        await model.perform(.trash, on: model.conversations)
        await model.undoLast()
        #expect(model.conversations.count == 1)
        #expect(model.conversations[0].isUnread)
        #expect(model.mailbox.messages[0].marks.trashedAt == nil)
        #expect(model.undo == nil)
        #expect(await store.saved.count == 2)
    }

    @Test func undoSpeaksForTheLastActionOnly() async {
        let (model, _) = await opened([message(), message()])
        let first = model.conversations[0]
        let second = model.conversations[1]
        await model.perform(.archive, on: [first])
        await model.perform(.trash, on: [second])
        await model.undoLast()
        #expect(model.conversations.map(\.id) == [second.id])
    }

    @Test func undoTheBarWentAwayForDoesNothing() async {
        let (model, _) = await opened([message()])
        await model.perform(.archive, on: model.conversations)
        let shown = model.undo?.id
        await model.perform(.markUnread, on: model.mailbox.conversations(in: .folder(.archive)))
        model.dismissUndo(shown!)
        #expect(model.undo != nil)
    }

    @Test func openingAConversationReadsItWithoutOfferingUndo() async {
        let (model, _) = await opened([message(MailMarks(isUnread: true))])
        await model.markRead(model.conversations[0])
        #expect(!model.conversations[0].isUnread)
        #expect(model.undo == nil)
    }

    @Test func severalAtOnceCountAsOneAction() async {
        let (model, store) = await opened([message(), message(), message()])
        model.beginSelecting()
        model.toggle(model.conversations[0])
        model.toggle(model.conversations[1])
        await model.perform(.archive, on: model.selected)
        #expect(model.conversations.count == 1)
        #expect(model.undo?.label == "Archived: 2 conversations")
        #expect(!model.isSelecting)
        #expect(await store.saved.count == 1)
    }

    @Test func changingPlaceEndsSelecting() async {
        let (model, _) = await opened([message()])
        model.beginSelecting(model.conversations[0])
        model.place = .starred
        #expect(!model.isSelecting)
        #expect(model.selection.isEmpty)
    }

    @Test func deletingForeverOffersNoUndoAndErases() async {
        let (model, store) = await opened([message(MailMarks(folder: .trash, trashedAt: now))])
        model.place = .folder(.trash)
        let ids = Set(model.mailbox.messages.map(\.id))
        await model.deleteForever(model.conversations)
        #expect(model.mailbox.messages.isEmpty)
        #expect(model.undo == nil)
        #expect(await store.erased == [ids])
    }

    @Test func oldTrashGoesOnOpen() async {
        let old = message(MailMarks(folder: .trash, trashedAt: now.addingTimeInterval(-Mailbox.trashLifetime - 60)))
        let (model, store) = await opened([old, message()])
        #expect(model.mailbox.messages.count == 1)
        #expect(await store.erased == [[old.id]])
    }

    @Test func blockingCanBeUndone() async {
        let (model, store) = await opened([message()])
        await model.block(dana)
        #expect(model.conversations.isEmpty)
        #expect(model.mailbox.settings.blockedSenders == [dana.key])
        await model.undoLast()
        #expect(model.conversations.count == 1)
        #expect(model.mailbox.settings.blockedSenders.isEmpty)
        #expect(await store.savedSettings.last?.blockedSenders.isEmpty == true)
    }

    @Test func undoTakesBackTheActionAndNothingSince() async {
        let (model, _) = await opened([message(MailMarks(isUnread: true))])
        let conversation = model.conversations[0]
        await model.perform(.archive, on: [conversation])
        await model.markRead(model.mailbox.conversations(in: .folder(.archive))[0])
        await model.addFolder(named: "Taxes")
        await model.undoLast()
        #expect(model.conversations.map(\.id) == [conversation.id])
        #expect(!model.conversations[0].isUnread)
        #expect(model.mailbox.settings.folders.map(\.name) == ["Taxes"])
    }

    @Test func undoingABlockKeepsEveryOtherSetting() async {
        let (model, store) = await opened([message()])
        await model.block(dana)
        await model.addFolder(named: "Taxes")
        await model.alwaysLoadImages(from: sam)
        await model.undoLast()
        #expect(model.conversations.count == 1)
        #expect(model.mailbox.settings.blockedSenders.isEmpty)
        #expect(model.mailbox.settings.folders.map(\.name) == ["Taxes"])
        #expect(model.mailbox.settings.alwaysLoadImages == [sam.key])
        #expect(await store.savedSettings.last == model.mailbox.settings)
    }

    @Test func undoingABlockOfSomeoneAlreadyBlockedLeavesThemBlocked() async {
        let (model, _) = await opened([message()], settings: MailSettings(blockedSenders: [dana.key]))
        await model.block(dana)
        await model.undoLast()
        #expect(model.mailbox.settings.blockedSenders == [dana.key])
    }

    @Test func whatChangesDuringAFetchOutlivesIt() async {
        let store = SlowStore(Mailbox(address: "mckay@usetotality.com", messages: [message(), message(), message()]))
        let model = MailModel(store: store, now: { now })
        await model.load()
        let archived = model.conversations[0]
        let deleted = model.conversations[1]
        let kept = model.conversations[2]
        let fetch = Task { await model.load() }
        while !(await store.isHolding) { await Task.yield() }
        await model.perform(.archive, on: [archived])
        await model.deleteForever([deleted])
        await model.addFolder(named: "Taxes")
        await store.letGo()
        await fetch.value
        #expect(model.conversations.map(\.id) == [kept.id])
        #expect(model.mailbox.conversations(in: .folder(.archive)).map(\.id) == [archived.id])
        #expect(model.mailbox.messages.count == 2)
        #expect(model.mailbox.settings.folders.map(\.name) == ["Taxes"])
    }

    @Test func aFetchAfterwardsTakesWhatTheStoreSays() async {
        let store = SlowStore(Mailbox(address: "mckay@usetotality.com", messages: [message()]))
        let model = MailModel(store: store, now: { now })
        await model.load()
        await model.perform(.archive, on: model.conversations)
        let fetch = Task { await model.load() }
        while !(await store.isHolding) { await Task.yield() }
        await store.letGo()
        await fetch.value
        #expect(model.conversations.count == 1)
    }

    @Test func anotherAccountGetsANewModelOnItsOwnStore() async {
        let made = Made()
        let mail = MailAccountModel { account in
            made.accounts.append(account)
            let messages = account == "dana" ? [message()] : []
            return FakeStore(Mailbox(address: "\(account ?? "nobody")@usetotality.com", messages: messages))
        }
        mail.use(account: "dana")
        let first = mail.current
        await first.load()
        first.query = "Saturday"
        #expect(first.conversations.count == 1)
        mail.use(account: "sam")
        let second = mail.current
        #expect(second !== first)
        #expect(second.phase == .loading(nil))
        #expect(second.mailbox.messages.isEmpty)
        #expect(second.query.isEmpty)
        await second.load()
        #expect(second.mailbox.address == "sam@usetotality.com")
        #expect(second.conversations.isEmpty)
        mail.use(account: "sam")
        #expect(mail.current === second)
        #expect(made.accounts == [nil, "dana", "sam"])
    }

    @Test func aKeyChangeStartsOverAndDropsTheReader() async {
        let made = Made()
        let mail = MailAccountModel { account in
            made.accounts.append(account)
            return FakeStore(Mailbox(address: "mckay@usetotality.com", messages: [message()]))
        }
        mail.use(account: "mckay")
        mail.receiver = FakeReader()
        let before = mail.current
        #expect(before.canSaveToReader)
        mail.keyChanged()
        #expect(mail.current !== before)
        #expect(!mail.current.canSaveToReader)
        #expect(made.accounts == [nil, "mckay", "mckay"])
        mail.receiver = FakeReader()
        #expect(mail.current.canSaveToReader)
    }

    @Test func offlineChangesWaitSayHowManyAndGoThroughLater() async {
        let (model, store) = await opened([message(), message()])
        await store.set(offline: true)
        await model.perform(.archive, on: [model.conversations[0]])
        await model.perform(.star, on: [model.conversations[0]])
        #expect(model.isOffline)
        #expect(model.waiting == 2)
        #expect(model.conversations.count == 1)
        #expect(model.notice == nil)
        #expect(await store.saved.isEmpty)

        await model.load()
        #expect(model.isOffline)
        #expect(model.waiting == 2)
        #expect(model.conversations.count == 1)

        await store.set(offline: false)
        await model.load()
        #expect(!model.isOffline)
        #expect(model.waiting == 0)
        #expect(await store.saved.count == 1)
        #expect(await store.saved[0].count == 2)
    }

    @Test func offlineDeleteWaitsToo() async {
        let (model, store) = await opened([message(MailMarks(folder: .trash, trashedAt: now))])
        model.place = .folder(.trash)
        await store.set(offline: true)
        await model.deleteForever(model.conversations)
        await model.load()
        #expect(model.mailbox.messages.isEmpty)
        #expect(model.waiting == 1)
    }

    @Test func aFolderGoesToArchiveNotAway() async {
        let folder = MailOwnFolder(name: "Travel")
        let (model, _) = await opened([message(MailMarks(folder: .own(folder.id)))], settings: MailSettings(folders: [folder]))
        model.place = .folder(.own(folder.id))
        await model.remove(folder)
        #expect(model.place == .inbox)
        #expect(model.mailbox.settings.folders.isEmpty)
        #expect(model.mailbox.messages[0].marks.folder == .archive)
    }

    @Test func folderNamesAreCheckedAgainstEveryOtherName() async {
        let (model, _) = await opened([])
        await model.addFolder(named: "  Travel ")
        await model.addFolder(named: "travel")
        await model.addFolder(named: "INBOX")
        await model.addFolder(named: "   ")
        #expect(model.mailbox.settings.folders.map(\.name) == ["Travel"])
        #expect(model.notice != nil)
    }

    @Test func aFolderCanChangeItsOwnCapitals() async {
        let (model, _) = await opened([])
        await model.addFolder(named: "travel")
        await model.rename(model.mailbox.settings.folders[0], to: "Trips")
        #expect(model.mailbox.settings.folders[0].name == "Trips")
    }

    @Test func savingToTheReaderNeedsAReceiver() async {
        let (model, _) = await opened([])
        let attachment = MailAttachment(name: "lease.pdf", mimeType: "application/pdf", size: 10)
        #expect(!model.canSaveToReader)
        let reader = FakeReader()
        model.receiver = reader
        await model.saveToReader(attachment)
        #expect(await reader.files == ["lease.pdf"])
        #expect(model.notice == "Saved lease.pdf to the Reader.")
    }
}

@Suite struct SampleMailTests {
    @Test func everyStateOpensAsItSays() async throws {
        let store = SampleMailStore(now: now, pause: .zero)
        #expect(try await !store.open { _ in }.mailbox.messages.isEmpty)
        await store.use(.empty)
        #expect(try await store.open { _ in }.mailbox.messages.isEmpty)
        await store.use(.offline)
        #expect(try await store.open { _ in }.isOffline)
        await store.use(.full)
        #expect(try await store.open { _ in }.mailbox.isFull)
        await store.use(.noKey)
        await #expect(throws: MailStoreError.noKey) { try await store.open { _ in } }
        await store.use(.failed)
        await #expect(throws: MailStoreError.unavailable) { try await store.open { _ in } }
    }

    @Test func theFirstDownloadReportsItsProgress() async throws {
        let store = SampleMailStore(scene: .download, now: now, pause: .zero)
        let seen = Seen()
        _ = try await store.open { download in Task { await seen.add(download.fraction) } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await seen.fractions.max() ?? 0 > 0.9)
    }

    @Test func everyAttachmentHasRealBytes() async throws {
        let store = SampleMailStore(now: now, pause: .zero)
        let attachments = try await store.open { _ in }.mailbox.messages.flatMap(\.attachments)
        #expect(!attachments.isEmpty)
        for attachment in attachments {
            let data = try await store.data(of: attachment.id)
            #expect(Int64(data.count) == attachment.size)
            #expect(data.count > 100)
        }
    }

    @Test func noSampleSenderIsARealDomain() {
        for message in SampleMail(now: now).mailbox.messages where !message.isUnreadable {
            for address in [message.from] + message.to {
                #expect(address.domain == "usetotality.com" || address.domain.hasSuffix(".example"))
            }
        }
    }

    private actor Seen {
        var fractions: [Double] = []
        func add(_ fraction: Double) { fractions.append(fraction) }
    }
}
