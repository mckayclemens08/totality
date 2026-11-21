import Foundation
import TotalityCore

/// What goes into an author's encrypted room, as the body of one room post. The room's sender is the
/// author of each message: a name written inside a body is never trusted.
public enum RoomMessage: Equatable, Sendable {
    /// The room's first post, from its owner: which audience it's for. It's inside the encryption, so the
    /// server can't tell a Friends room from a Close-friends one.
    case timeline(Audience)
    case post(id: UUID, title: String?, body: String, tags: [String], date: Date, media: [PostMedia] = [])
    case delete(post: UUID)
    case like(post: UUID, on: Bool)
    case comment(id: UUID, post: UUID, parent: UUID?, body: String)
    case uncomment(id: UUID)

    private struct Wire: Codable {
        var v = 1
        var type: String
        var audience: String?
        var id: UUID?
        var post: UUID?
        var parent: UUID?
        var title: String?
        var body: String?
        var tags: [String]?
        var date: Double?
        var on: Bool?
        /// Each item's key rides here, inside the encryption.
        var media: [PostMedia]?
    }

    public var encoded: String {
        var w: Wire
        switch self {
        case .timeline(let audience): w = Wire(type: "timeline", audience: audience.rawValue)
        case .post(let id, let title, let body, let tags, let date, let media):
            w = Wire(type: "post", id: id, title: title, body: body, tags: tags, date: date.timeIntervalSince1970, media: media.isEmpty ? nil : media)
        case .delete(let post): w = Wire(type: "delete", post: post)
        case .like(let post, let on): w = Wire(type: "like", post: post, on: on)
        case .comment(let id, let post, let parent, let body): w = Wire(type: "comment", id: id, post: post, parent: parent, body: body)
        case .uncomment(let id): w = Wire(type: "uncomment", id: id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(w)) ?? Data(), as: UTF8.self)
    }

    /// Nil for anything this version doesn't understand or that breaks the limits, so a hostile member
    /// can't make a device show something the app itself couldn't post.
    public init?(_ text: String) {
        guard text.utf8.count <= 64_000, let w = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)), w.v == 1 else { return nil }
        switch w.type {
        case "timeline":
            guard let a = w.audience.flatMap(Audience.init(rawValue:)), a.isEncrypted else { return nil }
            self = .timeline(a)
        case "post":
            let media = w.media ?? []
            guard let id = w.id, let body = w.body, let date = w.date,
                  PostLimits.problem(title: w.title ?? "", body: body, hasMedia: !media.isEmpty) == nil,
                  MediaLimits.problem(media, encrypted: true) == nil else { return nil }
            let tags = (w.tags ?? []).filter { $0.range(of: "^[a-z0-9_]{1,30}$", options: .regularExpression) != nil }
            self = .post(id: id, title: (w.title?.isEmpty ?? true) ? nil : w.title, body: body, tags: Array(tags.prefix(PostTags.limit)),
                         date: Date(timeIntervalSince1970: date), media: media)
        case "delete":
            guard let post = w.post else { return nil }
            self = .delete(post: post)
        case "like":
            guard let post = w.post, let on = w.on else { return nil }
            self = .like(post: post, on: on)
        case "comment":
            guard let id = w.id, let post = w.post, let body = w.body,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= PostLimits.comment else { return nil }
            self = .comment(id: id, post: post, parent: w.parent, body: body)
        case "uncomment":
            guard let id = w.id else { return nil }
            self = .uncomment(id: id)
        default:
            return nil
        }
    }
}

/// One author's encrypted room, folded from its history on this device.
public struct RoomTimeline: Equatable, Sendable {
    public let room: String
    /// The room's owner, the only one whose posts count.
    public let owner: String?
    public let audience: Audience?
    public let posts: [SocialPost]
    public let comments: [UUID: [SocialComment]]
    /// Posts this device couldn't open, such as ones sent before it joined.
    public let unreadable: Int

    /// Replays the room's history. Only the owner (power 100 at that point in the history) can set the
    /// audience, post or delete a post; anyone in the room can like and comment. A comment can be removed by
    /// whoever wrote it or by the owner. Each person's last like counts. Posts come back newest first.
    public static func build(room: String, history: SharedRoomHistory, me: String) -> RoomTimeline {
        var levels: [String: Int] = [:]
        var owner: String?
        var audience: Audience?
        var posts: [UUID: SocialPost] = [:]
        var order: [UUID] = []
        var deleted: Set<UUID> = []
        var likes: [UUID: [String: Bool]] = [:]
        var comments: [UUID: SocialComment] = [:]
        var commentPost: [UUID: UUID] = [:]
        var commentOrder: [UUID] = []
        var unreadable = 0

        for event in history.events {
            switch event {
            case .roles(let new):
                levels = new
                if owner == nil { owner = new.first { $0.value >= SharedRole.owner.rawValue }?.key }
            case .unreadable:
                unreadable += 1
            case .post(_, let sender, let date, let body):
                guard let message = RoomMessage(body) else { continue }
                let isOwner = (levels[sender] ?? 0) >= SharedRole.owner.rawValue && (owner == nil || owner == sender)
                switch message {
                case .timeline(let a):
                    guard isOwner, audience == nil else { continue }
                    owner = sender
                    audience = a
                case .post(let id, let title, let body, let tags, _, let media):
                    guard isOwner, let audience, posts[id] == nil, !deleted.contains(id) else { continue }
                    // The server's time, not the one written in the post, so an author can't backdate.
                    posts[id] = SocialPost(id: id, author: sender, audience: audience, title: title, body: body, tags: tags, date: date, room: room, media: media)
                    order.append(id)
                case .delete(let id):
                    guard isOwner else { continue }
                    deleted.insert(id)
                    posts[id] = nil
                case .like(let post, let on):
                    guard posts[post] != nil else { continue }
                    likes[post, default: [:]][sender] = on
                case .comment(let id, let post, let parent, let body):
                    guard posts[post] != nil, comments[id] == nil else { continue }
                    if let parent { guard commentPost[parent] == post, comments[parent]?.parent == nil else { continue } }
                    comments[id] = SocialComment(id: id, parent: parent, author: sender, body: body, date: date)
                    commentPost[id] = post
                    commentOrder.append(id)
                case .uncomment(let id):
                    guard let c = comments[id], c.author == sender || isOwner else { continue }
                    comments[id] = nil
                    for (other, value) in comments where value.parent == id { comments[other] = nil }
                }
            }
        }

        var byPost: [UUID: [SocialComment]] = [:]
        for id in commentOrder {
            guard let c = comments[id], let post = commentPost[id], posts[post] != nil else { continue }
            byPost[post, default: []].append(c)
        }
        for (post, list) in byPost { byPost[post] = Self.threaded(list) }
        let built: [SocialPost] = order.compactMap { id in
            guard var post = posts[id] else { return nil }
            let marks = likes[id] ?? [:]
            post.likes = marks.values.filter { $0 }.count
            post.liked = marks[me] ?? false
            post.comments = byPost[id]?.count ?? 0
            return post
        }.sorted { $0.date > $1.date }
        return RoomTimeline(room: room, owner: owner, audience: audience, posts: built, comments: byPost, unreadable: unreadable)
    }

    /// Comments oldest first, each reply straight after the comment it answers.
    static func threaded(_ list: [SocialComment]) -> [SocialComment] {
        let tops = list.filter { $0.parent == nil }
        return tops.flatMap { top in [top] + list.filter { $0.parent == top.id } }
    }
}

/// Friends and Close-friends posts, over the encrypted rooms the app hands Social (`SharedRooms` with
/// `SharedRoomMarker.social`). Each author has at most one room per audience and is its owner; the people
/// who may read it are invited as viewers, who can still like and comment.
///
/// What the server sees: two rooms per author named "Totality posts", who's in each, and when each
/// encrypted post was sent. Everyone in a room can also see who else is in it, which for Close friends
/// means the people on your list can see each other.
@MainActor
public final class PrivatePosts {
    let rooms: any SharedRooms
    private(set) var timelines: [String: RoomTimeline] = [:]

    public init(rooms: any SharedRooms) {
        self.rooms = rooms
    }

    public var unavailableReason: String? { rooms.unavailableReason }

    /// Reads every room this person is in, accepting invites from people they follow first. An invite from
    /// anyone else stays unanswered: a stranger can't put posts in your feed.
    public func refresh(following: Set<String>) async throws -> [RoomTimeline] {
        for invite in try await rooms.invites() {
            guard let inviter = invite.inviter, following.contains(inviter) else { continue }
            try? await rooms.accept(invite.room)
        }
        guard let me = await rooms.ownUsername else { throw SocialError.signedOut }
        var found: [String: RoomTimeline] = [:]
        for room in try await rooms.rooms() {
            guard let history = try? await rooms.history(of: room) else { continue }
            let timeline = RoomTimeline.build(room: room, history: history, me: me)
            // A room nobody you follow owns, or one with no audience, isn't a timeline: leave it be.
            guard let owner = timeline.owner, timeline.audience != nil, owner == me || following.contains(owner) else { continue }
            found[room] = timeline
        }
        timelines = found
        return found.values.sorted { $0.room < $1.room }
    }

    /// The room you own for an audience, made the first time it's needed.
    func ownRoom(_ audience: Audience) async throws -> String {
        guard audience.isEncrypted else { throw SocialError.failed("Public posts don't go in a room.") }
        guard let me = await rooms.ownUsername else { throw SocialError.signedOut }
        if let found = timelines.values.first(where: { $0.owner == me && $0.audience == audience }) { return found.room }
        let room = try await rooms.create(inviting: [:])
        try await rooms.post(RoomMessage.timeline(audience).encoded, to: room)
        timelines[room] = RoomTimeline(room: room, owner: me, audience: audience, posts: [], comments: [:], unreadable: 0)
        return room
    }

    /// Who's in your room for an audience, invited or joined, apart from you.
    public func members(_ audience: Audience) async throws -> Set<String> {
        guard let me = await rooms.ownUsername else { throw SocialError.signedOut }
        guard let room = timelines.values.first(where: { $0.owner == me && $0.audience == audience })?.room else { return [] }
        return Set(try await rooms.history(of: room).members.map(\.username)).subtracting([me])
    }

    /// Makes your room's members exactly these people. For Friends that's your mutual follows; for Close
    /// friends, your list. Someone removed keeps what they already saw, and gets nothing new.
    public func setMembers(_ people: Set<String>, of audience: Audience) async throws {
        let room = try await ownRoom(audience)
        let current = try await members(audience)
        for person in people.subtracting(current).sorted() { try await rooms.invite(person, as: .viewer, to: room) }
        for person in current.subtracting(people).sorted() { try await rooms.remove(person, from: room) }
    }

    public func publish(_ audience: Audience, title: String?, body: String, tags: [String], media: [PostMedia] = [], date: Date = Date()) async throws -> UUID {
        let room = try await ownRoom(audience)
        let id = UUID()
        try await rooms.post(RoomMessage.post(id: id, title: title, body: body, tags: tags, date: date, media: media).encoded, to: room)
        return id
    }

    public func delete(_ post: SocialPost) async throws {
        guard let room = post.room else { return }
        try await rooms.post(RoomMessage.delete(post: post.id).encoded, to: room)
    }

    public func setLiked(_ liked: Bool, _ post: SocialPost) async throws {
        guard let room = post.room else { return }
        try await rooms.post(RoomMessage.like(post: post.id, on: liked).encoded, to: room)
    }

    public func comment(_ body: String, on post: SocialPost, replyingTo parent: UUID?) async throws {
        guard let room = post.room else { return }
        try await rooms.post(RoomMessage.comment(id: UUID(), post: post.id, parent: parent, body: body).encoded, to: room)
    }

    public func comments(on post: SocialPost) -> [SocialComment] {
        guard let room = post.room else { return [] }
        return timelines[room]?.comments[post.id] ?? []
    }
}
