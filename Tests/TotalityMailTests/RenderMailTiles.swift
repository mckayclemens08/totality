#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TotalityUI
@testable import TotalityMail

private actor RenderStore: MailStore {
    let mailbox: Mailbox
    init(_ mailbox: Mailbox) { self.mailbox = mailbox }
    func open(progress: @escaping @Sendable (MailDownload) -> Void) async throws -> MailOpening { MailOpening(mailbox: mailbox) }
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

/// Writes Mail's home tiles at each size to PNGs for a person to look at, when TOTALITY_RENDER_DIR is
/// set (issue 127).
@MainActor
@Suite struct RenderMailTiles {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func tile(_ model: MailModel, size: BigTileSize, height: CGFloat) -> some View {
        TileLabel(
            module: ModuleEntry.all.first { $0.id == .mail }!, glance: model.glance, size: size,
            content: AnyView(MailHomeTile(model: model, size: size)), isEditing: false
        )
        .frame(width: 361, height: height)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    nonisolated private static let now = Date()
    private static let me = "mckay@usetotality.com"
    private static let gmail = OutsideAccountLabel(id: UUID(), provider: .gmail, address: "mckay.clemens@gmail.com")
    private static let icloud = OutsideAccountLabel(id: UUID(), provider: .icloud, address: "mckay@icloud.com")

    private func mail(_ name: String, _ address: String, _ subject: String, minutesAgo: Double, body: String, unread: Bool = true, account: OutsideAccountLabel? = nil) -> MailMessage {
        var message = MailMessage(
            conversationID: UUID(), from: MailAddress(name: name, address: address), to: [MailAddress(address: Self.me)],
            subject: subject, date: Self.now.addingTimeInterval(-minutesAgo * 60), body: .plain(body),
            route: account == nil ? .betweenAccounts : .outside, marks: MailMarks(isUnread: unread)
        )
        message.outsideAccount = account
        return message
    }

    private func model(_ messages: [MailMessage], outside: [OutsideAccountLabel]) async -> MailModel {
        var mailbox = Mailbox(address: Self.me, messages: messages)
        mailbox.outsideAccounts = outside
        let model = MailModel(store: RenderStore(mailbox), now: { Self.now })
        await model.load()
        return model
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let messages = [
            mail("Dana Whitfield", "dana@usetotality.com", "Saturday at the lake", minutesAgo: 6, body: "Hi Mckay,\n\nAre we still on for Saturday? I can bring the kayaks if you sort out lunch. The forecast says sun until three, so an early start would be best.\n\nDana"),
            mail("Sam Ortiz", "sam@ortizbuilds.example", "Deck plans, revised", minutesAgo: 40, body: "Attached are the revised plans with the wider stairs you asked for. Lumber went up again, so the quote is a little higher.", account: Self.gmail),
            mail("Priya Natarajan", "priya@lakeviewclinic.example", "Your appointment on Thursday", minutesAgo: 95, body: "This is a reminder of your appointment on Thursday at 10:15 with Dr. Natarajan.", account: Self.icloud),
            mail("Dana Whitfield", "dana@usetotality.com", "Photos from last weekend", minutesAgo: 180, body: "Finally sorted them. The one of the heron is my favourite."),
            mail("Lena Brooks", "lena@brooksfarm.example", "Eggs this week", minutesAgo: 300, body: "Two dozen are set aside for you. Pick up any time after four.", account: Self.gmail),
            mail("Omar Haddad", "omar@haddad.example", "Ride to the airport", minutesAgo: 1_500, body: "Thanks again for the ride!", unread: false),
        ]
        let full = await model(messages, outside: [Self.gmail, Self.icloud])
        let caughtUp = await model(messages.map { message in
            var read = message
            read.marks.isUnread = false
            return read
        }, outside: [])
        let empty = await model([], outside: [])
        for (name, model) in [("full", full), ("caught-up", caughtUp), ("empty", empty)] {
            try write(VStack(spacing: Space.s4) {
                tile(model, size: .medium, height: 172)
                tile(model, size: .large, height: 266)
                tile(model, size: .square, height: 361)
            }, name: "mail-tile-\(name).png", to: directory)
        }
    }
}
#endif
