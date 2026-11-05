import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// A store that counts what reached it, and sends however it's told to.
private actor CountingStore: MailStore {
    var mailbox: Mailbox
    var answer: Result<MailSendResult, MailStoreError>?
    private(set) var sends: [MailDraft] = []
    private(set) var saves: [MailDraft] = []
    private(set) var discards: [UUID] = []
    private(set) var settings: [MailSettings] = []

    init(_ mailbox: Mailbox) { self.mailbox = mailbox }

    func set(answer: Result<MailSendResult, MailStoreError>) { self.answer = answer }

    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening {
        MailOpening(mailbox: mailbox)
    }

    func save(_ marks: [UUID: MailMarks]) async throws {}
    func save(_ settings: MailSettings) async throws {
        self.settings.append(settings)
        mailbox.settings = settings
    }
    func erase(_ messages: Set<UUID>) async throws {}
    func data(of attachment: UUID) async throws -> Data { Data("trail map".utf8) }

    func save(_ draft: MailDraft) async throws {
        saves.append(draft)
        mailbox.drafts.removeAll { $0.id == draft.id }
        mailbox.drafts.insert(draft, at: 0)
    }

    func discard(draft: UUID) async throws {
        discards.append(draft)
        mailbox.drafts.removeAll { $0.id == draft }
    }

    func send(_ draft: MailDraft) async throws -> MailSendResult {
        sends.append(draft)
        switch answer {
        case .failure(let error): throw error
        case .success(let result):
            mailbox.drafts.removeAll { $0.id == draft.id }
            if let remaining = result.remaining { mailbox.drafts.insert(remaining, at: 0) }
            return result
        case nil:
            mailbox.drafts.removeAll { $0.id == draft.id }
            let everyone = draft.recipients.map { MailSendResult.Recipient(address: $0, outcome: .delivered) }
            return MailSendResult(recipients: everyone, sent: UUID(), keptCopy: true, remaining: nil)
        }
    }
}

@MainActor
@Suite struct MailComposerTests {
    private let me = MailAddress(name: "McKay", address: "mckay@usetotality.com")
    private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
    private let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
    private let date = Date(timeIntervalSince1970: 1_793_870_000)

    private func mailbox() -> Mailbox {
        let trail = UUID()
        return Mailbox(address: me.address, messages: [
            MailMessage(
                conversationID: trail, from: dana, to: [me], subject: "Saturday trailhead plan", date: date.addingTimeInterval(-7_200),
                body: .plain("Are we still on for Saturday?"), route: .betweenAccounts, marks: MailMarks()
            ),
            MailMessage(
                conversationID: trail, from: me, to: [dana], cc: [sam], subject: "Re: Saturday trailhead plan", date: date.addingTimeInterval(-3_600),
                body: .plain("Yes, coffee's on me."), route: .betweenAccounts, marks: MailMarks(folder: .sent)
            ),
            MailMessage(
                conversationID: UUID(), from: MailAddress(name: "Rewards Desk", address: "winner@claim-your-reward.example"), to: [me],
                subject: "You've won", date: date, body: .plain("Claim now."), route: .outside, marks: MailMarks(folder: .spam)
            ),
        ])
    }

    private func ready(_ store: CountingStore) async -> MailModel {
        let model = MailModel(store: store) { date }
        await model.load()
        return model
    }

    // MARK: Undo

    @Test("Undo inside the window stops the send, and nothing reaches the store")
    func undoCancelsTheSend() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let composer = MailComposer(draft: MailDraft(to: [dana], subject: "Lost Lake", body: "7:30 at the trailhead."), model: model, hold: .seconds(60))

        await composer.pressSend()
        guard case .holding = composer.phase else {
            Issue.record("Expected the Undo window, got \(composer.phase)")
            return
        }
        composer.undoSend()
        await composer.waitForSend()

        #expect(composer.phase == .writing)
        #expect(await store.sends.isEmpty)
        // Pressing saved it, so a quit inside the window can't lose it.
        #expect(model.mailbox.drafts.map(\.body) == ["7:30 at the trailhead."])
    }

    @Test("Once the window passes it sends, and the draft is gone")
    func sendsAfterTheWindow() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let draft = MailDraft(to: [dana], subject: "Lost Lake", body: "7:30 at the trailhead.")
        let composer = MailComposer(draft: draft, model: model, hold: .zero)

        await composer.pressSend()
        await composer.waitForSend()

        #expect(await store.sends.map(\.id) == [draft.id])
        guard case .finished(let result) = composer.phase else {
            Issue.record("Expected it to finish, got \(composer.phase)")
            return
        }
        #expect(result.deliveredToEveryone)
        #expect(model.mailbox.drafts.isEmpty)
    }

    @Test("Mail uses one Undo time for its actions and for sending")
    func oneUndoTime() {
        #expect(MailTiming.undo == .seconds(6))
    }

    // MARK: When it doesn't send

    @Test("A send that can't start keeps the draft with its words, and says why")
    func failedSendKeepsTheDraft() async throws {
        let store = CountingStore(mailbox())
        await store.set(answer: .failure(.offline))
        let model = await ready(store)
        let draft = MailDraft(to: [dana], subject: "Lost Lake", body: "7:30 at the trailhead.")
        let composer = MailComposer(draft: draft, model: model, hold: .zero)

        await composer.pressSend()
        await composer.waitForSend()

        #expect(composer.phase == .writing)
        #expect(composer.problem == MailWording.notSent(MailStoreError.offline))
        #expect(composer.draft == draft)
        #expect(model.mailbox.drafts == [draft])
        #expect(await store.mailbox.drafts == [draft])
    }

    @Test("Nobody reached: it stays a draft with everything written, and each person's reason is there")
    func nobodyReachedKeepsTheDraft() async throws {
        let store = CountingStore(mailbox())
        let draft = MailDraft(to: [dana, sam], subject: "Lost Lake", body: "7:30 at the trailhead.")
        let result = MailSendResult(
            recipients: [.init(address: dana, outcome: .offline), .init(address: sam, outcome: .outsideNotYet)],
            sent: nil, keptCopy: false, remaining: draft
        )
        await store.set(answer: .success(result))
        let model = await ready(store)
        let composer = MailComposer(draft: draft, model: model, hold: .zero)

        await composer.pressSend()
        await composer.waitForSend()

        #expect(composer.phase == .finished(result))
        #expect(model.mailbox.drafts == [draft])
        composer.keepWriting()
        #expect(composer.phase == .writing)
        #expect(composer.draft.body == "7:30 at the trailhead.")
        #expect(MailWording.outcome(.outsideNotYet).contains("Sending outside Totality isn't on yet"))
    }

    @Test("Some reached: the outside address stays on the draft, and the words stay too")
    func partialKeepsTheRest() async throws {
        let store = CountingStore(mailbox())
        let draft = MailDraft(to: [dana, sam], subject: "Lost Lake", body: "7:30 at the trailhead.")
        var rest = draft
        rest.to = [sam]
        await store.set(answer: .success(MailSendResult(
            recipients: [.init(address: dana, outcome: .delivered), .init(address: sam, outcome: .outsideNotYet)],
            sent: UUID(), keptCopy: true, remaining: rest
        )))
        let model = await ready(store)
        let composer = MailComposer(draft: draft, model: model, hold: .zero)

        await composer.pressSend()
        await composer.waitForSend()

        #expect(composer.draft == rest)
        #expect(model.mailbox.drafts == [rest])
        // A later autosave has nothing new to write, so it can't put Dana back.
        await composer.autosave()
        #expect(await store.saves.last == draft)
    }

    @Test("Only outside addresses never starts the window, and says why")
    func onlyOutside() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let composer = MailComposer(draft: MailDraft(to: [sam], subject: "Deck", body: "Plans attached."), model: model, hold: .zero)
        await composer.pressSend()
        #expect(composer.phase == .writing)
        #expect(composer.problem == MailWording.outsideNotYet)
        #expect(await store.sends.isEmpty)
    }

    @Test("Something that isn't an address is caught before the window")
    func notAnAddress() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let composer = MailComposer(draft: MailDraft(subject: "Lost Lake", body: "7:30."), model: model, hold: .zero)
        composer.typed[.to] = "dana@usetotality.com, dana at home"
        await composer.pressSend()
        #expect(composer.phase == .writing)
        #expect(composer.problem?.contains("isn't an email address") == true)
        #expect(await store.sends.isEmpty)
    }

    // MARK: Suggestions

    @Test("Suggestions come only from mail on this device, never Spam or the person themselves")
    func suggestionsFromTheMailbox() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let composer = MailComposer.new(in: model)

        composer.typed[.to] = "da"
        #expect(composer.suggestions(for: .to) == [dana])
        composer.typed[.to] = "Whit"
        #expect(composer.suggestions(for: .to) == [dana])
        composer.typed[.to] = "sam"
        #expect(composer.suggestions(for: .to) == [sam])
        composer.typed[.to] = "priya"
        #expect(composer.suggestions(for: .to).isEmpty)
        composer.typed[.to] = "winner"
        #expect(composer.suggestions(for: .to).isEmpty)
        composer.typed[.to] = "mck"
        #expect(composer.suggestions(for: .to).isEmpty)

        composer.choose(dana, for: .to)
        composer.typed[.cc] = "da"
        #expect(composer.suggestions(for: .cc).isEmpty)
        // Typing asked nothing of the store.
        #expect(await store.saves.isEmpty)
        #expect(await store.sends.isEmpty)
    }

    @Test("Typed addresses become chips at a comma, with names kept")
    func typedAddresses() async throws {
        let model = await ready(CountingStore(mailbox()))
        let composer = MailComposer.new(in: model)
        composer.typed[.to] = "Dana Whitfield <dana@usetotality.com>,"
        composer.typing(in: .to)
        #expect(composer.draft.to == [dana])
        #expect(composer.typed[.to] == "")
        composer.typed[.cc] = "dana@usetotality.com"
        composer.commit(.cc)
        #expect(composer.draft.cc.isEmpty)
    }

    // MARK: Drafts and signature

    @Test("A new message's signature alone isn't saved, and a change is, once")
    func autosaveOnlyChanges() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        await model.setSignature("McKay\nSent from Totality")
        let composer = MailComposer.new(in: model)
        #expect(composer.draft.body == "\n\n-- \nMcKay\nSent from Totality")

        await composer.autosave()
        #expect(await store.saves.isEmpty)

        composer.draft.subject = "Lost Lake"
        await composer.autosave()
        await composer.autosave()
        #expect(await store.saves.map(\.subject) == ["Lost Lake"])
        #expect(await store.settings.last?.signature == "McKay\nSent from Totality")
    }

    @Test("The signature sits above a reply's quote")
    func signatureAboveTheQuote() async throws {
        let model = await ready(CountingStore(mailbox()))
        await model.setSignature("McKay")
        let original = model.mailbox.messages[0]
        let composer = MailComposer.reply(to: original, all: false, in: model)
        #expect(composer.draft.to == [dana])
        #expect(composer.draft.body.hasPrefix("\n\n-- \nMcKay\n\nOn "))
    }

    @Test("Discard removes the draft through the model")
    func discard() async throws {
        let store = CountingStore(mailbox())
        let model = await ready(store)
        let composer = MailComposer(draft: MailDraft(to: [dana], subject: "Lost Lake", body: "7:30."), model: model)
        composer.draft.body = "7:30 at the trailhead."
        await composer.autosave()
        #expect(model.mailbox.drafts.count == 1)
        await composer.discard()
        #expect(composer.phase == .discarded)
        #expect(model.mailbox.drafts.isEmpty)
        #expect(await store.discards == [composer.draft.id])
    }

    @Test("Settings saved before signatures existed still open")
    func oldSettingsDecode() throws {
        let old = Data(#"{"folders":[],"blockedSenders":[],"alwaysLoadImages":["dana@usetotality.com"]}"#.utf8)
        let settings = try JSONDecoder().decode(MailSettings.self, from: old)
        #expect(settings.signature == "")
        #expect(settings.alwaysLoadImages == ["dana@usetotality.com"])
    }

    @Test("Mail between accounts says it's sealed, never end-to-end encrypted")
    func honestLabels() async throws {
        let model = await ready(CountingStore(mailbox()))
        let composer = MailComposer(draft: MailDraft(to: [dana]), model: model)
        #expect(composer.routeNote?.text == "Sealed by your device. Totality's servers can't read it.")
        #expect(composer.routeNote?.isSealed == true)
        composer.add(sam, to: .cc)
        #expect(composer.routeNote?.text == MailWording.outsideNotYet)
        for outcome: MailSendResult.Outcome in [.delivered, .noSuchAddress, .outsideNotYet, .notAnAddress, .recipientFull, .tooBig, .offline, .failed] {
            #expect(!MailWording.outcome(outcome).localizedCaseInsensitiveContains("end-to-end"))
        }
    }
}
