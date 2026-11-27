import Foundation
import TotalityCore

/// Who may send a post to a chat, and what a copied link is. Pure, so the rules test without a server.
public enum SharePolicy {
    /// Anyone can share a public or Friends post, except one by someone you blocked. Only the author can share a
    /// Close-friends post, since the people it was written for chose who sees it.
    public static func canShare(_ post: SocialPost, me: String?, blocked: Set<String>) -> Bool {
        if blocked.contains(post.author.lowercased()) { return false }
        switch post.audience {
        case .everyone, .friends: return true
        case .closeFriends: return me != nil && post.author.lowercased() == me?.lowercased()
        }
    }

    /// Copy link and the system share sheet work for public posts only: a link to anything else would open nothing.
    public static func link(for post: SocialPost) -> URL? {
        post.audience == .everyone ? URL(string: "https://usetotality.com/post/\(post.id.uuidString.lowercased())") : nil
    }

    public static func linkReason(for post: SocialPost) -> String? {
        post.audience == .everyone ? nil : "Copy link is off: only \(post.audience == .friends ? "friends" : "close friends") can open this post."
    }
}

extension SocialModel {
    /// The post as a ref for another module: its ID, and a title for the sender's own picker. Social's posts
    /// have no sealed key of their own here, so the ref names no key.
    public static func ref(for post: SocialPost) -> ContentRef {
        ContentRef(module: .social, kind: .post, id: post.id, keyRef: .plain, preview: .init(title: String(post.headline.prefix(120))))
    }

    public func canShare(_ post: SocialPost) -> Bool {
        SharePolicy.canShare(post, me: me, blocked: blockedAuthors)
    }

    /// Opens the share sheet. Nothing is sent until the person picks chats and presses Send.
    public func share(_ post: SocialPost) {
        guard canShare(post) else {
            notice = post.audience == .closeFriends ? "Only the author can share a Close-friends post." : "You can't share this post."
            return
        }
        guard let onShare else {
            notice = "Sharing to a chat isn't available here."
            return
        }
        onShare(ShareRequest(
            ref: Self.ref(for: post), author: post.author, authorName: post.displayName, snippet: String(post.headline.prefix(120)),
            link: SharePolicy.link(for: post), linkReason: SharePolicy.linkReason(for: post)
        ))
    }

    /// What a post someone sent in a chat shows as for this person, using this person's own access. A post they
    /// can't open gives a placeholder carrying nothing from the post itself.
    public func sharedCard(_ ref: ContentRef, author: String?) async -> SharedCardState {
        guard ref.module == .social, ref.kind == .post else { return .unavailable(author: author) }
        if let author, blockedAuthors.contains(author.lowercased()) { return .unavailable(author: author) }
        var found = post(ref.id)
        if found == nil, phase != .ready { await load() }
        if found == nil { found = post(ref.id) }
        if found == nil {
            do {
                found = try await server.post(ref.id)
            } catch {
                return .failed
            }
        }
        guard let found, !blockedAuthors.contains(found.author.lowercased()) else { return .unavailable(author: author) }
        var thumbnail: Data?
        if let cover = found.photos.first { thumbnail = try? await mediaData(cover) }
        let text = found.headline
        return .card(SharedCardContent(
            authorName: found.displayName, author: found.author, audience: found.audience.name,
            text: String(text.prefix(300)), thumbnail: thumbnail,
            likes: found.likesHidden ? nil : found.likes, comments: found.comments
        ))
    }

    /// The people to name in a placeholder, so a sender's chat can offer their profile.
    public func openShared(_ ref: ContentRef) {
        requestedPost = ref.id
    }
}
