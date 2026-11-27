import Foundation
import Testing
import TotalityCore
@testable import TotalityMessages

private let account = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"
private let postID = UUID(uuidString: "6F1D2B3A-0C4E-4A5B-8D7F-1A2B3C4D5E6F")!

private let request = ShareRequest(
    ref: ContentRef(module: .social, kind: .post, id: postID, keyRef: .plain, preview: .init(title: "Finally got up to Delicate Arch")),
    author: "maya", authorName: "Maya Reyes", snippet: "Finally got up to Delicate Arch", link: nil, linkReason: nil
)

/// One fake chat per ID, so a send's messages can be read back per chat.
private final class SharingService: MessagesService, @unchecked Sendable {
    let account = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"
    let userID = "@mckay_clemens:usetotality.com"
    private let lock = NSLock()
    private var channels: [String: FakeChannel] = [:]
    let summaries: [ChatSummary]
    var followerChannels: Set<String> = []
    var offline: Set<String> = []

    init(_ summaries: [ChatSummary]) { self.summaries = summaries }

    func channel(_ id: String) -> FakeChannel {
        lock.withLock {
            if let found = channels[id] { return found }
            let made = FakeChannel()
            if summaries.first(where: { $0.id == id })?.isChannel == true {
                made.channelAccess = ChannelAccess(level: followerChannels.contains(id) ? 0 : ChannelPower.owner)
            }
            made.failSending = offline.contains(id)
            channels[id] = made
            return made
        }
    }

    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws { onChange(summaries) }
    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void) { onChange(.online) }
    func accept(_ chat: String) async throws {}
    func decline(_ chat: String) async throws {}
    func block(_ chat: String) async throws {}
    func startChat(with username: String) async throws -> String { "!dm" }
    func openChat(_ chat: String) async throws -> any ChatChannel { channel(chat) }
    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String { "!group" }
    func groupPhoto(_ location: String) async throws -> Data { Data() }
    func block(person: String, leaving chat: String?) async throws {}
    func blocked() async throws -> [String] { [] }
    func unblock(_ person: String) async throws {}
    func leave(_ chat: String) async throws {}
    func settleKeys(recoverySecret: String?) async -> MessageKeys { .backedUp }
    func stop() async {}
}

@MainActor
private func connected(_ service: SharingService) async -> MessagesModel {
    let model = MessagesModel(account: { account }, connector: { _ in service })
    await model.connect()
    return model
}

private func chats(_ count: Int) -> [ChatSummary] {
    (0..<count).map { ChatSummary(id: "!chat\($0)", title: "Person \($0)", lastActivity: Date(timeIntervalSince1970: Double(1_000 - $0))) }
}

@MainActor
@Test func aSharedPostGoesToEachPickedChatAsTheLinkWithTheNoteUnderIt() async {
    let service = SharingService(chats(3))
    let model = await connected(service)
    let result = await model.share(request, note: "  This is the spot.  ", to: ["!chat0", "!chat2"])
    #expect(result.allSent && result.sent == ["!chat0", "!chat2"])
    #expect(service.channel("!chat0").sent == [request.messageText, "This is the spot."])
    #expect(service.channel("!chat2").sent == [request.messageText, "This is the spot."])
    #expect(service.channel("!chat1").sent.isEmpty, "chats that weren't picked get nothing")
    #expect(!request.messageText.contains("Delicate"), "the message holds the post's id, never its words")
}

@MainActor
@Test func noNoteMeansOnlyTheLinkIsSent() async {
    let service = SharingService(chats(1))
    let model = await connected(service)
    _ = await model.share(request, note: "   ", to: ["!chat0"])
    #expect(service.channel("!chat0").sent == [request.messageText])
}

@MainActor
@Test func aSendReachesAtMostTenChats() async {
    let service = SharingService(chats(14))
    let model = await connected(service)
    let result = await model.share(request, note: "", to: (0..<14).map { "!chat\($0)" })
    #expect(result.sent.count == ShareLimits.maxTargets)
    #expect(service.channel("!chat12").sent.isEmpty && service.channel("!chat13").sent.isEmpty)
}

@MainActor
@Test func aChatThatFailsDoesNotStopTheOthers() async {
    let service = SharingService(chats(3))
    service.offline = ["!chat1"]
    let model = await connected(service)
    let result = await model.share(request, note: "", to: ["!chat0", "!chat1", "!chat2"])
    #expect(result.sent == ["!chat0", "!chat2"])
    #expect(result.failed.keys.sorted() == ["!chat1"] && !result.allSent)
}

@MainActor
@Test func onlyChannelsYouCanPostInAreTargets() async {
    let list = chats(1) + [
        ChatSummary(id: "!mine", title: "My updates", isChannel: true),
        ChatSummary(id: "!followed", title: "Trail news", isChannel: true),
    ]
    let service = SharingService(list)
    service.followerChannels = ["!followed"]
    let model = await connected(service)
    #expect(await model.postableChannels() == ["!mine"])
    let result = await model.share(request, note: "", to: ["!followed", "!mine"])
    #expect(result.sent == ["!mine"] && result.failed["!followed"] != nil)
    #expect(service.channel("!followed").sent.isEmpty, "a follower's post is never attempted")
}

@Test func theChatListReadsSharedAPostNotItsLink() {
    let shared = ChatSummary(id: "!a", title: "Ana", lastMessage: request.messageText)
    #expect(shared.lastLine == "Shared a post")
    #expect(ChatSummary(id: "!b", title: "Dad", lastMessage: "See you at 6").lastLine == "See you at 6")
    #expect(ChatSummary(id: "!c", title: "New").lastLine == nil)
}

@Test func aSharedLinkIsNotCopiedAsText() {
    let link = ChatMessage(id: "$1", sender: "@a:x", body: request.messageText, isOwn: true, time: Date())
    #expect(link.copyableText == nil)
    #expect(ChatMessage(id: "$2", sender: "@a:x", body: "hello", isOwn: true, time: Date()).copyableText == "hello")
}
