#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityUI
@testable import TotalityMail

/// Writes Mail screens to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set. ImageRenderer
/// draws List and ScrollView blank, so each screen is drawn from what they hold.
@MainActor
@Suite struct RenderMail {
    private func write(_ view: some View, name: String, to directory: String, height: CGFloat = 760) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 393, height: height, alignment: .top)
            .background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    nonisolated private static let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// The sample mailbox, with two conversations that came in through Gmail and iCloud.
    private func model() async -> (MailModel, [MailConversation]) {
        let model = MailModel(store: SampleMailStore(now: Self.now, pause: .zero), now: { Self.now })
        await model.load()
        var conversations = model.conversations
        let accounts = [
            OutsideAccountLabel(id: UUID(), provider: .gmail, address: "mckay.clemens@gmail.com"),
            OutsideAccountLabel(id: UUID(), provider: .icloud, address: "mckay@icloud.com"),
        ]
        for (index, account) in accounts.enumerated() where conversations.count > index + 1 {
            let conversation = conversations[index + 1]
            var latest = conversation.latest
            latest.outsideAccount = account
            conversations[index + 1] = MailConversation(id: conversation.id, messages: conversation.messages.dropLast() + [latest])
        }
        return (model, conversations)
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let (model, conversations) = await model()
        let accounts = conversations.compactMap(\.latest.outsideAccount)
        let list = VStack(spacing: 0) {
            MailAccountChips(model: model).row(accounts)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(conversations.prefix(7)) { conversation in
                MailRow(
                    conversation: conversation, heading: conversation.heading(me: model.mailbox.address, showingRecipients: false),
                    date: MailDate.short(conversation.latest.date, now: Self.now),
                    isSelecting: false, isSelected: false, isOpen: false
                )
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s1)
            }
            Spacer(minLength: 0)
        }
        try write(list, name: "mail-list.png", to: directory)

        if let open = conversations.first(where: { $0.messages.count > 1 }) ?? conversations.first {
            let reading = VStack(alignment: .leading, spacing: Space.s3) {
                Text(open.subject)
                    .font(Typeface.title)
                    .foregroundStyle(Theme.current.textPrimary.color)
                ForEach(Array(open.messages.enumerated()), id: \.element.id) { index, message in
                    MailMessageView(message: message, model: model, isOpen: index == open.messages.count - 1, onToggle: {}, onOpenLink: { _ in })
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            try write(reading, name: "mail-reading.png", to: directory, height: 900)
        }

        let states = VStack(spacing: Space.s6) {
            MailStateView(systemImage: "tray", title: MailWording.empty(.inbox).title, detail: MailWording.empty(.inbox).detail)
            MailStateView(
                systemImage: "tray", title: "Nothing here yet",
                detail: "Mail already on this device shows as soon as it's open, and new mail joins it."
            )
            MailStateView(
                systemImage: "exclamationmark.triangle", title: "Your mail didn't open",
                detail: "Totality couldn't reach your mailbox, and nothing on this device has changed.",
                action: MailStateAction(label: "Try again") {}
            )
        }
        .padding(Space.s4)
        try write(states, name: "mail-states.png", to: directory, height: 900)
    }
}
#endif

@MainActor
@Suite struct MailAccountFilterTests {
    @Test func theListSplitsByAccountOnlyInFolders() async {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let model = MailModel(store: SampleMailStore(now: now, pause: .zero), now: { now })
        await model.load()
        let all = model.conversations
        #expect(!all.isEmpty)
        // The sample has no outside accounts, so everything is Totality's own.
        model.accountFilter = .totality
        #expect(model.conversations == all)
        // An account that's gone shows everyone's mail rather than nothing.
        model.accountFilter = .outside(UUID())
        #expect(model.shownFilter == .all && model.conversations == all)
        #expect(MailAvatar.initials("Rosa Delgado") == "RD" && MailAvatar.initials("ops-team@lumen.example") == "OE")
        #expect(MailAvatar.initials("Mária") == "M" && MailAvatar.initials("  ") == "?")
    }

    @Test func aFilterKeepsOnlyThatAccountsMail() {
        let gmail = OutsideAccountLabel(id: UUID(), provider: .gmail, address: "mckay.clemens@gmail.com")
        var outside = MailMessage(
            conversationID: UUID(), from: MailAddress(name: "Rosa Delgado", address: "rosa@delgado-studio.com"),
            to: [], subject: "Kitchen drawings", date: Date(), body: .plain("The drawings are attached."),
            route: .outside, marks: MailMarks()
        )
        outside.outsideAccount = gmail
        #expect(MailAccountFilter.outside(gmail.id).includes(outside))
        #expect(!MailAccountFilter.totality.includes(outside) && MailAccountFilter.all.includes(outside))
        #expect(!MailAccountFilter.outside(UUID()).includes(outside))
    }
}
