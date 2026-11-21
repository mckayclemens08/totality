import Foundation
import Testing
@testable import TotalitySocial

@Suite struct SocialTabBarTests {
    @Test func tabsAreTheApprovedOnesInOrder() {
        #expect(SocialTab.allCases.map(\.title) == ["Feed", "Search", "New post", "Saved", "Profile"])
        #expect(SocialTab.allCases[2] == .newPost, "The + sits in the centre.")
    }

    @Test func eachTabGoesToItsScreen() {
        #expect(SocialTab.feed.destination(me: "maya") == .show(.feed))
        #expect(SocialTab.search.destination(me: "maya") == .show(.search))
        #expect(SocialTab.newPost.destination(me: "maya") == .compose)
        #expect(SocialTab.saved.destination(me: "maya") == .show(.saved))
        #expect(SocialTab.profile.destination(me: "maya") == .show(.profile))
    }

    @Test func savedAndProfileWaitForAnAccount() {
        #expect(SocialTab.saved.destination(me: nil) == nil)
        #expect(SocialTab.profile.destination(me: nil) == nil)
        #expect(SocialTab.search.destination(me: nil) == .show(.search))
        #expect(SocialTab.newPost.destination(me: nil) == .compose)
    }
}

@Suite struct SocialHomeTileTests {
    private func post(_ author: String, _ minutes: Double) -> SocialPost {
        SocialPost(id: UUID(), author: author, audience: .everyone, body: "hi", date: Date(timeIntervalSince1970: minutes * 60))
    }

    @Test func recentPostsAreNewestFirstAndNeverYours() {
        let all = [post("ana", 1), post("maya", 9), post("ben", 5), post("cy", 3)]
        #expect(SocialTileLogic.recent(all, me: "maya", count: 2).map(\.author) == ["ben", "cy"])
        #expect(SocialTileLogic.recent([], me: nil, count: 3).isEmpty)
    }

    @Test func badgeHidesAtZeroAndCapsAtNine() {
        #expect(SocialTileLogic.badge(0) == nil)
        #expect(SocialTileLogic.badge(4) == "4")
        #expect(SocialTileLogic.badge(12) == "9+")
    }
}
