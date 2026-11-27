import Foundation

/// Who follows you on Social, asked through Core so Messages never imports Social. Only a broadcast channel
/// needs it: you may invite your followers and no one else. The app wires Social's answer in; Messages
/// treats a missing one as "can't check", which refuses the invite. The server checks the same rule.
public protocol FollowerDirectory: Sendable {
    /// People who follow you whose handle or name matches what's been typed, best first, at most `limit`.
    func followers(matching typed: String, limit: Int) async throws -> [ProfileSuggestion]
    /// Which of these handles follow you. Anyone not in the answer doesn't.
    func followers(among usernames: [String]) async throws -> Set<String>
}
