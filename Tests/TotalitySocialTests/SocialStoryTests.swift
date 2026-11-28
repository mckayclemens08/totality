import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

/// Social step 4 (issue 149): video posts and stories, against stand-ins for Totality's server and Matrix.
@MainActor
@Suite struct SocialStoryTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    init() {
        // Stories live for a day of real time, so the fake Matrix server's clock starts now.
        matrix.clock = Date()
    }

    func device(_ name: String) -> SocialModel {
        SocialModel(server: world.person(name), privateRooms: matrix.device(for: name))
    }

    func path(_ name: String) -> String { world.id(name).uuidString.lowercased() + "/" + UUID().uuidString.lowercased() }

    func friends(_ a: SocialModel, _ b: SocialModel) async {
        await a.load(); await b.load()
        _ = await a.setFollowing(true, b.me ?? "")
        _ = await b.setFollowing(true, a.me ?? "")
    }

    // MARK: Video limits

    @Test func aPostHoldsOneVideoWithItsCoverAndNothingElse() {
        let video = PostMedia(kind: .video, path: path("maya"), size: 20_000_000, duration: 42)
        let cover = PostMedia(kind: .photo, path: path("maya"), size: 90_000)
        #expect(MediaLimits.problem([video, cover], encrypted: false) == nil)
        #expect(MediaLimits.problem([video], encrypted: false) == nil)
        #expect(MediaLimits.problem([video, cover, cover], encrypted: false) != nil)
        #expect(MediaLimits.problem([video, video], encrypted: false) != nil)
        #expect(MediaLimits.problem([video, PostMedia(kind: .audio, path: path("maya"), size: 9, duration: 3)], encrypted: false) != nil)
    }

    @Test func aVideoIsThreeMinutesAndFortyMegabytesAtMost() {
        let long = PostMedia(kind: .video, path: path("maya"), size: 1000, duration: 200)
        #expect(MediaLimits.problem([long], encrypted: false) == "Video is capped at three minutes.")
        let unknown = PostMedia(kind: .video, path: path("maya"), size: 1000)
        #expect(MediaLimits.problem([unknown], encrypted: false) != nil)
        let big = PostMedia(kind: .video, path: path("maya"), size: MediaLimits.videoBytes + 29, duration: 60)
        #expect(MediaLimits.problem([big], encrypted: false) != nil)
        // A photo keeps its own, smaller limit.
        let bigPhoto = PostMedia(kind: .photo, path: path("maya"), size: MediaLimits.fileBytes + 29)
        #expect(MediaLimits.problem([bigPhoto], encrypted: false) != nil)
        // Audio's two minutes don't apply to video.
        let ninety = PostMedia(kind: .video, path: path("maya"), size: 1000, duration: 150)
        #expect(MediaLimits.problem([ninety], encrypted: false) == nil)
    }

    @Test func aPostNeverPointsAtTheStoryShelf() {
        let photo = PostMedia(kind: .photo, path: path("maya"), size: 9, store: .stories)
        #expect(MediaLimits.problem([photo], encrypted: false) != nil)
    }

    @Test func trimmingKeepsInsideTheVideoAndAtMostThreeMinutes() {
        #expect(TrimRange.clamped(start: 0, end: 600, length: 600) == TrimRange(start: 0, end: 180))
        #expect(TrimRange.clamped(start: 30, end: 10, length: 60) == TrimRange(start: 30, end: 60))
        #expect(TrimRange.clamped(start: -5, end: 20, length: 60) == TrimRange(start: 0, end: 20))
        #expect(TrimRange.clamped(start: 50, end: .nan, length: 60) == TrimRange(start: 50, end: 60))
    }

    @Test func aVideoPostGoesUpWithItsCoverAndPlaysFromAFile() async throws {
        let maya = device("maya")
        await maya.load()
        let video = Attachment(kind: .video, data: Data(repeating: 7, count: 5_000_000), width: 540, height: 960, duration: 42)
        let cover = try Attachment.photo(sampleJPEG(width: 540, height: 960))
        #expect(await maya.publish(.everyone, title: "", body: "Sunset from the Y trail.", attachments: [video, cover]))
        let post = try #require(maya.following.first)
        let item = try #require(post.video)
        #expect(post.photos.count == 1 && post.headline == "Sunset from the Y trail.")
        let file = try await maya.videoFile(item)
        #expect(try Data(contentsOf: file) == video.data)
        #expect(!file.lastPathComponent.contains(item.path.split(separator: "/").last ?? "x"), "named for a hash, not its address")
    }

    @Test func aFriendsVideoIsSealedAndOpensOnlyWithItsKey() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await friends(maya, jonah)
        let video = Attachment(kind: .video, data: Data(repeating: 3, count: 6_000_000), duration: 30)
        let cover = try Attachment.photo(sampleJPEG(width: 300, height: 300))
        #expect(await maya.publish(.friends, title: "", body: "", attachments: [video, cover]))
        #expect(world.files.values.allSatisfy { !$0.starts(with: video.data.prefix(64)) }, "the server holds only sealed bytes")
        await jonah.load()
        let post = try #require(jonah.following.first { $0.audience == .friends })
        let item = try #require(post.video)
        #expect(try Data(contentsOf: try await jonah.videoFile(item)) == video.data)
    }

    // MARK: Stories

    @Test func storyLimits() {
        let photo = PostMedia(kind: .photo, path: path("maya"), size: 9, store: .stories)
        let video = PostMedia(kind: .video, path: path("maya"), size: 9, duration: 20, store: .stories)
        #expect(StoryLimits.problem(kind: .text, text: "Moving day.", media: [], encrypted: false) == nil)
        #expect(StoryLimits.problem(kind: .text, text: "  ", media: [], encrypted: false) != nil)
        #expect(StoryLimits.problem(kind: .text, text: String(repeating: "a", count: 301), media: [], encrypted: false) != nil)
        #expect(StoryLimits.problem(kind: .photo, text: "", media: [photo], encrypted: false) == nil)
        #expect(StoryLimits.problem(kind: .video, text: "", media: [video, photo], encrypted: false) == nil)
        #expect(StoryLimits.problem(kind: .video, text: "", media: [video], encrypted: false) != nil)
        var kept = photo
        kept.store = .totality
        #expect(StoryLimits.problem(kind: .photo, text: "", media: [kept], encrypted: false) != nil, "a story's file has to expire")
    }

    @Test func aStoryLastsADay() {
        let story = SocialStory(id: UUID(), author: "maya", audience: .everyone, kind: .text, text: "Hi", date: Date(timeIntervalSince1970: 0))
        #expect(story.isLive(at: Date(timeIntervalSince1970: 86_399)))
        #expect(!story.isLive(at: Date(timeIntervalSince1970: 86_400)))
    }

    @Test func aPublicStoryGoesToTheServerWithItsFileOnTheStoryShelf() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await jonah.load()
        _ = await jonah.setFollowing(true, "maya")
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.postStory(.everyone, kind: .photo, text: "Tonight's ramen.", background: nil, attachments: [photo]))
        #expect(world.storyFiles.count == 1 && world.files.isEmpty)
        await jonah.load()
        let ring = try #require(jonah.ring(for: "maya"))
        #expect(ring.stories.count == 1 && !ring.allViewed)
        let story = ring.stories[0]
        #expect(try await jonah.mediaData(try #require(story.photo)) == photo.data)
        await jonah.markViewed(story)
        #expect(jonah.ring(for: "maya")?.allViewed == true)
        #expect(await maya.viewers(of: maya.stories[0]) == ["jonah"])
        #expect(await jonah.viewers(of: story).isEmpty, "only the author sees who viewed")
    }

    @Test func aFriendsStoryIsSealedInTheRoomAndOnlyFriendsSeeIt() async throws {
        let maya = device("maya"), jonah = device("jonah"), priya = device("priya")
        await friends(maya, jonah)
        await priya.load()
        _ = await priya.setFollowing(true, "maya")
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.postStory(.friends, kind: .photo, text: "", background: nil, attachments: [photo]))
        #expect(world.stories.isEmpty, "never a row on Totality's server")
        let stored = try #require(world.storyFiles.values.first)
        #expect(stored != photo.data, "sealed before upload")
        await jonah.load()
        let story = try #require(jonah.ring(for: "maya")?.stories.first)
        #expect(story.audience == .friends && story.photo?.isSealed == true)
        #expect(try await jonah.mediaData(try #require(story.photo)) == photo.data)
        await priya.load()
        #expect(priya.ring(for: "maya") == nil, "a follower who isn't a friend sees nothing")

        // A view of an encrypted story shows the author only people in its room.
        await jonah.markViewed(story)
        try await world.person("priya").viewStory(story.id, author: "maya")
        let mine = try #require(maya.stories.first)
        #expect(await maya.viewers(of: mine) == ["jonah"])
    }

    @Test func aTextStoryInTheRoomCarriesItsColour() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await friends(maya, jonah)
        await maya.load()
        #expect(await maya.postStory(.friends, kind: .text, text: "Moving day. If you have a dolly I owe you dinner.", background: .sage, attachments: []))
        await jonah.load()
        let story = try #require(jonah.ring(for: "maya")?.stories.last)
        #expect(story.kind == .text && story.background == .sage && story.text.hasPrefix("Moving day."))
    }

    @Test func deletingAStoryTakesItAndItsFileDown() async throws {
        let maya = device("maya")
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.postStory(.everyone, kind: .photo, text: "", background: nil, attachments: [photo]))
        let story = try #require(maya.stories.first)
        await maya.deleteStory(story)
        #expect(maya.stories.isEmpty && world.stories.isEmpty && world.storyFiles.isEmpty)
    }

    @Test func aRoomStoryOlderThanADayIsGoneAndOnlyTheOwnerCanPostOne() throws {
        let id = UUID()
        let now = Date()
        let body = RoomMessage.story(id: id, kind: .text, text: "Hi", background: .accent, media: []).encoded
        #expect(RoomMessage(body) == .story(id: id, kind: .text, text: "Hi", background: .accent, media: []))
        let history = SharedRoomHistory(events: [
            .roles(["maya": 100, "jonah": 0]),
            .post(id: "1", sender: "maya", date: now.addingTimeInterval(-90_000), body: RoomMessage.timeline(.friends).encoded),
            .post(id: "2", sender: "maya", date: now.addingTimeInterval(-90_000), body: RoomMessage.story(id: UUID(), kind: .text, text: "Old", background: nil, media: []).encoded),
            .post(id: "3", sender: "jonah", date: now, body: RoomMessage.story(id: UUID(), kind: .text, text: "Not mine", background: nil, media: []).encoded),
            .post(id: "4", sender: "maya", date: now, body: body),
        ], members: [], isEncrypted: true)
        let timeline = RoomTimeline.build(room: "!r", history: history, me: "jonah", now: now)
        #expect(timeline.stories.map(\.id) == [id])
        // A readable file in a sealed room is refused.
        let open = PostMedia(kind: .photo, path: path("maya"), size: 9, store: .stories)
        #expect(RoomMessage(RoomMessage.story(id: UUID(), kind: .photo, text: "", background: nil, media: [open]).encoded) == nil)
    }

    @Test func ringsPutYoursFirstThenNewOnesThenSeen() {
        let now = Date()
        func story(_ author: String, _ ago: TimeInterval, viewed: Bool) -> SocialStory {
            SocialStory(id: UUID(), author: author, audience: .everyone, kind: .text, text: "x", date: now.addingTimeInterval(-ago), viewed: viewed)
        }
        let rings = StoryRing.rings([story("ana", 10, viewed: true), story("ben", 500, viewed: false), story("me", 900, viewed: true),
                                     story("cal", 100, viewed: false), story("old", 90_000, viewed: false)], me: "me", now: now)
        #expect(rings.map(\.author) == ["me", "cal", "ben", "ana"])
    }

    @Test func postingASecondStoryShowsImmediatelyEvenWhenRefetchLags() async throws {
        let maya = device("maya"), jonah = device("jonah")
        await friends(maya, jonah)
        await maya.load()
        #expect(await maya.postStory(.everyone, kind: .text, text: "First story", background: .accent, attachments: []))
        let before = maya.ring(for: "maya")?.stories.count ?? 0
        #expect(before == 1)
        // Simulate server stories() failing or lagging right after posting a 2nd public story.
        world.storiesFail = true
        #expect(await maya.postStory(.everyone, kind: .text, text: "Second story", background: .sage, attachments: []))
        let after = maya.ring(for: "maya")?.stories ?? []
        #expect(after.count == 2)
        #expect(after.map(\.text) == ["First story", "Second story"])
        // And a 3rd friends-only story also appears immediately even when refetch lags behind the newest own story.
        world.storiesFail = false
        world.omitLatestOwnStory = true
        #expect(await maya.postStory(.friends, kind: .text, text: "Third story", background: .sage, attachments: []))
        let three = maya.ring(for: "maya")?.stories ?? []
        #expect(three.count == 3)
        #expect(three.map(\.text) == ["First story", "Second story", "Third story"])
        // And a 4th everyone story also shows immediately when `stories()` omits the newest own story.
        #expect(await maya.postStory(.everyone, kind: .text, text: "Fourth story", background: .accent, attachments: []))
        let four = maya.ring(for: "maya")?.stories ?? []
        #expect(four.count == 4)
        #expect(Set(four.map(\.text)) == ["First story", "Second story", "Third story", "Fourth story"])
    }
}
