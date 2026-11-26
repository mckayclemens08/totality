import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

@MainActor
struct SocialNotificationsTests {
    @Test func activityBecomesAlertsWithTheRightTargets() {
        let post = UUID()
        let like = SocialNotifications.note(SocialActivity(
            kind: .like, id: UUID(), username: "jonah_r", post: post, postSnippet: "First frost", date: Date()
        ))
        #expect(like.title == "@jonah_r liked your post" && like.body == "\u{201C}First frost\u{201D}")
        #expect(like.target == NotificationTarget(module: .social, kind: "post", item: post.uuidString) && !like.isPrivate)

        let request = SocialNotifications.note(SocialActivity(kind: .request, id: UUID(), username: "sam", displayName: "Sam Ito", date: Date()))
        #expect(request.title == "Sam Ito asked to follow you" && request.actions == [.approve])
        #expect(request.target.kind == "profile" && request.target.item == "sam" && request.kind == SocialNotifications.request)

        let reply = SocialNotifications.note(SocialActivity(kind: .reply, id: UUID(), username: "lena", post: post, snippet: "Agreed", date: Date()))
        #expect(reply.kind == SocialNotifications.comment && reply.body == "Agreed")
    }

    @Test func friendsPostsStartOffAndArePrivate() {
        #expect(!SocialNotifications.friendsPost.startsOn && SocialNotifications.closeFriendsPost.startsOn)
        #expect(Set(SocialNotifications.note(SocialActivity(kind: .follower, id: UUID(), username: "kai", date: Date())).id.split(separator: ".").prefix(2)) == ["social", "follower"])
    }
}
