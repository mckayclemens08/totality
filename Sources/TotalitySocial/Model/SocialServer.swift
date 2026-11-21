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
    /// Puts one file in your folder of the `social-media` bucket and returns its path. A file for an
    /// encrypted post is already sealed when it gets here.
    func uploadMedia(_ data: Data, contentType: String) async throws -> String
    /// A file from the bucket, as stored: readable for a public post, sealed for the others.
    func media(at path: String) async throws -> Data
    func removeMedia(_ paths: [String]) async throws
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
}

/// `SocialServer` over Supabase's REST interface. Everything is a call to one of the `social_*` functions
/// or a write the row rules allow, made with the signed-in person's own token, so the server decides what
/// they may see. Nothing here logs.
public extension SocialServer {
    /// A post with text only.
    func publish(title: String?, body: String, tags: [String]) async throws -> UUID {
        try await publish(title: title, body: body, tags: tags, media: [])
    }
}

public struct RestSocialServer: SocialServer {
    let base: URL
    let key: String
    let token: @Sendable () async throws -> String
    let username: @Sendable () async -> String?
    let session: URLSession

    public init(
        base: URL, publishableKey: String, session: URLSession = .shared,
        token: @escaping @Sendable () async throws -> String, username: @escaping @Sendable () async -> String?
    ) {
        self.base = base
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

    func send(_ request: URLRequest, signedIn: Bool, timeout: TimeInterval = 20) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "apikey")
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

    /// The bucket that holds posts' photos and audio. It's public to read, so a public post's media show
    /// to anyone; only you can add to or remove from your own folder.
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
        if message.contains("too many follows") { return .refused("You've followed a lot of people today. Try again tomorrow.") }
        if message.contains("no such user") { return .refused("That person isn't on Totality.") }
        if message.contains("yourself") { return .refused("You can't follow yourself.") }
        if message.contains("duplicate") { return .refused("Already done.") }
        if status == 413 || message.contains("exceeded the maximum allowed size") { return .refused("That file is too big to post.") }
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

    public func uploadMedia(_ data: Data, contentType: String) async throws -> String {
        guard data.count <= MediaLimits.fileBytes + MediaLimits.sealOverhead else { throw SocialError.refused("That file is too big to post.") }
        let token: String
        do { token = try await self.token() } catch { throw SocialError.signedOut }
        guard let account = Self.account(fromToken: token) else { throw SocialError.signedOut }
        let path = account + "/" + UUID().uuidString.lowercased()
        var request = URLRequest(url: base.appendingPathComponent("storage/v1/object/\(Self.bucket)/" + path))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = data
        _ = try await send(request, signedIn: true, timeout: 60)
        return path
    }

    public func media(at path: String) async throws -> Data {
        guard MediaLimits.path.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil else {
            throw SocialError.failed("That file has a bad address.")
        }
        let request = URLRequest(url: base.appendingPathComponent("storage/v1/object/public/\(Self.bucket)/" + path))
        let data = try await send(request, signedIn: false, timeout: 60)
        guard data.count <= MediaLimits.fileBytes + MediaLimits.sealOverhead else { throw SocialError.failed("That file is bigger than Social allows.") }
        return data
    }

    public func removeMedia(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("storage/v1/object/\(Self.bucket)"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": paths])
        _ = try await send(request, signedIn: true)
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
}
