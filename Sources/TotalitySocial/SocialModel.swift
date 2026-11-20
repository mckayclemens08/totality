import Foundation
import Observation
import TotalityCore

/// Social on this device: the two feeds, profiles, and what the person does. Public things go to
/// `SocialServer`; Friends and Close-friends things go to `PrivatePosts`, end-to-end encrypted. Posting,
/// deleting and unfollowing happen only from the person's own press on a button (non-negotiable 6).
@MainActor
@Observable
public final class SocialModel {
    public enum Phase: Equatable {
        case loading
        case ready
        /// Showing what was loaded before, with a note.
        case offline
        case failed(String)
        case unavailable(String)
    }

    public enum Feed: String, CaseIterable, Identifiable {
        case forYou, following
        public var id: String { rawValue }
        public var name: String { self == .forYou ? "For You" : "Following" }
    }

    public private(set) var phase: Phase = .loading
    public var feed: Feed = .forYou
    public private(set) var forYou: [SocialPost] = []
    public private(set) var following: [SocialPost] = []
    public private(set) var tags: [String] = []
    public var tag: String? {
        didSet { if tag != oldValue { Task { await loadForYou() } } }
    }
    public private(set) var me: String?
    /// A short note after something didn't go through, shown over the screen.
    public var notice: String?
    /// Whether Friends and Close-friends posts can be read and made right now, and why not.
    public var privateReason: String? {
        guard let privatePosts else { return "Friends and Close-friends posts need Messages, which isn't on this device." }
        return privatePosts.unavailableReason
    }
    public private(set) var closeFriends: Set<String> = []
    public private(set) var friends: Set<String> = []
    /// Who you follow, for the Following feed and for which rooms' invites to accept.
    public private(set) var followingSet: Set<String> = []
    public var requestedProfile: String?
    /// A post asked for from outside Social, such as a task's link back to where it came from.
    public var requestedPost: UUID?

    // Connections to the other modules (issue 149 §7), set by the app through the registry, so Social
    // imports none of them.
    /// Turns a post into a task.
    public var taskMaker: (any TaskMaker)?
    /// Keeps a copy of a post in the Reader, sealed there like any note.
    public var receiver: (any ContentReceiver)?
    /// Opens your chat with someone in Messages.
    public var onMessage: (@MainActor (String) -> Void)?
    /// Your own Social settings, once loaded.
    public private(set) var settings = SocialSettings()
    /// People waiting for you to approve their follow, while your account is private.
    public private(set) var followRequests: [String] = []
    /// Your saved public posts, newest first.
    public private(set) var saved: [SocialPost] = []

    let server: any SocialServer
    let privatePosts: PrivatePosts?
    let profiles: (any ProfileDirectory)?
    public private(set) var photos: [String: Data] = [:]
    private var privateFeed: [SocialPost] = []
    /// What For You has put on screen and hasn't told the server about yet.
    private var shown: Set<UUID> = []

    public init(server: any SocialServer, privateRooms: (any SharedRooms)? = nil, profiles: (any ProfileDirectory)? = nil) {
        self.server = server
        privatePosts = privateRooms.map(PrivatePosts.init)
        self.profiles = profiles
    }

    // MARK: Loading

    public func load() async {
        if forYou.isEmpty && following.isEmpty { phase = .loading }
        do {
            let me = try await server.me()
            // Someone else signed in since the last load: nothing of the last account's may stay on screen.
            if let old = self.me, old != me { forgetAccount() }
            self.me = me
            followingSet = Set(try await server.followed(by: me))
            tags = (try? await server.topTags()) ?? tags
            settings = (try? await server.settings()) ?? settings
            if settings.privateAccount { followRequests = (try? await server.followRequests()) ?? followRequests }
            await loadForYou()
            try await loadFollowing()
            phase = .ready
        } catch let error as SocialError {
            switch error {
            case .offline: phase = forYou.isEmpty && following.isEmpty ? .failed(error.message) : .offline
            case .signedOut:
                forgetAccount()
                phase = .unavailable(error.message)
            default: phase = .failed(error.message)
            }
        } catch {
            phase = .failed("Social didn't open. Pull down to try again.")
        }
        await loadPhotos()
    }

    /// Drops everything that was the signed-in account's: its feeds, its private posts, its lists of
    /// friends and follows, its settings and what For You has shown it.
    func forgetAccount() {
        me = nil
        forYou = []
        following = []
        privateFeed = []
        shown = []
        friends = []
        closeFriends = []
        followingSet = []
        followRequests = []
        saved = []
        settings = SocialSettings()
        photos = [:]
        requestedProfile = nil
        requestedPost = nil
        notice = nil
    }

    func loadForYou() async {
        do {
            forYou = try await server.forYou(tag: tag)
        } catch {
            if case .ready = phase { notice = (error as? SocialError)?.message }
        }
    }

    func loadFollowing() async throws {
        let publicPosts = try await server.following(before: nil)
        do {
            try await loadPrivate()
        } catch {
            notice = "Friends posts didn't load: \((error as? SharedRoomError)?.message ?? "try again")."
        }
        following = (publicPosts + privateFeed).sorted { $0.date > $1.date }
    }

    /// Reads the encrypted rooms this person is in: their own, and those of people they follow who let
    /// them in. Nothing here is fetched beyond that membership. Does nothing when Messages can't connect.
    private func loadPrivate() async throws {
        guard let privatePosts, privatePosts.unavailableReason == nil, let me else { return }
        let timelines = try await privatePosts.refresh(following: followingSet)
        privateFeed = timelines.flatMap(\.posts)
        friends = Set(try await server.friends())
        closeFriends = (try? await privatePosts.members(.closeFriends)) ?? closeFriends
        // Your Friends room follows who your friends are now. Anyone no longer one stops getting new posts.
        if timelines.contains(where: { $0.owner == me && $0.audience == .friends }) {
            try? await privatePosts.setMembers(friends, of: .friends)
        }
    }

    public func refresh() async { await load() }

    private func loadPhotos() async {
        guard let profiles else { return }
        let people = Set((forYou + following).map(\.author) + [me].compactMap { $0 })
        if let found = try? await profiles.profiles(of: Array(people), photos: [:]) {
            for (name, profile) in found { if let photo = profile.photo { photos[name] = photo } }
        }
    }

    public var posts: [SocialPost] { feed == .forYou ? forYou : following }

    /// The home tile: the newest from people you follow, else what For You has. Nil until Social has
    /// loaded, so the tile never claims it's empty while it's loading.
    public var glance: ModuleGlance? {
        guard phase == .ready || phase == .offline else { return nil }
        let source = following.filter { $0.author != me }.isEmpty ? forYou : following.filter { $0.author != me }
        guard !source.isEmpty else { return ModuleGlance(lines: ["Nothing new yet"], isQuiet: true) }
        return ModuleGlance(lines: source.prefix(4).map { "\(Handle.display($0.author)): \($0.headline)" })
    }

    /// For You never shows a post twice: what's been on screen is told to the server in batches.
    public func didShow(_ post: SocialPost) {
        guard post.audience == .everyone, feed == .forYou else { return }
        shown.insert(post.id)
    }

    public func flushShown() async {
        let batch = Array(shown)
        shown = []
        try? await server.markSeen(batch, notInterested: false)
    }

    public func notInterested(_ post: SocialPost) async {
        forYou.removeAll { $0.id == post.id }
        do { try await server.markSeen([post.id], notInterested: true) } catch { notice = (error as? SocialError)?.message }
    }

    // MARK: Posting

    /// Posts after the person pressed Post. Public goes to the server; the rest into their encrypted room.
    public func publish(_ audience: Audience, title: String, body: String) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = PostLimits.problem(title: cleanTitle, body: cleanBody) {
            notice = problem
            return false
        }
        let tags = PostTags.find(in: cleanTitle + " " + cleanBody)
        do {
            switch audience {
            case .everyone:
                _ = try await server.publish(title: cleanTitle.isEmpty ? nil : cleanTitle, body: cleanBody, tags: tags)
            case .friends, .closeFriends:
                guard let privatePosts, privateReason == nil else { throw SocialError.failed(privateReason ?? "") }
                if audience == .friends { try await privatePosts.setMembers(Set(try await server.friends()), of: .friends) }
                _ = try await privatePosts.publish(audience, title: cleanTitle.isEmpty ? nil : cleanTitle, body: cleanBody, tags: tags)
            }
            try? await loadFollowing()
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    public func delete(_ post: SocialPost) async {
        do {
            if post.audience == .everyone { try await server.delete(post.id) } else { try await privatePosts?.delete(post) }
            forYou.removeAll { $0.id == post.id }
            following.removeAll { $0.id == post.id }
        } catch {
            notice = Self.message(error)
        }
    }

    // MARK: Likes and comments

    public func toggleLike(_ post: SocialPost) async {
        let liked = !post.liked
        update(post.id) { $0.liked = liked; $0.likes += liked ? 1 : -1 }
        do {
            if post.audience == .everyone { try await server.setLiked(liked, post: post.id) } else { try await privatePosts?.setLiked(liked, post) }
        } catch {
            update(post.id) { $0.liked = !liked; $0.likes += liked ? -1 : 1 }
            notice = Self.message(error)
        }
    }

    public func comments(on post: SocialPost) async throws -> [SocialComment] {
        if post.audience == .everyone { return try await server.comments(on: post.id) }
        return privatePosts?.comments(on: post) ?? []
    }

    public func comment(_ text: String, on post: SocialPost, replyingTo parent: UUID?) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= PostLimits.comment else {
            notice = body.isEmpty ? "Write a comment first." : "That comment is too long."
            return false
        }
        do {
            if post.audience == .everyone {
                try await server.comment(body, on: post.id, replyingTo: parent)
            } else {
                try await privatePosts?.comment(body, on: post, replyingTo: parent)
                try? await loadFollowing()
            }
            update(post.id) { $0.comments += 1 }
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    private func update(_ id: UUID, _ change: (inout SocialPost) -> Void) {
        if let i = forYou.firstIndex(where: { $0.id == id }) { change(&forYou[i]) }
        if let i = following.firstIndex(where: { $0.id == id }) { change(&following[i]) }
        if let i = saved.firstIndex(where: { $0.id == id }) { change(&saved[i]) }
        if var p = opened[id] { change(&p); opened[id] = p }
    }

    public func post(_ id: UUID) -> SocialPost? {
        forYou.first { $0.id == id } ?? following.first { $0.id == id } ?? saved.first { $0.id == id } ?? opened[id]
    }

    /// Posts opened from a profile, which aren't in either feed.
    private var opened: [UUID: SocialPost] = [:]

    /// A public post that isn't in any list here, such as one a task links to.
    public func fetchPost(_ id: UUID) async {
        guard post(id) == nil, let found = try? await server.post(id) else { return }
        opened[id] = found
    }

    public func remember(_ posts: [SocialPost]) {
        for post in posts { opened[post.id] = post }
    }

    // MARK: People

    public func profile(_ username: String) async throws -> SocialProfile {
        guard let profile = try await server.profile(username) else { throw SocialError.noSuchPerson(username) }
        if photos[username] == nil, let found = try? await profiles?.profile(of: username), let photo = found.photo {
            photos[username] = photo
        }
        return profile
    }

    /// A profile's posts, newest first, one page at a time: the public ones from Totality's server and the
    /// Friends and Close-friends ones from rooms this person is already in. On your own profile that's all
    /// of yours. On anyone else's it's only what their rooms let you read, so a post you aren't let in on
    /// never shows, not even as a gap. The first page reads the rooms again, so it isn't left to whatever
    /// the feed last managed to read.
    public func posts(by username: String, before: Date? = nil) async throws -> [SocialPost] {
        if before == nil {
            do { try await loadPrivate() } catch {
                notice = "Friends posts didn't load: \((error as? SharedRoomError)?.message ?? "try again")."
            }
        }
        let publicPosts = try await server.posts(by: username, before: before)
        var privateOnes = decrypted(by: username).filter { post in before.map { post.date < $0 } ?? true }
        // A full public page stops at its oldest post; private ones older than that wait for the next page,
        // so the two stay in date order across pages and none shows twice.
        if publicPosts.count >= SocialPage.size, let oldest = publicPosts.map(\.date).min() {
            privateOnes = privateOnes.filter { $0.date >= oldest }
        }
        return (publicPosts + privateOnes).sorted { $0.date > $1.date }
    }

    /// Whether a page of a profile's posts could be followed by another.
    public func hasMore(after page: [SocialPost]) -> Bool {
        page.filter { $0.audience == .everyone }.count >= SocialPage.size
    }

    /// The count on a profile. Yours counts everything you've posted, whoever it's for. Anyone else's is
    /// Totality's public count and nothing more, so it never hints at Friends or Close-friends posts.
    public func postCount(_ profile: SocialProfile) -> Int {
        guard let me, Self.same(profile.username, me) else { return profile.posts }
        return profile.posts + decrypted(by: me).count
    }

    /// Decrypted posts written by this person. The author is the room's owner, checked as the room was read.
    private func decrypted(by username: String) -> [SocialPost] {
        privateFeed.filter { Self.same($0.author, username) }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    public func setFollowing(_ follow: Bool, _ username: String) async -> Bool {
        do {
            try await server.setFollowing(follow, username)
            if follow { followingSet.insert(username) } else { followingSet.remove(username) }
            friends = Set((try? await server.friends()) ?? Array(friends))
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    public func followers(of username: String) async -> [String] { (try? await server.followers(of: username)) ?? [] }
    public func followed(by username: String) async -> [String] { (try? await server.followed(by: username)) ?? [] }

    public func search(_ query: String) async -> [SocialProfile] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 1 else { return [] }
        return (try? await server.searchPeople(query)) ?? []
    }

    /// Close friends are chosen from the people you follow. They're the members of your Close-friends room.
    public func setCloseFriends(_ people: Set<String>) async -> Bool {
        guard let privatePosts, privateReason == nil else {
            notice = privateReason
            return false
        }
        do {
            try await privatePosts.setMembers(people, of: .closeFriends)
            closeFriends = people
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    // MARK: Safety

    public func save(_ new: SocialSettings) async -> Bool {
        do {
            try await server.save(new)
            settings = new
            followRequests = new.privateAccount ? ((try? await server.followRequests()) ?? []) : []
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    public func answerRequest(_ username: String, approve: Bool) async {
        do {
            if approve { try await server.approveFollower(username) } else { try await server.removeFollower(username) }
            followRequests.removeAll { $0 == username }
        } catch {
            notice = Self.message(error)
        }
    }

    /// Stops someone following you. They aren't told; they just stop seeing a private account's posts.
    /// They also leave your encrypted Friends room and your Close friends straight away, so your next
    /// Friends or Close-friends post doesn't reach them.
    public func removeFollower(_ username: String) async -> Bool {
        do { try await server.removeFollower(username) } catch { notice = Self.message(error); return false }
        if let privatePosts, privateReason == nil {
            friends = Set((try? await server.friends()) ?? Array(friends.subtracting([username])))
            if closeFriends.contains(username) { _ = await setCloseFriends(closeFriends.subtracting([username])) }
            if (try? await privatePosts.members(.friends))?.contains(username) == true {
                try? await privatePosts.setMembers(friends, of: .friends)
            }
        }
        return true
    }

    /// Muting hides their posts from your feeds. They aren't told.
    public func setMuted(_ muted: Bool, _ profile: SocialProfile) async -> Bool {
        guard let id = profile.id else { return false }
        do {
            try await server.setMuted(muted, id)
            if muted {
                forYou.removeAll { $0.author == profile.username }
                following.removeAll { $0.author == profile.username }
            }
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    /// Blocking is Totality-wide: neither of you sees the other's posts, likes, comments or follows, and it
    /// covers Messages too. They aren't told. Blocking also takes them out of your encrypted rooms.
    public func setBlocked(_ blocked: Bool, _ profile: SocialProfile) async -> Bool {
        guard let id = profile.id else { return false }
        do {
            try await server.setBlocked(blocked, id)
            if blocked {
                followingSet.remove(profile.username)
                forYou.removeAll { $0.author == profile.username }
                following.removeAll { $0.author == profile.username }
                if let privatePosts, privateReason == nil {
                    if closeFriends.contains(profile.username) { _ = await setCloseFriends(closeFriends.subtracting([profile.username])) }
                    try? await privatePosts.setMembers(Set(try await server.friends()), of: .friends)
                }
            }
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    /// Sends a report to Totality's moderator. It names the person, and the post or comment when there is one.
    /// Friends and Close-friends posts are end-to-end encrypted, so the moderator gets only the person's
    /// name and the reason, never the post.
    public func report(_ username: String, post: SocialPost?, comment: SocialComment?, reason: ReportReason) async -> Bool {
        let publicPost = post?.audience == .everyone ? post?.id : nil
        do {
            try await server.report(username, post: publicPost, comment: publicPost == nil ? nil : comment?.id, reason: reason.rawValue)
            notice = "Thanks. Your report went to Totality's moderator."
            return true
        } catch {
            notice = Self.message(error)
            return false
        }
    }

    // MARK: Other modules

    /// What Add to Tasks starts from: the post's headline, and a link back to it.
    public func taskDraft(_ post: SocialPost) -> TaskDraft {
        let title = String(post.headline.prefix(120))
        return TaskDraft(title: title, source: TaskSource(
            module: .social, itemID: post.id.uuidString, title: title, detail: Handle.display(post.author),
            quote: String(post.body.prefix(280))
        ))
    }

    /// A copy of the post as a Reader note. It's yours from then on: sealed in the Reader, and it stays
    /// even if the author deletes the post.
    public func saveToReader(_ post: SocialPost) async {
        guard let receiver else {
            notice = "The Reader isn't open on this phone yet."
            return
        }
        let title = post.title ?? String(post.body.prefix(60))
        let tags = post.tags.isEmpty ? "" : "\n\n" + post.tags.map { "#" + $0 }.joined(separator: " ")
        let body = post.body + tags + "\n\n— \(post.displayName) (\(Handle.display(post.author))), \(post.date.formatted(date: .abbreviated, time: .shortened)), \(post.audience.name) on Social"
        do {
            _ = try await receiver.receive(noteTitled: title, body: body)
            notice = "Saved to the Reader."
        } catch {
            notice = "That didn't reach the Reader. Try again."
        }
    }

    // MARK: Saves

    public func toggleSaved(_ post: SocialPost) async {
        guard post.audience == .everyone else {
            notice = "Friends and Close-friends posts can't be saved yet."
            return
        }
        let on = !post.saved
        update(post.id) { $0.saved = on }
        do {
            try await server.setSaved(on, post: post.id)
            if on { if !saved.contains(where: { $0.id == post.id }) { var p = post; p.saved = true; saved.insert(p, at: 0) } } else { saved.removeAll { $0.id == post.id } }
        } catch {
            update(post.id) { $0.saved = !on }
            notice = Self.message(error)
        }
    }

    public func loadSaved() async {
        do { saved = try await server.saved() } catch { notice = Self.message(error) }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? SocialError { return error.message }
        if let error = error as? SharedRoomError { return error.message }
        return "That didn't go through. Try again."
    }
}
