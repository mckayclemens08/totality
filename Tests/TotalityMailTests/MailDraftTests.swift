import Foundation
import Testing
@testable import TotalityMail

@Suite struct MailDraftTests {
    private let now = Date(timeIntervalSince1970: 1_793_870_000)
    private let me = "mckay@usetotality.com"
    private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
    private let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
    private let priya = MailAddress(name: "Priya Raman", address: "priya@usetotality.com")

    private func message(
        from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], subject: String = "Saturday's hike",
        replyTo: [MailAddress] = [], body: String = "Are we still on for 7?\nI'll bring the permit."
    ) -> MailMessage {
        MailMessage(
            conversationID: UUID(), from: from, to: to, cc: cc, subject: subject, date: now, body: .plain(body),
            route: .betweenAccounts, marks: MailMarks(), replyTo: replyTo, messageID: "hike-2@usetotality.com",
            references: ["hike-1@usetotality.com"]
        )
    }

    @Test func aReplyGoesToTheSenderAndQuotesThem() {
        let original = message(from: dana, to: [MailAddress(address: me), sam])
        let reply = MailDraft.reply(to: original, me: me)
        #expect(reply.to == [dana])
        #expect(reply.cc.isEmpty)
        #expect(reply.subject == "Re: Saturday's hike")
        #expect(reply.body.contains("Dana Whitfield wrote:\n> Are we still on for 7?\n> I'll bring the permit."))
        #expect(reply.origin == MailDraftOrigin(kind: .reply, message: original.id, messageID: "hike-2@usetotality.com", references: ["hike-1@usetotality.com"]))
    }

    @Test func aReplyFollowsReplyTo() {
        let original = message(from: dana, to: [MailAddress(address: me)], replyTo: [priya])
        #expect(MailDraft.reply(to: original, me: me).to == [priya])
    }

    @Test func replyingToYourOwnMessageGoesToWhoItWentTo() {
        let mine = message(from: MailAddress(address: me), to: [dana, sam])
        #expect(MailDraft.reply(to: mine, me: me).to == [dana, sam])
    }

    @Test func replyAllLeavesYouOutInAnyCaseOrTag() {
        let original = message(
            from: dana, to: [MailAddress(address: "McKay+Hikes@usetotality.com"), sam],
            cc: [priya, MailAddress(address: me), sam]
        )
        let reply = MailDraft.replyAll(to: original, me: me)
        #expect(reply.to == [dana])
        #expect(reply.cc == [sam, priya])
    }

    @Test(arguments: [
        ("Saturday's hike", "Re: Saturday's hike"),
        ("Re: Saturday's hike", "Re: Saturday's hike"),
        ("RE: Saturday's hike", "RE: Saturday's hike"),
        ("Re[2]: Saturday's hike", "Re[2]: Saturday's hike"),
        ("AW: Wanderung am Samstag", "AW: Wanderung am Samstag"),
        ("Fwd: Permit", "Re: Fwd: Permit"),
    ])
    func noReReInSubjects(subject: String, expected: String) {
        #expect(MailDraft.reply(to: message(from: dana, to: [], subject: subject), me: me).subject == expected)
    }

    @Test func forwardingCarriesTheTextAndNamesTheOriginal() {
        let original = message(from: dana, to: [MailAddress(address: me)], subject: "Fwd: Permit")
        let permit = MailDraftAttachment(name: "permit.pdf", mimeType: "application/pdf", data: Data("%PDF permit".utf8))
        let forward = MailDraft.forward(original, attachments: [permit])
        #expect(forward.subject == "Fwd: Permit")
        #expect(MailDraft.forward(message(from: dana, to: [])).subject == "Fwd: Saturday's hike")
        #expect(forward.to.isEmpty)
        #expect(forward.body.contains("---------- Forwarded message ----------\nFrom: Dana Whitfield <dana@usetotality.com>"))
        #expect(forward.body.hasSuffix("Are we still on for 7?\nI'll bring the permit."))
        #expect(forward.attachments == [permit])
        #expect(forward.origin?.kind == .forward)
    }

    @Test func recipientsCountOnceAndStopAtTen() throws {
        let draft = MailDraft(to: [dana, sam], cc: [MailAddress(address: "DANA@usetotality.com")], bcc: [priya])
        #expect(draft.recipients == [dana, sam, priya])
        try draft.checkRecipients()
        #expect(throws: MailSendError.noRecipients) { try MailDraft(subject: "Notes").checkRecipients() }
        let eleven = (1...11).map { MailAddress(address: "hiker\($0)@usetotality.com") }
        #expect(throws: MailSendError.tooManyRecipients(11)) { try MailDraft(to: eleven).checkRecipients() }
    }

    @Test func addressesAreCheckedBeforeTheyreWritten() {
        #expect(MailAddress(address: "dana@usetotality.com").isWellFormed)
        #expect(MailAddress(address: "dana+hikes@usetotality.com").totalityName == "dana")
        #expect(MailAddress(address: "Dana@UseTotality.com").totalityName == "dana")
        #expect(MailAddress(address: "dana@usetotality.com.evil.example").totalityName == nil)
        for bad in ["dana", "dana@", "@usetotality.com", "dana@usetotality", "dana smith@usetotality.com", "dana@usetotality.com\r\nBcc: x@y.z", "<dana@usetotality.com>"] {
            #expect(!MailAddress(address: bad).isWellFormed, "\(bad)")
        }
    }
}
