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

    private(set) var openedChannels: [FakeChannel] = []
    func openChat(_ chat: String) async throws -> any ChatChannel {
        let channel = FakeChannel()
        lock.withLock { openedChannels.append(channel) }
        return channel
    }

    private(set) var blockedList: [String] = []

    private(set) var groupPhotos: [GroupPhoto] = []

    func groupPhoto(_ location: String) async throws -> Data { try phonePhoto(width: 800, height: 800) }

    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String {
        record("group \(usernames.joined(separator: ",")) \(name ?? "-")")
        if let photo { lock.withLock { groupPhotos.append(photo) } }
        guard usernames.allSatisfy(known.contains) else { throw MessagesError.noSuchPerson }
        return "!group"
    }

    func block(person: String, leaving chat: String?) async throws {
        record("block \(person) \(chat ?? "-")")
        lock.withLock { blockedList.append(person) }
        if let chat { update { $0.removeAll { $0.id == chat } } }
    }

    func blocked() async throws -> [String] { lock.withLock { blockedList } }

    func unblock(_ person: String) async throws {
        record("unblock \(person)")
        lock.withLock { blockedList.removeAll { $0 == person } }
    }

    func leave(_ chat: String) async throws {
        record("leave \(chat)")
        update { $0.removeAll { $0.id == chat } }
    }

    private(set) var secretsSeen: [String?] = []
    /// Another device already backed this account's message keys up.
    var backupElsewhere = false

    func settleKeys(recoverySecret: String?) async -> MessageKeys {
        lock.withLock { secretsSeen.append(recoverySecret) }
        if recoverySecret != nil { return .backedUp }
        return backupElsewhere ? .canRestore : .needsRecoveryKey
    }

    func stop() async { lock.withLock { stopped = true } }

    private func record(_ action: String) { lock.withLock { actions.append(action) } }

    private func update(_ change: (inout [ChatSummary]) -> Void) {
        let (now, listener) = lock.withLock { change(&chats); return (chats, onChats) }
        listener?(now)
    }
}

final class FakeChannel: ChatChannel, @unchecked Sendable {
    let title = "mckay_test"
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private(set) var typing: [Bool] = []
    private(set) var receipts: [Bool] = []
    private(set) var replies: [String?] = []
    private(set) var photos: [OutgoingPhoto] = []
    private(set) var reactions: [String] = []
    private(set) var deleted: [String] = []
    private(set) var videos: [OutgoingVideo] = []
    private(set) var settings: [Disappearing] = []
    var failSending = false
    var failReactions = false
    var startingSetting = DisappearingState.off
    var startingMessages: [ChatMessage] = []
    let id = "!chat"
    let otherPerson: String? = "@mckay_test:usetotality.com"
    var isGroup = false
    let photo: String? = nil
    private(set) var names: [String?] = []
    private(set) var groupPhotos: [GroupPhoto?] = []
    func rename(_ name: String?) async throws { lock.withLock { names.append(name) } }
    func setPhoto(_ photo: GroupPhoto?) async throws { lock.withLock { groupPhotos.append(photo) } }
    var extraPeople: [String] = []

    func observe(messages: @escaping @Sendable ([ChatMessage]) -> Void, typing: @escaping @Sendable ([String]) -> Void) async {
        messages(startingMessages)
    }
    func observeDisappearing(_ onChange: @escaping @Sendable (DisappearingState) -> Void) async { onChange(startingSetting) }
    func setDisappearing(_ setting: Disappearing) async throws {
        if failSending { throw MessagesError.offline }
        lock.withLock { settings.append(setting) }
    }
    func sendVideo(_ video: OutgoingVideo, replyingTo: String?) async throws {
        lock.withLock { videos.append(video) }
    }
    func video(_ message: String) async throws -> Data { Data(message.utf8) }
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
    func toggleReaction(_ key: String, on message: String) async throws {
        if failReactions { throw MessagesError.offline }
        lock.withLock { reactions.append("\(key)@\(message)") }
    }
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

// MARK: Step 4: disappearing messages, groups, blocking

/// A setting that was on from before any message in these tests.
private func on(_ setting: Disappearing) -> DisappearingState {
    DisappearingState(setting: setting, since: jan1.addingTimeInterval(-86_400))
}

@Test func turningItOnNeverReachesBackIntoEarlierMessages() {
    let messages = [
        ChatMessage(id: "before", sender: "@me:x", body: "Months-old plans", isOwn: true, time: jan1, seen: true),
        ChatMessage(id: "theirs", sender: "@ana:x", body: "Old reply", isOwn: false, time: jan1),
        ChatMessage(id: "after", sender: "@me:x", body: "Sent once it was on", isOwn: true, time: jan1.addingTimeInterval(10 * 86_400)),
    ]
    let turnedOn = jan1.addingTimeInterval(9 * 86_400)
    let later = jan1.addingTimeInterval(30 * 86_400)
    for setting in [Disappearing.day, .afterViewing] {
        let state = DisappearingState(setting: setting, since: turnedOn, changedBy: "@ana:x")
        #expect(!DisappearingRule.due(messages, state: state, now: later).map(\.id).contains("before"))
        #expect(DisappearingRule.visible(messages, state: state, now: later, viewedUpTo: later).map(\.id).starts(with: ["before", "theirs"]))
    }
    // With no start time, nothing is touched at all.
    let unknown = DisappearingState(setting: .day, since: nil)
    #expect(DisappearingRule.due(messages, state: unknown, now: later).isEmpty)
    #expect(DisappearingRule.visible(messages, state: unknown, now: later, viewedUpTo: nil).count == 3)
}

@Test func disappearingSettingsRoundTripThroughTheRoomState() {
    for setting in Disappearing.allCases {
        #expect(Disappearing(stateJSON: setting.stateJSON) == setting, "\(setting)")
    }
    #expect(Disappearing(stateJSON: "not json") == .off)
    #expect(Disappearing(stateJSON: "{\"max_lifetime\":3600000}") == .hour)
    #expect(Disappearing(stateJSON: "{\"max_lifetime\":86400000}") == .day)
    #expect(Disappearing(stateJSON: "{\"max_lifetime\":2592000000}") == .week)
    #expect(Disappearing(stateJSON: "{\"max_lifetime\":0}") == .off)
}

@Test func timedMessagesHideOnceTheyExpire() {
    let messages = [
        ChatMessage(id: "old", sender: "@ana:x", body: "From two days ago", isOwn: false, time: jan1),
        ChatMessage(id: "new", sender: "@ana:x", body: "From an hour ago", isOwn: false, time: jan1.addingTimeInterval(47 * 3600)),
    ]
    let now = jan1.addingTimeInterval(48 * 3600)
    #expect(DisappearingRule.visible(messages, state: on(.day), now: now, viewedUpTo: nil).map(\.id) == ["new"])
    #expect(DisappearingRule.visible(messages, state: on(.week), now: now, viewedUpTo: nil).map(\.id) == ["old", "new"])
    #expect(DisappearingRule.visible(messages, state: .off, now: now, viewedUpTo: nil).count == 2)
}

@Test func afterViewingHidesWhatYouveAlreadySeenFromOthers() {
    let messages = [
        ChatMessage(id: "seen", sender: "@ana:x", body: "The gate code is 4417", isOwn: false, time: jan1),
        ChatMessage(id: "mine", sender: "@me:x", body: "Got it", isOwn: true, time: jan1),
        ChatMessage(id: "fresh", sender: "@ana:x", body: "Parking is round the back", isOwn: false, time: jan1.addingTimeInterval(60)),
    ]
    let shown = DisappearingRule.visible(messages, state: on(.afterViewing), now: jan1.addingTimeInterval(120), viewedUpTo: jan1)
    #expect(shown.map(\.id) == ["mine", "fresh"])
}

@Test func onlyYourOwnSentMessagesAreDue() {
    let late = jan1.addingTimeInterval(2 * 86_400)
    let messages = [
        ChatMessage(id: "mine", sender: "@me:x", body: "Dinner's at seven", isOwn: true, time: jan1),
        ChatMessage(id: "sending", sender: "@me:x", body: "Bring the salad", isOwn: true, time: jan1, state: .sending),
        ChatMessage(id: "theirs", sender: "@ana:x", body: "Will do", isOwn: false, time: jan1),
        ChatMessage(id: "seen", sender: "@me:x", body: "Door's open", isOwn: true, time: late, seen: true),
    ]
    #expect(DisappearingRule.due(messages, state: on(.day), now: late).map(\.id) == ["mine"])
    #expect(DisappearingRule.due(messages, state: on(.afterViewing), now: late).map(\.id) == ["seen"])
    #expect(DisappearingRule.due(messages, state: .off, now: late).isEmpty)
}

@Test func groupUsernamesAreCheckedAndTidied() throws {
    #expect(try GroupMembers.parse("@ana_ruiz, mckay_test  ana_ruiz, mckay_clemens", own: "mckay_clemens") == ["ana_ruiz", "mckay_test"])
    #expect(throws: MessagesError.self) { try GroupMembers.parse("ana_ruiz", own: "mckay_clemens") }
    #expect(throws: MessagesError.self) { try GroupMembers.parse("ana_ruiz, mckay clemens!", own: "x_y_z") }
    let twenty = (1...20).map { "friend_\($0)" }.joined(separator: ",")
    #expect(throws: MessagesError.self) { try GroupMembers.parse(twenty, own: "mckay_clemens") }
    let nineteen = (1...19).map { "friend_\($0)" }.joined(separator: ",")
    #expect(try GroupMembers.parse(nineteen, own: "mckay_clemens").count == 19)
}

@MainActor
@Test func dueMessagesAreRemovedOnceEach() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    channel.startingSetting = DisappearingState(setting: .day, since: Date().addingTimeInterval(-3 * 86_400))
    channel.startingMessages = [
        ChatMessage(id: "$old", sender: "@me:x", body: "Lunch at noon?", isOwn: true, time: Date().addingTimeInterval(-2 * 86_400)),
        ChatMessage(id: "$new", sender: "@me:x", body: "Running five late", isOwn: true, time: Date()),
    ]
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await settle()
    await chat.removeDue()
    #expect(channel.deleted == ["$old"])
    #expect(chat.messages.map(\.id) == ["$new"])
    chat.close()
}

@MainActor
@Test func leavingAnAfterViewingChatRemembersWhatYouSaw() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    channel.startingSetting = on(.afterViewing)
    channel.startingMessages = [
        ChatMessage(id: "$a", sender: "@ana:x", body: "The gate code is 4417", isOwn: false, time: jan1),
    ]
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await settle()
    #expect(chat.messages.count == 1)
    chat.close()
    #expect(defaults.object(forKey: "messages.viewedUpTo.!chat") as? Date == jan1)

    let again = ChatModel(channel: channel, defaults: defaults)
    await again.start()
    await settle()
    #expect(again.messages.isEmpty)
    again.close()
}

@MainActor
@Test func changingTheSettingKeepsTheOldOneWhenItFails() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    await chat.setDisappearing(.week)
    #expect(chat.disappearing == .week)
    channel.failSending = true
    await chat.setDisappearing(.off)
    #expect(chat.disappearing == .week)
    #expect(chat.notice == MessagesError.offline.message)
}

@MainActor
@Test func groupsStartFromTypedNamesAndBlockingCanBeUndone() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!dm", title: "mckay_test", lastMessage: "Hi", lastActivity: jan1),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()

    #expect(await model.startGroup(with: "ana_ruiz, @mckay_test") == "!group")
    #expect(await model.startGroup(with: "ana_ruiz") == nil)
    #expect(model.notice != nil)
    #expect(await model.startGroup(with: "ana_ruiz, nobody_here") == nil)

    #expect(await model.block(person: "@mckay_test:usetotality.com", leaving: "!dm"))
    await settle()
    #expect(model.chats.isEmpty)
    await model.loadBlocked()
    #expect(model.blockedPeople == ["@mckay_test:usetotality.com"])
    await model.unblock("@mckay_test:usetotality.com")
    #expect(model.blockedPeople.isEmpty)
    #expect(service.actions.contains("group ana_ruiz,mckay_test -"))
}

// MARK: Group names and photos

@Test func groupNamesAreTidied() {
    #expect(GroupName.clean("  Saturday climbing  ") == "Saturday climbing")
    #expect(GroupName.clean("Lake\nTrip") == "Lake Trip")
    #expect(GroupName.clean("   ") == nil)
    #expect(GroupName.clean(String(repeating: "a", count: 90))?.count == GroupName.longest)
}

@Test func groupLabelsSayTheNameAndPhotoArentEncrypted() {
    #expect(GroupLabels.notEncrypted == "Group name and photo aren't end-to-end encrypted. Messages are.")
    #expect(GroupLabels.photoOnServer.contains("without end-to-end encryption"))
}

@Test func aGroupPhotoLosesItsLocationAndIsMadeSmall() throws {
    let photo = try GroupPhoto.prepare(try phonePhoto())
    #expect(max(photo.width, photo.height) == GroupPhoto.side)
    let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
}

@MainActor
@Test func aGroupStartsWithItsNameAndARedrawnPhoto() async throws {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()
    let chat = await model.startGroup(with: "ana_ruiz, mckay_test", name: "  Lake trip ", photo: try phonePhoto())
    #expect(chat == "!group")
    #expect(service.actions.contains("group ana_ruiz,mckay_test Lake trip"))
    #expect(service.groupPhotos.first.map { max($0.width, $0.height) } == GroupPhoto.side)
    #expect(await model.groupPhoto("mxc://usetotality.com/abc") != nil)
}

@MainActor
@Test func renamingAndChangingTheGroupPhotoReachTheChat() async throws {
    let channel = FakeChannel()
    channel.isGroup = true
    let chat = ChatModel(channel: channel)
    #expect(await chat.rename(" Lake trip "))
    #expect(chat.title == "Lake trip")
    #expect(await chat.setGroupPhoto(try phonePhoto()))
    #expect(await chat.setGroupPhoto(nil))
    #expect(channel.names == ["Lake trip"])
    #expect(channel.groupPhotos.count == 2)
    #expect(channel.groupPhotos.last! == nil)
}

// MARK: One-to-one chats stay one-to-one

@Test func aChatIsReusedOnlyWhileItsJustTheTwoOfYou() {
    let me = "@mckay_clemens:usetotality.com", ana = "@ana_ruiz:usetotality.com", eve = "@eve_x:usetotality.com"
    #expect(DirectChatRule.isJustTheTwoOfYou(members: [me, ana], own: me, other: ana))
    #expect(DirectChatRule.isJustTheTwoOfYou(members: [ana, me], own: me, other: ana))
    // Someone invited a third person.
    #expect(!DirectChatRule.isJustTheTwoOfYou(members: [me, ana, eve], own: me, other: ana))
    // They left, or a stranger is there instead.
    #expect(!DirectChatRule.isJustTheTwoOfYou(members: [me], own: me, other: ana))
    #expect(!DirectChatRule.isJustTheTwoOfYou(members: [me, eve], own: me, other: ana))
    // Members couldn't be read: never treated as safe.
    #expect(!DirectChatRule.isJustTheTwoOfYou(members: [], own: me, other: ana))
    #expect(!DirectChatRule.isJustTheTwoOfYou(members: [me, ana, ana], own: me, other: ana))
    #expect(DirectChatRule.extraPeople(members: [me, ana, eve], own: me, other: ana) == [eve])
}

// MARK: Home tile and search

@MainActor
@Test func tileLinesOpenTheChatTheyName() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!ana", title: "ana_ruiz", lastMessage: "See you there", lastActivity: jan1, unread: 2),
        ChatSummary(id: "!lake", title: "Lake trip", lastMessage: "Bring the map", lastActivity: jan1.addingTimeInterval(-60), unread: 1, isGroup: true),
        ChatSummary(id: "!req", title: "mckay_test", isRequest: true, from: "@mckay_test:usetotality.com"),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()
    #expect(model.glance.lines == ["1 request", "2 unread chats", "ana_ruiz", "Lake trip"])
    #expect(model.glanceChat(at: 0) == nil)
    #expect(model.glanceChat(at: 1) == nil)
    #expect(model.glanceChat(at: 2) == "!ana")
    #expect(model.glanceChat(at: 3) == "!lake")
    #expect(model.glanceChat(at: 4) == nil)
    // Never message text on the tile.
    #expect(!model.glance.lines.contains { $0.contains("See you") || $0.contains("map") })
}

@MainActor
@Test func searchFindsChatsByNameButNeverByMessageText() async throws {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!ana", title: "ana_ruiz", lastMessage: "The gate code is 4417", lastActivity: jan1),
        ChatSummary(id: "!lake", title: "Lake trip", lastMessage: "Bring the map", lastActivity: jan1, isGroup: true),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    let searcher = MessagesSearcher(model: model)
    #expect(try await searcher.search("lake").isEmpty)
    await model.connect()
    await settle()
    let hits = try await searcher.search("LAKE trip")
    #expect(hits.map(\.itemID) == ["!lake"])
    #expect(hits.first?.detail == "Group")
    #expect(hits.first?.snippet == nil)
    #expect(try await searcher.search("4417").isEmpty)
    #expect(try await searcher.search("ana").map(\.itemID) == ["!ana"])
}

// MARK: Scrolling and the double-tap heart

@Test func newMessagesScrollIntoViewOnlyWhenYoureAtTheBottomOrSentThem() {
    #expect(ChatScroll.follows(atBottom: true, newestIsOwn: false))
    #expect(ChatScroll.follows(atBottom: false, newestIsOwn: true))
    #expect(!ChatScroll.follows(atBottom: false, newestIsOwn: false))
}

@Test func onlyMessagesOnTheServerCanTakeAHeart() {
    let sent = ChatMessage(id: "$a", sender: "@ana:x", body: "See you at six", isOwn: false, time: jan1)
    #expect(ChatScroll.canHeart(sent))
    #expect(!ChatScroll.canHeart(ChatMessage(id: "t", sender: "@me:x", body: "On my way", isOwn: true, time: jan1, state: .sending)))
    #expect(!ChatScroll.canHeart(ChatMessage(id: "$b", sender: "@ana:x", body: "", isOwn: false, time: jan1, decrypted: false)))
    #expect(!ChatScroll.canHeart(ChatMessage(id: "$c", sender: "@ana:x", body: "Message deleted", isOwn: false, time: jan1, kind: .deleted)))
    #expect(QuickReactions.heart == "❤️")
}

@MainActor
@Test func aDoubleTapHeartGoesToThatMessage() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel)
    let message = ChatMessage(id: "$a", sender: "@ana:x", body: "See you at six", isOwn: false, time: jan1)
    await chat.toggleReaction(QuickReactions.heart, on: message)
    #expect(channel.reactions == ["❤️@$a"])
}

// MARK: Key backup under the recovery key

@Test func theBackupSecretComesFromTheContentKeyAlone() throws {
    let key = try ContentRootKey(bytes: Data(repeating: 7, count: 32))
    let same = try ContentRootKey(bytes: Data(repeating: 7, count: 32))
    let other = try ContentRootKey(bytes: Data(repeating: 8, count: 32))
    #expect(key.matrixRecoverySecret() == same.matrixRecoverySecret())
    #expect(key.matrixRecoverySecret() != other.matrixRecoverySecret())
    #expect(key.matrixRecoverySecret() != Data(repeating: 7, count: 32).base64EncodedString())
    #expect(Data(base64Encoded: key.matrixRecoverySecret())?.count == 32)
}

@MainActor
@Test func messagesSaysWhenTheRecoveryKeyIsMissingAndWhenItsBackedUp() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [])
    let secret = LockedSecret()
    let model = MessagesModel(account: { mckay }, connector: { _ in service }, recoverySecret: { account in account == mckay ? secret.value : nil })
    await model.connect()
    #expect(model.keys == .needsRecoveryKey)
    #expect(model.keys.summary?.contains("recovery key") == true)
    secret.value = "from-the-content-key"
    await model.settleKeys()
    #expect(model.keys == .backedUp)
    #expect(service.secretsSeen == [nil, "from-the-content-key"])
    await model.disconnect()
    #expect(model.keys == .checking)
}

private final class LockedSecret: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: Messages that won't open

@Test func yourOwnLockedMessageSaysItCameFromAnEarlierInstall() {
    #expect(LockedMessage.placeholder(isOwn: true) == "Can't be opened on this device")
    #expect(LockedMessage.note(isOwn: true).contains("earlier install of Totality"))
    #expect(!LockedMessage.note(isOwn: true).contains("sender's device"))
}

@Test func someoneElsesLockedMessageStillWaitsForTheirDevice() {
    #expect(LockedMessage.placeholder(isOwn: false) == "Waiting for this message's key")
    #expect(LockedMessage.note(isOwn: false) == "It will open once the sender's device shares the key, usually when they're next online.")
}

@Test func restoreIsOfferedOnlyForYourOwnMessagesAndOnlyWhenABackupExists() {
    #expect(LockedMessage.offersRestore(isOwn: true, keys: .canRestore))
    #expect(!LockedMessage.offersRestore(isOwn: false, keys: .canRestore))
    for keys in [MessageKeys.checking, .backedUp, .needsRecoveryKey, .doesntOpen, .failed("x")] {
        #expect(!LockedMessage.offersRestore(isOwn: true, keys: keys))
    }
    #expect(LockedMessage.restoreLabel == "Restore with your recovery key")
    #expect(MessageKeys.canRestore.summary?.contains("recovery key") == true)
}

@MainActor
@Test func aBackupFromAnotherDeviceIsOfferedForRestoreUntilTheRecoveryKeyIsHere() async {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [])
    service.backupElsewhere = true
    let secret = LockedSecret()
    let model = MessagesModel(account: { mckay }, connector: { _ in service }, recoverySecret: { account in account == mckay ? secret.value : nil })
    await model.connect()
    #expect(model.keys == .canRestore)
    secret.value = "from-the-content-key"
    await model.settleKeys()
    #expect(model.keys == .backedUp)
    // The secret goes only to the service, and only once the recovery key put it on this device.
    #expect(service.secretsSeen == [nil, "from-the-content-key"])
}

@Test func theBackupSecretIsOnlyForTheAccountThatOwnsThisDevicesKey() {
    #expect(RecoverySecretRule.allows(keyOwner: mckay, account: mckay, joinedBackup: true))
    #expect(!RecoverySecretRule.allows(keyOwner: mckay, account: test, joinedBackup: true))
    #expect(!RecoverySecretRule.allows(keyOwner: nil, account: mckay, joinedBackup: true))
    #expect(!RecoverySecretRule.allows(keyOwner: mckay, account: mckay, joinedBackup: false))
}

@MainActor
@Test func messagesAsksForTheSecretOfTheAccountItsConnectedAs() async {
    let service = FakeService(account: test, user: "mckay_test", chats: [])
    let asked = LockedSecret()
    let model = MessagesModel(account: { test }, connector: { _ in service }, recoverySecret: { account in
        asked.value = account
        return nil
    })
    await model.connect()
    #expect(asked.value == test)
    #expect(service.secretsSeen == [nil])
}

// MARK: Other people's profiles

private final class FakeDirectory: ProfileDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [String: PublicProfile]
    private var asked: [String] = []
    var offline = false

    init(_ profiles: [PublicProfile]) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.username, $0) })
    }

    private var queries: [[String]] = []
    private var downloaded: [String] = []

    /// Every handle asked for, in order.
    var lookups: [String] { lock.withLock { asked } }
    /// Each query's handles.
    var batches: [[String]] { lock.withLock { queries } }
    /// Photo file names that had to be downloaded, because the device didn't have them.
    var downloads: [String] { lock.withLock { downloaded } }
    func change(_ profile: PublicProfile) { lock.withLock { profiles[profile.username] = profile } }

    func profiles(of usernames: [String], photos: [String: Data]) async throws -> [String: PublicProfile] {
        try lock.withLock {
            asked += usernames
            queries.append(usernames)
            if offline { throw URLError(.notConnectedToInternet) }
            var found: [String: PublicProfile] = [:]
            for name in usernames {
                guard let profile = profiles[name] else { continue }
                var photo: Data?
                if let key = profile.photoKey {
                    photo = photos[key]
                    if photo == nil { downloaded.append(key); photo = profile.photo }
                }
                found[name] = PublicProfile(
                    username: name, displayName: profile.displayName, bio: profile.bio, photo: photo, photoKey: profile.photoKey
                )
            }
            return found
        }
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private let ana = PublicProfile(username: "ana_ruiz", displayName: "Ana Ruiz", bio: "Climbs on Saturdays.", photo: nil)

@Test func onlyTotalityHandlesAreLookedUp() {
    #expect(MessagesPeople.handle(of: "@ana_ruiz:usetotality.com") == "ana_ruiz")
    #expect(MessagesPeople.handle(of: "@ana_ruiz:matrix.org") == nil)
    #expect(MessagesPeople.handle(of: "@ana_ruiz:evil.usetotality.com") == nil)
    #expect(MessagesPeople.handle(of: "@ana_ruiz:usetotality.com.evil.net") == nil)
    #expect(MessagesPeople.handle(of: "@Ana_Ruiz:usetotality.com") == nil)
    #expect(MessagesPeople.handle(of: "@a:usetotality.com") == nil)
    #expect(MessagesPeople.handle(of: "ana_ruiz") == nil)
}

@MainActor
@Test func aProfileIsKeptForADayThenFetchedAgain() async {
    let clock = Clock()
    let directory = FakeDirectory([ana])
    let people = MessagesPeople(now: { clock.now })
    people.directory = directory
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com", "@stranger:matrix.org"])
    #expect(people.name(ofMatrixID: "@ana_ruiz:usetotality.com") == "Ana Ruiz")
    #expect(people.name(ofMatrixID: "@stranger:matrix.org") == "stranger")
    #expect(directory.lookups == ["ana_ruiz"])

    clock.now += 60 * 60
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    #expect(directory.lookups.count == 1)

    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: nil, photo: nil))
    clock.now += MessagesPeople.freshFor
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    #expect(directory.lookups.count == 2)
    #expect(people.name(ofMatrixID: "@ana_ruiz:usetotality.com") == "Ana R.")
}

@MainActor
@Test func aPullFetchesEveryoneAgain() async {
    let directory = FakeDirectory([ana])
    let people = MessagesPeople()
    people.directory = directory
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: nil, photo: nil))
    await people.refresh()
    #expect(directory.lookups == ["ana_ruiz", "ana_ruiz"])
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.name == "Ana R.")
}

@MainActor
@Test func offlineKeepsWhatWasSavedAndOtherwiseSaysSo() async {
    let clock = Clock()
    let directory = FakeDirectory([ana])
    let people = MessagesPeople(now: { clock.now })
    people.directory = directory
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    directory.offline = true
    clock.now += MessagesPeople.freshFor * 3
    await people.refresh()
    #expect(people.phase(of: "ana_ruiz") == .found(ana))
    await people.want(matrixIDs: ["@mckay_test:usetotality.com"])
    guard case .failed = people.phase(of: "mckay_test") else {
        Issue.record("An unknown person offline should say it didn't load")
        return
    }
    directory.offline = false
    await people.reload("mckay_test")
    #expect(people.phase(of: "mckay_test") == .missing)
}

@MainActor
@Test func noOneIsKnownBeforeTheyreFetched() {
    let people = MessagesPeople()
    #expect(people.phase(of: "ana_ruiz") == .loading)
    #expect(people.name(ofMatrixID: "@ana_ruiz:usetotality.com") == "ana_ruiz")
}

@MainActor
@Test func savedProfilesComeBackForTheSameAccountOnly() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("people.json")

    let first = MessagesPeople()
    first.directory = FakeDirectory([ana])
    first.open(file: file)
    await first.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    first.close()
    #expect(first.profile(ofMatrixID: "@ana_ruiz:usetotality.com") == nil)

    let again = MessagesPeople()
    again.open(file: file)
    #expect(again.profile(ofMatrixID: "@ana_ruiz:usetotality.com") == ana)
    again.open(file: folder.appendingPathComponent("someone-else.json"))
    #expect(again.profile(ofMatrixID: "@ana_ruiz:usetotality.com") == nil)
}

@MainActor
@Test func aTamperedSaveDropsItsBadPhotoAndBadHandles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("people.json")
    let fetched = Date()
    let saved: [String: MessagesPeople.Entry] = [
        "ana_ruiz": .init(profile: PublicProfile(username: "ana_ruiz", displayName: "Ana Ruiz", bio: nil, photo: Data("<svg/>".utf8)), fetched: fetched),
        "../escape": .init(profile: nil, fetched: fetched),
        "mckay_test": .init(profile: PublicProfile(username: "someone_else", displayName: "Not them", bio: nil, photo: nil), fetched: fetched),
    ]
    try JSONEncoder().encode(saved).write(to: file)
    let people = MessagesPeople()
    people.open(file: file)
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.photo == nil)
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.name == "Ana Ruiz")
    #expect(people.phase(of: "mckay_test") == .loading)
    #expect(people.entries.count == 1)
}

@MainActor
@Test func theChatListAsksForTheOtherPersonButNeverARequestsSender() async {
    let directory = FakeDirectory([ana])
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!ana", title: "ana_ruiz", lastActivity: jan1, otherPerson: "@ana_ruiz:usetotality.com"),
        ChatSummary(id: "!req", title: "mckay_test", isRequest: true, from: "@mckay_test:usetotality.com"),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    model.people.directory = directory
    await model.connect()
    for _ in 0..<50 where model.people.profile(ofMatrixID: "@ana_ruiz:usetotality.com") == nil {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.people.name(ofMatrixID: "@ana_ruiz:usetotality.com") == "Ana Ruiz")
    #expect(directory.lookups == ["ana_ruiz"])
    #expect(model.filtered("Ana R").map(\.id) == ["!ana"])
}

@MainActor
@Test func everyoneIsRefreshedInOneQuery() async {
    let directory = FakeDirectory([ana, PublicProfile(username: "mckay_test", displayName: nil, bio: nil, photo: nil)])
    let people = MessagesPeople()
    people.directory = directory
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com", "@mckay_test:usetotality.com", "@ghost_user:usetotality.com"])
    await people.refresh()
    #expect(directory.batches == [["ana_ruiz", "ghost_user", "mckay_test"], ["ana_ruiz", "ghost_user", "mckay_test"]])
    #expect(people.phase(of: "ghost_user") == .missing)
}

@MainActor
@Test func aPhotoIsDownloadedAgainOnlyWhenItsNameChanges() async {
    let first = Data("first photo".utf8)
    let second = Data("second photo".utf8)
    let directory = FakeDirectory([
        PublicProfile(username: "ana_ruiz", displayName: "Ana Ruiz", bio: nil, photo: first, photoKey: "a/1.jpg"),
    ])
    let people = MessagesPeople()
    people.directory = directory
    await people.want(matrixIDs: ["@ana_ruiz:usetotality.com"])
    await people.refresh()
    #expect(directory.downloads == ["a/1.jpg"])

    // A new name or bio shows on the next refresh, with the same photo kept.
    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: "New bio", photo: first, photoKey: "a/1.jpg"))
    await people.refresh()
    #expect(directory.downloads == ["a/1.jpg"])
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.name == "Ana R.")
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.bio == "New bio")

    // A new photo gets a new name, so it's fetched.
    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: nil, photo: second, photoKey: "a/2.jpg"))
    await people.refresh()
    #expect(directory.downloads == ["a/1.jpg", "a/2.jpg"])
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.photo == second)

    // A removed photo goes to initials.
    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: nil, photo: nil))
    await people.refresh()
    #expect(people.profile(ofMatrixID: "@ana_ruiz:usetotality.com")?.photo == nil)
}

@MainActor
@Test func messagesRefresherKeepsProfilesInStep() async {
    let directory = FakeDirectory([ana])
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!ana", title: "ana_ruiz", lastActivity: jan1, otherPerson: "@ana_ruiz:usetotality.com"),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    model.people.directory = directory
    await model.connect()
    for _ in 0..<50 where model.people.profile(ofMatrixID: "@ana_ruiz:usetotality.com") == nil {
        try? await Task.sleep(for: .milliseconds(20))
    }
    directory.change(PublicProfile(username: "ana_ruiz", displayName: "Ana R.", bio: nil, photo: nil))
    // What AppRefresh runs at launch, on coming back and every minute.
    await model.refresher.refresh()
    #expect(model.people.name(ofMatrixID: "@ana_ruiz:usetotality.com") == "Ana R.")
}

// MARK: Home tiles (issue 127)

@MainActor
private func homeModel(_ chats: [ChatSummary]) async -> MessagesModel {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: chats)
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    await settle()
    return model
}

private let homeChats = [
    ChatSummary(id: "!ana", title: "Ana Ruiz", lastMessage: "See you there", lastActivity: jan1, unread: 2, otherPerson: "@ana_ruiz:usetotality.com"),
    ChatSummary(id: "!lake", title: "Lake trip", lastMessage: "Bring the map", lastActivity: jan1 - 60, isGroup: true, lastSender: "@dev_patel:usetotality.com"),
    ChatSummary(id: "!sam", title: "Sam Ortiz", lastMessage: "You: Thanks!", lastActivity: jan1 - 120, otherPerson: "@sam_ortiz:usetotality.com"),
    ChatSummary(id: "!priya", title: "Priya N", lastMessage: "Done", lastActivity: jan1 - 180, unread: 1, otherPerson: "@priya_n:usetotality.com"),
    ChatSummary(id: "!omar", title: "Omar Haddad", lastMessage: "Ok", lastActivity: jan1 - 240, otherPerson: "@omar:usetotality.com"),
    ChatSummary(id: "!req", title: "mckay_test", isRequest: true, from: "@mckay_test:usetotality.com"),
]

@MainActor
@Test("Medium: faces of chats with something unread, or the most recent when there's nothing")
func homeMediumFaces() async {
    let model = await homeModel(homeChats)
    #expect(model.homeFaces.hasUnread)
    #expect(model.homeFaces.chats.map(\.id) == ["!ana", "!priya"])
    let quiet = await homeModel(homeChats.map {
        ChatSummary(id: $0.id, title: $0.title, isRequest: $0.isRequest, lastMessage: $0.lastMessage, lastActivity: $0.lastActivity, isGroup: $0.isGroup)
    })
    #expect(!quiet.homeFaces.hasUnread)
    // Requests never show as faces: looking one up would say it was seen.
    #expect(quiet.homeFaces.chats.map(\.id) == ["!ana", "!lake", "!sam", "!priya"])
}

@MainActor
@Test("Large: the three most recent, and a group names who spoke last")
func homeLargeRows() async {
    let model = await homeModel(homeChats)
    #expect(model.homeRows.map(\.id) == ["!ana", "!lake", "!sam"])
    #expect(model.homeLastLine(of: model.homeRows[0]) == "See you there")
    #expect(model.homeLastLine(of: model.homeRows[1]) == "dev_patel: Bring the map")
    #expect(model.homeLastLine(of: model.homeRows[2]) == "You: Thanks!")
}

@MainActor
@Test("Square: the newest chat with something unread, switched by its faces")
func homeSquarePicks() async {
    let model = await homeModel(homeChats)
    #expect(model.homeTarget?.id == "!ana")
    #expect(model.homeSwitcher.map(\.id) == ["!ana", "!priya", "!lake", "!sam", "!omar"])
    model.homePicked = "!sam"
    #expect(model.homeTarget?.id == "!sam")
    // A pick that's gone falls back.
    model.homePicked = "!gone"
    #expect(model.homeTarget?.id == "!ana")
    let empty = await homeModel([])
    #expect(empty.homeTarget == nil)
}

@MainActor
@Test("Square: showing a chat there marks nothing read and sends nothing")
func homeSquareDoesntRead() async {
    let channel = FakeChannel()
    channel.startingMessages = (1...6).map {
        ChatMessage(id: "$\($0)", sender: "@mckay_test:usetotality.com", body: "Message \($0)", isOwn: false, time: jan1 + Double($0))
    }
    let chat = ChatModel(channel: channel, defaults: UserDefaults(suiteName: "home-\(UUID())")!)
    await chat.start(markingRead: false)
    await settle()
    #expect(chat.messages.count == 6)
    #expect(channel.receipts.isEmpty)
    #expect(channel.sent.isEmpty)
    #expect(channel.typing.isEmpty)
}

@MainActor
@Test("Opening a chat in Messages still marks it read")
func openingStillReads() async {
    let channel = FakeChannel()
    channel.startingMessages = [ChatMessage(id: "$1", sender: "@mckay_test:usetotality.com", body: "Hi", isOwn: false, time: jan1)]
    let chat = ChatModel(channel: channel, defaults: UserDefaults(suiteName: "open-\(UUID())")!)
    await chat.start()
    await settle()
    #expect(!channel.receipts.isEmpty)
}

@MainActor
@Test("Square: a double tap hearts the message")
func homeSquareHeart() async {
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel, defaults: UserDefaults(suiteName: "heart-\(UUID())")!)
    let message = ChatMessage(id: "$1", sender: "@mckay_test:usetotality.com", body: "Hi", isOwn: false, time: jan1)
    await chat.toggleReaction(QuickReactions.heart, on: message)
    #expect(channel.reactions == ["❤️@$1"])
}

// MARK: Who can message me (issue 149, step 8)

private final class FakePrivacy: MessagePrivacyService, @unchecked Sendable {
    private let lock = NSLock()
    var answers: [String: ReachAnswer] = [:]
    var reachValue: MessageReach = .anyone
    var waiting: [MessageRequest] = []
    var acceptedNames: [String] = []
    var offline = false
    var failSave = false
    private(set) var actions: [String] = []

    private func record(_ a: String) { lock.withLock { actions.append(a) } }
    func myReach() async throws -> MessageReach { reachValue }
    func setReach(_ reach: MessageReach) async throws {
        if failSave { throw MessagesError.offline }
        record("set \(reach.rawValue)")
        reachValue = reach
    }
    func reach(_ username: String) async throws -> ReachAnswer {
        if offline { throw MessagesError.offline }
        return answers[username] ?? .allowed
    }
    func sendRequest(to username: String) async throws { record("ask \(username)") }
    func incoming() async throws -> [MessageRequest] { waiting }
    func answer(_ username: String, accept: Bool) async throws { record("\(accept ? "accept" : "decline") \(username)") }
    func accepted() async throws -> [String] { acceptedNames }
}

@MainActor
private func privacyModel(_ privacy: FakePrivacy, chats: [ChatSummary] = []) async -> (MessagesModel, FakeService) {
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: chats)
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    model.privacy = privacy
    await model.connect()
    await settle()
    return (model, service)
}

@MainActor
@Test func someoneWhoseSettingLeavesYouOutIsOfferedARequestNotAChat() async {
    let privacy = FakePrivacy()
    privacy.answers["ana_ruiz"] = .ask
    let (model, service) = await privacyModel(privacy)
    #expect(await model.startChat(with: "@ana_ruiz") == nil)
    #expect(model.needsRequest == "ana_ruiz")
    #expect(model.notice == nil)
    #expect(service.actions.isEmpty)

    #expect(await model.sendRequest())
    #expect(privacy.actions == ["ask ana_ruiz"])
    #expect(model.needsRequest == nil)
    #expect(model.sentRequestTo == "ana_ruiz")
}

@MainActor
@Test func aWaitingRequestOrAnUnknownNameStartsNothing() async {
    let privacy = FakePrivacy()
    privacy.answers = ["ana_ruiz": .asked, "ghost_name": .unknown]
    let (model, service) = await privacyModel(privacy)
    #expect(await model.startChat(with: "ana_ruiz") == nil)
    #expect(model.notice?.contains("waiting") == true)
    #expect(await model.startChat(with: "ghost_name") == nil)
    #expect(model.notice == MessagesError.noSuchPerson.message)
    #expect(service.actions.isEmpty)
}

@MainActor
@Test func anAllowedPersonAndAnExistingChatOpenAsBefore() async {
    let privacy = FakePrivacy()
    privacy.answers["ana_ruiz"] = .ask
    let (model, service) = await privacyModel(privacy, chats: [
        ChatSummary(id: "!dm-ana_ruiz", title: "ana_ruiz", otherPerson: "@ana_ruiz:usetotality.com"),
    ])
    // Ana's setting changed after you started talking: your chat keeps working.
    #expect(await model.startChat(with: "ana_ruiz") == "!dm-ana_ruiz")
    #expect(await model.startChat(with: "mckay_test") == "!dm-mckay_test")
    #expect(service.actions == ["start ana_ruiz", "start mckay_test"])
}

@MainActor
@Test func whenTheSettingCantBeAskedTheServerDecides() async {
    let privacy = FakePrivacy()
    privacy.offline = true
    let (model, service) = await privacyModel(privacy)
    #expect(await model.startChat(with: "ana_ruiz") == "!dm-ana_ruiz")
    #expect(service.actions == ["start ana_ruiz"])
}

@MainActor
@Test func acceptingARequestStartsTheChatAndDeletingOneSaysNothing() async {
    let privacy = FakePrivacy()
    privacy.waiting = [MessageRequest(username: "ana_ruiz", sent: nil), MessageRequest(username: "mckay_test", sent: nil)]
    let (model, service) = await privacyModel(privacy)
    #expect(model.messageRequests.map(\.username) == ["ana_ruiz", "mckay_test"])

    await model.accept(model.messageRequests[0])
    #expect(privacy.actions == ["accept ana_ruiz"])
    #expect(service.actions == ["start ana_ruiz"])
    #expect(model.requestedChat == "!dm-ana_ruiz")

    await model.decline(model.messageRequests[0])
    #expect(privacy.actions == ["accept ana_ruiz", "decline mckay_test"])
    #expect(model.messageRequests.isEmpty)
}

@MainActor
@Test func theChatYouAskedForIsJoinedAtOnceButNothingElse() async {
    let privacy = FakePrivacy()
    privacy.acceptedNames = ["ana_ruiz"]
    let (_, service) = await privacyModel(privacy, chats: [
        ChatSummary(id: "!from-ana", title: "ana_ruiz", isRequest: true, from: "@ana_ruiz:usetotality.com"),
        ChatSummary(id: "!group-ana", title: "Climbing", isRequest: true, from: "@ana_ruiz:usetotality.com", isGroup: true),
        ChatSummary(id: "!from-other", title: "spammer", isRequest: true, from: "@spammer:usetotality.com"),
    ])
    await settle()
    #expect(service.actions == ["accept !from-ana"])
}

@MainActor
@Test func aGroupWithSomeoneWhoHasntLetYouInDoesntStart() async {
    let privacy = FakePrivacy()
    privacy.answers["ana_ruiz"] = .ask
    let (model, service) = await privacyModel(privacy)
    #expect(await model.startGroup(with: "ana_ruiz, mckay_test") == nil)
    #expect(model.notice?.contains("@ana_ruiz") == true)
    #expect(service.actions.isEmpty)
    privacy.answers = [:]
    #expect(await model.startGroup(with: "ana_ruiz, mckay_test") == "!group")
}

@MainActor
@Test func theSettingLoadsAndAFailedSaveGoesBack() async {
    let privacy = FakePrivacy()
    privacy.reachValue = .followers
    let (model, _) = await privacyModel(privacy)
    #expect(model.reach == .followers)
    await model.setReach(.friends)
    #expect(model.reach == .friends)
    #expect(privacy.actions == ["set friends"])
    privacy.failSave = true
    await model.setReach(.anyone)
    #expect(model.reach == .friends)
    #expect(model.notice != nil)
}

@Test func theServersRefusalsReadPlainly() throws {
    let body = { (m: String) in (try? JSONSerialization.data(withJSONObject: ["message": m])) ?? Data() }
    #expect(RestMessagePrivacy.error(status: 400, data: body("too many message requests")).message.contains("tomorrow"))
    #expect(RestMessagePrivacy.error(status: 400, data: body("no such user")) == .noSuchPerson)
    #expect(RestMessagePrivacy.error(status: 401, data: Data()) == .notSignedIn)
    #expect(RestMessagePrivacy.error(status: 500, data: body("secret detail")).message == "That didn't go through. Try again.")
    #expect(MessageReach.allCases.map(\.title) == ["Anyone", "Followers", "Friends"])
}

// MARK: Disappearing up front: markers, view-once photos, new-chat default

@Test func everyMessageThatWillDisappearSaysSo() {
    let mine = ChatMessage(id: "a", sender: "@me:x", body: "Hi", isOwn: true, time: jan1)
    let now = jan1.addingTimeInterval(20 * 60)
    #expect(DisappearingRule.marker(for: mine, state: on(.hour), now: now) == "Disappears in 40 min")
    #expect(DisappearingRule.marker(for: mine, state: on(.day), now: now) == "Disappears in 23 h 40 min")
    #expect(DisappearingRule.marker(for: mine, state: on(.week), now: now) == "Disappears in 6 days")
    #expect(DisappearingRule.marker(for: mine, state: on(.hour), now: jan1.addingTimeInterval(7_200)) == "Disappearing now")
    #expect(DisappearingRule.marker(for: mine, state: on(.afterViewing), now: now) == "Disappears once read")
    #expect(DisappearingRule.marker(for: mine, state: .off, now: now) == nil)
    // Sent before the timer went on: it stays, so it says nothing.
    let early = ChatMessage(id: "b", sender: "@me:x", body: "Old", isOwn: true, time: jan1.addingTimeInterval(-3 * 86_400))
    #expect(DisappearingRule.marker(for: early, state: on(.day), now: now) == nil)
}

@Test func anHourIsATimerChoiceAndWritesTheRoomState() {
    #expect(Disappearing.hour.lifetime == 3_600)
    #expect(Disappearing.hour.stateJSON == "{\"max_lifetime\":3600000}")
    #expect(Disappearing(stateJSON: Disappearing.hour.stateJSON) == .hour)
    #expect(Disappearing.hour.explanation.contains("after 1 hour"))
}

@Test func anOpenedViewOncePhotoOfYoursIsDueEvenWithNoTimer() {
    let photo = ChatMessage(id: "p", sender: "@me:x", body: "Photo", isOwn: true, time: jan1, kind: .photo(width: 4, height: 3), viewOnce: true)
    var opened = photo
    opened.opened = true
    let theirs = ChatMessage(id: "t", sender: "@ana:x", body: "Photo", isOwn: false, time: jan1, kind: .photo(width: 4, height: 3), viewOnce: true, opened: true)
    #expect(DisappearingRule.due([photo, opened, theirs], state: .off, now: jan1).map(\.id) == ["p"])
    #expect(DisappearingRule.due([photo], state: .off, now: jan1).isEmpty)
    #expect(DisappearingRule.marker(for: photo, state: on(.day), now: jan1) == nil)
}

@MainActor
@Test func aViewOncePhotoOpensOnceAndIsMarkedOpenedFirst() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    let photo = ChatMessage(id: "$p", sender: "@ana:x", body: "Photo", isOwn: false, time: jan1, kind: .photo(width: 4, height: 3), viewOnce: true)
    channel.startingMessages = [photo]
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await settle()
    #expect(await chat.photo(photo, thumbnail: true) == nil)
    let first = await chat.openOnce(photo)
    #expect(first != nil)
    #expect(channel.reactions == ["\(ViewOnce.openedKey)@$p"])
    #expect(chat.messages.first?.opened == true)
    let again = try #require(chat.messages.first)
    #expect(await chat.openOnce(again) == nil)
    #expect(await chat.openOnce(photo) == nil)
    #expect(channel.reactions.count == 1)
    chat.close()
}

@MainActor
@Test func aViewOncePhotoStaysClosedWhenItCantBeMarkedOpened() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    channel.failReactions = true
    let photo = ChatMessage(id: "$p", sender: "@ana:x", body: "Photo", isOwn: false, time: jan1, kind: .photo(width: 4, height: 3), viewOnce: true)
    channel.startingMessages = [photo]
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await settle()
    #expect(await chat.openOnce(photo) == nil)
    #expect(chat.messages.first?.opened == false)
    #expect(chat.notice != nil)
    channel.failReactions = false
    #expect(await chat.openOnce(photo) != nil)
    chat.close()
}

@MainActor
@Test func yourOpenedViewOncePhotoIsDeletedOnce() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    channel.startingMessages = [
        ChatMessage(id: "$p", sender: "@me:x", body: "Photo", isOwn: true, time: Date(), kind: .photo(width: 4, height: 3), viewOnce: true, opened: true),
    ]
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await settle()
    await chat.removeDue()
    #expect(channel.deleted == ["$p"])
    chat.close()
}

@MainActor
@Test func sendingAPhotoThatOpensOnceFlagsIt() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let channel = FakeChannel()
    let chat = ChatModel(channel: channel, defaults: defaults)
    await chat.start()
    await chat.sendPhoto(try phonePhoto(), viewOnce: true)
    await chat.sendPhoto(try phonePhoto())
    #expect(channel.photos.map(\.viewOnce) == [true, false])
    chat.close()
}

@Test func viewOnceIsMarkedInsideTheMessageAndNeverGuessedFromAnythingElse() {
    #expect(ViewOnce.isViewOnce(filename: ViewOnce.filename))
    #expect(!ViewOnce.isViewOnce(filename: "photo.jpg"))
    #expect(ViewOnce.explanation.contains("screenshot"))
}

@MainActor
@Test func aNewChatGetsYourDefaultTimerButAnExistingOneDoesnt() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    defaults.set(Disappearing.day.rawValue, forKey: MessagesPreferences.newChatsDisappearKey)
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [
        ChatSummary(id: "!dm-mckay_test", title: "mckay_test", lastMessage: "Hi", lastActivity: jan1),
    ])
    let model = MessagesModel(account: { mckay }, connector: { _ in service }, defaults: defaults)
    await model.connect()
    await settle()
    #expect(await model.startChat(with: "mckay_test") == "!dm-mckay_test")
    #expect(service.openedChannels.isEmpty)
    #expect(await model.startChat(with: "ana_ruiz") == "!dm-ana_ruiz")
    #expect(service.openedChannels.first?.settings == [.day])
    #expect(await model.startGroup(with: "ana_ruiz, @mckay_test") == "!group")
    #expect(service.openedChannels.last?.settings == [.day])
}

@MainActor
@Test func withNoDefaultNewChatsAreLeftAlone() async throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    #expect(MessagesPreferences.newChatsDisappear(defaults) == .off)
    let service = FakeService(account: mckay, user: "mckay_clemens", chats: [])
    let model = MessagesModel(account: { mckay }, connector: { _ in service }, defaults: defaults)
    await model.connect()
    await settle()
    #expect(await model.startChat(with: "ana_ruiz") == "!dm-ana_ruiz")
    #expect(service.openedChannels.isEmpty)
}
