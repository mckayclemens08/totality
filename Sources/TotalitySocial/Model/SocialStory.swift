import Foundation

/// A story: a photo, a video or text that vanishes after 24 hours (issue 149, owner's answer 3). A public
/// story is a row on Totality's server, readable to anyone who may see the author's posts. A Friends or
/// Close-friends story is a post in the author's end-to-end encrypted room, like their posts, and its file
/// is sealed on the phone. Every story's file sits on the server's story shelf, which deletes it after a day.
public struct SocialStory: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case photo, video, text
        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .photo: "Photo"
            case .video: "Video"
            case .text: "Text"
            }
        }
    }

    public let id: UUID
    public let author: String
    public var authorName: String?
    public let audience: Audience
    public let kind: Kind
    /// A text story's words, or a caption.
    public var text: String
    public var background: StoryBackground?
    /// A photo story's photo, or a video story's video and its cover. A text story has none.
    public var media: [PostMedia]
    /// When the server got it, never the time the author's phone claimed.
    public let date: Date
    /// The encrypted room it lives in, for one that isn't public.
    public let room: String?
    /// Whether this person has opened it.
    public var viewed = false

    public init(id: UUID, author: String, authorName: String? = nil, audience: Audience, kind: Kind, text: String = "",
                background: StoryBackground? = nil, media: [PostMedia] = [], date: Date, room: String? = nil, viewed: Bool = false) {
        self.id = id
        self.author = author
        self.authorName = authorName
        self.audience = audience
        self.kind = kind
        self.text = text
        self.background = background
        self.media = media
        self.date = date
        self.room = room
        self.viewed = viewed
    }

    public static let lifetime: TimeInterval = 24 * 60 * 60

    public var expires: Date { date.addingTimeInterval(Self.lifetime) }
    public func isLive(at now: Date = Date()) -> Bool { now < expires && date <= now.addingTimeInterval(5 * 60) }

    public var photo: PostMedia? { media.first { $0.kind == .photo } }
    public var video: PostMedia? { media.first { $0.kind == .video } }

    public var displayName: String {
        guard let authorName, !authorName.trimmingCharacters(in: .whitespaces).isEmpty else { return author }
        return authorName
    }

    /// How long the viewer shows it: five seconds for a photo or text, a video for its own length.
    public var showFor: TimeInterval {
        if kind == .video, let length = video?.duration, length > 0 { return min(length, MediaLimits.videoSeconds) }
        return 5
    }
}

/// A text story's colour. Each is a token from a theme in `Tokens.swift`; the view looks it up, so the
/// story keeps to the design.
public enum StoryBackground: String, Codable, Sendable, CaseIterable, Identifiable {
    case accent, blush, sage, lilac, slate
    public var id: String { rawValue }
}

/// What a story may hold, matching `private.social_story_media_valid` and the server's limits.
public enum StoryLimits {
    public static let text = 300

    /// Nil when this story is fine: a photo story holds one photo, a video story one video and its cover,
    /// a text story words and no file. Every file sits on the story shelf, sealed exactly when the story
    /// is encrypted.
    public static func problem(kind: SocialStory.Kind, text: String, media: [PostMedia], encrypted: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Self.text { return "A story's words are \(trimmed.count - Self.text) characters too long." }
        switch kind {
        case .text:
            if trimmed.isEmpty { return "Write something first." }
            if !media.isEmpty { return "A text story holds words only." }
        case .photo:
            if media.count != 1 || media[0].kind != .photo { return "A photo story holds one photo." }
        case .video:
            if media.count != 2 || media.filter({ $0.kind == .video }).count != 1 || media.filter({ $0.kind == .photo }).count != 1 {
                return "A video story holds one video and its cover."
            }
        }
        if media.contains(where: { $0.store != .stories }) { return "That file isn't on the story shelf." }
        return MediaLimits.items(media, encrypted: encrypted)
    }
}

/// One person's stories, as the row at the top of Following shows them: oldest first, as they play.
public struct StoryRing: Identifiable, Hashable, Sendable {
    public let author: String
    public let name: String
    public let stories: [SocialStory]
    public var id: String { author }
    /// Every one of them opened, so the ring goes quiet.
    public var allViewed: Bool { stories.allSatisfy(\.viewed) }
    /// The first one not yet opened, where the viewer starts.
    public var firstUnviewed: Int { stories.firstIndex { !$0.viewed } ?? 0 }

    /// Rings for everyone with a live story: yours first, then anyone with something new, newest first,
    /// then those you've seen.
    public static func rings(_ stories: [SocialStory], me: String?, now: Date = Date()) -> [StoryRing] {
        let live = stories.filter { $0.isLive(at: now) }
        let byAuthor = Dictionary(grouping: live, by: \.author)
        let rings = byAuthor.map { author, list in
            let sorted = list.sorted { $0.date < $1.date }
            return StoryRing(author: author, name: sorted.last?.displayName ?? author, stories: sorted)
        }
        return rings.sorted { a, b in
            if a.author == me { return b.author != me }
            if b.author == me { return false }
            if a.allViewed != b.allViewed { return !a.allViewed }
            return (a.stories.last?.date ?? .distantPast) > (b.stories.last?.date ?? .distantPast)
        }
    }
}
