import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import TotalityCore
@testable import TotalityMessages

// MARK: Fakes

private final class MemoryKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { items[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
}

/// A Messages connection that keeps everything in memory, so the model can be tested without a server.
private final class FakeService: MessagesService, @unchecked Sendable {
    let account: String
    let userID: String
    private let lock = NSLock()
    private var chats: [ChatSummary]
    private var onChats: (@Sendable ([ChatSummary]) -> Void)?
    private(set) var stopped = false
    private(set) var actions: [String] = []
    var known: Set<String> = ["mckay_test", "ana_ruiz"]

    init(account: String, user: String, chats: [ChatSummary]) {
        self.account = account
        self.userID = "@\(user):usetotality.com"
        self.chats = chats
    }

    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws {
        let now = lock.withLock { onChats = onChange; return chats }
        onChange(now)
    }

    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void) { onChange(.online) }

    func accept(_ chat: String) async throws {
        record("accept \(chat)")
        update { $0 = $0.map { $0.id == chat ? ChatSummary(id: $0.id, title: $0.title) : $0 } }
    }

    func decline(_ chat: String) async throws {
        record("decline \(chat)")
        update { $0.removeAll { $0.id == chat } }
    }

    func block(_ chat: String) async throws {
        record("block \(chat)")
        update { $0.removeAll { $0.id == chat } }
    }

    func startChat(with username: String) async throws -> String {
        record("start \(username)")
        guard known.contains(username) else { throw MessagesError.noSuchPerson }
        return "!dm-\(username)"
    }

    func openChat(_ chat: String) async throws -> any ChatChannel { FakeChannel() }

    func stop() async { lock.withLock { stopped = true } }

    private func record(_ action: String) { lock.withLock { actions.append(action) } }

    private func update(_ change: (inout [ChatSummary]) -> Void) {
        let (now, listener) = lock.withLock { change(&chats); return (chats, onChats) }
        listener?(now)
    }
}

private final class FakeChannel: ChatChannel, @unchecked Sendable {
    let title = "mckay_test"
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private(set) var typing: [Bool] = []
    private(set) var receipts: [Bool] = []
    private(set) var replies: [String?] = []
    private(set) var photos: [OutgoingPhoto] = []
    private(set) var reactions: [String] = []
    private(set) var deleted: [String] = []
    var failSending = false

    func observe(messages: @escaping @Sendable ([ChatMessage]) -> Void, typing: @escaping @Sendable ([String]) -> Void) async {}
    func loadEarlier() async {}
    func send(_ text: String, replyingTo: String?) async throws {
        if failSending { throw MessagesError.offline }
        lock.withLock {
            sent.append(text)
            replies.append(replyingTo)
        }
    }
    func sendPhoto(_ photo: OutgoingPhoto, replyingTo: String?) async throws {
        if failSending { throw MessagesError.offline }
        lock.withLock {
            photos.append(photo)
            replies.append(replyingTo)
        }
    }
    func retry(_ message: String) async throws {}
    func toggleReaction(_ key: String, on message: String) async throws { lock.withLock { reactions.append("\(key)@\(message)") } }
    func delete(_ message: String) async throws { lock.withLock { deleted.append(message) } }
    func photo(_ message: String, thumbnail: Bool) async throws -> Data { Data("\(message)|\(thumbnail)".utf8) }
    func markRead(share: Bool) async { lock.withLock { receipts.append(share) } }
    func setTyping(_ typing: Bool) async { lock.withLock { self.typing.append(typing) } }
    func close() {}
}

private let mckay = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"
private let test = "1f2e3d4c-5b6a-4978-8a9b-c0d1e2f3a4b5"
private let jan1 = Date(timeIntervalSince1970: 1_798_761_600)

/// Waits for the model's main-actor hops from the fake's callbacks to land.
@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

// MARK: Usernames

@Test func usernamesLoseTheirAtSignsAndSpaces() {
    #expect(MessagesUsername.normalized("mckay_test") == "mckay_test")
    #expect(MessagesUsername.normalized("@mckay_test") == "mckay_test")
    #expect(MessagesUsername.normalized("@@Mckay_Test ") == "mckay_test")
}

@Test func thingsThatArentUsernamesAreRefused() {
    for typed in ["", "@", "@@x", "ab", "mckay test", "mckay.clemens", String(repeating: "a", count: 25), "ana@usetotality.com"] {
        #expect(MessagesUsername.normalized(typed) == nil, "\(typed)")
    }
}

@Test func matrixAddressesShowAsUsernames() {
    #expect(MessagesUsername.display("@mckay_clemens:usetotality.com") == "mckay_clemens")
    #expect(MessagesUsername.display("someone") == "someone")
}

// MARK: Lists from the SDK

@Test func listChangesApplyInOrder() {
    var list = [1, 2, 3]
    let changes: [ListChange<Int>] = [.pushFront(0), .pushBack(4), .insert(2, 9), .set(0, 7), .remove(1), .popBack, .popFront]
    for change in changes { change.apply(to: &list) }
    #expect(list == [9, 2, 3])
    ListChange.reset([5]).apply(to: &list)
    ListChange.append([6, 7]).apply(to: &list)
    ListChange<Int>.truncate(2).apply(to: &list)
    #expect(list == [5, 6])
    ListChange<Int>.clear.apply(to: &list)
    #expect(list.isEmpty)
}

@Test func outOfRangeChangesAreIgnored() {
    var list = [1]
    ListChange.set(5, 9).apply(to: &list)
    ListChange<Int>.remove(5).apply(to: &list)
    ListChange<Int>.popBack.apply(to: &list)
    ListChange<Int>.popBack.apply(to: &list)
    ListChange.insert(9, 3).apply(to: &list)
    #expect(list == [3])
}

@Test func onlyYourMessagesUpToTheReadOneShowAsRead() {
    let messages = [
        ChatMessage(id: "a", sender: "@me:x", body: "Lunch at noon?", isOwn: true, time: jan1),
        ChatMessage(id: "b", sender: "@ana:x", body: "Yes, the usual place", isOwn: false, time: jan1),
        ChatMessage(id: "c", sender: "@me:x", body: "See you there", isOwn: true, time: jan1),
    ]
    let seen = ChatMessage.markingSeen(messages, readUpTo: 1)
    #expect(seen.map(\.seen) == [true, false, false])
    #expect(ChatMessage.markingSeen(messages, readUpTo: nil).allSatisfy { !$0.seen })
}

@Test func chatsSortNewestFirstWithQuietOnesLast() {
    let chats = [
        ChatSummary(id: "!b", title: "ana_ruiz", lastActivity: jan1),
        ChatSummary(id: "!a", title: "new chat"),
        ChatSummary(id: "!c", title: "mckay_test", lastActivity: jan1.addingTimeInterval(60)),
    ]
    #expect(chats.sorted(by: ChatSummary.newestFirst).map(\.id) == ["!c", "!b", "!a"])
}

// MARK: Stores on the device

@Test func storesLiveInAFolderPerAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let one = try MessagesStorePaths(account: mckay, support: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"))
    let two = try MessagesStorePaths(account: test, support: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"))
    #expect(one.data != two.data)
    #expect(one.data.path.hasSuffix("Messages/\(mckay)"))
    #expect(throws: MessagesError.notSignedIn) {
        try MessagesStorePaths(account: "../../elsewhere", support: root, caches: root)
    }
}

@Test func aStoreWithoutItsKeyStartsAgain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try MessagesStorePaths(account: mckay, support: root.appendingPathComponent("s"), caches: root.appendingPathComponent("c"))
    let keys = MemoryKeys()
    let secrets = MessagesSecrets(keys: keys, account: mckay)

    let first = try secrets.storeKey(for: paths)
    #expect(first.count == 32)
    try Data("sealed rows".utf8).write(to: paths.data.appendingPathComponent("matrix-sdk-crypto.sqlite3"))
    try keys.save(Data("session".utf8), as: secrets.sessionName)
    #expect(try secrets.storeKey(for: paths) == first)

    // The key is lost, as after a restore to a new phone: the old store can't be opened, so it goes.
    try keys.delete(secrets.storeKeyName)
    let second = try secrets.storeKey(for: paths)
    #expect(second != first)
    #expect(paths.isEmpty)
    #expect(try keys.load(secrets.sessionName) == nil)
}

@Test func aReinstallDropsTheOldSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try MessagesStorePaths(account: mckay, support: root.appendingPathComponent("s"), caches: root.appendingPathComponent("c"))
    let keys = MemoryKeys()
    let secrets = MessagesSecrets(keys: keys, account: mckay)
    try keys.save(Data(repeating: 1, count: 32), as: secrets.storeKeyName)
    try keys.save(Data("session".utf8), as: secrets.sessionName)
    // The container is empty, but the Keychain kept both.
    _ = try secrets.storeKey(for: paths)
    #expect(try keys.load(secrets.sessionName) == nil)
}

// MARK: The model

@MainActor
@Test func requestsAndChatsAreKeptApart() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!chat", title: "ana_ruiz", lastMessage: "See you there", lastActivity: jan1, unread: 2),
        ChatSummary(id: "!req", title: "mckay_test", isRequest: true, from: "@mckay_test:usetotality.com"),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()
    #expect(model.phase == .ready)
    #expect(model.chats.map(\.id) == ["!chat"])
    #expect(model.requests.map(\.id) == ["!req"])
    #expect(model.connection == .online)

    await model.accept(model.requests[0])
    await settle()
    #expect(model.requests.isEmpty)
    #expect(Set(model.chats.map(\.id)) == ["!chat", "!req"])
}

@MainActor
@Test func blockingADeclinesAndRecordsIt() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!req", title: "spammer", isRequest: true, from: "@spammer:usetotality.com"),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()
    await model.block(model.requests[0])
    await settle()
    #expect(model.requests.isEmpty)
    #expect(service.actions == ["block !req"])
}

@MainActor
@Test func aDifferentSignInGetsADifferentConnection() async {
    let first = FakeService(account: mckay, user: "mckay_clemens", chats: [ChatSummary(id: "!private", title: "ana_ruiz")])
    let second = FakeService(account: test, user: "mckay_test", chats: [])
    let signedIn = Signed(mckay)
    let model = MessagesModel(account: { signedIn.value }, connector: { account in account == mckay ? first : second })
    await model.connect()
    await settle()
    #expect(model.chats.count == 1)

    signedIn.value = test
    await model.connect()
    await settle()
    #expect(first.stopped)
    #expect(model.chats.isEmpty)
    #expect(model.userID == "@mckay_test:usetotality.com")
}

@MainActor
@Test func signingOutStopsMessages() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [ChatSummary(id: "!private", title: "ana_ruiz")])
    let signedIn = Signed(mckay)
    let model = MessagesModel(account: { signedIn.value }, connector: { _ in service })
    await model.connect()
    await settle()
    signedIn.value = nil
    await model.checkAccount()
    #expect(service.stopped)
    #expect(model.chats.isEmpty)
    #expect(model.phase == .idle)
    await model.connect()
    #expect(model.phase == .failed(MessagesError.notSignedIn.message))
}

@MainActor
@Test func startingAChatChecksTheUsernameFirst() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()

    #expect(await model.startChat(with: "@@x") == nil)
    #expect(model.notice == MessagesError.notAUsername.message)
    #expect(await model.startChat(with: "@mckay_clemens") == nil)
    #expect(model.notice == MessagesError.ownUsername.message)
    #expect(await model.startChat(with: "nobody_here") == nil)
    #expect(model.notice == MessagesError.noSuchPerson.message)
    #expect(await model.startChat(with: "@MCKAY_test") == "!dm-mckay_test")
    #expect(model.notice == nil)
    #expect(service.actions == ["start nobody_here", "start mckay_test"])
}

@MainActor
@Test func theHomeTileNamesPeopleButNeverShowsMessageText() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!chat", title: "ana_ruiz", lastMessage: "The door code is 4471", lastActivity: jan1, unread: 1),
        ChatSummary(id: "!req", title: "mckay_test", isRequest: true),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    #expect(model.glance.isQuiet)
    await model.connect()
    await settle()
    #expect(model.glance.lines == ["1 request", "1 unread chat", "ana_ruiz"])
    #expect(!model.glance.lines.joined().contains("4471"))
}

@MainActor
@Test func withoutBackendSettingsMessagesSaysSo() async {
    let model = MessagesModule.makeModel(account: nil, connector: nil)
    await model.connect()
    guard case .unavailable = model.phase else {
        Issue.record("expected unavailable, got \(model.phase)")
        return
    }
}

@MainActor
@Test func typingIsSentOnlyOnChangesAndOnlyWhenAllowed() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel, defaults: defaults)
    chat.draft = "On my"
    await chat.draftChanged()
    chat.draft = "On my way"
    await chat.draftChanged()
    await chat.send()
    #expect(channel.typing == [true, false])
    #expect(channel.sent == ["On my way"])
    #expect(chat.draft.isEmpty)

    defaults.set(false, forKey: MessagesPreferences.shareReadAndTypingKey)
    chat.draft = "Running late"
    await chat.draftChanged()
    #expect(channel.typing == [true, false])
}

@MainActor
@Test func readReceiptsGoPrivateWhenSwitchedOff() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    defaults.set(false, forKey: MessagesPreferences.shareReadAndTypingKey)
    await chat.start()
    #expect(channel.receipts == [true, false])
}

@MainActor
@Test func aFailedSendKeepsTheText() async {
    let channel = FakeChannel()
    channel.failSending = true
    let chat = ChatModel(channel: channel)
    chat.draft = "Back by six"
    await chat.send()
    #expect(chat.draft == "Back by six")
    #expect(chat.notice == MessagesError.offline.message)
}

@Test func timesReadLikeAPhone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
    let now = jan1.addingTimeInterval(3 * 86_400)
    #expect(MessagesTime.short(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
    #expect(MessagesTime.short(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar).contains("/"))
}

// MARK: Step 3: photos, replies, reactions, deleting

/// A wide JPEG carrying a GPS position and a camera make, like one straight off a phone.
private func phonePhoto(width: Int = 3000, height: Int = 1500) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    let metadata: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.2338, kCGImagePropertyGPSLongitude: 111.6585],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 14"],
    ]
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

private func properties(_ data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

@Test func photosLoseWhereTheyWereTakenAndShrink() throws {
    let original = try phonePhoto()
    #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil)
    let photo = try PhotoPrep.prepare(original)
    let sent = try properties(photo.data)
    #expect(sent[kCGImagePropertyGPSDictionary] == nil)
    #expect((sent[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
    #expect(max(photo.width, photo.height) == PhotoPrep.longestSide)
    #expect(photo.width == 2 * photo.height)
    #expect(max(photo.thumbnailWidth, photo.thumbnailHeight) == PhotoPrep.thumbnailSide)
    #expect(try properties(photo.thumbnail)[kCGImagePropertyGPSDictionary] == nil)
}

@Test func somethingThatIsntAPhotoIsRefused() {
    #expect(throws: MessagesError.self) { try PhotoPrep.prepare(Data("Dinner at 7".utf8)) }
}

@MainActor
@Test func aReplyGoesWithTheMessageItAnswers() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    let question = ChatMessage(id: "m1", sender: "@mckay_test:usetotality.com", body: "Lunch tomorrow?", isOwn: false, time: jan1)
    chat.replyingTo = question
    chat.draft = "Yes, noon works"
    await chat.send()
    #expect(channel.sent == ["Yes, noon works"])
    #expect(channel.replies == ["m1"])
    #expect(chat.replyingTo == nil)
}

@MainActor
@Test func aFailedReplyKeepsWhatItAnswered() async {
    let channel = FakeChannel()
    channel.failSending = true
    let chat = ChatModel(channel: channel)
    let question = ChatMessage(id: "m1", sender: "@mckay_test:usetotality.com", body: "Lunch tomorrow?", isOwn: false, time: jan1)
    chat.replyingTo = question
    chat.draft = "Yes, noon works"
    await chat.send()
    #expect(chat.replyingTo == question)
    #expect(chat.draft == "Yes, noon works")
}

@MainActor
@Test func aPhotoIsPreparedBeforeItsSent() async throws {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    await chat.sendPhoto(try phonePhoto(width: 800, height: 600))
    #expect(channel.photos.count == 1)
    #expect(try properties(channel.photos[0].data)[kCGImagePropertyGPSDictionary] == nil)
    #expect(chat.sendingPhoto == false)
}

@MainActor
@Test func onlyYourOwnMessagesCanBeDeleted() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    let theirs = ChatMessage(id: "m1", sender: "@mckay_test:usetotality.com", body: "See you there", isOwn: false, time: jan1)
    let mine = ChatMessage(id: "m2", sender: "@mckay_clemens:usetotality.com", body: "Running late", isOwn: true, time: jan1)
    #expect(!theirs.canDelete)
    #expect(mine.canDelete)
    await chat.delete(theirs)
    await chat.delete(mine)
    #expect(channel.deleted == ["m2"])
}

@MainActor
@Test func reactionsReachTheRightMessage() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    let message = ChatMessage(id: "m7", sender: "@mckay_test:usetotality.com", body: "We won", isOwn: false, time: jan1)
    await chat.toggleReaction("❤️", on: message)
    #expect(channel.reactions == ["❤️@m7"])
}

@Test func photosAndDeletedMessagesHaveNothingToCopy() {
    let photo = ChatMessage(id: "p", sender: "a", body: "Photo", isOwn: true, time: jan1, kind: .photo(width: 4, height: 3))
    let gone = ChatMessage(id: "d", sender: "a", body: "Message deleted", isOwn: true, time: jan1, kind: .deleted)
    let locked = ChatMessage(id: "l", sender: "a", body: "Waiting for this message's key", isOwn: false, time: jan1, decrypted: false)
    let text = ChatMessage(id: "t", sender: "a", body: "Gate code 4412", isOwn: false, time: jan1)
    #expect(photo.copyableText == nil)
    #expect(gone.copyableText == nil)
    #expect(locked.copyableText == nil)
    #expect(text.copyableText == "Gate code 4412")
    #expect(!gone.canDelete)
}

@MainActor
@Test func openedPhotosStayInMemoryAndAreForgottenOnClose() async {
    let chat = ChatModel(channel: FakeChannel())
    let photo = ChatMessage(id: "p1", sender: "a", body: "Photo", isOwn: false, time: jan1, kind: .photo(width: nil, height: nil))
    #expect(await chat.photo(photo, thumbnail: true) == Data("p1|true".utf8))
    #expect(await chat.photo(photo, thumbnail: false) == Data("p1|false".utf8))
}

@MainActor
@Test func photoMemoryKeepsOnlyTheNewest() {
    let memory = PhotoMemory(limit: 2)
    memory["a"] = Data([1])
    memory["b"] = Data([2])
    memory["c"] = Data([3])
    #expect(memory["a"] == nil)
    #expect(memory["c"] == Data([3]))
    memory.removeAll()
    #expect(memory["c"] == nil)
}

private final class Signed: @unchecked Sendable {
    var value: String?
    init(_ value: String?) { self.value = value }
}
