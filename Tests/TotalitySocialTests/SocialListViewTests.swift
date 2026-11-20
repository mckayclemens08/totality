import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

/// What the Followers/Following rows and the profile stats say.
@MainActor
@Suite struct SocialListViewTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    func device(_ name: String) -> SocialModel {
        SocialModel(server: world.person(name), privateRooms: matrix.device(for: name))
    }

    @Test func yourOwnFollowingListSaysFollowingNeverFollow() async {
        let ana = device("ana"), eli = device("eli"), kai = device("kai")
        await eli.load(); await kai.load()
        await ana.load(); _ = await ana.setFollowing(true, "eli"); _ = await ana.setFollowing(true, "kai")
        let list = FollowList(social: ana, username: "ana", showingFollowers: false)
        await list.reload(query: "")
        #expect(list.isMine)
        #expect(list.people.count == 2)
        #expect(list.people.allSatisfy { Relationship($0, me: ana.me) == .following })
    }

    @Test func closeFriendTagOnlyOnYourOwnList() {
        let carter = SocialPerson(username: "carter", iFollow: true, followsMe: true)
        #expect(FollowListView.tags(carter, isMine: true, closeFriends: ["carter"]) == [.closeFriend])
        // Someone else's list never shows a Close-friends tag, whatever this phone holds.
        #expect(FollowListView.tags(carter, isMine: false, closeFriends: ["carter"]) == [.friends])
        // A row the signed-in account doesn't follow can't be tagged either.
        let stranger = SocialPerson(username: "carter")
        #expect(FollowListView.tags(stranger, isMine: true, closeFriends: ["carter"]).isEmpty)
        let muted = SocialPerson(username: "carter", iFollow: true, muted: true)
        #expect(FollowListView.tags(muted, isMine: true, closeFriends: []) == [.muted])
    }

    @Test func statsPluralize() {
        #expect(SocialProfileView.label(1, "post", "posts") == "post")
        #expect(SocialProfileView.label(0, "post", "posts") == "posts")
        #expect(SocialProfileView.label(2, "follower", "followers") == "followers")
    }
}
