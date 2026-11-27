import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

private func post(_ audience: Audience, by author: String = "maya") -> SocialPost {
    SocialPost(id: UUID(), author: author, authorName: "Maya Reyes", audience: audience, body: "Finally got up to Delicate Arch.", date: Date())
}

@MainActor
@Suite struct SharePolicyTests {
    @Test func publicAndFriendsPostsCanBeSharedByAnyone() {
        #expect(SharePolicy.canShare(post(.everyone), me: "jonah", blocked: []))
        #expect(SharePolicy.canShare(post(.friends), me: "jonah", blocked: []))
    }

    @Test func closeFriendsPostsOnlyByTheirAuthor() {
        #expect(!SharePolicy.canShare(post(.closeFriends), me: "jonah", blocked: []))
        #expect(!SharePolicy.canShare(post(.closeFriends), me: nil, blocked: []))
        #expect(SharePolicy.canShare(post(.closeFriends), me: "Maya", blocked: []))
    }

    @Test func aBlockedAuthorsPostsGetNoShare() {
        #expect(!SharePolicy.canShare(post(.everyone), me: "jonah", blocked: ["maya"]))
        #expect(!SharePolicy.canShare(post(.friends, by: "Maya"), me: "jonah", blocked: ["maya"]))
    }

    @Test func copyLinkIsForPublicPostsOnly() {
        let open = post(.everyone)
        #expect(SharePolicy.link(for: open)?.absoluteString == "https://usetotality.com/post/\(open.id.uuidString.lowercased())")
        #expect(SharePolicy.linkReason(for: open) == nil)
        #expect(SharePolicy.link(for: post(.friends)) == nil)
        #expect(SharePolicy.link(for: post(.closeFriends)) == nil)
        #expect(SharePolicy.linkReason(for: post(.friends)) != nil)
    }

    @Test func theRefNamesThePostAndNoKey() {
        let p = post(.friends)
        let ref = SocialModel.ref(for: p)
        #expect(ref.module == .social && ref.kind == .post && ref.id == p.id && ref.keyRef == .plain)
    }
}
