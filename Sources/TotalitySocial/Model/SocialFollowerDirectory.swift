import Foundation
import TotalityCore

/// Social's answer to "who follows me", handed to Messages through Core's `FollowerDirectory`. It reads
/// the same follower list as Social's own Followers screen, so it includes friends and close friends.
public struct SocialFollowerDirectory: FollowerDirectory {
    let server: any SocialServer
    let username: @Sendable () async -> String?

    public init(server: any SocialServer, username: @escaping @Sendable () async -> String?) {
        self.server = server
        self.username = username
    }

    public func followers(matching typed: String, limit: Int) async throws -> [ProfileSuggestion] {
        guard let me = await username() else { return [] }
        let found = try await server.people(of: me, followers: true, query: typed, after: nil, limit: min(max(limit, 1), 20))
        return found.map { ProfileSuggestion(handle: $0.username, displayName: $0.displayName) }
    }

    public func followers(among usernames: [String]) async throws -> Set<String> {
        guard let me = await username() else { return [] }
        var follow: Set<String> = []
        for name in usernames {
            let found = try await server.people(of: me, followers: true, query: name, after: nil, limit: 20)
            if found.contains(where: { $0.username == name }) { follow.insert(name) }
        }
        return follow
    }
}
