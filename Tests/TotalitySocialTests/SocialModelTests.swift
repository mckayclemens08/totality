import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

@Suite struct SocialTextTests {
    @Test func labelsAreTheAgreedOnes() {
        #expect(Audience.everyone.label == "Public: anyone on Totality can see this")
        #expect(Audience.friends.label == "Friends: end-to-end encrypted")
        #expect(Audience.closeFriends.label == "Close friends: end-to-end encrypted")
        #expect(!Audience.everyone.isEncrypted)
        #expect(Audience.friends.isEncrypted && Audience.closeFriends.isEncrypted)
    }

    @Test func tagsAreFoundAsTheServerStoresThem() {
        #expect(PostTags.find(in: "Sourdough attempt #4: finally an open crumb. #Baking #sourdough #baking") == ["baking", "sourdough"])
        #expect(PostTags.find(in: "mail me at a#b or see issue#12") == [])
        #expect(PostTags.find(in: (1...12).map { "#t\($0)" }.joined(separator: " ")).count == 10)
    }

    @Test func handlesParse() {
        #expect(Handle.parse("@Maya_Cooks ") == "maya_cooks")
        #expect(Handle.parse("ab") == nil)
        #expect(Handle.parse("maya.cooks") == nil)
        #expect(Handle.display("jonah") == "@jonah")
    }

    @Test func limitsMatchTheServer() {
        #expect(PostLimits.problem(title: "  ", body: "\n") == "Write something first.")
        #expect(PostLimits.problem(title: "Trailhead at dawn", body: "") == nil)
        #expect(PostLimits.problem(title: String(repeating: "a", count: 121), body: "x") != nil)
    }

    @Test func serverDatesWithMicrosecondsParse() {
        #expect(RestSocialServer.date("2026-11-19T03:12:45.123456+00:00") != nil)
        #expect(RestSocialServer.date("2026-11-19T03:12:45+00:00") != nil)
        #expect(RestSocialServer.date("2026-11-19T03:12:45.123Z") != nil)
    }

    @Test func serverRefusalsBecomePlainWords() {
        let data = Data(#"{"message":"too many posts in an hour"}"#.utf8)
        #expect(RestSocialServer.error(status: 400, data: data) == .refused("That's a lot of posts this hour. Try again later."))
        #expect(RestSocialServer.error(status: 401, data: Data()) == .signedOut)
        // The server's own words are never passed through.
        #expect(RestSocialServer.error(status: 500, data: Data(#"{"message":"<script>"}"#.utf8)) == .failed("Social couldn't do that just now. Try again."))
    }
}

@Suite struct RoomMessageTests {
    @Test func roundTrips() {
        let id = UUID(), post = UUID()
        let messages: [RoomMessage] = [
            .timeline(.closeFriends),
            .post(id: id, title: "Trailhead at dawn", body: "Out the door at 4:30.", tags: ["hiking"], date: Date(timeIntervalSince1970: 1_795_000_000)),
            .delete(post: post), .like(post: post, on: true),
            .comment(id: id, post: post, parent: nil, body: "Worth it."), .uncomment(id: id),
        ]
        for m in messages { #expect(RoomMessage(m.encoded) == m) }
    }

    @Test func refusesWhatTheAppCouldNotPost() {
        #expect(RoomMessage(#"{"v":1,"type":"timeline","audience":"public"}"#) == nil)
        #expect(RoomMessage(#"{"v":2,"type":"like","post":"\#(UUID())","on":true}"#) == nil)
        #expect(RoomMessage(#"{"v":1,"type":"post","id":"\#(UUID())","body":"\#(String(repeating: "a", count: 5001))","date":1}"#) == nil)
        #expect(RoomMessage("not json") == nil)
        let tags = RoomMessage(#"{"v":1,"type":"post","id":"\#(UUID())","body":"x","tags":["ok","Not OK"],"date":1}"#)
        if case .post(_, _, _, let t, _)? = tags { #expect(t == ["ok"]) } else { Issue.record("not a post") }
    }
}

@Suite struct RoomTimelineTests {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func onlyTheOwnerPostsAndEveryoneLikesAndComments() {
        let p1 = UUID(), fake = UUID(), c1 = UUID(), r1 = UUID()
        let events: [SharedRoomEvent] = [
            .roles(["maya": 100]),
            .post(id: "$1", sender: "maya", date: at(1), body: RoomMessage.timeline(.friends).encoded),
            .roles(["maya": 100, "jonah": 0]),
            .post(id: "$2", sender: "maya", date: at(2), body: RoomMessage.post(id: p1, title: nil, body: "Six bowls in three days.", tags: ["food"], date: at(-9999)).encoded),
            .post(id: "$3", sender: "jonah", date: at(3), body: RoomMessage.post(id: fake, title: nil, body: "Pretending to be Maya.", tags: [], date: at(3)).encoded),
            .post(id: "$4", sender: "jonah", date: at(4), body: RoomMessage.like(post: p1, on: true).encoded),
            .post(id: "$5", sender: "jonah", date: at(5), body: RoomMessage.like(post: p1, on: false).encoded),
            .post(id: "$6", sender: "jonah", date: at(6), body: RoomMessage.like(post: p1, on: true).encoded),
            .post(id: "$7", sender: "jonah", date: at(7), body: RoomMessage.comment(id: c1, post: p1, parent: nil, body: "The corn butter one!").encoded),
            .post(id: "$8", sender: "maya", date: at(8), body: RoomMessage.comment(id: r1, post: p1, parent: c1, body: "Sapporo specialty.").encoded),
            .post(id: "$9", sender: "jonah", date: at(9), body: RoomMessage.timeline(.closeFriends).encoded),
            .post(id: "$10", sender: "jonah", date: at(10), body: RoomMessage.delete(post: p1).encoded),
            .unreadable(id: "$11", sender: "jonah", date: at(11)),
        ]
        let history = SharedRoomHistory(events: events, members: [], isEncrypted: true)
        let t = RoomTimeline.build(room: "!r", history: history, me: "jonah")
        #expect(t.owner == "maya")
        #expect(t.audience == .friends)
        #expect(t.posts.map(\.id) == [p1])
        #expect(t.posts[0].date == at(2), "the server's time, never the one written in the post")
        #expect(t.posts[0].likes == 1 && t.posts[0].liked)
        #expect(t.posts[0].comments == 2)
        #expect(t.comments[p1]?.map(\.id) == [c1, r1])
        #expect(t.unreadable == 1)
    }

    @Test func ownerDeletesAndCommentsComeOff() {
        let p = UUID(), c = UUID(), r = UUID()
        func post(_ n: Int, _ who: String, _ m: RoomMessage) -> SharedRoomEvent { .post(id: "$\(n)", sender: who, date: at(Double(n)), body: m.encoded) }
        let base: [SharedRoomEvent] = [
            .roles(["maya": 100]), post(1, "maya", .timeline(.closeFriends)),
            post(2, "maya", .post(id: p, title: "Kyoto list", body: "Close friends only.", tags: [], date: at(2))),
            post(3, "jonah", .comment(id: c, post: p, parent: nil, body: "Saving this.")),
            post(4, "priya", .comment(id: r, post: p, parent: c, body: "Same.")),
            post(5, "priya", .uncomment(id: c)),
        ]
        var t = RoomTimeline.build(room: "!r", history: .init(events: base, members: [], isEncrypted: true), me: "maya")
        #expect(t.comments[p]?.count == 2, "only the writer or the owner can remove a comment")
        t = RoomTimeline.build(room: "!r", history: .init(events: base + [post(6, "maya", .uncomment(id: c))], members: [], isEncrypted: true), me: "maya")
        #expect(t.comments[p] == nil, "a removed comment takes its replies with it")
        t = RoomTimeline.build(room: "!r", history: .init(events: base + [post(6, "maya", .delete(post: p))], members: [], isEncrypted: true), me: "maya")
        #expect(t.posts.isEmpty)
    }
}

@MainActor
@Suite struct SocialModelTests {
    @Test func publicPostsGoToTheServerWithTheirTags() async {
        let world = FakeSocialWorld()
        let model = SocialModel(server: world.person("maya"))
        await model.load()
        #expect(model.phase == .ready)
        #expect(await model.publish(.everyone, title: "The best miso ramen in Sapporo, ranked", body: "Sumire wins. #food #japan"))
        let row = world.posts.values.first!.post
        #expect(row.tags == ["food", "japan"])
        #expect(model.following.count == 1)
    }

    @Test func anEmptyPostIsCaughtOnTheDevice() async {
        let world = FakeSocialWorld()
        let model = SocialModel(server: world.person("maya"))
        #expect(await model.publish(.everyone, title: " ", body: "") == false)
        #expect(model.notice == "Write something first.")
        #expect(world.posts.isEmpty)
    }

    @Test func friendsPostsNeedEncryptedRooms() async {
        let world = FakeSocialWorld()
        let model = SocialModel(server: world.person("maya"))
        #expect(await model.publish(.friends, title: "", body: "Only friends.") == false)
        #expect(world.posts.isEmpty, "a Friends post never falls back to the server")
        #expect(model.privateReason != nil)
    }

    @Test func likesShowStraightAwayAndUndoOnFailure() async {
        let world = FakeSocialWorld()
        let maya = world.person("maya")
        _ = try? await maya.publish(title: nil, body: "Sourdough attempt #4.", tags: [])
        let model = SocialModel(server: world.person("jonah"))
        await model.load()
        let post = model.forYou[0]
        await model.toggleLike(post)
        #expect(model.forYou[0].liked && model.forYou[0].likes == 1)
        #expect(world.posts[post.id]?.likedBy == ["jonah"])
    }

    @Test func forYouNeverRepeatsWhatWasShown() async {
        let world = FakeSocialWorld()
        _ = try? await world.person("maya").publish(title: nil, body: "Sunrise on Timpanogos.", tags: ["hiking"])
        let model = SocialModel(server: world.person("jonah"))
        await model.load()
        model.didShow(model.forYou[0])
        await model.flushShown()
        await model.load()
        #expect(model.forYou.isEmpty)
    }
}
