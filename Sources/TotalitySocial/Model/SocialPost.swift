import Foundation

/// Who can read a post (issue 149 §1). It decides where the post is kept: a public post is a readable row on
/// Totality's server, so For You can rank it; the other two travel only in end-to-end encrypted Matrix rooms.
public enum Audience: String, Codable, Sendable, CaseIterable, Identifiable {
    case everyone = "public"
    case friends
    case closeFriends = "close_friends"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .everyone: "Public"
        case .friends: "Friends"
        case .closeFriends: "Close friends"
        }
    }

    /// The label the spec agreed on. It has to stay literally true (non-negotiable 5).
    public var label: String {
        switch self {
        case .everyone: "Public: anyone on Totality can see this"
        case .friends: "Friends: end-to-end encrypted"
        case .closeFriends: "Close friends: end-to-end encrypted"
        }
    }

    public var who: String {
        switch self {
        case .everyone: "Anyone on Totality"
        case .friends: "People you follow who follow you back"
        case .closeFriends: "A list you choose"
        }
    }

    public var isEncrypted: Bool { self != .everyone }

    public var systemImage: String {
        switch self {
        case .everyone: "globe"
        case .friends: "lock"
        case .closeFriends: "star.circle"
        }
    }
}

/// One post, whatever its audience. Public posts come from the server; the others from the author's
/// encrypted room, opened on this device.
public struct SocialPost: Identifiable, Hashable, Sendable {
    /// For a public post, its row's ID. For an encrypted one, the ID inside the room post, made on the
    /// author's device.
    public let id: UUID
    public let author: String
    public let authorName: String?
    public let audience: Audience
    public var title: String?
    public var body: String
    public var tags: [String]
    public let date: Date
    public var edited: Bool
    public var likes: Int
    public var comments: Int
    public var liked: Bool
    /// For You's "Why am I seeing this?" line.
    public var reason: String?
    /// The encrypted room it lives in, for one that isn't public.
    public let room: String?

    public init(
        id: UUID, author: String, authorName: String? = nil, audience: Audience, title: String? = nil, body: String,
        tags: [String] = [], date: Date, edited: Bool = false, likes: Int = 0, comments: Int = 0, liked: Bool = false,
        reason: String? = nil, room: String? = nil
    ) {
        self.id = id
        self.author = author
        self.authorName = authorName
        self.audience = audience
        self.title = title
        self.body = body
        self.tags = tags
        self.date = date
        self.edited = edited
        self.likes = likes
        self.comments = comments
        self.liked = liked
        self.reason = reason
        self.room = room
    }

    public var displayName: String {
        guard let authorName, !authorName.trimmingCharacters(in: .whitespaces).isEmpty else { return author }
        return authorName
    }

    /// A headline for the grid: the title, or the start of the text.
    public var headline: String {
        if let title, !title.isEmpty { return title }
        return body
    }
}

public struct SocialComment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let parent: UUID?
    public let author: String
    public let authorName: String?
    public let body: String
    public let date: Date

    public init(id: UUID, parent: UUID?, author: String, authorName: String? = nil, body: String, date: Date) {
        self.id = id
        self.parent = parent
        self.author = author
        self.authorName = authorName
        self.body = body
        self.date = date
    }
}

/// Someone's profile as Social shows it. It's the one public profile (owner, 2026-11-17).
public struct SocialProfile: Hashable, Sendable {
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let photoKey: String?
    public var posts: Int
    public var followers: Int
    public var following: Int
    public var iFollow: Bool
    public var followsMe: Bool

    public init(
        username: String, displayName: String?, bio: String?, photoKey: String? = nil, posts: Int = 0,
        followers: Int = 0, following: Int = 0, iFollow: Bool = false, followsMe: Bool = false
    ) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.photoKey = photoKey
        self.posts = posts
        self.followers = followers
        self.following = following
        self.iFollow = iFollow
        self.followsMe = followsMe
    }

    public var name: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return username }
        return displayName
    }

    /// Following each other, so they can read your Friends posts.
    public var isFriend: Bool { iFollow && followsMe }
}

/// @username handles. The handle is the Totality username, the same rule the server checks.
public enum Handle {
    public static func isValid(_ handle: String) -> Bool {
        handle.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil
    }

    /// "@maya.cooks" or "Maya" typed in a search box, as a handle to look up, or nil.
    public static func parse(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("@") { text.removeFirst() }
        return isValid(text) ? text : nil
    }

    public static func display(_ handle: String) -> String { "@" + handle }
}

/// Tags typed as #words in a post, the way the server stores them: lower case, at most ten, no repeats.
public enum PostTags {
    public static let limit = 10

    public static func find(in text: String) -> [String] {
        var tags: [String] = []
        let pattern = try! NSRegularExpression(pattern: "(?:^|[^\\w#])#([A-Za-z0-9_]{1,30})(?![\\w])")
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let tag = text[r].lowercased()
            if tag.allSatisfy(\.isNumber) { continue }
            if !tags.contains(tag) { tags.append(tag) }
            if tags.count == limit { break }
        }
        return tags
    }
}

/// What a post may hold, matching the server's checks so a refusal is caught before sending.
public enum PostLimits {
    public static let title = 120
    public static let body = 5000
    public static let comment = 1000

    public static func problem(title: String, body: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && body.isEmpty { return "Write something first." }
        if title.count > Self.title { return "The title is \(title.count - Self.title) characters too long." }
        if body.count > Self.body { return "The post is \(body.count - Self.body) characters too long." }
        return nil
    }
}
