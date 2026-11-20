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
