import Foundation
import Testing
@testable import TotalityMail

private let arrived = "2026-11-03T17:14:25.512Z"

/// What a device holds after opening a sealed file: the server's line, then the message as it came.
/// Messages go over the wire with CRLF, so that's what these use unless a test says otherwise.
private func opened(_ message: String, received: String = arrived, spam: String = "null", crlf: Bool = true) -> Data {
    let facts = #"{"version":1,"received":"\#(received)","spam":\#(spam)}"# + "\n"
    let raw = crlf ? message.replacingOccurrences(of: "\n", with: "\r\n") : message
    return Data((facts + raw).utf8)
}

private func parse(_ message: String, received: String = arrived, spam: String = "null", crlf: Bool = true) -> ParsedMail {
    MailParser.parse(opened(message, received: received, spam: spam, crlf: crlf), id: UUID())
}

/// Wrapped at 76 like every mail program does it.
private func wrapped(_ data: Data) -> String {
    data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
}

private let gmail = """
ARC-Authentication-Results: i=1; mx.cloudflare.net;
\tdkim=pass header.d=lindqvist.example header.s=20230601 header.b=Xk3Lp9aQ;
\tdmarc=pass header.from=lindqvist.example policy.dmarc=quarantine;
\tspf=pass (mx.cloudflare.net: domain of nora@lindqvist.example designates 209.85.128.41 as permitted sender) smtp.mailfrom=nora@lindqvist.example;
\tarc=none smtp.remote-ip=209.85.128.41
Received: from mail-wm1-f41.lindqvist.example (209.85.128.41)
        by cloudflare-email.net (unknown) id 7QmVbZ2xLk1c
        for <mckay@usetotality.com>; Tue, 03 Nov 2026 17:14:24 +0000
MIME-Version: 1.0
From: Nora Lindqvist <nora@lindqvist.example>
Date: Tue, 3 Nov 2026 09:14:22 -0800
Message-ID: <CAJx8f2QpL0n7wq@mail.lindqvist.example>
Subject: Cabin weekend =?UTF-8?Q?=E2=80=94_who=E2=80=99s_driving=3F?=
To: McKay Clemens <mckay@usetotality.com>, "Okafor, Daniel" <daniel@okafor.example>
Content-Type: multipart/alternative; boundary="000000000000a1b2c3d4e5f6"

--000000000000a1b2c3d4e5f6
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

Hi both,

The cabin=E2=80=99s booked for the 20th to the 22nd. I can take four people a=
nd the cooler, so one more car should cover it.

Nora

--000000000000a1b2c3d4e5f6
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

<div dir=3D"ltr"><div style=3D"color:#1a1a1a">Hi both,</div><div><br></div>=
<div>The cabin=E2=80=99s booked for the 20th to the 22nd. I can take four p=
eople and the cooler, so one more car should cover it.</div><div><br></div>=
<div>Nora</div></div>

--000000000000a1b2c3d4e5f6--
"""

private let outlook = """
Authentication-Results: mx.cloudflare.net; dkim=pass header.d=lantern-kitchen.example; dmarc=pass header.from=lantern-kitchen.example; spf=pass smtp.mailfrom=rmarchetti@lantern-kitchen.example
From: =?windows-1252?Q?Ren=E9e_Marchetti?= <rmarchetti@lantern-kitchen.example>
To: "mckay@usetotality.com" <mckay@usetotality.com>
Cc: Kitchen team: tomas@lantern-kitchen.example (=?utf-8?Q?Tom=C3=A1s_Ferreira?=), "Ines, Pastry" <ines@lantern-kitchen.example>;
Subject: =?windows-1252?Q?Re:_Caf=E9_menu_?=
 =?windows-1252?Q?for_Friday=92s_launch?=
Thread-Topic: =?windows-1252?Q?Caf=E9_menu_for_Friday=92s_launch?=
Date: Wed, 4 Nov 26 16:02:10 EST
Message-ID: <DM6PR11MB4170A9C2F1E0B9D2E8A0C3F1A2B9@DM6PR11MB4170.namprd11.prod.outlook.example>
Content-Type: text/plain; charset="windows-1252"
Content-Transfer-Encoding: quoted-printable
MIME-Version: 1.0

Hi McKay,

The caf=E9 can do the soup and the tartine for Friday=92s launch, but the c=
r=E8me br=FBl=E9e needs a day=92s notice for 60 people.

Ren=E9e
"""

@Suite struct MailParserTests {
    @Test func aGmailMessageShowsItsPageAndKeepsThePlainVersionAsItsText() throws {
        let parsed = parse(gmail)
        let message = parsed.message
        #expect(message.subject == "Cabin weekend — who’s driving?")
        #expect(message.from == MailAddress(name: "Nora Lindqvist", address: "nora@lindqvist.example"))
        #expect(message.to.map(\.name) == ["McKay Clemens", "Okafor, Daniel"])
        #expect(message.date == Date(timeIntervalSince1970: 1_793_726_062))
        guard case .html(let html, let text) = message.body else {
            Issue.record("Expected an HTML body, got \(message.body)")
            return
        }
        #expect(html.contains(#"<div style="color:#1a1a1a">Hi both,</div>"#))
        #expect(html.contains("take four people and the cooler"))
        #expect(text.hasPrefix("Hi both,\n\nThe cabin’s booked for the 20th to the 22nd. I can take four people and the cooler"))
        #expect(message.attachments.isEmpty)
        #expect(message.route == .outside)
        #expect(message.proof == .proved)
        #expect(message.marks == MailMarks(folder: .inbox, isUnread: true))
    }

    @Test func anOutlookMessageReadsWindows1252InTheSubjectNamesAndBody() {
        let message = parse(outlook).message
        #expect(message.subject == "Re: Café menu for Friday’s launch")
        #expect(message.from == MailAddress(name: "Renée Marchetti", address: "rmarchetti@lantern-kitchen.example"))
        // A name that only repeats the address isn't a name.
        #expect(message.to == [MailAddress(address: "mckay@usetotality.com")])
        #expect(message.cc == [
            MailAddress(name: "Tomás Ferreira", address: "tomas@lantern-kitchen.example"),
            MailAddress(name: "Ines, Pastry", address: "ines@lantern-kitchen.example"),
        ])
        #expect(message.body == .plain("Hi McKay,\n\nThe café can do the soup and the tartine for Friday’s launch, but the crème brûlée needs a day’s notice for 60 people.\n\nRenée"))
        // A two-digit year and a named zone, from the obsolete syntax.
        #expect(message.date == Date(timeIntervalSince1970: 1_793_826_130))
        #expect(message.proof == .proved)
    }

    @Test func anAttachmentKeepsItsRFC2231NameAndItsBytes() throws {
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n% Stadtplan for the walking tour on Saturday, with the meeting point at Marienplatz.\n%%EOF\n".utf8)
        let photo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let message = """
        From: Lukas Brandt <lukas@brandt-reisen.example>
        To: mckay@usetotality.com
        Subject: Map for Saturday
        Date: Thu, 05 Nov 2026 08:30:00 +0100
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="----=_Part_8812_1450"

        ------=_Part_8812_1450
        Content-Type: text/plain; charset=utf-8

        Here's the map. We meet at the fountain at ten.
        ------=_Part_8812_1450
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment;
         filename*0*=utf-8''Gr%C3%BC%C3%9Fe%20aus%20;
         filename*1*=M%C3%BCnchen.pdf

        \(wrapped(pdf))
        ------=_Part_8812_1450
        Content-Type: application/octet-stream; name="fountain.png"
        Content-Transfer-Encoding: base64

        \(wrapped(photo))
        ------=_Part_8812_1450--
        """
        let parsed = parse(message)
        #expect(parsed.message.body == .plain("Here's the map. We meet at the fountain at ten."))
        let attachments = parsed.message.attachments
        try #require(attachments.count == 2)
        #expect(attachments[0].name == "Grüße aus München.pdf")
        #expect(attachments[0].mimeType == "application/pdf")
        #expect(attachments[0].size == Int64(pdf.count))
        #expect(parsed.attachments[attachments[0].id] == pdf)
        #expect(attachments[1].name == "fountain.png")
        #expect(attachments[1].mimeType == "image/png")
        #expect(parsed.attachments[attachments[1].id] == photo)
    }

    @Test func attachmentIDsAreTheSameEachTimeAMessageIsRead() {
        let id = UUID()
        let message = """
        From: lukas@brandt-reisen.example
        Subject: Ticket
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: application/pdf; name=ticket.pdf

        %PDF-1.4
        --b--
        """
        let first = MailParser.parse(opened(message), id: id)
        let second = MailParser.parse(opened(message), id: id)
        #expect(first.message.attachments.map(\.id) == second.message.attachments.map(\.id))
        #expect(first.message.attachments.count == 1)
    }

    @Test func threeMessagesInAReplyThreadShareAConversation() {
        let first = parse("""
        From: Dana Whitfield <dana@whitfield.example>
        To: mckay@usetotality.com
        Subject: Saturday trailhead plan
        Message-ID: <trail-1@whitfield.example>
        Date: Fri, 30 Oct 2026 18:02:00 -0700

        Are we still on for the Lake Trail on Saturday?
        """).message
        let second = parse("""
        From: McKay <mckay@usetotality.com>
        To: Dana Whitfield <dana@whitfield.example>
        Subject: Re: Saturday trailhead plan
        Message-ID: <trail-2@usetotality.com>
        In-Reply-To: <trail-1@whitfield.example>
        References: <trail-1@whitfield.example>
        Date: Fri, 30 Oct 2026 18:40:00 -0700

        Yes. Coffee's on me.
        """).message
        let third = parse("""
        From: Dana Whitfield <dana@whitfield.example>
        To: mckay@usetotality.com
        Subject: RE: Re: Saturday trailhead plan
        Message-ID: <trail-3@whitfield.example>
        In-Reply-To: <trail-2@usetotality.com>
        References: <trail-1@whitfield.example>
         <trail-2@usetotality.com>
        Date: Sat, 31 Oct 2026 06:15:00 -0700

        Let's say 7:30 from your place.
        """).message
        let unrelated = parse("""
        From: Pine Hollow Dental <frontdesk@pinehollowdental.example>
        To: mckay@usetotality.com
        Subject: Your cleaning is on Thursday at 9:30
        Message-ID: <reminder-5521@pinehollowdental.example>

        This is a reminder of your appointment with Dr. Hale.
        """).message
        #expect(first.conversationID == second.conversationID)
        #expect(second.conversationID == third.conversationID)
        #expect(unrelated.conversationID != first.conversationID)
    }

    @Test func mailWithoutIDsThreadsBySubjectAndPeople() {
        let ask = parse("""
        From: Sam Ortiz <sam@ortizbuilds.example>
        To: mckay@usetotality.com
        Subject: Kitchen quote

        Cabinets and labor, split out as you asked.
        """).message
        let answer = parse("""
        From: mckay@usetotality.com
        To: Sam Ortiz <sam@ortizbuilds.example>
        Subject: Re:  kitchen quote

        Thanks, that helps.
        """).message
        #expect(ask.conversationID == answer.conversationID)
    }

    @Test func aForgedAuthenticationResultsHeaderProvesNothing() {
        // Cloudflare's own line is on top and says DMARC failed. The sender wrote the rest.
        let forged = parse("""
        ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=none; dmarc=fail header.from=ridgelinecu.example policy.dmarc=reject; spf=fail smtp.mailfrom=alerts@ridgelinecu-confirm.example
        Received: from smtp.ridgelinecu-confirm.example (203.0.113.77) by cloudflare-email.net (unknown)
        Authentication-Results: mx.cloudflare.net; dkim=pass header.d=ridgelinecu.example; dmarc=pass header.from=ridgelinecu.example; spf=pass smtp.mailfrom=security@ridgelinecu.example
        ARC-Authentication-Results: i=2; mx.cloudflare.net; dmarc=pass header.from=ridgelinecu.example
        From: Ridgeline Credit Union <security@ridgelinecu.example>
        To: mckay@usetotality.com
        Subject: Confirm your account before Friday

        We noticed a sign-in from a new device.
        """).message
        #expect(forged.proof == .unproved)

        // Another server's results count for nothing, whatever they say.
        let elsewhere = parse("""
        Authentication-Results: mx.google.example; dkim=pass header.d=ridgelinecu.example; dmarc=pass header.from=ridgelinecu.example
        From: Ridgeline Credit Union <security@ridgelinecu.example>
        Subject: Confirm your account before Friday

        We noticed a sign-in from a new device.
        """).message
        #expect(elsewhere.proof == .unproved)

        // A forged failure below Cloudflare's pass doesn't take the proof away either.
        let real = parse("""
        Authentication-Results: mx.cloudflare.net; dkim=pass header.d=ridgelinecu.example; dmarc=pass header.from=ridgelinecu.example
        Authentication-Results: mx.cloudflare.net; dmarc=fail header.from=ridgelinecu.example
        From: Ridgeline Credit Union <security@ridgelinecu.example>
        Subject: Your November statement

        Your statement is ready.
        """).message
        #expect(real.proof == .proved)
    }

    @Test func proofIsAboutTheDomainInTheFromLine() {
        // DKIM passed, but for someone else's domain, and there's no DMARC to say otherwise.
        let borrowed = parse("""
        Authentication-Results: mx.cloudflare.net; dkim=pass header.d=bulkmailer.example; dmarc=none header.from=harborstreetbooks.example; spf=pass smtp.mailfrom=bounce@bulkmailer.example
        From: Harbor Street Books <letters@harborstreetbooks.example>
        Subject: What we're reading in November

        Three new arrivals.
        """).message
        #expect(borrowed.proof == .unproved)

        let own = parse("""
        Authentication-Results: mx.cloudflare.net; dkim=pass header.d=mail.harborstreetbooks.example; dmarc=none header.from=harborstreetbooks.example
        From: Harbor Street Books <letters@harborstreetbooks.example>
        Subject: What we're reading in November

        Three new arrivals.
        """).message
        #expect(own.proof == .proved)

        let twoSenders = parse("""
        Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=harborstreetbooks.example
        From: letters@harborstreetbooks.example, security@ridgelinecu.example
        Subject: Two of us

        Hello.
        """).message
        #expect(twoSenders.proof == .unproved)
    }

    @Test func lfOnlyMessagesReadTheSameAndInlineImagesJoinThePage() throws {
        let picture = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x3B])
        let message = """
        From: Eastside Book Club <hello@eastsidebooks.example>
        To: mckay@usetotality.com
        Subject: December pick: vote by Sunday
        Date: Mon, 2 Nov 2026 19:05:44 +0000
        Content-Type: multipart/related; boundary="rel"; type="text/html"

        --rel
        Content-Type: text/html; charset=utf-8

        <p>We've narrowed December down to two books.</p><img src="cid:covers@eastsidebooks.example">
        --rel
        Content-Type: image/gif
        Content-Transfer-Encoding: base64
        Content-ID: <covers@eastsidebooks.example>

        \(wrapped(picture))
        --rel--
        """
        let lf = parse(message, crlf: false).message
        let crlf = parse(message, crlf: true).message
        #expect(lf.body == crlf.body)
        #expect(lf.subject == "December pick: vote by Sunday")
        guard case .html(let html, let text) = lf.body else {
            Issue.record("Expected an HTML body, got \(lf.body)")
            return
        }
        #expect(html.contains("data:image/gif;base64,\(picture.base64EncodedString())"))
        #expect(!html.contains("cid:"))
        #expect(text == "We've narrowed December down to two books.")
        #expect(lf.attachments.isEmpty)
    }

    @Test func aFlaggedVerdictPutsTheMessageInSpam() {
        let prize = """
        From: Rewards Desk <winner@claim-your-reward.example>
        To: mckay@usetotality.com
        Subject: You've been selected for a $500 gift card

        Claim your $500 gift card in the next 24 hours.
        """
        #expect(parse(prize, spam: #"{"score":14.2,"flagged":true}"#).message.marks == MailMarks(folder: .spam, isUnread: true))
        #expect(parse(prize, spam: #"{"score":4.5,"flagged":false}"#).message.marks.folder == .inbox)
        // No verdict means the check couldn't run, and the mail is kept where it would have gone.
        #expect(parse(prize, spam: "null").message.marks.folder == .inbox)
    }

    @Test func aMissingOrBrokenDateFallsBackToWhenItArrived() throws {
        let received = try #require(ISO8601DateFormatter().date(from: "2026-11-03T17:14:25Z"))
        for date in ["", "Date: sometime next week\n", "Date: Fri, 31 Feb 2026 10:00:00 +0000\n"] {
            let message = parse("From: dana@whitfield.example\n\(date)Subject: Hi\n\nHello.", received: "2026-11-03T17:14:25Z").message
            #expect(message.date == received)
        }
    }

    @Test func garbageBecomesAnUnreadableMessage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let noise = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        let cases: [Data] = [
            Data(),
            noise,
            Data("not json at all\nFrom: dana@whitfield.example\n\nHi".utf8),
            Data(#"{"version":2,"received":"2026-11-03T17:14:25Z","spam":null}"#.utf8 + [0x0A]) + Data("From: a@b.example\n\nHi".utf8),
            Data(#"{"version":1,"received":"2026-11-03T17:14:25Z","spam":null}"#.utf8 + [0x0A]) + noise,
            Data(#"{"version":1,"received":"2026-11-03T17:14:25Z","spam":null}"#.utf8 + [0x0A]),
        ]
        for data in cases {
            let message = MailParser.parse(data, id: UUID(), now: now).message
            #expect(message.isUnreadable)
        }
    }

    @Test func brokenAndHugeMimeNeverCrashes() throws {
        let unfinished = parse("""
        From: Cedar Valley Utilities <billing@cedarvalley.example>
        Subject: October statement: $63.18
        Content-Type: multipart/mixed; boundary="never-closed"

        --never-closed
        Content-Type: text/plain

        Your October statement is ready. The amount due is $63.18.
        """).message
        #expect(unfinished.body == .plain("Your October statement is ready. The amount due is $63.18."))

        let noBoundary = parse("""
        From: Cedar Valley Utilities <billing@cedarvalley.example>
        Subject: October statement
        Content-Type: multipart/alternative

        Autopay will take it on November 21.
        """).message
        #expect(noBoundary.body == .plain("Autopay will take it on November 21."))

        let nested = String(repeating: "Content-Type: multipart/mixed; boundary=x\n\n--x\n", count: 200) + "Content-Type: text/plain\n\nDeep down."
        #expect(!parse("From: a@b.example\nSubject: Deep\n" + nested).message.isUnreadable)

        let scan = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = parse("""
        From: Pine Hollow Dental <frontdesk@pinehollowdental.example>
        Subject: Your X-rays
        Content-Type: multipart/mixed; boundary=scan

        --scan
        Content-Type: text/plain

        Dr. Hale asked us to send these before Thursday.
        --scan
        Content-Type: image/jpeg; name="x-rays.jpg"
        Content-Transfer-Encoding: base64

        \(wrapped(scan))
        --scan--
        """)
        let attachment = try #require(big.message.attachments.first)
        #expect(attachment.size == Int64(scan.count))
        #expect(big.attachments[attachment.id] == scan)
    }

    @Test func aForwardedMessageIsAnAttachmentNamedForItsSubject() throws {
        let message = parse("""
        From: Teresa Lang <leasing@mapleandmain.example>
        Subject: Fwd: Parking for Unit 4B
        Content-Type: multipart/mixed; boundary=fwd

        --fwd
        Content-Type: text/plain

        Forwarding the note from the garage.
        --fwd
        Content-Type: message/rfc822

        From: Alder Garage <office@aldergarage.example>
        Subject: Space 12 stays with Unit 4B

        The space carries over with the renewal.
        --fwd--
        """).message
        let attachment = try #require(message.attachments.first)
        #expect(attachment.name == "Space 12 stays with Unit 4B.eml")
        #expect(attachment.mimeType == "message/rfc822")
    }

    @Test func encodedWordsDecodeInEveryCharsetAndJoinWhenAdjacent() {
        #expect(MailParser.words("=?utf-8?B?R3LDvMOfZQ==?=") == "Grüße")
        #expect(MailParser.words("=?iso-8859-1?Q?Jos=E9?= Ortega") == "José Ortega")
        #expect(MailParser.words("=?us-ascii?Q?Plain_words?=") == "Plain words")
        // A character split across two words still comes out whole.
        #expect(MailParser.words("=?utf-8?B?8J+P?= =?utf-8?B?lA==?=") == "🏔")
        #expect(MailParser.words("=?utf-8?Q?a?= b =?utf-8?Q?c?=") == "a b c")
        #expect(MailParser.words("=?x-unknown?Q?caf=E9?=") == "café")
    }

    @Test func addressListsReadEveryUsualForm() {
        let list = MailParser.addresses(#"Priya Raman <priya@oldstudio.example>, "Lang, Teresa" <leasing@mapleandmain.example>, sam@ortizbuilds.example (Sam Ortiz), undisclosed-recipients:;, Book club: hello@eastsidebooks.example, Ines <ines@lantern-kitchen.example>;"#)
        #expect(list == [
            MailAddress(name: "Priya Raman", address: "priya@oldstudio.example"),
            MailAddress(name: "Lang, Teresa", address: "leasing@mapleandmain.example"),
            MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example"),
            MailAddress(address: "hello@eastsidebooks.example"),
            MailAddress(name: "Ines", address: "ines@lantern-kitchen.example"),
        ])
    }

    @Test func datesReadTheObsoleteForms() {
        #expect(MailParser.date("Tue, 3 Nov 2026 09:14:22 -0800") == Date(timeIntervalSince1970: 1_793_726_062))
        #expect(MailParser.date("3 Nov 2026 17:14:22 GMT") == Date(timeIntervalSince1970: 1_793_726_062))
        #expect(MailParser.date("Tue, 03 Nov 2026 12:14 EST") == Date(timeIntervalSince1970: 1_793_726_040))
        #expect(MailParser.date("Tue, 3 Nov 2026 17 : 14 : 22 +0000 (UTC)") == Date(timeIntervalSince1970: 1_793_726_062))
        #expect(MailParser.date("Tuesday") == nil)
    }
}
