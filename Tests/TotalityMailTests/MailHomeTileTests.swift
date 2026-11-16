import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// A store that keeps what reached it.
private actor TileStore: MailStore {
    let mailbox: Mailbox
    private(set) var saved: [[UUID: MailMarks]] = []
    private(set) var sent = 0
    private(set) var erased = 0

    init(_ mailbox: Mailbox) { self.mailbox = mailbox }

    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening { MailOpening(mailbox: mailbox) }
    func save(_ marks: [UUID: MailMarks]) async throws { saved.append(marks) }
    func save(_ settings: MailSettings) async throws {}
    func erase(_ messages: Set<UUID>) async throws { erased += 1 }
    func data(of attachment: UUID) async throws -> Data { Data() }
    func save(_ draft: MailDraft) async throws {}
    func discard(draft: UUID) async throws {}
    func send(_ draft: MailDraft) async throws -> MailSendResult {
        sent += 1
        return MailSendResult(recipients: [], sent: nil, keptCopy: false, remaining: nil)
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let me = "mckay@usetotality.com"
private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
private let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
private let priya = MailAddress(name: "Priya Natarajan", address: "priya@lakeviewclinic.example")
private let gmail = OutsideAccountLabel(id: UUID(), provider: .gmail, address: "mckay.clemens@gmail.com")

private func mail(
    _ from: MailAddress, _ subject: String, minutesAgo: Double, unread: Bool = true, body: String = "Are we still on?",
    folder: MailFolder = .inbox, account: OutsideAccountLabel? = nil
) -> MailMessage {
    var message = MailMessage(
        conversationID: UUID(), from: from, to: [MailAddress(address: me)], subject: subject,
        date: now.addingTimeInterval(-minutesAgo * 60), body: .plain(body), route: .betweenAccounts,
        marks: MailMarks(folder: folder, isUnread: unread)
    )
    message.outsideAccount = account
    return message
}

@MainActor
@Suite struct MailHomeTileTests {
    private func opened(_ messages: [MailMessage], outside: [OutsideAccountLabel] = []) async -> (MailModel, TileStore) {
        var mailbox = Mailbox(address: me, messages: messages)
        mailbox.outsideAccounts = outside
        let store = TileStore(mailbox)
        let model = MailModel(store: store, now: { now })
        await model.load()
        return (model, store)
    }

    // MARK: Medium

    @Test("Medium: up to four senders of unread mail, each with how much, newest first")
    func mediumFaces() async {
        let (model, _) = await opened([
            mail(dana, "Saturday", minutesAgo: 1),
            mail(sam, "Deck plans", minutesAgo: 2),
            mail(dana, "Sunday too", minutesAgo: 3),
            mail(priya, "Your appointment", minutesAgo: 4),
            mail(MailAddress(name: "Lena Brooks", address: "lena@brooksfarm.example"), "Eggs", minutesAgo: 5),
            mail(MailAddress(name: "Omar Haddad", address: "omar@haddad.example"), "Ride", minutesAgo: 6),
            mail(sam, "Read already", minutesAgo: 0, unread: false),
        ])
        #expect(model.homeUnreadConversations.count == 6)
        #expect(model.homeSenders.map(\.name) == ["Dana Whitfield", "Sam Ortiz", "Priya Natarajan", "Lena Brooks"])
        #expect(model.homeSenders.map(\.unread) == [2, 1, 1, 1])
        // A face opens that sender's newest unread.
        #expect(model.homeSenders[0].conversation == model.homeUnreadConversations[0].id)
    }

    @Test("Medium: each account's unread shows once there's an outside account")
    func mediumChips() async {
        let alone = await opened([mail(dana, "Saturday", minutesAgo: 1)]).0
        #expect(alone.homeAccounts.isEmpty)
        let (model, _) = await opened([
            mail(dana, "Saturday", minutesAgo: 1),
            mail(sam, "Deck plans", minutesAgo: 2, account: gmail),
            mail(priya, "Your appointment", minutesAgo: 3, account: gmail),
        ], outside: [gmail])
        #expect(model.homeAccounts.map(\.name) == ["Totality", "Gmail"])
        #expect(model.homeAccounts.map(\.unread) == [1, 2])
    }

    // MARK: Large

    @Test("Large: the four newest unread, never Spam")
    func largeRows() async {
        let (model, _) = await opened([
            mail(dana, "Saturday", minutesAgo: 1),
            mail(sam, "Deck plans", minutesAgo: 2),
            mail(priya, "Your appointment", minutesAgo: 3),
            mail(dana, "Sunday too", minutesAgo: 4),
            mail(sam, "Invoice", minutesAgo: 5),
            mail(sam, "You won a prize", minutesAgo: 0, folder: .spam),
            mail(priya, "Read already", minutesAgo: 0, unread: false),
        ])
        let rows = model.homeRows
        #expect(!rows.caughtUp)
        #expect(rows.conversations.map(\.subject) == ["Saturday", "Deck plans", "Your appointment", "Sunday too"])
    }

    @Test("Large: with nothing unread, all caught up and the three most recent")
    func largeCaughtUp() async {
        let (model, _) = await opened([
            mail(dana, "Saturday", minutesAgo: 1, unread: false),
            mail(sam, "Deck plans", minutesAgo: 2, unread: false),
            mail(priya, "Your appointment", minutesAgo: 3, unread: false),
            mail(dana, "Sunday too", minutesAgo: 4, unread: false),
        ])
        let rows = model.homeRows
        #expect(rows.caughtUp)
        #expect(rows.conversations.map(\.subject) == ["Saturday", "Deck plans", "Your appointment"])
        let empty = await opened([]).0
        #expect(empty.homeRows.caughtUp && empty.homeRows.conversations.isEmpty)
    }

    @Test("Large: Mark read and Archive from the tile change only that conversation, and never delete")
    func largeActions() async {
        let (model, store) = await opened([mail(dana, "Saturday", minutesAgo: 1), mail(sam, "Deck plans", minutesAgo: 2)])
        let first = model.homeRows.conversations[0]
        await model.performFromHome(.markRead, on: first)
        #expect(model.homeRows.conversations.map(\.subject) == ["Deck plans"])
        await model.performFromHome(.archive, on: model.homeRows.conversations[0])
        #expect(model.homeUnreadConversations.isEmpty)
        #expect(model.mailbox.messages.first { $0.subject == "Deck plans" }?.marks.folder == .archive)
        #expect(await store.saved.count == 2)
        #expect(await store.erased == 0)
        #expect(await store.sent == 0)
    }

    // MARK: Square

    @Test("Square: the newest unread is open, Next goes through the rest and round again")
    func squareNext() async {
        let (model, _) = await opened([
            mail(dana, "Saturday", minutesAgo: 1),
            mail(sam, "Deck plans", minutesAgo: 2),
            mail(priya, "Your appointment", minutesAgo: 3),
        ])
        #expect(model.homeOpen?.subject == "Saturday")
        model.showNextOnHome()
        #expect(model.homeOpen?.subject == "Deck plans")
        model.showNextOnHome()
        #expect(model.homeOpen?.subject == "Your appointment")
        model.showNextOnHome()
        #expect(model.homeOpen?.subject == "Saturday")
    }

    @Test("Square: reading it there doesn't mark it read, and archiving moves on to the next")
    func squareArchive() async {
        let (model, store) = await opened([mail(dana, "Saturday", minutesAgo: 1), mail(sam, "Deck plans", minutesAgo: 2)])
        model.showNextOnHome()
        #expect(model.homeOpen?.subject == "Deck plans")
        #expect(await store.saved.isEmpty)
        await model.performFromHome(.archive, on: model.homeOpen!)
        #expect(model.homeOpen?.subject == "Saturday")
        #expect(model.homeNext == nil)
        await model.performFromHome(.archive, on: model.homeOpen!)
        #expect(model.homeOpen == nil)
    }

    @Test("Square: Reply asks Mail to open the conversation with a reply, and sends nothing")
    func squareReply() async {
        let (model, store) = await opened([mail(dana, "Saturday", minutesAgo: 1)])
        model.place = .folder(.sent)
        let id = model.homeOpen!.id
        model.requestReplyFromHome(id)
        #expect(model.place == .inbox)
        #expect(model.requestedConversation == id)
        #expect(model.requestedReply == id)
        #expect(await store.sent == 0)
    }

    @Test("Square: the first paragraphs as plain text, cut short when long")
    func squareOpening() {
        let short = mail(dana, "Saturday", minutesAgo: 1, body: "Hi Mckay,\n\nAre we   still on\nfor Saturday?\n\nDana\n\nSent from my phone")
        #expect(MailModel.opening(of: short) == "Hi Mckay,\n\nAre we still on for Saturday?\n\nDana")
        let long = mail(dana, "Notes", minutesAgo: 1, body: String(repeating: "The roof needs new flashing. ", count: 40))
        let opening = MailModel.opening(of: long)
        #expect(opening.count <= MailModel.homeCharacters + 1)
        #expect(opening.hasSuffix("…"))
    }

    @Test("Nothing that can't be opened shows as unread on the tiles")
    func unreadableStaysOff() async {
        var locked = mail(dana, "Saturday", minutesAgo: 1)
        locked = MailMessage(
            conversationID: locked.conversationID, from: dana, to: locked.to, subject: "Saturday", date: locked.date,
            body: .unreadable, route: .betweenAccounts, marks: MailMarks(isUnread: true)
        )
        let (model, _) = await opened([locked, mail(sam, "Deck plans", minutesAgo: 2)])
        #expect(model.homeUnreadConversations.map(\.subject) == ["Deck plans"])
    }
}
