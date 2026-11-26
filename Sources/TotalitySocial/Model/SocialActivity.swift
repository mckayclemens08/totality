import Foundation

/// Something that happened to you on Social: a follow, a request, a like, a comment or a reply (issue 232).
/// Only public things are here, read from Totality's server. Friends and Close-friends activity stays in
/// the encrypted rooms.
public struct SocialActivity: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case follower, request, like, repost, comment, reply
    }

    public let kind: Kind
    /// The row's ID, so the same follow or like is only ever alerted once.
    public let id: UUID
    public let username: String
    public let displayName: String?
    public let post: UUID?
    /// The start of the post's title or text, which the person wrote themselves and is public.
    public let postSnippet: String?
    public let comment: UUID?
    /// The start of the comment, for comments and replies.
    public let snippet: String?
    public let date: Date

    public init(
        kind: Kind, id: UUID, username: String, displayName: String? = nil, post: UUID? = nil, postSnippet: String? = nil,
        comment: UUID? = nil, snippet: String? = nil, date: Date
    ) {
        self.kind = kind
        self.id = id
        self.username = username
        self.displayName = displayName
        self.post = post
        self.postSnippet = postSnippet
        self.comment = comment
        self.snippet = snippet
        self.date = date
    }
}

/// A server that can say what happened to you since a time. Kept apart from `SocialServer`, so test
/// servers that don't need it are left alone.
public protocol SocialActivityServer: Sendable {
    func activity(since: Date) async throws -> [SocialActivity]
}

extension RestSocialServer: SocialActivityServer {
    struct ActivityRow: Decodable {
        let kind: String
        let id: UUID
        let handle: String
        let display_name: String?
        let post_id: UUID?
        let post_snippet: String?
        let comment_id: UUID?
        let snippet: String?
        let at: String
    }

    public func activity(since: Date) async throws -> [SocialActivity] {
        try await rpc("social_activity", ["p_since": Self.text(since), "p_limit": 50], as: ActivityRow.self).compactMap { row in
            guard let kind = SocialActivity.Kind(rawValue: row.kind), let date = Self.date(row.at) else { return nil }
            return SocialActivity(
                kind: kind, id: row.id, username: row.handle, displayName: row.display_name, post: row.post_id,
                postSnippet: row.post_snippet, comment: row.comment_id, snippet: row.snippet, date: date
            )
        }
    }
}
