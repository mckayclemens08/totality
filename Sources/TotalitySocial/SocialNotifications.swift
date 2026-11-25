import Foundation
import TotalityCore

/// Social's part of the notifications system (issue 232, issue 149 step 6). The app hands it to
/// `NotificationHub`, so Social imports no other module.
///
/// Public activity (follows, requests, likes, comments, replies) is read from Totality's server, where it
/// already is. Friends and Close-friends posts are read from the encrypted rooms on this phone, so their
/// words never reach the server: the push that woke the phone said nothing, and the alert is written here.
@MainActor
public final class SocialNotifications: NotificationSource {
    public static let follower = NotificationKind(module: .social, key: "follower", name: "New followers", detail: "When someone follows you")
    public static let request = NotificationKind(module: .social, key: "request", name: "Follow requests", detail: "While your account is private")
    public static let like = NotificationKind(module: .social, key: "like", name: "Likes", detail: "On your posts")
    public static let comment = NotificationKind(module: .social, key: "comment", name: "Comments and replies", detail: "On your posts and comments")
    public static let closeFriendsPost = NotificationKind(
        module: .social, key: "closeFriendsPost", name: "Close-friends posts", detail: "From people who added you"
    )
    public static let friendsPost = NotificationKind(
        module: .social, key: "friendsPost", name: "Friends posts", detail: "Off at first, since friends may post often", startsOn: false
    )

    /// A few minutes back past the last look, in case the phone's clock and the server's disagree. The
    /// hub never alerts the same ID twice.
    static let overlap: TimeInterval = 10 * 60

    public let module = ModuleID.social
    public let kinds = [follower, request, like, comment, closeFriendsPost, friendsPost]

    private let model: SocialModel
    private let activity: (any SocialActivityServer)?
    private let publicCursor: NotificationCursor
    private let privateCursor: NotificationCursor
    private let wants: @MainActor (NotificationKind) -> Bool
    private let clock: @Sendable () -> Date

    public init(
        model: SocialModel, defaults: UserDefaults = .standard,
        wants: @escaping @MainActor (NotificationKind) -> Bool = { NotificationHub.shared.allows($0) },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.model = model
        activity = model.server as? any SocialActivityServer
        publicCursor = NotificationCursor("social.activity", defaults: defaults)
        privateCursor = NotificationCursor("social.private", defaults: defaults)
        self.wants = wants
        self.clock = clock
    }

    public func newNotifications() async -> [AppNotification] {
        var notes: [AppNotification] = []
        if [Self.follower, Self.request, Self.like, Self.comment].contains(where: wants) {
            notes += await publicNotes()
        }
        if wants(Self.closeFriendsPost) || wants(Self.friendsPost) {
            notes += await privateNotes()
        }
        return notes
    }

    private func publicNotes() async -> [AppNotification] {
        guard let activity else { return [] }
        let now = clock()
        guard let since = publicCursor.date else {
            publicCursor.date = now
            return []
        }
        guard let found = try? await activity.activity(since: since.addingTimeInterval(-Self.overlap)) else { return [] }
        publicCursor.date = max(since, found.map(\.date).max() ?? since, min(now, since.addingTimeInterval(Self.overlap)))
        return found.map(Self.note)
    }

    /// New Friends and Close-friends posts by others, read again from the rooms.
    private func privateNotes() async -> [AppNotification] {
        let now = clock()
        guard let since = privateCursor.date else {
            privateCursor.date = now
            return []
        }
        await model.load()
        guard let me = model.me else { return [] }
        let fresh = model.following.filter { $0.audience != .everyone && $0.author.lowercased() != me.lowercased() && $0.date > since }
        privateCursor.date = max(since, fresh.map(\.date).max() ?? since)
        return fresh.map { Self.note($0, closeFriend: model.closeFriends.contains($0.author)) }
    }

    static func name(_ username: String, _ display: String?) -> String {
        if let display, !display.trimmingCharacters(in: .whitespaces).isEmpty { return display }
        return "@" + username
    }

    static func note(_ item: SocialActivity) -> AppNotification {
        let who = name(item.username, item.displayName)
        let profile = NotificationTarget(module: .social, kind: "profile", item: item.username)
        let post = item.post.map { NotificationTarget(module: .social, kind: "post", item: $0.uuidString) }
        let quoted = item.postSnippet.map { "\u{201C}\($0)\u{201D}" } ?? ""
        let (kind, title, body, target, actions): (NotificationKind, String, String, NotificationTarget, [NotificationAction]) = switch item.kind {
        case .follower: (follower, "\(who) followed you", "", profile, [])
        case .request: (request, "\(who) asked to follow you", "Approve here, or see them in Social.", profile, [.approve])
        case .like: (like, "\(who) liked your post", quoted, post ?? profile, [])
        case .comment: (comment, "\(who) commented on your post", item.snippet ?? quoted, post ?? profile, [])
        case .reply: (comment, "\(who) replied to your comment", item.snippet ?? quoted, post ?? profile, [])
        }
        return AppNotification(
            id: "social.\(item.kind.rawValue).\(item.id.uuidString.lowercased())", kind: kind, title: title, body: body,
            thread: item.post?.uuidString.lowercased() ?? "people", target: target, actions: actions, date: item.date
        )
    }

    static func note(_ post: SocialPost, closeFriend: Bool) -> AppNotification {
        let closeOnly = post.audience == .closeFriends
        let text = [post.title, post.body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return AppNotification(
            id: "social.post.\(post.id.uuidString.lowercased())", kind: closeOnly ? closeFriendsPost : friendsPost,
            title: "@\(post.author) shared a \(closeOnly ? "Close-friends" : "Friends") post", body: String(text.prefix(140)),
            isPrivate: true, thread: post.id.uuidString.lowercased(),
            target: NotificationTarget(module: .social, kind: "post", item: post.id.uuidString),
            fromCloseFriend: closeFriend, date: post.date
        )
    }

    public func badgeCount() -> Int { model.followRequests.count }

    public func prepareToOpen(_ target: NotificationTarget) {
        switch target.kind {
        case "post":
            guard let id = UUID(uuidString: target.item) else { return }
            let model = model
            Task {
                await model.fetchPost(id)
                model.requestedPost = id
            }
        case "profile":
            model.requestedProfile = target.item
        default:
            break
        }
    }

    public func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async {
        guard action == .approve, target.kind == "profile" else { return }
        await model.answerRequest(target.item, approve: true)
    }
}
