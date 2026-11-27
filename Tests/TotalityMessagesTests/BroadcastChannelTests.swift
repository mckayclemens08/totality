import Foundation
import Testing
import TotalityCore
@testable import TotalityMessages

private let mckay = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"

// MARK: Rules

@Test func onlyOwnerAndAdminsCanPostButEveryoneCanReact() {
    #expect(ChannelPower.canPost(level: ChannelPower.owner))
    #expect(ChannelPower.canPost(level: ChannelPower.admin))
    #expect(!ChannelPower.canPost(level: ChannelPower.follower))
    #expect(ChannelPower.canReact(level: ChannelPower.follower))
    #expect(!ChannelPower.canInvite(level: ChannelPower.follower))
    #expect(ChannelAccess(level: 0).title == "Follower")
    #expect(ChannelAccess(level: 50).title == "Admin")
    #expect(ChannelAccess(level: 100).title == "Owner")
}

@Test func theRoomSettingsLetFollowersReactAndUnreactButNotPost() {
    #expect(ChannelPower.isChannel(eventsDefault: ChannelSettings.eventsDefault))
    #expect(!ChannelPower.isChannel(eventsDefault: 0), "ordinary chats and groups let everyone post")
    #expect(!ChannelSettings.allows("m.room.message", level: 0))
    #expect(!ChannelSettings.allows("m.room.encrypted", level: 0), "encrypted posts are checked as messages")
    #expect(ChannelSettings.allows("m.reaction", level: 0))
    #expect(ChannelSettings.allows("m.room.redaction", level: 0))
    #expect(ChannelSettings.redact > ChannelPower.follower, "followers can't remove other people's posts")
    #expect(ChannelSettings.invite > ChannelPower.follower)
    #expect(ChannelSettings.users(admins: ["a", "b", "a"]) == ["a": 50, "b": 50])
}

@Test func aChannelHoldsUpTo500People() throws {
    #expect(ChannelLimits.room(members: 1) == 499)
    try ChannelLimits.check(members: 499, adding: 1)
    #expect(throws: MessagesError.self) { try ChannelLimits.check(members: 500, adding: 1) }
    #expect(throws: MessagesError.self) { try ChannelLimits.check(members: 498, adding: 3) }
}

@Test func theLabelsClaimNothingUntrue() {
    #expect(ChannelLabels.nameNotEncrypted.contains("isn't end-to-end encrypted"))
    #expect(ChannelLabels.followersVisible.contains("count"))
    #expect(!ChannelLabels.followersVisible.lowercased().contains("hidden"))
    #expect(ChannelLabels.followers(1) == "1 follower" && ChannelLabels.followers(12) == "12 followers")
}

// MARK: Model

/// Who follows the signed-in person on Social, for the channel invite rule.
private struct FakeFollowers: FollowerDirectory {
    let handles: Set<String>
    func followers(matching typed: String, limit: Int) async throws -> [ProfileSuggestion] {
        handles.filter { $0.hasPrefix(typed) }.sorted().map { ProfileSuggestion(handle: $0, displayName: nil) }
    }
    func followers(among usernames: [String]) async throws -> Set<String> { handles.intersection(usernames) }
}

@MainActor
@Test func onlyFollowersCanBeInvitedToAChannel() async {
    let service = FakeServiceForChannels()
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    await model.connect()
    // Social can't be asked: nothing goes through on a guess.
    #expect(await !model.invite("ana_ruiz", toChannel: "!channel"))
    #expect(model.notice?.contains("couldn't be checked") == true)
    model.people.followers = FakeFollowers(handles: ["ana_ruiz"])
    #expect(await !model.invite("ana_ruiz, mckay_test", toChannel: "!channel"))
    #expect(model.notice == "@mckay_test doesn't follow you. You can only invite people who follow you.")
    #expect(await model.startChannel(name: "Trail", admins: "mckay_test") == nil)
    #expect(model.notice?.contains("follow you") == true)
    #expect(await model.invite("ana_ruiz", toChannel: "!channel"))
    // Suggestions come from followers only.
    #expect(await model.people.followerSuggestions(for: "an").map(\.handle) == ["ana_ruiz"])
    #expect(await model.people.followerSuggestions(for: "zz").isEmpty)
}

@MainActor
@Test func startingAChannelNamesItAndSendsAdminsAlong() async {
    let service = FakeServiceForChannels()
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    model.people.followers = FakeFollowers(handles: ["ana_ruiz", "nobody_here"])
    await model.connect()
    #expect(await model.startChannel(name: "  ", admins: "") == nil)
    #expect(model.notice == "Give the channel a name.")
    #expect(await model.startChannel(name: " Trail notes ", admins: "ana_ruiz, @ana_ruiz") == "!channel")
    #expect(service.actions == ["channel Trail notes ana_ruiz"])
    #expect(await model.startChannel(name: "x", admins: "nobody_here") == nil)
}

@MainActor
@Test func inviteStopsAtTheLimit() async {
    let service = FakeServiceForChannels()
    let model = MessagesModel(account: { mckay }, connector: { _ in service })
    model.people.followers = FakeFollowers(handles: ["ana_ruiz", "mckay_test"])
    await model.connect()
    #expect(await model.invite("ana_ruiz mckay_test", toChannel: "!channel"))
    service.members = 499
    #expect(await !model.invite("ana_ruiz, mckay_test", toChannel: "!channel"))
    #expect(model.notice?.contains("500") == true)
}

@MainActor
@Test func aFollowersPostIsStoppedBeforeItIsQueued() async {
    let channel = FakeChannel()
    channel.channelAccess = ChannelAccess(level: 0)
    let chat = ChatModel(channel: channel)
    chat.draft = "Hello?"
    await chat.send()
    #expect(channel.sent.isEmpty)
    #expect(chat.notice == ChannelLabels.followerNote)
}

// MARK: Two-user case (definition of done)

/// A Matrix room as the server sees it: it checks power levels itself, so these tests don't rely on the app.
private final class ChannelRoom: @unchecked Sendable {
    var levels: [String: Int] = [:]
    var feed: [String] = []
    var reactions: [String] = []
    var members: Set<String> = []

    func send(_ eventType: String, as who: String, _ text: String = "") -> Bool {
        guard members.contains(who), ChannelSettings.allows(eventType, level: levels[who] ?? 0) else { return false }
        if eventType == "m.reaction" { reactions.append("\(who) \(text)") } else if eventType == "m.room.redaction" {
            reactions.removeAll { $0.hasPrefix(who) }
        } else { feed.append(text) }
        return true
    }
    func invite(_ person: String, as who: String) -> Bool {
        guard ChannelPower.canInvite(level: levels[who] ?? 0), members.count < ChannelLimits.maxMembers else { return false }
        members.insert(person)
        return true
    }
}

@Test func twoUserBroadcastChannelOwnerPostsFollowerReadsAndReactsButCannotPost() {
    let room = ChannelRoom()
    room.levels = ["maya": ChannelPower.owner].merging(ChannelSettings.users(admins: ["jonah"])) { a, _ in a }
    room.members = ["maya"]
    // Maya, the owner, invites Jonah (an admin) and Priya (a follower).
    #expect(room.invite("jonah", as: "maya") && room.invite("priya", as: "maya"))
    #expect(room.send("m.room.message", as: "maya", "Trailhead closed Friday."))
    #expect(room.send("m.room.message", as: "jonah", "Reopens Saturday."))

    // Priya reads the same feed, can react and take the reaction back, and can't post, invite or delete.
    #expect(room.feed == ["Trailhead closed Friday.", "Reopens Saturday."])
    #expect(room.send("m.reaction", as: "priya", "heart"))
    #expect(room.send("m.room.redaction", as: "priya"))
    #expect(room.reactions.isEmpty)
    #expect(!room.send("m.room.message", as: "priya", "Can I come?"))
    #expect(!room.send("m.room.encrypted", as: "priya", "Can I come?"))
    #expect(!room.invite("sam", as: "priya"))
    #expect(room.feed.count == 2, "the follower's post never reached the channel")

    // Someone who was never invited can't do anything.
    #expect(!room.send("m.reaction", as: "sam", "heart"))
    #expect(ChannelAccess(level: room.levels["priya"] ?? 0).canPost == false)
    #expect(ChannelAccess(level: room.levels["jonah"] ?? 0).canPost)
}

@MainActor
@Test func twoUserAFollowersScreenOffersAPrivateMessageNotAComposer() {
    let follower = ChannelAccess(level: 0), owner = ChannelAccess(level: 100)
    #expect(!follower.canPost && follower.canReact && !follower.canInvite)
    #expect(owner.canPost && owner.canInvite)
    #expect(ChannelLabels.messageOwner("maya") == "Message maya privately")
}

private final class FakeServiceForChannels: MessagesService, @unchecked Sendable {
    let account = mckay
    let userID = "@mckay_clemens:usetotality.com"
    private let lock = NSLock()
    private(set) var actions: [String] = []
    var members = 1
    func observeChats(_ onChange: @escaping @Sendable ([ChatSummary]) -> Void) async throws { onChange([]) }
    func observeConnection(_ onChange: @escaping @Sendable (Connection) -> Void) { onChange(.online) }
    func accept(_ chat: String) async throws {}
    func decline(_ chat: String) async throws {}
    func block(_ chat: String) async throws {}
    func startChat(with username: String) async throws -> String { "!dm" }
    func openChat(_ chat: String) async throws -> any ChatChannel { FakeChannel() }
    func startGroup(with usernames: [String], name: String?, photo: GroupPhoto?) async throws -> String { "!group" }
    func groupPhoto(_ location: String) async throws -> Data { Data() }
    func block(person: String, leaving chat: String?) async throws {}
    func blocked() async throws -> [String] { [] }
    func unblock(_ person: String) async throws {}
    func leave(_ chat: String) async throws {}
    func settleKeys(recoverySecret: String?) async -> MessageKeys { .backedUp }
    func stop() async {}

    func startChannel(name: String, admins: [String]) async throws -> String {
        guard admins.allSatisfy({ $0 == "ana_ruiz" }) else { throw MessagesError.noSuchPerson }
        lock.withLock { actions.append("channel \(name) \(admins.joined(separator: ","))") }
        return "!channel"
    }
    func invite(_ usernames: [String], toChannel chat: String) async throws {
        try ChannelLimits.check(members: members, adding: usernames.count)
    }
}
