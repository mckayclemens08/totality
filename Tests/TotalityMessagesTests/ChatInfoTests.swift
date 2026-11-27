import Foundation
import Testing
import TotalityCore
@testable import TotalityMessages

// MARK: Username suggestions

@Test func theTokenBeingTypedIsTheLastOne() {
    #expect(UsernameTyping.currentToken("ann") == "ann")
    #expect(UsernameTyping.currentToken("ann, bo") == "bo")
    #expect(UsernameTyping.currentToken("ann, @Bo") == "bo")
    #expect(UsernameTyping.currentToken("ann, ") == "")
    #expect(UsernameTyping.currentToken("") == "")
}

@Test func namesAlreadyTypedInFullAreNotSuggestedAgain() {
    #expect(UsernameTyping.finished("ann, bo") == ["ann"])
    #expect(UsernameTyping.finished("ann, bob, ") == ["ann", "bob"])
    #expect(UsernameTyping.finished("ann") == [])
}

@Test func aTappedSuggestionReplacesOnlyTheLastToken() {
    #expect(UsernameTyping.replacingCurrent(in: "ann, bo", with: "bobby", multiple: true) == "ann, bobby, ")
    #expect(UsernameTyping.replacingCurrent(in: "bo", with: "bobby", multiple: true) == "bobby, ")
    #expect(UsernameTyping.replacingCurrent(in: "bo", with: "bobby", multiple: false) == "bobby")
}

@Test func suggestionsShowPrefixMatchesFirstWithoutPickedPeople() {
    let found = [
        ProfileSuggestion(handle: "abbot", displayName: "Bo Abbot"),
        ProfileSuggestion(handle: "bob", displayName: nil),
        ProfileSuggestion(handle: "bobby", displayName: "Bobby"),
    ]
    let shown = UsernameTyping.shown(found, typing: "bo", excluding: ["bob"])
    #expect(shown.map(\.handle) == ["bobby", "abbot"])
    #expect(UsernameTyping.shown(found, typing: "", excluding: []).isEmpty)
    #expect(UsernameTyping.shown(found, typing: "b", excluding: [], limit: 2).count == 2)
}

// MARK: Followers and invited

@Test func invitedPeopleAreNotFollowersButStillCountTowardTheCap() {
    // Owner plus 12 who joined plus 3 pending: Matrix holds 16.
    #expect(ChannelCounts.followers(members: 16, invited: 3) == 12)
    #expect(ChannelLimits.room(members: 16) == ChannelLimits.maxMembers - 16)
    #expect(ChannelCounts.followers(members: 1, invited: 0) == 0)
    #expect(ChannelCounts.followers(members: 3, invited: 5) == 0)
}

@Test func aChannelInviteIsNamedFromItsTopicAlone() {
    #expect(ChannelMarker.isChannel(topic: ChannelMarker.topic))
    #expect(!ChannelMarker.isChannel(topic: nil))
    #expect(!ChannelMarker.isChannel(topic: "Weekend plans"))
    #expect(ChannelMarker.requestTitle(from: "mckay", isChannel: true) == "Channel from mckay")
    #expect(ChannelMarker.requestTitle(from: "mckay", isChannel: false) == "Group from mckay")
}

// MARK: Only followers may be invited to a channel

@Test func aChannelInviteNeedsEveryoneToFollowYou() {
    #expect(ChannelInviteRule.refusal(inviting: ["ana", "bea"], followers: ["ana", "bea", "cal"]) == nil)
    #expect(ChannelInviteRule.refusal(inviting: [], followers: []) == nil)
    let one = ChannelInviteRule.refusal(inviting: ["ana", "bea"], followers: ["ana"])
    #expect(one == "@bea doesn't follow you. You can only invite people who follow you.")
    let two = ChannelInviteRule.refusal(inviting: ["ana", "bea"], followers: [])
    #expect(two?.contains("don't follow you") == true)
    // When Social can't be asked, nothing goes through on a guess.
    #expect(ChannelInviteRule.refusal(inviting: ["ana"], followers: nil)?.contains("couldn't be checked") == true)
}

// MARK: Permissions and roster

@Test func whatEachPersonIsOfferedInAGroupOrChannel() {
    let owner = ChatPermissions(isChannel: true, level: ChannelPower.owner)
    #expect(owner.canRename && owner.canAddPeople && owner.canManageAdmins)
    let admin = ChatPermissions(isChannel: true, level: ChannelPower.admin)
    #expect(!admin.canRename && admin.canAddPeople && !admin.canManageAdmins)
    let follower = ChatPermissions(isChannel: true, level: ChannelPower.follower)
    #expect(!follower.canRename && !follower.canAddPeople && !follower.canManageAdmins)
    let groupMember = ChatPermissions(isChannel: false, level: 0)
    #expect(!groupMember.canRename && groupMember.canAddPeople && groupMember.leaveWarning == nil)
    #expect(ChatPermissions(isChannel: false, level: ChannelPower.admin).canRename)
    #expect(owner.leaveWarning != nil)
}

@Test func theRosterListsOwnerThenAdminsThenPeopleThenInvited() {
    let members = [
        ChatMember(id: "@zed:usetotality.com", level: 0),
        ChatMember(id: "@amy:usetotality.com", level: 0, invited: true),
        ChatMember(id: "@bea:usetotality.com", level: ChannelPower.admin),
        ChatMember(id: "@own:usetotality.com", level: ChannelPower.owner),
        ChatMember(id: "@cal:usetotality.com", level: 0),
    ]
    let ordered = ChatRoster.ordered(members, name: MessagesUsername.display).map { MessagesUsername.display($0.id) }
    #expect(ordered == ["own", "bea", "cal", "zed", "amy"])
    #expect(ChatRoster.admins(members).map { MessagesUsername.display($0.id) } == ["bea", "own"])
    #expect(ChatRoster.level(of: "@bea:usetotality.com", in: members) == ChannelPower.admin)
    #expect(ChatRoster.level(of: "@nobody:usetotality.com", in: members) == ChannelPower.follower)
    #expect(members[1].role == "Invited")
}

@Test func aGroupHasRoomForTwentyIncludingInvited() throws {
    try GroupMembers.check(current: 18, adding: 2)
    #expect(throws: MessagesError.self) { try GroupMembers.check(current: 18, adding: 3) }
    #expect(throws: MessagesError.self) { try GroupMembers.check(current: 20, adding: 1) }
}

// MARK: Muting

@MainActor @Test func aMutedChatMakesNoAlert() {
    let suite = UserDefaults(suiteName: "chat-info-mute-\(UUID().uuidString)")!
    #expect(!MutedChats.isMuted("!a:usetotality.com", suite))
    MutedChats.set("!a:usetotality.com", muted: true, suite)
    #expect(MutedChats.isMuted("!a:usetotality.com", suite))
    MutedChats.set("!a:usetotality.com", muted: false, suite)
    #expect(MutedChats.all(suite).isEmpty)

    let now = Date()
    let chat = ChatSummary(
        id: "!a:usetotality.com", title: "Hikers", lastMessage: "Trailhead at 7", lastActivity: now, unread: 1,
        isGroup: true, lastSender: "@bea:usetotality.com"
    )
    let since = now.addingTimeInterval(-60)
    #expect(MessagesNotifications.notes(chats: [chat], requests: [], since: since).count == 1)
    #expect(MessagesNotifications.notes(chats: [chat], requests: [], since: since, muted: [chat.id]).isEmpty)
}
