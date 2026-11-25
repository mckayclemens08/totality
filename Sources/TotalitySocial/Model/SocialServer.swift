import Foundation

public enum SocialError: Error, Equatable, Sendable {
    case signedOut
    case offline
    case noSuchPerson(String)
    case refused(String)
    case failed(String)

    public var message: String {
        switch self {
        case .signedOut: "Sign in to use Social."
        case .offline: "You're offline. Showing what's on this phone."
        case .noSuchPerson(let name): "There's no one called @\(name)."
        case .refused(let reason): reason
        case .failed(let reason): reason
        }
    }
}

/// Social's public side on Totality's server: public posts, follows, likes and comments (issue 149). It
/// never carries a Friends or Close-friends post: those go through `PrivatePosts`.
/// How many posts the server sends at a time.
public enum SocialPage {
    public static let size = 30
}

public protocol SocialServer: Sendable {
    func me() async throws -> String
    func forYou(tag: String?) async throws -> [SocialPost]
    func following(before: Date?) async throws -> [SocialPost]
    func posts(by username: String, before: Date?) async throws -> [SocialPost]
    func post(_ id: UUID) async throws -> SocialPost?
    func publish(title: String?, body: String, tags: [String], media: [PostMedia]) async throws -> UUID
    /// Puts one file in your folder on Totality's media server and returns its path. A file for an
    /// encrypted post is already sealed when it gets here.
    func uploadMedia(_ data: Data, contentType: String, store: PostMedia.Store) async throws -> String
    /// A file as stored, from wherever `item.store` says: readable for a public post, sealed for the others.
    func media(_ item: PostMedia) async throws -> Data
    /// Removes your own files, and throws if any of them couldn't be removed, so the caller can try again.
    /// Files in someone else's folder are skipped: they were never yours to remove.
    func removeMedia(_ items: [PostMedia]) async throws
    func delete(_ id: UUID) async throws
    func setLiked(_ liked: Bool, post: UUID) async throws
    func comments(on post: UUID) async throws -> [SocialComment]
    func comment(_ body: String, on post: UUID, replyingTo parent: UUID?) async throws
    func profile(_ username: String) async throws -> SocialProfile?
    func setFollowing(_ follow: Bool, _ username: String) async throws
    /// People you follow who follow you back.
    func friends() async throws -> [String]
    func followers(of username: String) async throws -> [String]
    func followed(by username: String) async throws -> [String]
    /// A page of someone's Followers (or Following), newest first, each with how you relate to them.
    /// A private account's lists come back empty unless you're it or one of its approved followers.
    func people(of username: String, followers: Bool, query: String?, after: PeopleCursor?, limit: Int) async throws -> [SocialPerson]
    func markSeen(_ posts: [UUID], notInterested: Bool) async throws
    func topTags() async throws -> [String]
    func searchPeople(_ query: String) async throws -> [SocialProfile]

    // Safety (issue 149 §6)
    func settings() async throws -> SocialSettings
    func save(_ settings: SocialSettings) async throws
    func followRequests() async throws -> [String]
    func approveFollower(_ username: String) async throws
    func removeFollower(_ username: String) async throws
    func setMuted(_ muted: Bool, _ person: UUID) async throws
    func setBlocked(_ blocked: Bool, _ person: UUID) async throws
    func report(_ username: String, post: UUID?, comment: UUID?, reason: String) async throws

    // Saves
    func setSaved(_ saved: Bool, post: UUID) async throws
    func saved() async throws -> [SocialPost]

    // Stories (issue 149, owner's answer 3). Only public ones; the others go through `PrivatePosts`.
    /// Your public stories and those of people you follow, still inside their day.
    func stories() async throws -> [SocialStory]
    func postStory(kind: SocialStory.Kind, text: String, background: StoryBackground?, media: [PostMedia]) async throws -> UUID
    func deleteStory(_ id: UUID) async throws
    /// Tells the author you opened one of their stories, public or encrypted. Only they can read it.
    func viewStory(_ id: UUID, author: String) async throws
    /// Who opened one of your stories, newest first.
    func storyViewers(_ id: UUID) async throws -> [String]
}

/// `SocialServer` over Supabase's REST interface. Everything is a call to one of the `social_*` functions
/// or a write the row rules allow, made with the signed-in person's own token, so the server decides what
/// they may see. Nothing here logs.
public extension SocialServer {
    /// A post with text only.
    func publish(title: String?, body: String, tags: [String]) async throws -> UUID {
        try await publish(title: title, body: body, tags: tags, media: [])
    }

    /// A post's file, on the shelf that keeps it.
    func uploadMedia(_ data: Data, contentType: String) async throws -> String {
        try await uploadMedia(data, contentType: contentType, store: .totality)
    }
}

public struct RestSocialServer: SocialServer {
    let base: URL
    let key: String
    let token: @Sendable () async throws -> String
    let username: @Sendable () async -> String?
    let session: URLSession
    /// Totality's own media server, `server/social-media/`.
    let mediaBase: URL
    /// The story shelf on the same server, whose files go after a day.
    let storyBase: URL
    public static let standardMediaBase = URL(string: "https://usetotality.com/social/media/")!
    public static let standardStoryBase = URL(string: "https://usetotality.com/social/stories/")!

    public init(
        base: URL, publishableKey: String, session: URLSession = .shared, mediaBase: URL = RestSocialServer.standardMediaBase,
        storyBase: URL = RestSocialServer.standardStoryBase,
        token: @escaping @Sendable () async throws -> String, username: @escaping @Sendable () async -> String?
    ) {
        self.base = base
        self.mediaBase = mediaBase
        self.storyBase = storyBase
        key = publishableKey
        self.token = token
        self.username = username
        self.session = session
    }

    // MARK: Rows as the server sends them

    struct PostRow: Decodable {
        let id: UUID
        let handle: String
        let display_name: String?
        let title: String?
        let body: String
        let tags: [String]
        let created_at: String
        let edited_at: String?
        let likes: Int?
        let comments: Int
        let liked: Bool
        let reason: String?
        let saved: Bool?
        let media: [PostMedia]?

        var post: SocialPost {
            var post = SocialPost(
                id: id, author: handle, authorName: display_name, audience: .everyone, title: title, body: body, tags: tags,
                date: RestSocialServer.date(created_at) ?? .distantPast, edited: edited_at != nil, likes: likes ?? 0,
                comments: comments, liked: liked, reason: (reason?.isEmpty ?? true) ? nil : reason
            )
            post.likesHidden = likes == nil
            post.saved = saved ?? false
            // A public row never carries keys; drop anything that claims to.
            let media = (media ?? []).filter { !$0.isSealed }
            if MediaLimits.problem(media, encrypted: false) == nil { post.media = media }
            return post
        }
    }

    struct CommentRow: Decodable {
        let id: UUID
        let parent_id: UUID?
        let handle: String
        let display_name: String?
        let body: String
        let created_at: String
    }

    struct ProfileRow: Decodable {
        let id: UUID?
        let handle: String
        let display_name: String?
        let bio: String?
        let avatar_key: String?
        let posts: Int
        let followers: Int
        let following: Int
        let i_follow: Bool
        let follows_me: Bool
        let requested: Bool?
        let private_account: Bool?
        let muted: Bool?
        let can_comment: Bool?
        let can_message: Bool?
    }

    struct SettingsRow: Decodable {
        let who_can_comment: String
        let who_can_message: String
        let private_account: Bool
        let hide_like_counts: Bool
    }

    struct HandleRow: Decodable {
        let handle: String
        let display_name: String?
    }

    struct PersonRow: Decodable {
        let id: UUID?
        let handle: String
        let display_name: String?
        let avatar_key: String?
        let followed_at: String
        let i_follow: Bool
        let follows_me: Bool
        let requested: Bool
        let muted: Bool?
    }

    struct TagRow: Decodable { let tag: String }
    struct IDRow: Decodable { let id: UUID }

    static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Postgres sends microseconds, which the formatter may not take: drop the fraction and try again.
        let trimmed = text.replacingOccurrences(of: " ", with: "T")
            .replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        return plain.date(from: trimmed) ?? plain.date(from: trimmed.replacingOccurrences(of: "+00$", with: "Z", options: .regularExpression))
    }

    static func text(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: Requests

    func request(_ path: String, method: String = "POST", query: [URLQueryItem] = [], body: Any? = nil, prefer: String? = nil) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent("rest/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(request, signedIn: true)
    }

    func send(_ request: URLRequest, signedIn: Bool, timeout: TimeInterval = 20, toSupabase: Bool = true) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        if toSupabase { request.setValue(key, forHTTPHeaderField: "apikey") }
        if signedIn {
            let token: String
            do { token = try await self.token() } catch { throw SocialError.signedOut }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dataNotAllowed].contains(error.code) {
            throw SocialError.offline
        } catch {
            throw SocialError.failed("Social didn't answer. Try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    /// The Supabase bucket that held posts' photos and audio before they moved to Totality's own server.
    /// Older posts' files are still read from it and removed from it; nothing new goes there.
    static let bucket = "social-media"

    /// The signed-in account's ID, the `sub` of its token, which names its folder in the bucket.
    static func account(fromToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let sub = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sub"] as? String,
              let id = UUID(uuidString: sub) else { return nil }
        return id.uuidString.lowercased()
    }

    /// The server's refusal in plain words. Its own text is only matched, never shown, so nothing it says
    /// reaches the screen unchecked.
    static func error(status: Int, data: Data) -> SocialError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        if status == 401 { return .signedOut }
        if message.contains("too many posts") { return .refused("That's a lot of posts this hour. Try again later.") }
        if message.contains("too many comments") { return .refused("That's a lot of comments this hour. Try again later.") }
        if message.contains("too many stories") { return .refused("That's a lot of stories today. Try again tomorrow.") }
        if message.contains("too many follows") { return .refused("You've followed a lot of people today. Try again tomorrow.") }
        if message.contains("no such user") { return .refused("That person isn't on Totality.") }
        if message.contains("yourself") { return .refused("You can't follow yourself.") }
        if message.contains("duplicate") { return .refused("Already done.") }
        if status == 413 || message.contains("exceeded the maximum allowed size") { return .refused("That file is too big to post.") }
        if status == 415 { return .refused("That file isn't a photo or clip Social can post.") }
        if status == 429 { return .refused("That's a lot of photos and clips today. Try again tomorrow.") }
        if status == 507 { return .refused("There's no room for more photos and clips just now. Try again later.") }
        if status == 403 { return .refused("That file isn't yours to change.") }
        if message.contains("row-level security") { return .refused("That post isn't available any more.") }
        return .failed("Social couldn't do that just now. Try again.")
    }

    func rpc<Row: Decodable>(_ name: String, _ args: [String: Any] = [:], as: Row.Type) async throws -> [Row] {
        let data = try await request("rpc/" + name, body: args)
        do { return try JSONDecoder().decode([Row].self, from: data) } catch {
            throw SocialError.failed("Social sent something this version can't read.")
        }
    }

    func call(_ name: String, _ args: [String: Any] = [:]) async throws {
        _ = try await request("rpc/" + name, body: args)
    }

    // MARK: SocialServer

    public func me() async throws -> String {
        guard let name = await username() else { throw SocialError.signedOut }
        return name
    }

    public func forYou(tag: String?) async throws -> [SocialPost] {
        try await rpc("social_for_you", ["p_limit": 30, "p_tag": tag ?? NSNull()], as: PostRow.self).map(\.post)
    }

    public func following(before: Date?) async throws -> [SocialPost] {
        try await rpc("social_following_feed", ["p_before": before.map(Self.text) ?? NSNull(), "p_limit": 30], as: PostRow.self).map(\.post)
    }

    public func posts(by username: String, before: Date?) async throws -> [SocialPost] {
        try await rpc("social_posts_by", ["p_handle": username, "p_before": before.map(Self.text) ?? NSNull(), "p_limit": SocialPage.size], as: PostRow.self).map(\.post)
    }

    public func post(_ id: UUID) async throws -> SocialPost? {
        try await rpc("social_post", ["p_id": id.uuidString.lowercased()], as: PostRow.self).first?.post
    }

    public func publish(title: String?, body: String, tags: [String], media: [PostMedia]) async throws -> UUID {
        let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(media.map(\.forServer)))
        let data = try await request("social_posts", query: [URLQueryItem(name: "select", value: "id")],
                                     body: ["title": title ?? NSNull(), "body": body, "tags": tags, "media": items], prefer: "return=representation")
        guard let row = try? JSONDecoder().decode([IDRow].self, from: data).first else {
            throw SocialError.failed("The post went up but its address didn't come back. Pull to refresh.")
        }
        return row.id
    }

    public func uploadMedia(_ data: Data, contentType: String, store: PostMedia.Store) async throws -> String {
        let most = contentType == "image/jpeg" || contentType == "audio/mp4" ? MediaLimits.most(.photo) : MediaLimits.most(.video)
        guard data.count <= most else { throw SocialError.refused("That file is too big to post.") }
        let account = try await myAccount()
        let path = account + "/" + UUID().uuidString.lowercased()
        var request = URLRequest(url: shelf(store).appendingPathComponent(path))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        // A video can take a while on a slow connection.
        _ = try await send(request, signedIn: true, timeout: data.count > MediaLimits.fileBytes ? 600 : 60, toSupabase: false)
        return path
    }

    func shelf(_ store: PostMedia.Store) -> URL { store == .stories ? storyBase : mediaBase }

    public func media(_ item: PostMedia) async throws -> Data {
        guard Self.isMediaPath(item.path) else { throw SocialError.failed("That file has a bad address.") }
        let data: Data
        switch item.store {
        case .totality, .stories:
            // Signed in, so a file can't be hotlinked from elsewhere on the web.
            data = try await send(URLRequest(url: shelf(item.store ?? .totality).appendingPathComponent(item.path)), signedIn: true,
                                  timeout: item.kind == .video ? 600 : 60, toSupabase: false)
        case nil:
            data = try await send(URLRequest(url: base.appendingPathComponent("storage/v1/object/public/\(Self.bucket)/" + item.path)),
                                  signedIn: false, timeout: 60)
        }
        guard data.count <= MediaLimits.most(item.kind) else { throw SocialError.failed("That file is bigger than Social allows.") }
        return data
    }

    public func removeMedia(_ items: [PostMedia]) async throws {
        guard !items.isEmpty else { return }
        let account = try await myAccount()
        let mine = items.filter { $0.folder == account && Self.isMediaPath($0.path) }
        for item in mine where item.store != nil {
            var request = URLRequest(url: shelf(item.store ?? .totality).appendingPathComponent(item.path))
            request.httpMethod = "DELETE"
            _ = try await send(request, signedIn: true, toSupabase: false)
        }
        let legacy = mine.filter { $0.store == nil }.map(\.path)
        guard !legacy.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("storage/v1/object/\(Self.bucket)"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": legacy])
        _ = try await send(request, signedIn: true)
    }

    static func isMediaPath(_ path: String) -> Bool {
        MediaLimits.path.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// The signed-in account's ID, which names its folder.
    func myAccount() async throws -> String {
        let token: String
        do { token = try await self.token() } catch { throw SocialError.signedOut }
        guard let account = Self.account(fromToken: token) else { throw SocialError.signedOut }
        return account
    }

    public func delete(_ id: UUID) async throws {
        _ = try await request("social_posts", method: "DELETE", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")])
    }

    public func setLiked(_ liked: Bool, post: UUID) async throws {
        let id = post.uuidString.lowercased()
        if liked {
            do {
                _ = try await request("social_likes", body: ["post_id": id])
            } catch SocialError.refused("Already done.") {}
        } else {
            _ = try await request("social_likes", method: "DELETE", query: [URLQueryItem(name: "post_id", value: "eq.\(id)")])
        }
    }

    public func comments(on post: UUID) async throws -> [SocialComment] {
        try await rpc("social_comments_of", ["p_post": post.uuidString.lowercased()], as: CommentRow.self).map {
            SocialComment(id: $0.id, parent: $0.parent_id, author: $0.handle, authorName: $0.display_name, body: $0.body, date: Self.date($0.created_at) ?? .distantPast)
        }
    }

    public func comment(_ body: String, on post: UUID, replyingTo parent: UUID?) async throws {
        _ = try await request("social_comments", body: [
            "post_id": post.uuidString.lowercased(), "parent_id": parent?.uuidString.lowercased() ?? NSNull(), "body": body,
        ])
    }

    public func profile(_ username: String) async throws -> SocialProfile? {
        try await rpc("social_profile", ["p_handle": username], as: ProfileRow.self).first.map {
            var p = SocialProfile(username: $0.handle, displayName: $0.display_name, bio: $0.bio, photoKey: $0.avatar_key, posts: $0.posts,
                                  followers: $0.followers, following: $0.following, iFollow: $0.i_follow, followsMe: $0.follows_me)
            p.id = $0.id
            p.requested = $0.requested ?? false
            p.privateAccount = $0.private_account ?? false
            p.muted = $0.muted ?? false
            p.canComment = $0.can_comment ?? true
            p.canMessage = $0.can_message ?? true
            return p
        }
    }

    public func setFollowing(_ follow: Bool, _ username: String) async throws {
        try await call(follow ? "social_follow" : "social_unfollow", ["p_handle": username])
    }

    public func friends() async throws -> [String] {
        try await rpc("social_friends", as: HandleRow.self).map(\.handle)
    }

    public func followers(of username: String) async throws -> [String] {
        try await rpc("social_people", ["p_handle": username, "p_followers": true], as: HandleRow.self).map(\.handle)
    }

    public func followed(by username: String) async throws -> [String] {
        try await rpc("social_people", ["p_handle": username, "p_followers": false], as: HandleRow.self).map(\.handle)
    }

    public func people(of username: String, followers: Bool, query: String?, after: PeopleCursor?, limit: Int) async throws -> [SocialPerson] {
        try await rpc("social_people", [
            "p_handle": username, "p_followers": followers, "p_query": query ?? NSNull(),
            "p_before_at": after?.followedAt ?? NSNull(), "p_before_handle": after?.username ?? NSNull(), "p_limit": limit,
        ], as: PersonRow.self).map {
            SocialPerson(username: $0.handle, displayName: $0.display_name, photoKey: $0.avatar_key, followedAt: $0.followed_at,
                         iFollow: $0.i_follow, followsMe: $0.follows_me, requested: $0.requested, muted: $0.muted ?? false, accountID: $0.id)
        }
    }

    public func markSeen(_ posts: [UUID], notInterested: Bool) async throws {
        guard !posts.isEmpty else { return }
        try await call("social_mark_seen", ["p_posts": posts.map { $0.uuidString.lowercased() }, "p_not_interested": notInterested])
    }

    public func topTags() async throws -> [String] {
        try await rpc("social_top_tags", as: TagRow.self).map(\.tag)
    }

    public func searchPeople(_ query: String) async throws -> [SocialProfile] {
        try await rpc("social_search_people", ["p_query": query], as: HandleRow.self).map {
            SocialProfile(username: $0.handle, displayName: $0.display_name, bio: nil)
        }
    }

    // MARK: Safety

    public func settings() async throws -> SocialSettings {
        guard let row = try await rpc("social_my_settings", as: SettingsRow.self).first else { return SocialSettings() }
        return SocialSettings(
            whoCanComment: Reach(rawValue: row.who_can_comment) ?? .anyone, whoCanMessage: Reach(rawValue: row.who_can_message) ?? .anyone,
            privateAccount: row.private_account, hideLikeCounts: row.hide_like_counts
        )
    }

    public func save(_ settings: SocialSettings) async throws {
        try await call("social_set_settings", [
            "p_who_can_comment": settings.whoCanComment.rawValue, "p_who_can_message": settings.whoCanMessage.rawValue,
            "p_private_account": settings.privateAccount, "p_hide_like_counts": settings.hideLikeCounts,
        ])
    }

    public func followRequests() async throws -> [String] {
        try await rpc("social_follow_requests", as: HandleRow.self).map(\.handle)
    }

    public func approveFollower(_ username: String) async throws { try await call("social_approve_follower", ["p_handle": username]) }
    public func removeFollower(_ username: String) async throws { try await call("social_remove_follower", ["p_handle": username]) }

    public func setMuted(_ muted: Bool, _ person: UUID) async throws {
        let id = person.uuidString.lowercased()
        if muted {
            do { _ = try await request("social_mutes", body: ["muted_id": id]) } catch SocialError.refused("Already done.") {}
        } else {
            _ = try await request("social_mutes", method: "DELETE", query: [URLQueryItem(name: "muted_id", value: "eq.\(id)")])
        }
    }

    /// Blocking is Totality's one block (`block_contact`), so it also covers Messages and sharing.
    public func setBlocked(_ blocked: Bool, _ person: UUID) async throws {
        let id = person.uuidString.lowercased()
        if blocked {
            try await call("block_contact", ["p_peer": id])
        } else {
            _ = try await request("contacts", method: "DELETE", query: [
                URLQueryItem(name: "peer_id", value: "eq.\(id)"), URLQueryItem(name: "state", value: "eq.blocked"),
            ])
        }
    }

    public func report(_ username: String, post: UUID?, comment: UUID?, reason: String) async throws {
        try await call("social_report", [
            "p_handle": username, "p_post": post?.uuidString.lowercased() ?? NSNull(),
            "p_comment": comment?.uuidString.lowercased() ?? NSNull(), "p_reason": reason,
        ])
    }

    // MARK: Saves

    public func setSaved(_ saved: Bool, post: UUID) async throws {
        let id = post.uuidString.lowercased()
        if saved {
            do { _ = try await request("social_saves", body: ["post_id": id]) } catch SocialError.refused("Already done.") {}
        } else {
            _ = try await request("social_saves", method: "DELETE", query: [URLQueryItem(name: "post_id", value: "eq.\(id)")])
        }
    }

    public func saved() async throws -> [SocialPost] {
        try await rpc("social_saved", as: PostRow.self).map(\.post)
    }

    // MARK: Stories

    struct StoryRow: Decodable {
        let id: UUID
        let handle: String
        let display_name: String?
        let kind: String
        let body: String
        let background: String?
        let media: [PostMedia]?
        let created_at: String
        let viewed: Bool

        /// Nil for anything this version can't show or that breaks the limits.
        var story: SocialStory? {
            guard let kind = SocialStory.Kind(rawValue: kind), let date = RestSocialServer.date(created_at) else { return nil }
            let media = media ?? []
            guard StoryLimits.problem(kind: kind, text: body, media: media, encrypted: false) == nil else { return nil }
            return SocialStory(id: id, author: handle, authorName: display_name, audience: .everyone, kind: kind, text: body,
                               background: background.flatMap(StoryBackground.init(rawValue:)), media: media, date: date, viewed: viewed)
        }
    }

    public func stories() async throws -> [SocialStory] {
        try await rpc("social_stories", as: StoryRow.self).compactMap(\.story)
    }

    public func postStory(kind: SocialStory.Kind, text: String, background: StoryBackground?, media: [PostMedia]) async throws -> UUID {
        let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(media.map(\.forServer)))
        let data = try await request("social_stories", query: [URLQueryItem(name: "select", value: "id")], body: [
            "kind": kind.rawValue, "body": text, "background": background?.rawValue ?? NSNull(), "media": items,
        ], prefer: "return=representation")
        guard let row = try? JSONDecoder().decode([IDRow].self, from: data).first else {
            throw SocialError.failed("The story went up but its address didn't come back. Pull to refresh.")
        }
        return row.id
    }

    public func deleteStory(_ id: UUID) async throws {
        _ = try await request("social_stories", method: "DELETE", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")])
    }

    public func viewStory(_ id: UUID, author: String) async throws {
        try await call("social_view_story", ["p_story": id.uuidString.lowercased(), "p_author": author])
    }

    public func storyViewers(_ id: UUID) async throws -> [String] {
        try await rpc("social_story_viewers", ["p_story": id.uuidString.lowercased()], as: HandleRow.self).map(\.handle)
    }
}
