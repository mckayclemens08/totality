import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

@MainActor
@Suite struct FollowListTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    func device(_ name: String) -> SocialModel {
        SocialModel(server: world.person(name), privateRooms: matrix.device(for: name))
    }

    /// Two people who follow each other, with Ana's Friends room made.
    func friends() async -> (SocialModel, SocialModel) {
        let ana = device("ana"), eli = device("eli")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await ana.load(); _ = await ana.setFollowing(true, "eli")
        _ = await ana.publish(.friends, title: "", body: "Friends only: the kiln finally works.")
        return (ana, eli)
    }

    @Test func closeFriendsAreThereAfterOpeningAgain() async throws {
        let (ana, _) = await friends()
        #expect(await ana.setCloseFriends(["eli"]))
        // Opening Social again starts with nothing in memory: the list comes back from the room.
        let again = device("ana")
        await again.load()
        #expect(again.closeFriends == ["eli"])
        // Saving again uses the same room rather than making a second one.
        #expect(await again.setCloseFriends(["eli"]))
        #expect(try await again.privatePosts!.members(.closeFriends) == ["eli"])
    }

    @Test func closeFriendsShowBeforeTheirRoomLoads() async throws {
        let shared = try #require(UserDefaults(suiteName: "social.test." + UUID().uuidString))
        let ana = SocialModel(server: world.person("ana"), privateRooms: matrix.device(for: "ana"), remembered: shared)
        let eli = device("eli")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await ana.load(); _ = await ana.setFollowing(true, "eli")
        #expect(await ana.setCloseFriends(["eli"]))
        // Reopened with Messages not reachable yet: the remembered list shows, and saving waits.
        let again = SocialModel(server: world.person("ana"), privateRooms: nil, remembered: shared)
        await again.load()
        #expect(again.closeFriends == ["eli"])
    }

    @Test func removingAFollowerTakesThemOutOfYourRoomsAtOnce() async throws {
        let (ana, _) = await friends()
        #expect(await ana.setCloseFriends(["eli"]))
        #expect(try await ana.privatePosts!.members(.friends)?.contains("eli") == true)
        #expect(await ana.removeFollower("eli"))
        // No refresh or publish in between: the rooms change with the remove itself.
        #expect(try await ana.privatePosts!.members(.friends)?.contains("eli") != true)
        #expect(try await ana.privatePosts!.members(.closeFriends)?.contains("eli") != true)
        #expect(!ana.closeFriends.contains("eli"))
        #expect(!ana.friends.contains("eli"))
    }

    @Test func removingAFollowerWhoIsNotAFriendLeavesTheRoomAlone() async throws {
        let (ana, _) = await friends()
        let kai = device("kai")
        await kai.load(); _ = await kai.setFollowing(true, "ana")
        #expect(await ana.removeFollower("kai"))
        #expect(try await ana.privatePosts!.members(.friends) == ["eli"])
    }

    @Test func eachRowSaysHowYouRelate() async {
        let ana = device("ana"), eli = device("eli"), kai = device("kai")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await kai.load(); _ = await kai.setFollowing(true, "ana")
        await ana.load(); _ = await ana.setFollowing(true, "kai")
        let list = FollowList(social: ana, username: "ana", showingFollowers: true)
        await list.reload(query: "")
        #expect(list.phase == .ready)
        #expect(list.isMine)
        let rows = Dictionary(uniqueKeysWithValues: list.people.map { ($0.username, Relationship($0, me: "ana")) })
        #expect(rows == ["eli": .followBack, "kai": .following])
        await list.setFollowing(true, list.people[0])
        #expect(Relationship(list.people[0], me: "ana") == .following)
    }

    @Test func aPrivateListIsEmptyToSomeoneNotFollowing() async {
        let ana = device("ana"), eli = device("eli"), kai = device("kai")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await ana.load(); _ = await ana.save(SocialSettings(privateAccount: true))
        await kai.load()
        let list = FollowList(social: kai, username: "ana", showingFollowers: true)
        await list.reload(query: "")
        #expect(list.people.isEmpty)
        #expect(!list.isMine)
    }

    @Test func searchAndPagesReachEveryone() async {
        let ana = device("ana")
        let names = (0..<(FollowList.pageSize + 5)).map { String(format: "fan%03d", $0) }
        for name in names { _ = try? await world.person(name).setFollowing(true, "ana") }
        await ana.load()
        let list = FollowList(social: ana, username: "ana", showingFollowers: true)
        await list.reload(query: "")
        #expect(list.people.count == FollowList.pageSize)
        #expect(list.hasMore)
        await list.loadMore()
        #expect(list.people.count == names.count)
        #expect(Set(list.people.map(\.username)).count == names.count)
        await list.reload(query: "@fan05")
        #expect(list.people.map(\.username) == ["fan050", "fan051", "fan052", "fan053", "fan054"])
        list.showingFollowers = false
        #expect(list.phase == .loading)
        await list.reload(query: "")
        #expect(list.people.isEmpty)
    }

    @Test func muteAndCloseFriendsFromTheFollowingTab() async throws {
        let (ana, _) = await friends()
        let list = FollowList(social: ana, username: "ana", showingFollowers: false)
        await list.reload(query: "")
        let eli = try #require(list.people.first)
        await list.setMuted(true, eli)
        #expect(list.people.first?.muted == true)
        #expect(world.mutes["ana"]?.contains(world.id("eli")) == true)
        #expect(list.closeFriendsReason == nil)
        await list.setCloseFriend(true, eli)
        #expect(list.isCloseFriend(eli))
        #expect(try await ana.privatePosts!.members(.closeFriends) == ["eli"])
        await list.setCloseFriend(false, eli)
        #expect(!list.isCloseFriend(eli))
    }

    @Test func removingFromTheListDropsTheRow() async {
        let (ana, _) = await friends()
        let list = FollowList(social: ana, username: "ana", showingFollowers: true)
        await list.reload(query: "")
        #expect(list.people.map(\.username) == ["eli"])
        await list.remove(list.people[0])
        #expect(list.people.isEmpty)
    }
}
