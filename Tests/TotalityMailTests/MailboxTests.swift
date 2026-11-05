import Foundation
import Testing
@testable import TotalityMail

private let me = MailAddress(name: "McKay", address: "mckay@usetotality.com")
private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
private let shop = MailAddress(name: "Harbor Street Books", address: "letters@harborstreetbooks.example")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func message(
    in conversation: UUID = UUID(), from: MailAddress = dana, subject: String = "Saturday trailhead plan", text: String = "Are we still on?",
    minutesAgo: Double = 0, proof: MailProof = .proved, marks: MailMarks = MailMarks()
) -> MailMessage {
    MailMessage(
        conversationID: conversation, from: from, to: [me], subject: subject, date: now.addingTimeInterval(-minutesAgo * 60),
        body: .plain(text), route: .outside, proof: proof, marks: marks
    )
}

@Suite struct MailboxTests {
    @Test func aConversationListsOnceWithItsNewestMessageFirst() {
        let thread = UUID()
        let box = Mailbox(address: me.address, messages: [
            message(in: thread, minutesAgo: 30),
            message(in: thread, from: me, minutesAgo: 20, marks: MailMarks(folder: .sent)),
            message(in: thread, subject: "Re: Saturday trailhead plan", minutesAgo: 10),
            message(from: shop, subject: "What we're reading in November", minutesAgo: 60),
        ])
        let inbox = box.conversations(in: .inbox)
        #expect(inbox.count == 2)
        #expect(inbox[0].messages.count == 3)
        #expect(inbox[0].subject == "Re: Saturday trailhead plan")
        #expect(inbox[1].subject == "What we're reading in November")
    }

    @Test func starredIsAViewAndNotAPlaceMailMovesTo() {
        let box = Mailbox(messages: [
            message(marks: MailMarks(folder: .archive, isStarred: true)),
            message(marks: MailMarks(folder: .trash, isStarred: true)),
            message(),
        ])
        #expect(box.conversations(in: .starred).count == 1)
        #expect(box.conversations(in: .starred)[0].latest.marks.folder == .archive)
    }

    @Test func trashAndSpamStayOutOfEverywhereElse() {
        let thread = UUID()
        let box = Mailbox(messages: [
            message(in: thread, minutesAgo: 10),
            message(in: thread, marks: MailMarks(folder: .trash)),
        ])
        #expect(box.conversations(in: .inbox)[0].messages.count == 1)
        #expect(box.conversations(in: .folder(.trash))[0].messages.count == 1)
    }

    @Test func searchFindsAWordInTheBodyAndIgnoresCase() {
        let box = Mailbox(messages: [message(text: "The forecast says clear until noon"), message(subject: "Lease", text: "Sign by December 15")])
        #expect(box.conversations(in: .inbox, matching: "FORECAST").count == 1)
        #expect(box.conversations(in: .inbox, matching: "harbor").isEmpty)
        #expect(box.conversations(in: .inbox, matching: "   ").count == 2)
    }

    @Test func archivingLeavesTheSentCopyInSent() {
        let thread = UUID()
        let box = Mailbox(messages: [
            message(in: thread, minutesAgo: 10),
            message(in: thread, from: me, marks: MailMarks(folder: .sent)),
        ])
        var after = box
        after.apply(box.marks(after: .archive, on: box.conversations(in: .inbox), now: now))
        #expect(after.conversations(in: .inbox).isEmpty)
        #expect(after.conversations(in: .folder(.archive)).count == 1)
        #expect(after.conversations(in: .folder(.sent)).count == 1)
    }

    @Test func trashTakesTheWholeConversationAndRestoringPutsEachMessageBack() {
        let thread = UUID()
        let box = Mailbox(messages: [
            message(in: thread, minutesAgo: 10),
            message(in: thread, from: me, marks: MailMarks(folder: .sent)),
        ])
        var after = box
        after.apply(box.marks(after: .trash, on: box.conversations(in: .inbox), now: now))
        #expect(after.messages.allSatisfy { $0.marks.folder == .trash && $0.marks.trashedAt == now })
        after.apply(after.marks(after: .move(.inbox), on: after.conversations(in: .folder(.trash)), now: now))
        #expect(after.messages.map(\.marks) == box.messages.map(\.marks))
    }

    @Test func markingUnreadTouchesOnlyTheNewestMessage() {
        let thread = UUID()
        let box = Mailbox(messages: [message(in: thread, minutesAgo: 10), message(in: thread)])
        let changed = box.marks(after: .markUnread, on: box.conversations(in: .inbox), now: now)
        #expect(changed.count == 1)
        #expect(changed[box.conversations(in: .inbox)[0].latest.id]?.isUnread == true)
    }

    @Test func anUnchangedMessageIsNotAChange() {
        let box = Mailbox(messages: [message()])
        #expect(box.marks(after: .markRead, on: box.conversations(in: .inbox), now: now).isEmpty)
    }

    @Test func trashExpiresAfterExactlyThirtyDays() {
        let young = message(marks: MailMarks(folder: .trash, trashedAt: now.addingTimeInterval(-Mailbox.trashLifetime + 60)))
        let old = message(marks: MailMarks(folder: .trash, trashedAt: now.addingTimeInterval(-Mailbox.trashLifetime)))
        #expect(Mailbox(messages: [young, old]).expired(at: now) == [old.id])
    }

    @Test func blockingMovesOnlyThatSendersInboxMail() {
        let box = Mailbox(messages: [
            message(from: shop),
            message(from: shop, marks: MailMarks(folder: .archive)),
            message(from: dana),
        ])
        let changed = box.marksAfterBlocking(shop)
        #expect(changed.count == 1)
        #expect(changed.values.first?.folder == .spam)
    }

    @Test func alwaysLoadOnlyCountsForAMessageThatProvesItsSender() {
        var box = Mailbox(settings: MailSettings(alwaysLoadImages: [shop.key]))
        #expect(box.loadsImages(for: message(from: shop)))
        #expect(!box.loadsImages(for: message(from: shop, proof: .unproved)))
        #expect(!box.loadsImages(for: message(from: shop, marks: MailMarks(folder: .spam))))
        box.settings.alwaysLoadImages = []
        #expect(!box.loadsImages(for: message(from: shop)))
    }

    @Test func alwaysLoadIsOfferedOnlyWhereItCanWork() {
        let box = Mailbox()
        #expect(box.allowsAlwaysLoad(for: message(from: shop)))
        #expect(!box.allowsAlwaysLoad(for: message(from: shop, proof: .unproved)))
        #expect(!box.allowsAlwaysLoad(for: message(from: shop, marks: MailMarks(folder: .spam))))
    }

    @Test func aRowNamesTheOtherPersonOrWhoItWentTo() {
        let thread = UUID()
        let conversation = Mailbox(messages: [
            message(in: thread, minutesAgo: 10),
            MailMessage(conversationID: thread, from: me, to: [dana], subject: "Re", date: now, body: .plain("Yes"), route: .outside, marks: MailMarks(folder: .sent)),
        ]).conversations(in: .folder(.sent))[0]
        #expect(conversation.heading(me: me.address, showingRecipients: false) == "Dana Whitfield")
        #expect(conversation.heading(me: me.address, showingRecipients: true) == "To Dana Whitfield")
    }

    @Test func aSentRowNamesWhoTheReaderWroteToEvenAfterAReply() {
        let thread = UUID()
        let conversation = Mailbox(messages: [
            MailMessage(conversationID: thread, from: me, to: [dana], subject: "Re", date: now.addingTimeInterval(-60), body: .plain("Yes"), route: .outside, marks: MailMarks(folder: .sent)),
            message(in: thread),
        ]).conversations(in: .folder(.sent))[0]
        #expect(conversation.heading(me: me.address, showingRecipients: true) == "To Dana Whitfield")
    }

    @Test func aPlaceCountsOnlyTheUnreadMailItHolds() {
        let thread = UUID()
        let box = Mailbox(messages: [
            MailMessage(conversationID: thread, from: me, to: [dana], subject: "Re", date: now, body: .plain("Yes"), route: .outside, marks: MailMarks(folder: .sent)),
            message(in: thread, marks: MailMarks(isUnread: true)),
        ])
        #expect(box.unreadCount(in: .inbox) == 1)
        #expect(box.unreadCount(in: .folder(.sent)) == 0)
    }

    @Test func aMessageThatWontOpenClaimsNothing() {
        let conversation = Mailbox(messages: [.unreadable(date: now, marks: MailMarks())]).conversations(in: .inbox)[0]
        #expect(conversation.isUnreadable)
        #expect(conversation.heading(me: me.address, showingRecipients: false) == "Can't be opened")
    }

    @Test func onlySafeKindsPreview() {
        func kind(_ mime: String) -> MailAttachment.Preview? { MailAttachment(name: "file", mimeType: mime, size: 1).preview }
        #expect(kind("IMAGE/PNG") == .image)
        #expect(kind("application/pdf") == .pdf)
        #expect(kind("text/plain") == .text)
        #expect(kind("text/html") == nil)
        #expect(kind("image/svg+xml") == nil)
    }
}

@Suite struct MailWordingTests {
    @Test func theRouteLinesAreTheSpecsOwnWords() {
        #expect(MailWording.route(.betweenAccounts) == "Sealed by your device. Totality's servers can't read it.")
        #expect(MailWording.route(.outside) == "Email isn't end-to-end encrypted. Totality's server handles it as it arrives or leaves, and so do Cloudflare and the mail servers it passes through. Cloudflare's log keeps the subject and addresses of mail to and from outside. The stored copy is sealed.")
    }

    @Test func receivedMailSaysTheSendersDeviceSealedIt() {
        let sent = MailMessage(
            conversationID: UUID(), from: MailAddress(address: "mckay@usetotality.com"), to: [MailAddress(address: "dana@usetotality.com")],
            subject: "Lost Lake", date: Date(), body: .plain("Meet at 7."), route: .betweenAccounts, marks: MailMarks(folder: .sent, isUnread: false)
        )
        let received = sent.travelled(.betweenAccounts, proof: .proved, sentBy: MailAddress(address: "mckay@usetotality.com"))
        #expect(MailWording.route(for: received) == "Sealed by the sender's device. Totality's servers carry it but can't open it.")
        #expect(MailWording.route(for: sent) == "Sealed by your device. Totality's servers can't read it.")
        #expect(MailWording.route(for: .unreadable(date: Date(), marks: MailMarks())) == nil)
    }

    @Test func unprovedReceivedMailNeverSaysTheSendersDeviceSealedIt() {
        let sent = MailMessage(
            conversationID: UUID(), from: MailAddress(address: "mckay@usetotality.com"), to: [MailAddress(address: "dana@usetotality.com")],
            subject: "Permit fee", date: Date(), body: .plain("Pay it to this account instead."), route: .betweenAccounts,
            marks: MailMarks(folder: .sent, isUnread: false)
        )
        let sentBy = MailAddress(address: "mckay@usetotality.com")
        let unproved = sent.travelled(.betweenAccounts, proof: .unproved, sentBy: sentBy)
        let changedKey = sent.travelled(.betweenAccounts, proof: .unproved, sentBy: sentBy, senderKeyChanged: true)
        // Proved can't come with a changed key from the store, but the line mustn't trust either alone.
        let provedButChanged = sent.travelled(.betweenAccounts, proof: .proved, sentBy: sentBy, senderKeyChanged: true)
        for message in [unproved, changedKey, provedButChanged] {
            #expect(MailWording.route(for: message) == "Totality couldn't confirm who sealed this.")
            #expect(MailWording.route(for: message) != MailWording.betweenAccountsReceived)
        }
        #expect(MailWording.warning(for: unproved) != nil)
        #expect(MailWording.warning(for: changedKey)?.contains("key has changed") == true)
    }

    @Test func aChangedKeyIsNamedInTheWarning() {
        let message = MailMessage(
            conversationID: UUID(), from: MailAddress(address: "mckay@usetotality.com"), to: [], subject: "Change of plan", date: Date(),
            body: .plain("Send the fee here."), route: .betweenAccounts, proof: .unproved, marks: MailMarks(),
            sentBy: MailAddress(address: "mckay@usetotality.com"), senderKeyChanged: true
        )
        #expect(MailWording.warning(for: message) == "This message says it's from mckay@usetotality.com, but their key has changed since you first heard from them, or couldn't be checked, so it couldn't be proved. Be careful with its links and attachments.")
    }

    @Test func nothingClaimsEndToEndEncryption() {
        #expect(!MailWording.route(.betweenAccounts).lowercased().contains("end-to-end"))
        #expect(!MailWording.betweenAccountsReceived.lowercased().contains("end-to-end"))
        #expect(!MailWording.betweenAccountsUnconfirmed.lowercased().contains("end-to-end"))
        #expect(!MailWording.keyChanged(MailAddress(address: "mckay@usetotality.com")).lowercased().contains("end-to-end"))
        #expect(MailWording.route(.outside).hasPrefix("Email isn't end-to-end encrypted."))
    }

    @Test func aWarningNamesTheDomainAndNotTheDisplayName() {
        let line = MailWording.unproved(MailAddress(name: "Ridgeline Credit Union", address: "security@ridgelinecu.example"))
        #expect(line.contains("ridgelinecu.example"))
        #expect(!line.contains("Ridgeline Credit Union"))
    }

    @Test func datesShortenWithDistance() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        let at = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        func text(days: Int) -> String {
            MailDate.short(calendar.date(byAdding: .day, value: -days, to: at)!, now: at, calendar: calendar)
        }
        #expect(text(days: 0).contains("12"))
        #expect(text(days: 1) == "Sun")
        #expect(text(days: 9).contains("Oct"))
        #expect(text(days: 400).contains("2025"))
    }
}
