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

    @Test("Signing in as someone else on the same phone shows nothing of the last account's")
    func anotherAccountOnTheSamePhoneSeesNothingOfTheLast() async throws {
        let maya = device("maya"), jonah = device("jonah")
        for (a, b) in [(jonah, "maya"), (maya, "jonah")] { await a.load(); #expect(await a.setFollowing(true, b)) }
        await maya.load()
        #expect(await maya.publish(.friends, title: "", body: "Only for friends: the spare key is under the fern."))
        #expect(await maya.publish(.everyone, title: "Trailhead at dawn", body: "Frost on the boardwalk."))

        // Jonah's phone, one Social model, then Jonah signs out and Priya signs up on it.
        let server = world.person("jonah"), rooms = matrix.device(for: "jonah")
        let phone = SocialModel(server: server, privateRooms: rooms)
        await phone.load()
        #expect(phone.me == "jonah")
        #expect(phone.following.contains { $0.audience == .friends })
        server.signedIn.name = "priya"
        // Messages hasn't connected Priya yet, so Social can't read any private rooms for her.
        rooms.me = "priya"
        rooms.unavailableReason = "Messages is still connecting."
        await phone.load()
        #expect(phone.me == "priya")
        #expect(!phone.following.contains { $0.audience == .friends }, "Jonah's Friends posts never reach Priya")
        #expect(phone.friends.isEmpty && phone.followingSet.isEmpty)
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

    // MARK: Reposts

    @Test("A repost reaches the reposter's followers as 'reposted by', counts, and goes when undone")
    func repostsReachFollowersAndUndo() async throws {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya")
        // Priya follows Jonah only. Maya posts publicly; Jonah follows Maya.
        await jonah.load(); #expect(await jonah.setFollowing(true, "maya"))
        await priya.load(); #expect(await priya.setFollowing(true, "jonah"))
        await maya.load()
        #expect(await maya.publish(.everyone, title: "Trailhead at dawn", body: "Frost on the boardwalk."))
        await jonah.load()
        let original = try #require(jonah.following.first)
        await jonah.toggleRepost(original)
        #expect(jonah.post(original.id)?.reposted == true)

        await priya.load()
        let seen = try #require(priya.following.first { $0.id == original.id })
        #expect(seen.repostedBy?.handle == "jonah")
        #expect(seen.repostedBy?.line(me: priya.me) == "jonah reposted")
        #expect(seen.reposts == 1 && !seen.reposted)
        // Priya reposts it too, which Maya sees as a count of two, and an own post has no repost button.
        await priya.toggleRepost(seen)
        await maya.load()
        let mine = try #require(maya.following.first)
        #expect(mine.reposts == 2 && mine.repostedBy == nil && !mine.canRepost(by: maya.me))

        // It shows on Jonah's profile, marked, and undo takes it back out of both.
        let profile = try await priya.posts(by: "jonah")
        #expect(profile.first?.repostedBy?.handle == "jonah")
        await jonah.toggleRepost(original)
        await priya.load()
        #expect(priya.following.first { $0.id == original.id }?.repostedBy?.handle == "priya")
        #expect(try await priya.posts(by: "jonah").isEmpty)
    }

    @Test("You can't repost your own post, a private account's post, or the same post twice")
    func repostsAreLimited() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await maya.load()
        #expect(await maya.publish(.everyone, title: "Sourdough", body: "Open crumb at last."))
        let own = try #require(maya.following.first)
        await maya.toggleRepost(own)
        #expect(world.reposts["maya"] == nil)
        await jonah.load()
        let theirs = try #require(jonah.forYou.first)
        await jonah.toggleRepost(theirs)
        await jonah.toggleRepost(theirs) // pressed again: that's the undo
        #expect(world.reposts["jonah"]?[theirs.id] == nil)
        await jonah.toggleRepost(theirs)
        #expect(world.reposts["jonah"]?.count == 1)
        await jonah.toggleRepost(theirs) // undo
        world.settings["maya"] = SocialSettings(privateAccount: true)
        await jonah.toggleRepost(theirs)
        #expect(world.reposts["jonah"]?[theirs.id] == nil, "a private account's post can't be reposted")
        #expect(jonah.post(theirs.id)?.reposted == false)
    }

    @Test("A Friends post can't be reposted")
    func friendsPostsCannotBeReposted() async throws {
        let maya = device("maya"), jonah = device("jonah")
        for (a, b) in [(jonah, "maya"), (maya, "jonah")] { await a.load(); #expect(await a.setFollowing(true, b)) }
        await maya.load()
        #expect(await maya.publish(.friends, title: "Spare key", body: "Under the fern."))
        await jonah.load()
        let private1 = try #require(jonah.following.first { $0.audience == .friends })
        #expect(!private1.canRepost(by: jonah.me))
        await jonah.toggleRepost(private1)
        #expect(world.reposts["jonah"] == nil)
    }

    // MARK: Profiles

    /// The two servers keep separate clocks; this keeps their posts in the order they were made.
    func step() {
        let later = max(world.clock, matrix.clock).addingTimeInterval(60)
        world.clock = later
        matrix.clock = later
    }

    /// Maya posts one of each: Public, then Friends (Jonah), then Close friends (Priya).
    func mayaPostsOneOfEach() async throws -> (maya: SocialModel, jonah: SocialModel, priya: SocialModel, sam: SocialModel) {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya"), sam = device("sam")
        // Jonah and Priya are Maya's friends; Priya is also a close friend. Sam follows Maya, who doesn't follow back.
        for (a, b) in [(jonah, "maya"), (priya, "maya"), (sam, "maya"), (maya, "jonah"), (maya, "priya")] {
            await a.load(); #expect(await a.setFollowing(true, b))
        }
        await maya.load()
        #expect(await maya.setCloseFriends(["priya"]))
        step(); #expect(await maya.publish(.everyone, title: "Trailhead", body: "Public."))
        step(); #expect(await maya.publish(.friends, title: "Spare key", body: "Friends."))
        step(); #expect(await maya.publish(.closeFriends, title: "Kyoto list", body: "Close friends."))
        return (maya, jonah, priya, sam)
    }

    @Test("Your own profile shows every post you made, newest first, whoever it's for")
    func ownProfileShowsEveryAudience() async throws {
        let (maya, _, _, _) = try await mayaPostsOneOfEach()
        let posts = try await maya.posts(by: "maya")
        #expect(posts.map(\.audience) == [.closeFriends, .friends, .everyone])
        let profile = try await maya.profile("maya")
        #expect(maya.postCount(profile) == 3)
    }

    @Test("Someone else's profile shows only what their rooms let you read, and the count stays public")
    func othersSeeOnlyWhatMembershipAllows() async throws {
        let (_, jonah, priya, sam) = try await mayaPostsOneOfEach()
        #expect(try await jonah.posts(by: "maya").map(\.title) == ["Spare key", "Trailhead"])
        #expect(try await priya.posts(by: "maya").map(\.title) == ["Kyoto list", "Spare key", "Trailhead"])
        #expect(try await sam.posts(by: "maya").map(\.title) == ["Trailhead"], "a follower who isn't a friend sees public only")
        // No viewer's count hints at a post they can't see, and none depends on which rooms they're in.
        for viewer in [jonah, priya, sam] {
            #expect(viewer.postCount(try await viewer.profile("maya")) == 1)
        }
    }

    @Test("A profile reads the rooms itself when the feed couldn't, as when Messages was still connecting")
    func profileReadsRoomsWhenTheFeedCouldNot() async throws {
        let (_, _, _, _) = try await mayaPostsOneOfEach()
        let rooms = matrix.device(for: "maya")
        rooms.unavailableReason = "Messages is still connecting."
        let phone = SocialModel(server: world.person("maya"), privateRooms: rooms)
        await phone.load()
        #expect(!phone.following.contains { $0.audience != .everyone })
        rooms.unavailableReason = nil
        #expect(try await phone.posts(by: "maya").count == 3)
    }

    @Test("Paging a profile keeps public and private posts in date order, each once")
    func pagingMergesBothSourcesByDate() async throws {
        let maya = device("maya"), jonah = device("jonah")
        for (a, b) in [(jonah, "maya"), (maya, "jonah")] { await a.load(); _ = await a.setFollowing(true, b) }
        await maya.load()
        for n in 0..<40 {
            step()
            #expect(await maya.publish(n % 4 == 0 ? .friends : .everyone, title: "", body: "Post \(n)"))
        }
        for viewer in [maya, jonah] {
            var page = try await viewer.posts(by: "maya")
            var all = page
            #expect(viewer.hasMore(after: page))
            while viewer.hasMore(after: page), let oldest = all.last?.date {
                page = try await viewer.posts(by: "maya", before: oldest)
                all += page
            }
            #expect(all.map(\.body) == (0..<40).reversed().map { "Post \($0)" })
        }
    }

    @Test("A Friends photo opens on a friend's phone, and the bucket only ever holds ciphertext")
    func friendsPhotosReachOnlyFriendsAndStaySealed() async throws {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya")
        for (a, b) in [(jonah, "maya"), (maya, "jonah"), (priya, "maya")] { await a.load(); #expect(await a.setFollowing(true, b)) }
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 1200, height: 900))
        #expect(await maya.publish(.friends, title: "", body: "The saddle at first light.", attachments: [photo]))
        #expect(world.posts.isEmpty, "a Friends post is never a row on Totality's server")
        #expect(world.files.count == 1 && world.files.values.allSatisfy { $0 != photo.data }, "the bucket holds only the sealed file")

        await jonah.load()
        let seen = try #require(jonah.following.first)
        let item = try #require(seen.photos.first)
        #expect(item.isSealed)
        #expect(try await jonah.mediaData(item) == photo.data, "the key from the encrypted room opens it on a friend's phone")

        await priya.load()
        #expect(priya.following.isEmpty, "a follower who isn't a friend never learns the file's address or key")
        // Even with the address, the bytes are only ciphertext without the key.
        let stored = try await world.person("priya").media(item)
        #expect(stored != photo.data)
    }

    @Test func publicAudioIsReadableByAnyone() async throws {
        let maya = device("maya"), priya = device("priya")
        await maya.load()
        let clip = Attachment(kind: .audio, data: Data(repeating: 3, count: 4000), duration: 40)
        #expect(await maya.publish(.everyone, title: "Kant's first Critique in ten minutes", body: "", attachments: [clip]))
        let id = try #require(world.posts.keys.first)
        await priya.load()
        await priya.fetchPost(id)
        let post = try #require(priya.post(id))
        let audio = try #require(post.audio)
        #expect(!audio.isSealed && audio.duration == 40)
        #expect(try await priya.mediaData(audio) == clip.data)
        // Priya can't remove Maya's file.
        try await world.person("priya").removeMedia([audio])
        #expect(world.files[audio.path] != nil)
    }
}
