import Foundation
@testable import TotalitySocial

/// A stand-in for Totality's server, shared by several people. It does what the real `social_*`
/// functions do for public posts and follows, and holds nothing that isn't public.
final class FakeSocialWorld: @unchecked Sendable {
    struct Row { var post: SocialPost; var likedBy: Set<String> = []; var comments: [SocialComment] = [] }
    let lock = NSLock()
    var posts: [UUID: Row] = [:]
    var follows: Set<[String]> = []
    var people: Set<String> = []
    var seen: [String: Set<UUID>] = [:]
    var clock = Date(timeIntervalSince1970: 1_795_000_000)

    func person(_ name: String) -> FakeSocial {
        lock.withLock { _ = people.insert(name) }
        return FakeSocial(world: self, me: name)
    }

    func tick() -> Date {
        clock = clock.addingTimeInterval(60)
        return clock
    }
}

struct FakeSocial: SocialServer {
    let world: FakeSocialWorld
    let me: String

    private func view(_ row: FakeSocialWorld.Row) -> SocialPost {
        var p = row.post
        p.likes = row.likedBy.count
        p.liked = row.likedBy.contains(me)
        p.comments = row.comments.count
        return p
    }

    func me() async throws -> String { me }

    func forYou(tag: String?) async throws -> [SocialPost] {
        world.lock.withLock {
            world.posts.values.filter { $0.post.author != me && !(world.seen[me]?.contains($0.post.id) ?? false) && (tag == nil || $0.post.tags.contains(tag!)) }
                .map { var p = view($0); p.reason = "New on Totality."; return p }.sorted { $0.date > $1.date }
        }
    }

    func following(before: Date?) async throws -> [SocialPost] {
        world.lock.withLock {
            world.posts.values.filter { $0.post.author == me || world.follows.contains([me, $0.post.author]) }.map(view).sorted { $0.date > $1.date }
        }
    }

    func posts(by username: String, before: Date?) async throws -> [SocialPost] {
        world.lock.withLock { world.posts.values.filter { $0.post.author == username }.map(view) }
    }

    func post(_ id: UUID) async throws -> SocialPost? { world.lock.withLock { world.posts[id].map(view) } }

    func publish(title: String?, body: String, tags: [String]) async throws -> UUID {
        world.lock.withLock {
            let id = UUID()
            world.posts[id] = .init(post: SocialPost(id: id, author: me, audience: .everyone, title: title, body: body, tags: tags, date: world.tick()))
            return id
        }
    }

    func delete(_ id: UUID) async throws {
        world.lock.withLock { if world.posts[id]?.post.author == me { world.posts[id] = nil } }
    }

    func setLiked(_ liked: Bool, post: UUID) async throws {
        world.lock.withLock {
            if liked { world.posts[post]?.likedBy.insert(me) } else { world.posts[post]?.likedBy.remove(me) }
        }
    }

    func comments(on post: UUID) async throws -> [SocialComment] { world.lock.withLock { world.posts[post]?.comments ?? [] } }

    func comment(_ body: String, on post: UUID, replyingTo parent: UUID?) async throws {
        world.lock.withLock {
            world.posts[post]?.comments.append(SocialComment(id: UUID(), parent: parent, author: me, body: body, date: world.tick()))
        }
    }

    func profile(_ username: String) async throws -> SocialProfile? {
        world.lock.withLock {
            guard world.people.contains(username) else { return nil }
            return SocialProfile(
                username: username, displayName: nil, bio: nil,
                posts: world.posts.values.filter { $0.post.author == username }.count,
                followers: world.follows.filter { $0[1] == username }.count,
                following: world.follows.filter { $0[0] == username }.count,
                iFollow: world.follows.contains([me, username]), followsMe: world.follows.contains([username, me])
            )
        }
    }

    func setFollowing(_ follow: Bool, _ username: String) async throws {
        try world.lock.withLock {
            guard world.people.contains(username) else { throw SocialError.refused("That person isn't on Totality.") }
            if follow { world.follows.insert([me, username]) } else { world.follows.remove([me, username]) }
        }
    }

    func friends() async throws -> [String] {
        world.lock.withLock { world.follows.filter { $0[0] == me && world.follows.contains([$0[1], me]) }.map { $0[1] }.sorted() }
    }

    func followers(of username: String) async throws -> [String] { world.lock.withLock { world.follows.filter { $0[1] == username }.map { $0[0] }.sorted() } }
    func followed(by username: String) async throws -> [String] { world.lock.withLock { world.follows.filter { $0[0] == username }.map { $0[1] }.sorted() } }

    func markSeen(_ posts: [UUID], notInterested: Bool) async throws {
        world.lock.withLock { world.seen[me, default: []].formUnion(posts) }
    }

    func topTags() async throws -> [String] { [] }

    func searchPeople(_ query: String) async throws -> [SocialProfile] {
        world.lock.withLock { world.people.filter { $0.contains(query.lowercased()) }.sorted().map { SocialProfile(username: $0, displayName: nil, bio: nil) } }
    }
}
