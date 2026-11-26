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
    /// The author hides like counts from everyone else (their setting), so `likes` is meaningless here.
    public var likesHidden = false
    public var saved = false
    /// For You's "Why am I seeing this?" line.
    public var reason: String?
    /// The encrypted room it lives in, for one that isn't public.
    public let room: String?
    /// Its photos or audio clip, if any. A sealed item carries its key, which only an encrypted room holds.
    public var media: [PostMedia] = []

    public init(
        id: UUID, author: String, authorName: String? = nil, audience: Audience, title: String? = nil, body: String,
        tags: [String] = [], date: Date, edited: Bool = false, likes: Int = 0, comments: Int = 0, liked: Bool = false,
        reason: String? = nil, room: String? = nil, media: [PostMedia] = []
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
        self.media = media
    }

    /// A post's photos. For a video post, that's its one cover photo.
    public var photos: [PostMedia] { media.filter { $0.kind == .photo } }
    public var audio: PostMedia? { media.first { $0.kind == .audio } }
    public var video: PostMedia? { media.first { $0.kind == .video } }

    public var displayName: String {
        guard let authorName, !authorName.trimmingCharacters(in: .whitespaces).isEmpty else { return author }
        return authorName
    }

    /// A headline for the grid: the title, or the start of the text.
    public var headline: String {
        if let title, !title.isEmpty { return title }
        if body.isEmpty, audio != nil { return "Audio" }
        if body.isEmpty, video != nil { return "Video" }
        if body.isEmpty, !photos.isEmpty { return photos.count == 1 ? "Photo" : "\(photos.count) photos" }
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
    /// Their account ID, which blocking needs. Nil from search results.
    public var id: UUID?
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let photoKey: String?
    public var posts: Int
    public var followers: Int
    public var following: Int
    public var iFollow: Bool
    public var followsMe: Bool
    /// You asked to follow their private account and they haven't answered.
    public var requested = false
    public var privateAccount = false
    public var muted = false
    /// Whether their settings let you comment on their posts, or message them.
    public var canComment = true
    public var canMessage = true
    /// Their https links, as the server stored them. Checked again by `ProfileLinks.safe` before showing.
    public var links: [String] = []

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

    /// A private account you don't follow: its posts stay hidden.
    public var isClosed: Bool { privateAccount && !iFollow }

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

    /// The scheme of the links made for #tags in a post's text.
    public static let linkScheme = "totality-tag"

    /// The tags that aren't already written in the text, so a tag line never repeats what's above it.
    public static func notInText(_ tags: [String], text: String) -> [String] {
        let inText = Set(find(in: text))
        return tags.filter { !inText.contains($0) }
    }

    /// The text with each #tag made a link the app handles itself (totality-tag://tag).
    public static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let pattern = try! NSRegularExpression(pattern: "(?:^|[^\\w#])(#([A-Za-z0-9_]{1,30}))(?![\\w])")
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let whole = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { continue }
            let tag = text[name].lowercased()
            if tag.allSatisfy(\.isNumber) { continue }
            guard let a = AttributedString.Index(whole.lowerBound, within: out), let b = AttributedString.Index(whole.upperBound, within: out),
                  let url = URL(string: "\(linkScheme)://\(tag)") else { continue }
            out[a..<b].link = url
        }
        return out
    }

    /// The tag a tapped link stands for, or nil for any other link.
    public static func tag(from url: URL) -> String? {
        url.scheme == linkScheme ? url.host(percentEncoded: false)?.lowercased() : nil
    }
}

/// What a post may hold, matching the server's checks so a refusal is caught before sending.
public enum PostLimits {
    public static let title = 120
    public static let body = 5000
    public static let comment = 1000

    /// With media, the text may be empty: a photo or a clip is a post on its own.
    public static func problem(title: String, body: String, hasMedia: Bool = false) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && body.isEmpty && !hasMedia { return "Write something first." }
        if title.count > Self.title { return "The title is \(title.count - Self.title) characters too long." }
        if body.count > Self.body { return "The post is \(body.count - Self.body) characters too long." }
        return nil
    }
}

/// Who may do something: comment on your posts, or message you (issue 149 §4 and §6).
public enum Reach: String, Codable, Sendable, CaseIterable, Identifiable {
    case anyone, followers, friends
    case noOne = "no_one"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .anyone: "Anyone"
        case .followers: "Followers"
        case .friends: "Friends"
        case .noOne: "No one"
        }
    }

    /// "No one" isn't offered for messages: that would be turning Messages off.
    public static let forMessages: [Reach] = [.anyone, .followers, .friends]
}

/// Your Social settings. They're public to Totality, because others' devices and the server need them to
/// decide what's allowed, but only you can change them.
public struct SocialSettings: Equatable, Sendable {
    public var whoCanComment: Reach = .anyone
    public var whoCanMessage: Reach = .anyone
    public var privateAccount = false
    public var hideLikeCounts = false

    public init(whoCanComment: Reach = .anyone, whoCanMessage: Reach = .anyone, privateAccount: Bool = false, hideLikeCounts: Bool = false) {
        self.whoCanComment = whoCanComment
        self.whoCanMessage = whoCanMessage
        self.privateAccount = privateAccount
        self.hideLikeCounts = hideLikeCounts
    }
}

/// Why someone reported a post, a comment or a person. Reports go to Totality's moderator, who is the
/// owner for now (issue 149, 2026-11-17).
public enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam = "Spam"
    case harassment = "Harassment or bullying"
    case hate = "Hate"
    case violence = "Violence or threats"
    case nudity = "Nudity or sexual content"
    case selfHarm = "Self-harm"
    case falseInfo = "False information"
    case other = "Something else"

    public var id: String { rawValue }
}
