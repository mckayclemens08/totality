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

@MainActor
@Suite struct SocialGlanceTests {
    @Test func theTileWaitsThenShowsTheNewest() async {
        let world = FakeSocialWorld()
        let maya = world.person("maya")
        let model = SocialModel(server: world.person("jonah"))
        #expect(model.glance == nil, "nothing claimed before loading")
        await model.load()
        #expect(model.glance == ModuleGlance(lines: ["Nothing new yet"], isQuiet: true))
        _ = try? await maya.publish(title: "Sunrise on Timpanogos", body: "Summit to saddle.", tags: [])
        await model.load()
        #expect(model.glance?.lines == ["@maya: Sunrise on Timpanogos"])
    }
}

@MainActor
@Suite struct SocialLinkTests {
    final class Reader: ContentReceiver, @unchecked Sendable {
        let module = ModuleID.reader
        let kinds: Set<ContentKind> = [.note]
        var notes: [(String, String)] = []
        func attachable() async throws -> [ContentRef] { [] }
        func current(_ ref: ContentRef) async throws -> ContentRef? { ref }
        func receive(noteTitled title: String, body: String) async throws -> ContentRef {
            notes.append((title, body))
            return ContentRef(module: .reader, kind: .note, id: UUID(), keyRef: .plain, preview: .init(title: title))
        }
        func receive(file data: Data, named filename: String) async throws -> ContentRef { throw CancellationError() }
    }

    @Test func aPostBecomesAReaderNoteAndATaskDraft() async throws {
        let world = FakeSocialWorld()
        _ = try await world.person("maya").publish(title: "Kyoto ramen list", body: "Ichiran, Menbaka Fire. #food", tags: ["food"])
        let model = SocialModel(server: world.person("jonah"))
        let reader = Reader()
        model.receiver = reader
        await model.load()
        let post = try #require(model.forYou.first)
        await model.saveToReader(post)
        #expect(reader.notes.first?.0 == "Kyoto ramen list")
        #expect(reader.notes.first?.1.contains("@maya") == true)
        let draft = model.taskDraft(post)
        #expect(draft.title == "Kyoto ramen list")
        #expect(draft.source.module == .social && draft.source.itemID == post.id.uuidString)
    }

    final class SlowReader: ContentReceiver, @unchecked Sendable {
        let module = ModuleID.reader
        let kinds: Set<ContentKind> = [.note]
        var notes = 0
        func attachable() async throws -> [ContentRef] { [] }
        func current(_ ref: ContentRef) async throws -> ContentRef? { ref }
        func receive(noteTitled title: String, body: String) async throws -> ContentRef {
            try await Task.sleep(for: .milliseconds(100))
            notes += 1
            return ContentRef(module: .reader, kind: .note, id: UUID(), keyRef: .plain, preview: .init(title: title))
        }
        func receive(file data: Data, named filename: String) async throws -> ContentRef { throw CancellationError() }
    }

    @Test func savingToTheReaderTwiceMakesOneNote() async throws {
        let world = FakeSocialWorld()
        _ = try await world.person("maya").publish(title: "Kyoto ramen list", body: "Ichiran.", tags: [])
        let model = SocialModel(server: world.person("jonah"))
        let reader = Reader()
        model.receiver = reader
        await model.load()
        let post = try #require(model.forYou.first)
        await model.saveToReader(post)
        #expect(model.notice == "Saved to the Reader.")
        #expect(model.isSavedToReader(post))
        await model.saveToReader(post)
        #expect(reader.notes.count == 1)
        #expect(model.notice == "Already saved to the Reader.")
    }

    @Test func twoTapsDuringASaveMakeOneNote() async throws {
        let world = FakeSocialWorld()
        _ = try await world.person("maya").publish(title: "Kyoto ramen list", body: "Ichiran.", tags: [])
        let model = SocialModel(server: world.person("jonah"))
        let reader = SlowReader()
        model.receiver = reader
        await model.load()
        let post = try #require(model.forYou.first)
        async let first: Void = model.saveToReader(post)
        async let second: Void = model.saveToReader(post)
        _ = await (first, second)
        #expect(reader.notes == 1)
        #expect(!model.isSavingToReader(post))
    }

    @Test func savedPostsAreRememberedOnThisDevice() async throws {
        let world = FakeSocialWorld()
        _ = try await world.person("maya").publish(title: "Kyoto ramen list", body: "Ichiran.", tags: [])
        let defaults = try #require(UserDefaults(suiteName: "social.test." + UUID().uuidString))
        let model = SocialModel(server: world.person("jonah"), remembered: defaults)
        let reader = Reader()
        model.receiver = reader
        await model.load()
        let post = try #require(model.forYou.first)
        await model.saveToReader(post)
        let later = SocialModel(server: world.person("jonah"), remembered: defaults)
        later.receiver = reader
        await later.load()
        #expect(later.isSavedToReader(post))
        await later.saveToReader(post)
        #expect(reader.notes.count == 1)
    }

    @Test func aDoubleTapLikesButNeverUnlikes() async throws {
        let world = FakeSocialWorld()
        _ = try await world.person("maya").publish(title: nil, body: "Sourdough attempt #4.", tags: [])
        let model = SocialModel(server: world.person("jonah"))
        await model.load()
        let post = try #require(model.forYou.first)
        await model.like(post)
        await model.like(post)
        #expect(model.forYou[0].liked && model.forYou[0].likes == 1)
        #expect(world.posts[post.id]?.likedBy == ["jonah"])
        await model.toggleLike(model.forYou[0])
        #expect(!model.forYou[0].liked, "the Like button still unlikes")
    }

    @Test func aLinkedPostLoadsWhenItIsNotInAFeed() async throws {
        let world = FakeSocialWorld()
        let id = try await world.person("maya").publish(title: nil, body: "Old post.", tags: [])
        let model = SocialModel(server: world.person("jonah"))
        #expect(model.post(id) == nil)
        await model.fetchPost(id)
        #expect(model.post(id)?.body == "Old post.")
    }
}
