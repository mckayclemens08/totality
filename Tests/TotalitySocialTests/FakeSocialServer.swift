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
    var settings: [String: SocialSettings] = [:]
    var saves: [String: Set<UUID>] = [:]
    /// Who reposted what, and when.
    var reposts: [String: [UUID: Date]] = [:]
    var mutes: [String: Set<UUID>] = [:]
    var blocks: [String: Set<UUID>] = [:]
    var reports: [(from: String, about: String, post: UUID?, comment: UUID?, reason: String)] = []
    var requests: [String: Set<String>] = [:]
    var ids: [String: UUID] = [:]
    /// Display names, for lists that show them.
    var names: [String: String] = [:]
    /// Totality's media server: path to bytes as stored.
    var files: [String: Data] = [:]
    /// The old Supabase bucket, which posts made before the move still read from.
    var oldFiles: [String: Data] = [:]
    /// Set to make removals fail, as if the server were unreachable.
    var removalsFail = false
    /// Set to make `stories()` fail, or omit `me`'s newest own story on refetch (simulating replica/sync lag).
    var storiesFail = false
    var omitLatestOwnStory = false
    /// Public stories, and who opened any story (public or encrypted) by its ID.
    var stories: [UUID: SocialStory] = [:]
    var storyViews: [UUID: Set<String>] = [:]
    var storyAuthors: [UUID: String] = [:]
    /// The story shelf: path to bytes as stored.
    var storyFiles: [String: Data] = [:]

    func id(_ name: String) -> UUID {
        if let id = ids[name] { return id }
        let id = UUID()
        ids[name] = id
        return id
    }
    var clock = Date(timeIntervalSince1970: 1_795_000_000)

    func person(_ name: String) -> FakeSocial {
        lock.withLock { _ = people.insert(name) }
        return FakeSocial(world: self, signedIn: SignedIn(name))
    }

    func tick() -> Date {
        clock = clock.addingTimeInterval(60)
        return clock
    }
}

/// Who is signed in on a fake phone, which can change, as signing out and in again does.
final class SignedIn: @unchecked Sendable {
    var name: String
    init(_ name: String) { self.name = name }
}

struct FakeSocial: SocialServer {
    let world: FakeSocialWorld
    let signedIn: SignedIn
    var me: String { signedIn.name }

    private func view(_ row: FakeSocialWorld.Row) -> SocialPost {
        var p = row.post
        p.likes = row.likedBy.count
        p.liked = row.likedBy.contains(me)
        p.comments = row.comments.count
        p.reposts = world.reposts.values.filter { $0[p.id] != nil }.count
        p.reposted = world.reposts[me]?[p.id] != nil
        return p
    }

    /// Reposts by these people, as the server's `social_reposts_feed` and `social_reposts_by` return them.
    private func repostEntries(by people: Set<String>) -> [SocialPost] {
        world.reposts.filter { people.contains($0.key) }.flatMap { person, posts in
            posts.compactMap { id, date in
                world.posts[id].map { row in
                    var entry = view(row)
                    entry.repostedBy = Reposter(handle: person, name: world.names[person], date: date)
                    return entry
                }
            }
        }
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
            let people = Set(world.people.filter { $0 == me || world.follows.contains([me, $0]) })
            let posts = world.posts.values.filter { people.contains($0.post.author) }.map(view)
            return RestSocialServer.merged(posts, repostEntries(by: people), pageSize: 30)
        }
    }

    func posts(by username: String, before: Date?) async throws -> [SocialPost] {
        world.lock.withLock {
            let posts = Array(world.posts.values.filter { $0.post.author == username && (before == nil || $0.post.date < before!) }
                .map(view).sorted { $0.date > $1.date }.prefix(SocialPage.size))
            let reposts = repostEntries(by: [username]).filter { before == nil || $0.feedDate < before! }
            return RestSocialServer.merged(posts, Array(reposts.sorted { $0.feedDate > $1.feedDate }.prefix(SocialPage.size)), pageSize: SocialPage.size)
        }
    }

    func post(_ id: UUID) async throws -> SocialPost? { world.lock.withLock { world.posts[id].map(view) } }

    func publish(title: String?, body: String, tags: [String], media: [PostMedia]) async throws -> UUID {
        // As `private.social_media_valid` does: no keys, only the author's own folder.
        let folder = world.lock.withLock { world.id(me).uuidString.lowercased() }
        guard MediaLimits.problem(media, encrypted: false) == nil, media.allSatisfy({ $0.path.hasPrefix(folder + "/") }) else {
            throw SocialError.refused("bad media")
        }
        return world.lock.withLock {
            let id = UUID()
            world.posts[id] = .init(post: SocialPost(id: id, author: me, audience: .everyone, title: title, body: body, tags: tags,
                                                     date: world.tick(), media: media))
            return id
        }
    }

    func uploadMedia(_ data: Data, contentType: String, store: PostMedia.Store) async throws -> String {
        let most = contentType == "video/mp4" || contentType == "application/octet-stream" ? MediaLimits.most(.video) : MediaLimits.most(.photo)
        guard data.count <= most else { throw SocialError.refused("That file is too big to post.") }
        return world.lock.withLock {
            let path = world.id(me).uuidString.lowercased() + "/" + UUID().uuidString.lowercased()
            if store == .stories { world.storyFiles[path] = data } else { world.files[path] = data }
            return path
        }
    }

    func media(_ item: PostMedia) async throws -> Data {
        let found = world.lock.withLock {
            switch item.store {
            case .totality: world.files[item.path]
            case .stories: world.storyFiles[item.path]
            case nil: world.oldFiles[item.path]
            }
        }
        guard let found else { throw SocialError.failed("That file isn't there any more.") }
        return found
    }

    func removeMedia(_ items: [PostMedia]) async throws {
        try world.lock.withLock {
            if world.removalsFail { throw SocialError.offline }
            let folder = world.id(me).uuidString.lowercased()
            for item in items where item.folder == folder {
                switch item.store {
                case .totality: world.files[item.path] = nil
                case .stories: world.storyFiles[item.path] = nil
                case nil: world.oldFiles[item.path] = nil
                }
            }
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
            var p = SocialProfile(
                username: username, displayName: nil, bio: nil,
                posts: world.posts.values.filter { $0.post.author == username }.count,
                followers: world.follows.filter { $0[1] == username }.count,
                following: world.follows.filter { $0[0] == username }.count,
                iFollow: world.follows.contains([me, username]), followsMe: world.follows.contains([username, me])
            )
            p.id = world.id(username)
            p.muted = world.mutes[me]?.contains(world.id(username)) ?? false
            p.privateAccount = world.settings[username]?.privateAccount ?? false
            p.requested = world.requests[username]?.contains(me) ?? false
            return p
        }
    }

    func setFollowing(_ follow: Bool, _ username: String) async throws {
        try world.lock.withLock {
            guard world.people.contains(username) else { throw SocialError.refused("That person isn't on Totality.") }
            if follow, world.settings[username]?.privateAccount == true {
                world.requests[username, default: []].insert(me)
            } else if follow {
                world.follows.insert([me, username])
            } else {
                world.follows.remove([me, username])
                world.requests[username]?.remove(me)
            }
        }
    }

    func friends() async throws -> [String] {
        world.lock.withLock { world.follows.filter { $0[0] == me && world.follows.contains([$0[1], me]) }.map { $0[1] }.sorted() }
    }

    func followers(of username: String) async throws -> [String] { world.lock.withLock { world.follows.filter { $0[1] == username }.map { $0[0] }.sorted() } }
    func followed(by username: String) async throws -> [String] { world.lock.withLock { world.follows.filter { $0[0] == username }.map { $0[1] }.sorted() } }

    /// Like `social_people`: a private account's lists are empty to anyone but it and its followers. The
    /// fake has no follow times, so it pages by username instead.
    func people(of username: String, followers: Bool, query: String?, after: PeopleCursor?, limit: Int) async throws -> [SocialPerson] {
        world.lock.withLock {
            if world.settings[username]?.privateAccount == true, me != username, !world.follows.contains([me, username]) { return [] }
            let names = world.follows.filter { followers ? $0[1] == username : $0[0] == username }.map { followers ? $0[0] : $0[1] }
            let q = query?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            return names.sorted()
                .filter { q == nil || q!.isEmpty || $0.hasPrefix(q!) }
                .filter { after == nil || $0 > after!.username }
                .prefix(limit)
                .map { name in
                    SocialPerson(username: name, displayName: world.names[name], iFollow: world.follows.contains([me, name]), followsMe: world.follows.contains([name, me]),
                                 requested: world.requests[name]?.contains(me) ?? false,
                                 muted: world.mutes[me]?.contains(world.id(name)) ?? false, accountID: world.id(name))
                }
        }
    }

    func markSeen(_ posts: [UUID], notInterested: Bool) async throws {
        world.lock.withLock { world.seen[me, default: []].formUnion(posts) }
    }

    func topTags() async throws -> [String] { [] }

    func searchPeople(_ query: String) async throws -> [SocialProfile] {
        world.lock.withLock { world.people.filter { $0.contains(query.lowercased()) }.sorted().map { SocialProfile(username: $0, displayName: nil, bio: nil) } }
    }

    func settings() async throws -> SocialSettings { world.lock.withLock { world.settings[me] ?? SocialSettings() } }
    func save(_ settings: SocialSettings) async throws { world.lock.withLock { world.settings[me] = settings } }
    func followRequests() async throws -> [String] { world.lock.withLock { (world.requests[me] ?? []).sorted() } }
    func approveFollower(_ username: String) async throws {
        world.lock.withLock {
            if world.requests[me]?.remove(username) != nil { world.follows.insert([username, me]) }
        }
    }
    func removeFollower(_ username: String) async throws {
        world.lock.withLock { world.requests[me]?.remove(username); world.follows.remove([username, me]) }
    }
    func setMuted(_ muted: Bool, _ person: UUID) async throws {
        world.lock.withLock { if muted { world.mutes[me, default: []].insert(person) } else { world.mutes[me]?.remove(person) } }
    }
    func setBlocked(_ blocked: Bool, _ person: UUID) async throws {
        world.lock.withLock {
            if blocked {
                world.blocks[me, default: []].insert(person)
                if let name = world.ids.first(where: { $0.value == person })?.key { world.follows.remove([me, name]); world.follows.remove([name, me]) }
            } else { world.blocks[me]?.remove(person) }
        }
    }
    func report(_ username: String, post: UUID?, comment: UUID?, reason: String) async throws {
        world.lock.withLock { world.reports.append((me, username, post, comment, reason)) }
    }
    func setSaved(_ saved: Bool, post: UUID) async throws {
        world.lock.withLock { if saved { world.saves[me, default: []].insert(post) } else { world.saves[me]?.remove(post) } }
    }
    /// As `social_reposts` does: someone else's public post, from an account that isn't private, once.
    func setReposted(_ reposted: Bool, post: UUID) async throws {
        try world.lock.withLock {
            if reposted {
                guard let row = world.posts[post], row.post.author != me, !(world.settings[row.post.author]?.privateAccount ?? false) else {
                    throw SocialError.refused("That post isn't available any more.")
                }
                if world.reposts[me]?[post] == nil { world.reposts[me, default: [:]][post] = world.tick() }
            } else {
                world.reposts[me]?[post] = nil
            }
        }
    }

    func saved() async throws -> [SocialPost] {
        world.lock.withLock { (world.saves[me] ?? []).compactMap { world.posts[$0].map(view) }.map { var p = $0; p.saved = true; return p } }
    }

    // As `social_stories` and friends do: public only, the author's own folder on the story shelf, no keys.
    func stories() async throws -> [SocialStory] {
        try world.lock.withLock {
            if world.storiesFail { throw SocialError.refused("Stories temporarily unavailable.") }
            let followed = Set(world.follows.filter { $0[0] == me }.map { $0[1] })
            let latestOwn = world.omitLatestOwnStory
                ? world.stories.values.filter { $0.author == me }.max(by: { $0.date < $1.date })?.id
                : nil
            return world.stories.values.filter { story in
                if story.id == latestOwn { return false }
                return story.author == me || followed.contains(story.author)
            }
            .map { var s = $0; s.viewed = world.storyViews[s.id]?.contains(me) ?? false; return s }
            .sorted { $0.date < $1.date }
        }
    }

    func postStory(kind: SocialStory.Kind, text: String, background: StoryBackground?, media: [PostMedia]) async throws -> UUID {
        let folder = world.lock.withLock { world.id(me).uuidString.lowercased() }
        guard StoryLimits.problem(kind: kind, text: text, media: media, encrypted: false) == nil,
              media.allSatisfy({ $0.path.hasPrefix(folder + "/") }) else { throw SocialError.refused("bad story") }
        return world.lock.withLock {
            let id = UUID()
            world.stories[id] = SocialStory(id: id, author: me, audience: .everyone, kind: kind, text: text, background: background,
                                            media: media, date: Date())
            return id
        }
    }

    func deleteStory(_ id: UUID) async throws {
        world.lock.withLock { if world.stories[id]?.author == me { world.stories[id] = nil } }
    }

    func viewStory(_ id: UUID, author: String) async throws {
        world.lock.withLock {
            guard author != me else { return }
            world.storyViews[id, default: []].insert(me)
            world.storyAuthors[id] = author
        }
    }

    func storyViewers(_ id: UUID) async throws -> [String] {
        world.lock.withLock {
            guard world.storyAuthors[id] == me || world.stories[id]?.author == me else { return [] }
            return (world.storyViews[id] ?? []).sorted()
        }
    }
}
