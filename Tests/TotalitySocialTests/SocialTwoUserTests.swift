import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

/// Social's case of the two-user test (definition of done), against stand-ins for Totality's server and the
/// Matrix server. The live run on two iPhones waits for the owner's friend's account.
@MainActor
@Suite struct SocialTwoUserTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    func device(_ name: String) -> SocialModel {
        SocialModel(server: world.person(name), privateRooms: matrix.device(for: name))
    }

    @Test func friendsPostsReachOnlyFriends() async throws {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya")
        // Jonah and Maya follow each other; Priya follows Maya but Maya doesn't follow back.
        for (a, b) in [(jonah, "maya"), (maya, "jonah"), (priya, "maya")] { await a.load(); #expect(await a.setFollowing(true, b)) }
        await maya.load()
        #expect(await maya.publish(.friends, title: "", body: "Out the door at 4:30. Worth it for the saddle."))
        #expect(world.posts.isEmpty, "a Friends post is never on Totality's server")

        await jonah.load()
        #expect(jonah.following.map(\.body) == ["Out the door at 4:30. Worth it for the saddle."])
        #expect(jonah.following.first?.audience == .friends)
        await priya.load()
        #expect(priya.following.isEmpty, "a follower who isn't followed back isn't a friend")

        // Jonah likes and comments; Maya sees both.
        let post = try #require(jonah.following.first)
        await jonah.toggleLike(post)
        #expect(await jonah.comment("Saddle at first light is the best.", on: post, replyingTo: nil))
        await maya.load()
        let seen = try #require(maya.following.first)
        #expect(seen.likes == 1 && seen.comments == 1)
        #expect(try await maya.comments(on: seen).map(\.author) == ["jonah"])
    }

    @Test func unfollowingStopsNewFriendsPosts() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await jonah.load(); _ = await jonah.setFollowing(true, "maya")
        await maya.load(); _ = await maya.setFollowing(true, "jonah")
        #expect(await maya.publish(.friends, title: "", body: "First."))
        await jonah.load()
        #expect(jonah.following.count == 1)

        _ = await maya.setFollowing(false, "jonah")
        await maya.load()
        #expect(await maya.publish(.friends, title: "", body: "Second, after unfollowing."))
        await jonah.load()
        #expect(!jonah.following.contains { $0.body == "Second, after unfollowing." })
    }

    @Test func closeFriendsAreAListYouChoose() async throws {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya")
        for (a, b) in [(jonah, "maya"), (priya, "maya"), (maya, "jonah"), (maya, "priya")] { await a.load(); _ = await a.setFollowing(true, b) }
        await maya.load()
        #expect(await maya.setCloseFriends(["priya"]))
        #expect(await maya.publish(.closeFriends, title: "Kyoto list", body: "Close friends only."))
        await priya.load()
        await jonah.load()
        #expect(priya.following.map(\.title) == ["Kyoto list"])
        #expect(priya.following.first?.audience == .closeFriends)
        #expect(!jonah.following.contains { $0.audience == .closeFriends })
    }

    @Test func aStrangerCannotPutPostsInYourFeed() async throws {
        let maya = device("maya")
        let stranger = matrix.device(for: "stranger")
        let room = try await stranger.create(inviting: ["maya": .viewer])
        try await stranger.post(RoomMessage.timeline(.friends).encoded, to: room)
        try await stranger.post(RoomMessage.post(id: UUID(), title: nil, body: "Buy now", tags: [], date: Date()).encoded, to: room)
        await maya.load()
        #expect(maya.following.isEmpty)
        #expect(matrix.rooms[room]?.joined.contains("maya") == false, "an invite from someone you don't follow stays unanswered")
    }

    @Test func publicPostsAreSharedAndOnlyTheAuthorDeletes() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await maya.load()
        #expect(await maya.publish(.everyone, title: "Every Penguin Classic I read this year", body: "Twenty-two of them. #books"))
        await jonah.load()
        let post = try #require(jonah.forYou.first)
        try await world.person("jonah").delete(post.id)
        #expect(world.posts[post.id] != nil, "user 2 can't delete user 1's post")
        await maya.load()
        await maya.delete(try #require(maya.following.first))
        #expect(world.posts.isEmpty)
    }
}
