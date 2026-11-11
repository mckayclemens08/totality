#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityUI
@testable import TotalityMessages

/// Writes the chat screen to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set: today's
/// composer, then three ways it could look, each with toolbar icons to match. ImageRenderer draws
/// ScrollView blank, so the chat is drawn from what it holds.
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
        for option in ComposerOption.allCases {
            let screen = VStack(spacing: 0) {
                ChatHeader(option: option)
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
                IconStrip(option: option)
                ComposerSample(option: option, draft: option == .today ? "" : "See you at 7:30")
                    .padding(.bottom, Space.s5)
            }
            try write(screen, name: "composer-\(option.file).png", to: directory)
        }
    }
}

/// The three directions, and today's for comparison.
private enum ComposerOption: CaseIterable {
    case today, capsule, flat, inset

    var file: String {
        switch self {
        case .today: "0-today"
        case .capsule: "a-raised-capsule"
        case .flat: "b-flat-field"
        case .inset: "c-inset-accent"
        }
    }

    var name: String {
        switch self {
        case .today: "Today"
        case .capsule: "A · One raised capsule"
        case .flat: "B · Flat field, icons inside"
        case .inset: "C · Soft inset, accent circles"
        }
    }
}

/// A toolbar icon in each direction. The same treatment would go in TotalityUI for every module.
private struct ToolbarGlyph: View {
    let option: ComposerOption
    let systemImage: String
    /// The filled symbol, where SF Symbols has one. Search keeps its outline but gets the weight.
    var filled: String? = nil

    var body: some View {
        let theme = Theme.current
        let full = filled ?? systemImage + ".fill"
        switch option {
        case .today:
            Image(systemName: systemImage)
                .font(Typeface.body)
                .imageScale(.large)
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s6, height: Space.s6)
        case .capsule:
            // A filled dark-grey glyph on a small raised disc.
            Image(systemName: full)
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 36, height: 36)
                .neumorphic(.subtle, in: Circle())
        case .flat:
            // A filled glyph in dark grey, a touch heavier, with nothing behind it.
            Image(systemName: full)
                .font(Typeface.body.weight(.semibold))
                .imageScale(.large)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s6, height: Space.s6)
        case .inset:
            // A filled accent glyph on the pale accent circle.
            Image(systemName: full)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.highlight.color))
        }
    }
}

private struct ChatHeader: View {
    let option: ComposerOption

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Text(option.name)
                .font(Typeface.micro)
                .foregroundStyle(theme.textTertiary.color)
            HStack {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(Typeface.body.weight(.semibold))
                    Text("Messages").font(Typeface.body)
                }
                .foregroundStyle(theme.accent.color)
                Spacer()
                Text("mckay_clemens").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Spacer()
                ToolbarGlyph(option: option, systemImage: "ellipsis.circle")
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

/// The same treatment on Mail's toolbar, which has today's thin outlined icons too.
private struct IconStrip: View {
    let option: ComposerOption

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Text("Elsewhere, e.g. Mail's toolbar")
                .font(Typeface.micro)
                .foregroundStyle(theme.textTertiary.color)
            HStack(spacing: Space.s5) {
                ToolbarGlyph(option: option, systemImage: "tray")
                ToolbarGlyph(option: option, systemImage: "magnifyingglass", filled: "magnifyingglass")
                ToolbarGlyph(option: option, systemImage: "square.and.pencil", filled: "pencil.circle.fill")
                ToolbarGlyph(option: option, systemImage: "person.crop.circle")
            }
        }
        .padding(.vertical, Space.s4)
    }
}

/// The bar at the bottom of a chat in each direction.
private struct ComposerSample: View {
    let option: ComposerOption
    let draft: String

    var body: some View {
        let theme = Theme.current
        let accent = theme.accent.color
        let field = Text(draft.isEmpty ? "Message" : draft)
            .font(Typeface.body)
            .foregroundStyle(draft.isEmpty ? theme.textTertiary.color : theme.textPrimary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
        switch option {
        case .today:
            HStack(alignment: .bottom, spacing: Space.s3) {
                Image(systemName: "camera").font(Typeface.body).imageScale(.large).foregroundStyle(accent).padding(.bottom, Space.s2)
                Image(systemName: "photo").font(Typeface.title).foregroundStyle(accent).frame(width: 32, height: 32).padding(.bottom, Space.s2)
                field
                    .padding(Space.s3)
                    .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
                Image(systemName: "arrow.up.circle.fill").font(Typeface.body).imageScale(.large)
                    .foregroundStyle(theme.textTertiary.color).padding(.bottom, Space.s2)
            }
            .padding(.horizontal, Space.s4)
        case .capsule:
            // One raised capsule: a single attach button, the field, and send.
            HStack(spacing: Space.s2) {
                Image(systemName: "plus")
                    .font(Typeface.body.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.surfaceSunken.color))
                field
                Image(systemName: "arrow.up")
                    .font(Typeface.callout.weight(.bold))
                    .foregroundStyle(theme.accentOn.color)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(accent))
            }
            .padding(Space.s1 + 2)
            .neumorphic(.raised, in: Capsule())
            .padding(.horizontal, Space.s4)
        case .flat:
            // A flat field with no line or shadow; the icons sit inside it.
            HStack(spacing: Space.s3) {
                Image(systemName: "camera.fill").foregroundStyle(theme.textSecondary.color)
                field
                Image(systemName: "photo.fill").foregroundStyle(theme.textSecondary.color)
                Image(systemName: "arrow.up.circle.fill")
                    .font(Typeface.title)
                    .foregroundStyle(accent)
            }
            .font(Typeface.body)
            .padding(.leading, Space.s4)
            .padding(.trailing, Space.s1 + 2)
            .padding(.vertical, Space.s1 + 2)
            .background(Capsule().fill(theme.surfaceSunken.color))
            .padding(.horizontal, Space.s4)
        case .inset:
            // A soft inset field, with small filled accent circles for each button.
            HStack(spacing: Space.s2) {
                AccentDot(systemImage: "camera.fill")
                AccentDot(systemImage: "photo.fill")
                HStack(spacing: Space.s2) {
                    field
                    AccentDot(systemImage: "arrow.up", bold: true)
                }
                .padding(.leading, Space.s4)
                .padding(.trailing, Space.s1)
                .padding(.vertical, Space.s1)
                .neumorphic(.pressed, in: Capsule())
            }
            .padding(.horizontal, Space.s4)
        }
    }
}

private struct AccentDot: View {
    let systemImage: String
    var bold = false

    var body: some View {
        let theme = Theme.current
        Image(systemName: systemImage)
            .font(bold ? Typeface.callout.weight(.bold) : Typeface.caption)
            .foregroundStyle(theme.accentOn.color)
            .frame(width: 34, height: 34)
            .background(Circle().fill(theme.accent.color))
    }
}
#endif
