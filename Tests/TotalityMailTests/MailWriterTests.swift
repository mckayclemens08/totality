import Foundation
import Testing
@testable import TotalityMail

/// What `MailWriter` writes has to come back through `MailParser` exactly as it was written, and
/// nothing a person types can add a header.
@Suite struct MailWriterTests {
    private let date = Date(timeIntervalSince1970: 1_793_870_000)
    private let message = UUID(uuidString: "c3a1e5f2-6b7d-4e8f-9a0b-1c2d3e4f5a6b")!
    private let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
    private let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
    private let renee = MailAddress(name: "Renée Østergaard", address: "renee@usetotality.com")
    private let priya = MailAddress(address: "priya@usetotality.com")

    private func parsed(_ raw: Data) -> ParsedMail {
        MailParser.parseMessage(raw, id: UUID(), received: date, marks: MailMarks())
    }

    @Test func aPlainMessageComesBackAsWritten() throws {
        let body = """
        Hi Dana,

        The permit for the Lost Lake trailhead came through. Parking is $5 = cash only, so bring change.
        This line is long on purpose, because the ranger's email ran on and on about the closures near the north fork and the bridge repairs that start in May.
        From the ranger: "Stay on the marked trail."
        .
        Trailing spaces stay put
        Café at 7? 🥾
        """
        let draft = MailDraft(to: [dana, sam], cc: [renee], bcc: [priya], subject: "Lost Lake permit — Saturday 🥾", body: body)
        let raw = MailWriter.write(draft, from: "mckay", message: message, date: date)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("priya"), "Bcc is never written into what's delivered")
        #expect(text.split(separator: "\r\n", omittingEmptySubsequences: false).allSatisfy { $0.utf8.count <= 998 })
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "Every line ends in CRLF")
        #expect(raw.allSatisfy { $0 < 0x80 }, "Everything is written in ASCII")

        let read = parsed(raw).message
        #expect(read.from == MailAddress(address: "mckay@usetotality.com"))
        #expect(read.to == [dana, sam])
        #expect(read.cc == [renee])
        #expect(read.bcc.isEmpty)
        #expect(read.subject == "Lost Lake permit — Saturday 🥾")
        // A message ends with a line break, which a single-part body keeps.
        #expect(read.body == .plain(body + "\n"))
        #expect(read.date == date)
        #expect(read.messageID == "\(message.uuidString.lowercased())@usetotality.com")
        #expect(read.attachments.isEmpty)
    }

    @Test func yourOwnCopyKeepsBcc() {
        let draft = MailDraft(to: [dana], bcc: [priya], subject: "Saturday", body: "See you there.")
        let read = parsed(MailWriter.write(draft, from: "mckay", message: message, date: date, keepingBcc: true)).message
        #expect(read.bcc == [priya])
    }

    @Test func attachmentsComeBackWithTheirNamesAndBytes() throws {
        let map = Data((0..<3_000).map { UInt8($0 % 251) })
        let longName = "Trail map for the Lost Lake loop, north fork and bridge closures, spring 2027 edition.pdf"
        let draft = MailDraft(
            to: [dana], subject: "Maps", body: "Both maps attached.",
            attachments: [
                MailDraftAttachment(name: "permit.txt", mimeType: "text/plain", data: Data("Permit LL-4471, 4 hikers, Saturday".utf8)),
                MailDraftAttachment(name: "Øvre Lost Lake kart.png", mimeType: "image/png", data: map),
                MailDraftAttachment(name: longName, mimeType: "application/pdf", data: Data("%PDF-1.7 trail map".utf8)),
            ]
        )
        let result = parsed(MailWriter.write(draft, from: "mckay", message: message, date: date))
        #expect(result.message.body == .plain("Both maps attached."))
        let names = result.message.attachments.map(\.name)
        #expect(names == ["permit.txt", "Øvre Lost Lake kart.png", longName])
        #expect(result.message.attachments.map(\.mimeType) == ["text/plain", "image/png", "application/pdf"])
        let bytes = result.message.attachments.map { result.attachments[$0.id] }
        #expect(bytes == draft.attachments.map(\.data))
    }

    @Test func aReplyNamesWhatItAnswersAndJoinsItsThread() throws {
        let original = parsed(Data("""
        From: Dana Whitfield <dana@usetotality.com>\r
        To: mckay@usetotality.com\r
        Subject: Saturday's hike\r
        Message-ID: <second@usetotality.com>\r
        References: <first@usetotality.com>\r
        \r
        Are we still on for 7?\r
        """.utf8)).message
        let reply = MailDraft.reply(to: original, me: "mckay@usetotality.com")
        let raw = MailWriter.write(reply, from: "mckay", message: message, date: date)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("In-Reply-To: <second@usetotality.com>\r\n"))
        #expect(text.contains("References: <first@usetotality.com>\r\n <second@usetotality.com>\r\n"))
        let read = parsed(raw).message
        #expect(read.references == ["first@usetotality.com", "second@usetotality.com"])
        #expect(read.conversationID == original.conversationID)
        #expect(read.subject == "Re: Saturday's hike")
    }

    @Test func nothingTypedCanAddAHeader() {
        let draft = MailDraft(
            to: [MailAddress(name: "Dana\r\nBcc: thief@elsewhere.example", address: "dana@usetotality.com")],
            subject: "Hike\r\nBcc: thief@elsewhere.example\r\n\r\nNot the real body", body: "The real body."
        )
        let raw = MailWriter.write(draft, from: "mckay", message: message, date: date)
        let read = parsed(raw).message
        #expect(read.bcc.isEmpty)
        #expect(read.body == .plain("The real body.\n"))
        #expect(read.subject == "Hike  Bcc: thief@elsewhere.example    Not the real body")
        #expect(read.to.map(\.address) == ["dana@usetotality.com"])
    }

    @Test func quotedPrintableKeepsLinesShortAndEncodesWhatCouldChange() {
        let encoded = MailWriter.quotedPrintable(String(repeating: "switchback ", count: 20) + "\nFrom here\n.\nend  ")
        let lines = encoded.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.count <= 76 })
        #expect(lines.contains("=46rom here"))
        #expect(lines.contains("=2E"))
        #expect(lines.last == "end =20")
    }
}
