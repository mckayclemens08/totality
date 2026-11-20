import Foundation
import Observation

/// One person on someone's Followers or Following list, with how you relate to them.
public struct SocialPerson: Hashable, Sendable, Identifiable {
    public var id: String { username }
    /// Their account ID, which muting needs.
    public var accountID: UUID?
    public let username: String
    public let displayName: String?
    public let photoKey: String?
    /// When the follow began, as the server sent it. It's the next page's cursor, so it's kept exact.
    public let followedAt: String
    public var iFollow: Bool
    public var followsMe: Bool
    public var requested: Bool
    public var muted: Bool

    public init(
        username: String, displayName: String? = nil, photoKey: String? = nil, followedAt: String = "",
        iFollow: Bool = false, followsMe: Bool = false, requested: Bool = false, muted: Bool = false, accountID: UUID? = nil
    ) {
        self.username = username
        self.displayName = displayName
        self.photoKey = photoKey
        self.followedAt = followedAt
        self.iFollow = iFollow
        self.followsMe = followsMe
        self.requested = requested
        self.muted = muted
        self.accountID = accountID
    }

    public var name: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return username }
        return displayName
    }

    /// Enough of a profile for muting, which needs only the ID and the username.
    var profile: SocialProfile {
        var p = SocialProfile(username: username, displayName: displayName, bio: nil, photoKey: photoKey, iFollow: iFollow, followsMe: followsMe)
        p.id = accountID
        p.requested = requested
        p.muted = muted
        return p
    }
}

/// Where the next page of a list starts: just after this person.
public struct PeopleCursor: Hashable, Sendable {
    public let followedAt: String
    public let username: String

    public init(after person: SocialPerson) {
        followedAt = person.followedAt
        username = person.username
    }
}

/// What a row's one button says, which is how you relate to that person.
public enum Relationship: Equatable, Sendable {
    case you, following, requested, followBack, follow

    public init(_ person: SocialPerson, me: String?) {
        if person.username == me { self = .you }
        else if person.iFollow { self = .following }
        else if person.requested { self = .requested }
        else if person.followsMe { self = .followBack }
        else { self = .follow }
    }

    public var title: String {
        switch self {
        case .you: "You"
        case .following: "Following"
        case .requested: "Requested"
        case .followBack: "Follow back"
        case .follow: "Follow"
        }
    }
}

/// Someone's Followers or Following list on screen: pages of 50, newest first, and a search that runs on
/// the server so it finds people past the pages already loaded.
@MainActor
@Observable
public final class FollowList {
    public enum Phase: Equatable { case loading, ready, failed(String) }

    public static let pageSize = 50

    public let username: String
    public var showingFollowers: Bool {
        didSet { if showingFollowers != oldValue { people = []; hasMore = false; phase = .loading } }
    }
    public private(set) var phase: Phase = .loading
    public private(set) var people: [SocialPerson] = []
    public private(set) var hasMore = false
    public private(set) var photos: [String: Data] = [:]
    private(set) var query = ""
    private let social: SocialModel
    private var loadingMore = false

    public init(social: SocialModel, username: String, showingFollowers: Bool) {
        self.social = social
        self.username = username
        self.showingFollowers = showingFollowers
    }

    /// Your own list: only there do rows get the More button.
    public var isMine: Bool { username == social.me }

    /// Loads the first page for the tab and search showing now.
    public func reload(query: String) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query != self.query { people = [] }
        self.query = query
        if people.isEmpty { phase = .loading }
        do {
            let page = try await fetch(after: nil)
            people = page
            hasMore = page.count == Self.pageSize
            phase = .ready
            await loadPhotos(page)
        } catch {
            // A refresh that fails keeps what's on screen, with a note; a first load shows the error.
            if people.isEmpty { phase = .failed(SocialModel.message(error)) } else { social.notice = SocialModel.message(error) }
        }
    }

    /// The next page, when the last row comes on screen.
    public func loadMore() async {
        guard hasMore, !loadingMore, let last = people.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await fetch(after: PeopleCursor(after: last))
            let known = Set(people.map(\.username))
            people += page.filter { !known.contains($0.username) }
            hasMore = page.count == Self.pageSize
            await loadPhotos(page)
        } catch {
            social.notice = SocialModel.message(error)
        }
    }

    private func fetch(after cursor: PeopleCursor?) async throws -> [SocialPerson] {
        try await social.server.people(of: username, followers: showingFollowers, query: query.isEmpty ? nil : query,
                                       after: cursor, limit: Self.pageSize)
    }

    private func loadPhotos(_ page: [SocialPerson]) async {
        let wanted = page.filter { $0.photoKey != nil && photos[$0.username] == nil }.map(\.username)
        guard let profiles = social.profiles, !wanted.isEmpty,
              let found = try? await profiles.profiles(of: wanted, photos: [:]) else { return }
        for (name, profile) in found { if let photo = profile.photo { photos[name] = photo } }
    }

    // MARK: What a row does

    /// The row's one button: Follow, Follow back, or taking back a request. Unfollowing is confirmed first,
    /// by the view.
    public func setFollowing(_ follow: Bool, _ person: SocialPerson) async {
        guard await social.setFollowing(follow, person.username) else { return }
        await refreshRow(person.username)
    }

    /// Your Followers tab only: they stop following you, and leave your Friends and Close-friends rooms.
    public func remove(_ person: SocialPerson) async {
        guard await social.removeFollower(person.username) else { return }
        people.removeAll { $0.username == person.username }
    }

    public func setMuted(_ muted: Bool, _ person: SocialPerson) async {
        guard await social.setMuted(muted, person.profile) else { return }
        update(person.username) { $0.muted = muted }
    }

    public func isCloseFriend(_ person: SocialPerson) -> Bool { social.closeFriends.contains(person.username) }

    /// Why Close friends can't be changed on this phone, if it can't.
    public var closeFriendsReason: String? { social.privateReason }

    public func setCloseFriend(_ on: Bool, _ person: SocialPerson) async {
        var people = social.closeFriends
        if on { people.insert(person.username) } else { people.remove(person.username) }
        _ = await social.setCloseFriends(people)
    }

    private func refreshRow(_ name: String) async {
        guard let profile = try? await social.profile(name) else { return }
        update(name) { $0.iFollow = profile.iFollow; $0.requested = profile.requested; $0.followsMe = profile.followsMe }
    }

    private func update(_ name: String, _ change: (inout SocialPerson) -> Void) {
        if let i = people.firstIndex(where: { $0.username == name }) { change(&people[i]) }
    }
}
