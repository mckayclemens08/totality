import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

private let gmail = OutsideAccountLabel(id: UUID(), provider: .gmail, address: "mckay.clemens@gmail.com")
private let icloud = OutsideAccountLabel(id: UUID(), provider: .icloud, address: "mckay@icloud.com")
private let now = Date(timeIntervalSince1970: 1_794_000_000)

private func message(
    _ subject: String, from: MailAddress = MailAddress(name: "Rosa Delgado", address: "rosa@delgado-studio.com"),
    account: OutsideAccountLabel? = gmail, marks: MailMarks = MailMarks(isUnread: true), at date: Date = now
) -> MailMessage {
    var message = MailMessage(
        conversationID: UUID(), from: from, to: [MailAddress(address: "mckay.clemens@gmail.com")], subject: subject,
        date: date, body: .plain("The drawings for the kitchen are attached."), route: nil, marks: marks
    )
    message.outsideAccount = account
    return message
}

private func mailbox(_ messages: [MailMessage]) -> Mailbox {
    var box = Mailbox()
    box.messages = messages
    return box
}

private func defaults() -> UserDefaults {
    let name = "gmail-push-tests-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}

@Suite struct GmailPushTests {
    @Test func notifiesOnlyNewUnreadGmailInTheInbox() {
        let old = message("Invoice 2041", at: now.addingTimeInterval(-3600))
        let before = mailbox([old])
        let fresh = message("Kitchen drawings")
        let after = mailbox([
            old, fresh,
            message("Read already", marks: MailMarks(isUnread: false)),
            message("Archived", marks: MailMarks(folder: .archive, isUnread: true)),
            message("From iCloud", account: icloud),
            message("Totality mail", account: nil),
        ])
        let notes = NewMailNote.notes(before: before, after: after, details: true)
        #expect(notes == [NewMailNote(
            id: fresh.id, title: "Rosa Delgado", subtitle: "New email \u{00B7} Gmail", body: "Kitchen drawings",
            conversationID: fresh.conversationID, account: gmail.id
        )])
    }

    @Test func newMailOnlySaysWhichAccount() {
        let fresh = message("Kitchen drawings")
        let notes = NewMailNote.notes(before: mailbox([]), after: mailbox([fresh]), details: false)
        #expect(notes.map(\.title) == ["New email"])
        #expect(notes.map(\.subtitle) == ["New email \u{00B7} Gmail"])
        #expect(notes.map(\.body) == ["mckay.clemens@gmail.com"])
    }

    /// Everything in the Inbox rings, including Gmail's Promotions, Social and Updates tabs (owner, 2026-11-26).
    @Test func mailInAGmailTabStillRings() {
        var promotion = message("Tick Tock: Don't miss these prices", from: MailAddress(name: "Fossil", address: "fossil@email.fossil.com"))
        promotion.outsideLabels = ["CATEGORY_PROMOTIONS"]
        var social = message("Maya tagged you in a photo", from: MailAddress(name: "Instagram", address: "no-reply@mail.instagram.com"))
        social.outsideLabels = ["CATEGORY_SOCIAL"]
        let primary = message("Kitchen drawings")
        let after = mailbox([promotion, social, primary])
        let notes = NewMailNote.notes(before: mailbox([]), after: after, details: true)
        #expect(Set(notes.map(\.id)) == [primary.id, social.id, promotion.id])
        let listed = after.conversations(in: .inbox).map(\.id)
        #expect(notes.allSatisfy { listed.contains($0.conversationID) }, "Every alert opens to a conversation the Inbox shows")
    }

    @Test func alertsGroupByAccount() {
        let other = OutsideAccountLabel(id: UUID(), provider: .gmail, address: "studio@gmail.com")
        let notes = NewMailNote.notes(
            before: mailbox([]), after: mailbox([message("One"), message("Two", account: other)]), details: true
        )
        #expect(Set(notes.map(\.account)) == [gmail.id, other.id])
    }

    @Test func aBurstIsCappedNewestFirst() {
        let burst = (0..<8).map { message("Update \($0)", at: now.addingTimeInterval(Double($0))) }
        let notes = NewMailNote.notes(before: mailbox([]), after: mailbox(burst), details: true)
        #expect(notes.map(\.body) == ["Update 7", "Update 6", "Update 5", "Update 4", "Update 3"])
    }

    @Test func anEmptySubjectSaysSo() {
        let fresh = message("  ")
        #expect(NewMailNote.notes(before: mailbox([]), after: mailbox([fresh]), details: true).first?.body == "No subject")
    }

    @Test func settingsStartOnWithDetails() {
        let settings = GmailPushSettings(defaults: defaults())
        #expect(settings.isOn && settings.showsDetails)
        settings.isOn = false
        settings.showsDetails = false
        #expect(!settings.isOn && !settings.showsDetails)
    }

    @Test func watchesRenewTwoDaysBeforeTheyLapse() {
        let book = GmailWatchBook(defaults: defaults())
        let account = UUID()
        #expect(book.needsRenewal(account, now: now))
        book.set(account, expiry: now.addingTimeInterval(7 * 86_400))
        #expect(!book.needsRenewal(account, now: now))
        #expect(!book.needsRenewal(account, now: now.addingTimeInterval(4.9 * 86_400)))
        #expect(book.needsRenewal(account, now: now.addingTimeInterval(5.1 * 86_400)))
        #expect(book.watched() == [account])
        book.set(account, expiry: nil)
        #expect(book.watched().isEmpty)
        #expect(!book.needsAllow(account))
        book.setNeedsAllow(account, true)
        #expect(book.needsAllow(account))
        book.setNeedsAllow(account, false)
        #expect(!book.needsAllow(account))
    }

    @Test func onlyAGoogleTopicNameTurnsItOn() {
        let push = PushClient { "token" }
        #expect(GmailPushPlan(topic: "projects/turnkey-point-514103-d9/topics/gmail-push", push: push) != nil)
        for bad in [nil, "", "gmail-push", "projects//topics/gmail-push", "projects/p/topics/x", "https://evil.example/topics/x"] {
            #expect(GmailPushPlan(topic: bad, push: push) == nil)
        }
    }

    @Test func theProfileSaysWhichApplePushService() {
        let development = Data("junk<key>aps-environment</key>\n\t\t<string>development</string>junk".utf8)
        let production = Data("junk<key>aps-environment</key>\n\t\t<string>production</string>junk".utf8)
        #expect(PushClient.sandbox(inProfile: development))
        #expect(!PushClient.sandbox(inProfile: production))
        #expect(PushClient.sandbox(inProfile: Data()))
        #expect(PushClient.hex(Data([0x00, 0xab, 0xff])) == "00abff")
    }
}
