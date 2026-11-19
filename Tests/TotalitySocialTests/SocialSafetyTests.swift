import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

@MainActor
@Suite struct SocialSafetyTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    func device(_ name: String) -> SocialModel {
        SocialModel(server: world.person(name), privateRooms: matrix.device(for: name))
    }

    @Test func aPrivateAccountTurnsFollowsIntoRequests() async throws {
        let ana = device("ana"), eli = device("eli")
        await ana.load()
        #expect(await ana.save(SocialSettings(privateAccount: true)))
        await eli.load()
        _ = await eli.setFollowing(true, "ana")
        #expect(try await eli.profile("ana").requested)
        await ana.load()
        #expect(ana.followRequests == ["eli"])
        await ana.answerRequest("eli", approve: true)
        #expect(ana.followRequests.isEmpty)
        #expect(try await eli.profile("ana").iFollow)
    }

    @Test func muteHidesTheirPostsAndTellsNoOne() async throws {
        let ana = device("ana"), eli = device("eli")
        await ana.load()
        _ = await ana.publish(.everyone, title: "", body: "Raku firing this weekend.")
        await eli.load()
        #expect(eli.forYou.count == 1)
        #expect(await eli.setMuted(true, try await eli.profile("ana")))
        #expect(eli.forYou.isEmpty)
        #expect(world.mutes["ana"] == nil, "ana's side records nothing")
    }

    @Test func blockingTakesThemOutOfYourFriendsRoom() async throws {
        let ana = device("ana"), eli = device("eli")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await ana.load(); _ = await ana.setFollowing(true, "eli")
        #expect(await ana.publish(.friends, title: "", body: "Friends only: the kiln finally works."))
        await eli.load()
        #expect(eli.following.count == 1)
        #expect(await ana.setBlocked(true, try await ana.profile("eli")))
        #expect(await ana.publish(.friends, title: "", body: "After the block."))
        await eli.load()
        #expect(!eli.following.contains { $0.body == "After the block." })
    }

    @Test func reportingAnEncryptedPostSendsNoPost() async throws {
        let ana = device("ana"), eli = device("eli")
        await eli.load(); _ = await eli.setFollowing(true, "ana")
        await ana.load(); _ = await ana.setFollowing(true, "eli")
        _ = await ana.publish(.friends, title: "", body: "Friends only.")
        await eli.load()
        let post = try #require(eli.following.first)
        #expect(await eli.report("ana", post: post, comment: nil, reason: .spam))
        #expect(world.reports.count == 1)
        #expect(world.reports[0].post == nil, "the moderator never gets an encrypted post's ID")
        #expect(world.reports[0].reason == "Spam")
    }

    @Test func savesArePublicPostsOnly() async throws {
        let ana = device("ana"), eli = device("eli")
        await ana.load()
        _ = await ana.publish(.everyone, title: "Glaze recipes", body: "Celadon, tenmoku, shino.")
        await eli.load()
        let post = try #require(eli.forYou.first)
        await eli.toggleSaved(post)
        #expect(eli.forYou.first?.saved == true)
        await eli.loadSaved()
        #expect(eli.saved.map(\.id) == [post.id])
        await eli.toggleSaved(eli.forYou[0])
        #expect(eli.saved.isEmpty)
    }

    @Test func hiddenLikeCountsReadAsLike() {
        var post = SocialPost(id: UUID(), author: "ana", audience: .everyone, body: "x", date: Date(), likes: 41)
        #expect(LikeText.count(post, hideEverywhere: false) == "41")
        #expect(LikeText.count(post, hideEverywhere: true) == "Like")
        post.likesHidden = true
        post.liked = true
        #expect(LikeText.count(post, hideEverywhere: false) == "Liked")
    }
}
