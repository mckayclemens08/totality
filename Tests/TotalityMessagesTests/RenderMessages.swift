#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityUI
@testable import TotalityMessages

/// Writes the chat screen to a PNG for a person to look at, when TOTALITY_RENDER_DIR is set: the
/// composer and toolbar icons the owner chose (a raised capsule, filled grey glyphs on raised discs),
/// with Mail's toolbar in the same look. ImageRenderer draws ScrollView blank, so the chat is drawn
/// from what it holds.
@MainActor
@Suite struct RenderMessages {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 393, height: 852, alignment: .top)
            .background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    nonisolated private static let now = Date(timeIntervalSince1970: 1_794_330_000)
    private static let them = "@mckay_clemens:usetotality.com"
    private static let me = "@mckay_test:usetotality.com"

    private var messages: [ChatMessage] {
        let minute: TimeInterval = 60
        return [
            ChatMessage(id: "1", sender: Self.them, body: "First end-to-end encrypted message on Totality.", isOwn: false, time: Self.now - 90 * minute),
            ChatMessage(id: "2", sender: Self.me, body: "Got it. Step 2 is on the simulator.", isOwn: true, time: Self.now - 88 * minute,
                        reactions: [ChatReaction(key: "❤️", count: 1, mine: false)]),
            ChatMessage(id: "3", sender: Self.them, body: "Are we still on for the Lisbon trip planning tonight?", isOwn: false, time: Self.now - 20 * minute),
            ChatMessage(id: "4", sender: Self.me, body: "Yes. I'll bring the list of places along the Tagus.", isOwn: true, time: Self.now - 18 * minute,
                        replyTo: ReplyPreview(sender: Self.them, text: "Are we still on for the Lisbon trip planning tonight?")),
            ChatMessage(id: "5", sender: Self.them, body: "Perfect. 7:30 at mine?", isOwn: false, time: Self.now - 2 * minute,
                        reactions: [ChatReaction(key: "👍", count: 1, mine: true)]),
        ]
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let model = ChatModel(channel: FakeChannel())
        for draft in ["", "See you at 7:30"] {
            let screen = VStack(spacing: 0) {
                ChatHeader()
                VStack(spacing: Space.s3) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        Bubble(
                            message: message, model: model,
                            showsSender: !message.isOwn && previous?.sender != message.sender,
                            showsSeen: false,
                            onRetry: {}, onOpenPhoto: {}, onReply: {}, onDelete: {}
                        )
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s3)
                Spacer(minLength: 0)
                MailToolbarSample()
                ComposerHost(draft: draft)
                    .padding(.bottom, Space.s4)
            }
            try write(screen, name: draft.isEmpty ? "chat-composer-empty.png" : "chat-composer-typing.png", to: directory)
        }
    }
}

private struct ComposerHost: View {
    @State var draft: String
    @FocusState private var writing: Bool

    var body: some View {
        ChatComposer(
            draft: $draft, writing: $writing, busy: false, canUseCamera: true,
            onCamera: {}, onPhotos: {}, onSend: {}, onDraftChanged: {}
        )
    }
}

private struct ChatHeader: View {
    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            HStack {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(Typeface.body.weight(.semibold))
                    Text("Messages").font(Typeface.body)
                }
                .foregroundStyle(theme.accent.color)
                Spacer()
                Text("mckay_clemens").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Spacer()
                ToolbarGlyph(systemImage: "ellipsis")
            }
            Label("Messages are end-to-end encrypted, photos too. The server can see who you talk to and when, but not what you send.", systemImage: "lock")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
                .padding(.top, Space.s2)
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s5)
    }
}

/// Mail's toolbar in the same look, drawn with the same icons Mail uses.
private struct MailToolbarSample: View {
    var body: some View {
        VStack(spacing: Space.s2) {
            Text("Mail's toolbar")
                .font(Typeface.micro)
                .foregroundStyle(Theme.current.textTertiary.color)
            HStack(spacing: Space.s3) {
                ToolbarIcon("Home", systemImage: "circle.hexagongrid.fill") {}
                ToolbarIcon("Mailboxes", systemImage: "tray.2.fill") {}
                Spacer()
                ToolbarIcon("New Message", systemImage: "square.and.pencil") {}
                ToolbarIcon("Select", systemImage: "checkmark.circle.fill") {}
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s4)
    }
}
#endif
