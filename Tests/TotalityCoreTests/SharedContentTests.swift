import Foundation
import Testing
@testable import TotalityCore

private let postID = UUID(uuidString: "6F1D2B3A-0C4E-4A5B-8D7F-1A2B3C4D5E6F")!

private func postRef(_ title: String = "Finally got up to Delicate Arch") -> ContentRef {
    ContentRef(module: .social, kind: .post, id: postID, keyRef: .plain, preview: .init(title: title))
}

@Suite struct SharedContentTests {
    @Test("A shared post's message carries the id and the author's handle, never its words")
    func textHoldsNoContent() {
        let text = SharedContentLink.text(for: postRef(), author: "Maya")
        #expect(text == "totality://share/social/post/6f1d2b3a-0c4e-4a5b-8d7f-1a2b3c4d5e6f?by=maya")
        #expect(!text.contains("Delicate"))
    }

    @Test func roundTrips() throws {
        let shared = try #require(SharedContentLink.parse(SharedContentLink.text(for: postRef(), author: "maya")))
        #expect(shared.ref.id == postID && shared.ref.module == .social && shared.ref.kind == .post)
        #expect(shared.author == "maya")
        let bare = try #require(SharedContentLink.parse(SharedContentLink.text(for: postRef())))
        #expect(bare.author == nil)
    }

    @Test("Only a message that is exactly one link becomes a card")
    func rejectsEverythingElse() {
        let link = SharedContentLink.text(for: postRef())
        #expect(SharedContentLink.parse("look at " + link) == nil)
        #expect(SharedContentLink.parse(link + " wow") == nil)
        #expect(SharedContentLink.parse("totality://share/social/post/not-a-uuid") == nil)
        #expect(SharedContentLink.parse("totality://share/nowhere/post/\(postID)") == nil)
        #expect(SharedContentLink.parse("totality://share/social/photo") == nil)
        #expect(SharedContentLink.parse("https://example.com/share/social/post/\(postID)") == nil)
        #expect(SharedContentLink.parse("hello") == nil)
    }

    @Test("A handle with odd characters is dropped rather than carried")
    func oddHandlesAreDropped() throws {
        #expect(!SharedContentLink.text(for: postRef(), author: "ma ya&x=1").contains("by="))
        let parsed = try #require(SharedContentLink.parse(SharedContentLink.text(for: postRef()) + "?by=maya%20x"))
        #expect(parsed.author == nil)
    }

    @Test func theChatListSaysSharedAPost() {
        #expect(SharedContentLink.summary(of: SharedContentLink.text(for: postRef())) == "Shared a post")
        #expect(SharedContentLink.summary(of: "See you at 6") == nil)
    }

    @Test("A send reaches at most ten chats, once each")
    func limitsTargets() {
        let many = (0..<14).map { "!chat\($0)" }
        #expect(ShareLimits.limited(many).count == 10)
        #expect(ShareLimits.limited(["!a", "!b", "!a"]) == ["!a", "!b"])
        #expect(ShareLimits.canSend(selected: 1) && ShareLimits.canSend(selected: 10))
        #expect(!ShareLimits.canSend(selected: 0) && !ShareLimits.canSend(selected: 11))
    }

    @Test func requestSendsTheLinkNotTheSnippet() {
        let request = ShareRequest(ref: postRef(), author: "maya", authorName: "Maya Reyes", snippet: "Finally got up", link: nil, linkReason: "off")
        #expect(request.messageText.contains("maya") && !request.messageText.contains("Finally"))
        #expect(request.id == postID)
    }
}
