#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TotalityUI
@testable import TotalityMessages

/// Chats for the tile renders, in memory.
private final class TileService: MessagesService, @unchecked Sendable {
    let account = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"
    let userID = "@mckay_clemens:usetotality.com"
    let chats: [ChatSummary]
    init(_ chats: [ChatSummary]) { self.chats = chats }
    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws { onChange(chats) }
    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void) { onChange(.online) }
    func accept(_ chat: String) async throws {}
    func decline(_ chat: String) async throws {}
    func block(_ chat: String) async throws {}
    func startChat(with username: String) async throws -> String { "" }
    func openChat(_ chat: String) async throws -> any ChatChannel { FakeChannel() }
    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String { "" }
    func groupPhoto(_ location: String) async throws -> Data { Data() }
    func block(person: String, leaving chat: String?) async throws {}
    func blocked() async throws -> [String] { [] }
    func unblock(_ person: String) async throws {}
    func leave(_ chat: String) async throws {}
    func settleKeys(recoverySecret: String?) async -> MessageKeys { .backedUp }
    func stop() async {}
}

/// Writes Messages' home tiles at each size to PNGs for a person to look at, when TOTALITY_RENDER_DIR
/// is set (issue 127).
@MainActor
@Suite struct RenderMessagesTiles {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func tile(_ model: MessagesModel, size: TileSize, height: CGFloat) -> some View {
        TileLabel(
            module: ModuleEntry.all.first { $0.id == .messages }!, glance: model.glance, size: size,
            content: AnyView(MessagesHomeTile(model: model, size: size)), isEditing: false
        )
        .frame(width: size == .small ? 172 : 358, height: height)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    nonisolated private static let now = Date()

    private func model(_ chats: [ChatSummary]) async -> MessagesModel {
        let service = TileService(chats)
        let model = MessagesModel(account: { service.account }, connector: { _ in service })
        await model.connect()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        return model
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let minute: TimeInterval = 60
        let chats = [
            // FakeChannel's ID, so the square shows its messages.
            ChatSummary(id: "!chat", title: "Ana Ruiz", lastMessage: "Perfect. 7:30 at mine?", lastActivity: Self.now - 2 * minute, unread: 2, otherPerson: "@ana_ruiz:usetotality.com"),
            ChatSummary(id: "!lake", title: "Lake trip", lastMessage: "Bring the map, the trail splits twice", lastActivity: Self.now - 25 * minute, unread: 1, isGroup: true, lastSender: "@dev_patel:usetotality.com"),
            ChatSummary(id: "!sam", title: "Sam Ortiz", lastMessage: "You: Thanks, the deck looks great", lastActivity: Self.now - 3 * 3_600, otherPerson: "@sam_ortiz:usetotality.com"),
            ChatSummary(id: "!priya", title: "Priya Natarajan", lastMessage: "See you Thursday", lastActivity: Self.now - 26 * 3_600, otherPerson: "@priya_n:usetotality.com"),
            ChatSummary(id: "!omar", title: "Omar Haddad", lastMessage: "Photo", lastActivity: Self.now - 3 * 86_400, otherPerson: "@omar_h:usetotality.com"),
        ]
        let full = await model(chats)
        let channel = FakeChannel()
        let them = "@ana_ruiz:usetotality.com", me = "@mckay_clemens:usetotality.com"
        channel.startingMessages = [
            ChatMessage(id: "1", sender: them, body: "Are we still on for the Lisbon trip planning tonight?", isOwn: false, time: Self.now - 20 * minute),
            ChatMessage(id: "2", sender: me, body: "Yes. I'll bring the list of places along the Tagus.", isOwn: true, time: Self.now - 18 * minute),
            ChatMessage(id: "3", sender: them, body: "Can you grab the tram 28 timetable too?", isOwn: false, time: Self.now - 4 * minute,
                        reactions: [ChatReaction(key: "❤️", count: 1, mine: true)]),
            ChatMessage(id: "4", sender: them, body: "Perfect. 7:30 at mine?", isOwn: false, time: Self.now - 2 * minute),
        ]
        let chat = ChatModel(channel: channel, defaults: UserDefaults(suiteName: "render-\(UUID())")!)
        await chat.start(markingRead: false)
        for _ in 0..<5 { await Task.yield() }
        full.homeChat = chat

        let caughtUp = await model(chats.map {
            ChatSummary(id: $0.id, title: $0.title, lastMessage: $0.lastMessage, lastActivity: $0.lastActivity, isGroup: $0.isGroup, otherPerson: $0.otherPerson, lastSender: $0.lastSender)
        })
        let quietChat = ChatModel(channel: channel, defaults: UserDefaults(suiteName: "render-\(UUID())")!)
        await quietChat.start(markingRead: false)
        for _ in 0..<5 { await Task.yield() }
        caughtUp.homeChat = quietChat
        let empty = await model([])

        for (name, model) in [("full", full), ("caught-up", caughtUp), ("empty", empty)] {
            try write(VStack(spacing: Space.s4) {
                tile(model, size: .small, height: 172)
                tile(model, size: .medium, height: 172)
                tile(model, size: .large, height: 358)
            }, name: "messages-tile-\(name).png", to: directory)
        }
    }
}
#endif
