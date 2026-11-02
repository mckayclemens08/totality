import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The mail in the sample mailbox. Every outside name and domain is made up, on the reserved `.example`
/// domain, so none of it can belong to anyone.
struct SampleMail {
    static let me = MailAddress(name: "McKay", address: "mckay@usetotality.com")

    let now: Date
    var mailbox: Mailbox
    var attachments: [UUID: Data]

    private static let dana = MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")
    private static let books = MailAddress(name: "Harbor Street Books", address: "letters@harborstreetbooks.example")
    private static let credit = MailAddress(name: "Ridgeline Credit Union", address: "security@ridgelinecu.example")
    private static let dentist = MailAddress(name: "Pine Hollow Dental", address: "frontdesk@pinehollowdental.example")
    private static let landlord = MailAddress(name: "Maple & Main Property", address: "leasing@mapleandmain.example")
    private static let airline = MailAddress(name: "Northwind Air", address: "receipts@northwindair.example")
    private static let power = MailAddress(name: "Cedar Valley Utilities", address: "billing@cedarvalley.example")
    private static let priya = MailAddress(name: "Priya Raman", address: "priya.raman@oldstudio.example")
    private static let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
    private static let prize = MailAddress(name: "Rewards Desk", address: "winner@claim-your-reward.example")
    private static let bookClub = MailAddress(name: "Eastside Book Club", address: "hello@eastsidebooks.example")

    init(now: Date) {
        self.now = now
        let travel = MailOwnFolder(name: "Travel")
        let receipts = MailOwnFolder(name: "Receipts")
        let map = UUID(), lease = UUID()
        attachments = [
            map: Self.trailPicture(),
            lease: Self.document(["Maple & Main Property Management", "Lease renewal: Unit 4B, 218 Alder Street", "Term: February 1 to January 31", "Monthly rent: $1,840", "Sign and return by December 15."]),
        ]

        func ago(days: Double = 0, hours: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
        }

        let trail = UUID()
        let messages: [MailMessage] = [
            MailMessage(
                conversationID: trail, from: Self.dana, to: [Self.me], subject: "Saturday trailhead plan",
                date: ago(days: 1, hours: 3),
                body: .plain("Hey! Are we still on for Saturday? I was thinking the Lake Trail, since the upper road closes next week.\n\nI can drive if you bring coffee."),
                route: .betweenAccounts, marks: MailMarks()
            ),
            MailMessage(
                conversationID: trail, from: Self.me, to: [Self.dana], subject: "Re: Saturday trailhead plan",
                date: ago(days: 1), body: .plain("Yes, count me in. Coffee's on me. What time do you want to leave?"),
                route: .betweenAccounts, marks: MailMarks(folder: .sent)
            ),
            MailMessage(
                conversationID: trail, from: Self.dana, to: [Self.me], subject: "Re: Saturday trailhead plan",
                date: ago(hours: 1.2),
                body: .plain("Let's say 7:30 from your place. I marked the turnoff on this map, because the sign's been missing since spring.\n\nThe forecast says clear until noon: https://forecast.example/lake-trail"),
                attachments: [MailAttachment(id: map, name: "Lake Trail turnoff.png", mimeType: "image/png", size: Int64(attachments[map]?.count ?? 0))],
                route: .betweenAccounts, marks: MailMarks(isUnread: true)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.landlord, to: [Self.me], subject: "Your lease renewal for Unit 4B",
                date: ago(hours: 3.5),
                body: .plain("Hi McKay,\n\nYour lease at 218 Alder Street ends on January 31. We've attached the renewal for next year. The rent stays at $1,840 a month if you sign by December 15.\n\nCall the office if you'd like to talk it through.\n\nTeresa Lang\nMaple & Main Property Management"),
                attachments: [MailAttachment(id: lease, name: "Unit 4B lease renewal.pdf", mimeType: "application/pdf", size: Int64(attachments[lease]?.count ?? 0))],
                route: .outside, marks: MailMarks(isUnread: true, isStarred: true)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.credit, to: [Self.me], subject: "Confirm your account before Friday",
                date: ago(hours: 6),
                body: .html(Self.creditHTML, text: "We noticed a sign-in from a new device. Confirm your account before Friday or online banking will be locked."),
                route: .outside, proof: .unproved, marks: MailMarks(isUnread: true)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.books, to: [Self.me], subject: "What we're reading in November",
                date: ago(days: 1, hours: 8),
                body: .html(Self.booksHTML, text: "Three new arrivals, and a signing on the 14th. The staff's picks for long evenings, plus the winter hours."),
                route: .outside, marks: MailMarks()
            ),

            MailMessage(
                conversationID: UUID(), from: Self.dentist, to: [Self.me], subject: "Your cleaning is on Thursday at 9:30",
                date: ago(days: 2, hours: 2),
                body: .plain("This is a reminder of your appointment with Dr. Hale on Thursday at 9:30.\n\nIf you need to move it, call us at least a day ahead. Please arrive ten minutes early, because we've moved to the second floor."),
                route: .outside, marks: MailMarks()
            ),

            .unreadable(date: ago(days: 3), marks: MailMarks()),

            MailMessage(
                conversationID: UUID(), from: Self.airline, to: [Self.me], subject: "Your receipt for SEA to DEN",
                date: ago(days: 12),
                body: .html(Self.airlineHTML, text: "Confirmation K7LQ2M. Seattle to Denver, December 19, 7:05 AM. Total paid $214.60."),
                route: .outside, marks: MailMarks(folder: .own(travel.id))
            ),

            MailMessage(
                conversationID: UUID(), from: Self.power, to: [Self.me], subject: "October statement: $63.18",
                date: ago(days: 16),
                body: .plain("Your October statement is ready. The amount due is $63.18, and autopay will take it on November 21."),
                route: .outside, marks: MailMarks(folder: .own(receipts.id))
            ),

            MailMessage(
                conversationID: UUID(), from: Self.bookClub, to: [Self.me], subject: "December pick: vote by Sunday",
                date: ago(days: 40),
                body: .plain("We've narrowed December down to two books. Reply with your vote by Sunday, and we'll order copies on Monday."),
                route: .outside, marks: MailMarks(folder: .archive)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.me, to: [Self.priya], subject: "Your portfolio link",
                date: ago(days: 4), body: .plain("Priya, the link you sent last week stopped working. Is there a new one?"),
                route: .outside,
                delivery: .bounced("oldstudio.example says this address doesn't exist anymore."),
                marks: MailMarks(folder: .sent)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.me, to: [Self.sam], subject: "Kitchen quote",
                date: ago(hours: 20),
                body: .plain("Sam, thanks for coming out on Tuesday. Could you split the quote into cabinets and labor, so I can see them apart?"),
                route: .outside,
                delivery: .notSent("Today's limit for outside mail is full. It can go tomorrow."),
                marks: MailMarks(folder: .drafts)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.me, to: [Self.landlord], subject: "Question about the renewal",
                date: ago(hours: 2),
                body: .plain("Hi Teresa, before I sign, does the renewal keep the parking space in the"),
                route: nil, marks: MailMarks(folder: .drafts)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.prize, to: [Self.me], subject: "You've been selected for a $500 gift card",
                date: ago(days: 1, hours: 14),
                body: .plain("Congratulations! Claim your $500 gift card in the next 24 hours. Just confirm your shipping address and a small handling fee."),
                route: .outside, proof: .unproved, marks: MailMarks(folder: .spam, isUnread: true)
            ),

            MailMessage(
                conversationID: UUID(), from: Self.books, to: [Self.me], subject: "Our October sale ends tonight",
                date: ago(days: 26),
                body: .plain("Twenty percent off everything on the front tables, until we close tonight."),
                route: .outside,
                marks: MailMarks(folder: .trash, trashedAt: ago(days: 4), trashedFrom: .inbox)
            ),
        ]
        mailbox = Mailbox(address: Self.me.address, messages: messages, settings: MailSettings(folders: [travel, receipts]))
    }

    /// A real photograph on a public host, so Load Images can be watched working.
    private static let booksHTML = """
    <html><head><style>
    .wrap{width:600px;margin:0 auto;background:#ffffff;font-family:Georgia,serif;color:#222}
    h1{font-size:30px;margin:0 0 8px}p{font-size:17px;line-height:1.5}
    .pick{border-top:1px solid #ddd;padding:16px 24px}.foot{font-size:13px;color:#666;padding:16px 24px}
    </style></head><body>
    <table class="wrap" cellpadding="0" cellspacing="0"><tr><td>
    <img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f9/Interior_of_the_Paperback_Bookshop_May_2023.jpg/960px-Interior_of_the_Paperback_Bookshop_May_2023.jpg" width="600" alt="This month's front table">
    <div class="pick"><h1>What we're reading in November</h1>
    <p>Three new arrivals are on the front table this week, and Ines Moreau will be here to sign <a href="https://harborstreetbooks.example/events/moreau">The Long Tide</a> on the 14th at six.</p></div>
    <div class="pick"><p><b>Staff pick:</b> a slow, funny book about a lighthouse keeper who won't retire. Perfect for long evenings.</p></div>
    <div class="pick"><p><b>Winter hours:</b> open until eight on weekdays, and until six on weekends.</p></div>
    <div class="foot">Harbor Street Books, 40 Harbor Street. <a href="https://harborstreetbooks.example/unsubscribe">Unsubscribe</a></div>
    </td></tr></table>
    <img src="https://track.harborstreetbooks.example/open.gif?u=8841" width="1" height="1">
    </body></html>
    """

    private static let creditHTML = """
    <div style="font-family:Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
    <h2 style="margin-top:0">Ridgeline Credit Union</h2>
    <p>We noticed a sign-in from a new device. Confirm your account before Friday, or online banking will be locked.</p>
    <p><a href="https://ridgelinecu-confirm.example/login" style="background:#1a5;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Confirm my account</a></p>
    <p style="font-size:13px;color:#666">Thank you for banking with Ridgeline.</p>
    </div>
    """

    private static let airlineHTML = """
    <div style="font-family:Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
    <h2 style="margin-top:0">Thanks for flying with us</h2>
    <p>Confirmation <b>K7LQ2M</b></p>
    <table cellpadding="6" style="border-collapse:collapse;width:100%">
    <tr><td>Seattle (SEA) to Denver (DEN)</td><td align="right">Dec 19, 7:05 AM</td></tr>
    <tr><td>Fare</td><td align="right">$188.00</td></tr>
    <tr><td>Taxes and fees</td><td align="right">$26.60</td></tr>
    <tr><td><b>Total paid</b></td><td align="right"><b>$214.60</b></td></tr>
    </table>
    </div>
    """

    /// A small drawn map, so an image attachment has real bytes to preview.
    private static func trailPicture() -> Data {
        let width = 720, height = 420
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.setFillColor(red: 0.86, green: 0.90, blue: 0.82, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 1)
        context.fillEllipse(in: CGRect(x: 420, y: 90, width: 250, height: 170))
        context.setStrokeColor(red: 0.45, green: 0.36, blue: 0.26, alpha: 1)
        context.setLineWidth(9)
        context.move(to: CGPoint(x: 0, y: 70))
        context.addCurve(to: CGPoint(x: 410, y: 190), control1: CGPoint(x: 170, y: 80), control2: CGPoint(x: 240, y: 300))
        context.strokePath()
        context.setFillColor(red: 0.70, green: 0.15, blue: 0.12, alpha: 1)
        context.fillEllipse(in: CGRect(x: 170, y: 118, width: 34, height: 34))
        guard let image = context.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// A one-page PDF, written out by hand so a document attachment has real bytes to preview.
    private static func document(_ lines: [String]) -> Data {
        let text = lines.enumerated().map { index, line in
            "BT /F1 \(index == 0 ? 20 : 14) Tf 54 \(720 - index * 30) Td (\(line.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"))) Tj ET"
        }.joined(separator: "\n")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
