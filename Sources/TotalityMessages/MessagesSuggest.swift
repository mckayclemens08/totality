import Foundation
import TotalityCore

/// The rules behind username suggestions: which part of the field is being typed, what's already picked,
/// and how a tapped suggestion goes back into the text. Plain functions, so tests cover them.
public enum UsernameTyping {
    private static func isSeparator(_ character: Character) -> Bool { character == "," || character.isWhitespace }

    /// What's being typed now: everything after the last comma or space. Without a leading @, in lower case.
    public static func currentToken(_ text: String) -> String {
        let token = text.reversed().prefix { !isSeparator($0) }.reversed()
        return String(token.drop { $0 == "@" }).lowercased()
    }

    /// Usernames already typed in full, which aren't suggested again. The one being typed isn't among them.
    public static func finished(_ text: String) -> Set<String> {
        var parts = text.split(whereSeparator: isSeparator).map(String.init)
        if let last = text.last, !isSeparator(last), !parts.isEmpty { parts.removeLast() }
        return Set(parts.compactMap(MessagesUsername.normalized))
    }

    /// The text after a suggestion is tapped. A list keeps what's typed and adds ", " ready for the next name;
    /// a single field becomes just that name.
    public static func replacingCurrent(in text: String, with handle: String, multiple: Bool) -> String {
        guard multiple else { return handle }
        let kept = text.dropLast(text.reversed().prefix { !isSeparator($0) }.count)
        return String(kept) + handle + ", "
    }

    /// What to show: best matches first (handles starting with what's typed, then the rest, each in the
    /// order given), without people already picked, or more than `limit`.
    public static func shown(
        _ found: [ProfileSuggestion], typing token: String, excluding: Set<String>, limit: Int = 5
    ) -> [ProfileSuggestion] {
        guard !token.isEmpty else { return [] }
        let usable = found.filter { !excluding.contains($0.handle) }
        let starts = usable.filter { $0.handle.hasPrefix(token) }
        let others = usable.filter { !$0.handle.hasPrefix(token) }
        return Array((starts + others).prefix(limit))
    }
}

/// The channel rule: you may invite only people who follow you. The server checks it too.
public enum ChannelInviteRule {
    public static let line = "You can only invite people who follow you."

    /// Why this invite can't go, or nil when everyone on it follows you. `followers` is nil when Social
    /// couldn't be asked, which refuses rather than guesses.
    public static func refusal(inviting names: [String], followers: Set<String>?) -> String? {
        guard !names.isEmpty else { return nil }
        guard let followers else { return "Your followers couldn't be checked just now. Try again in a moment." }
        let others = names.filter { !followers.contains($0) }
        guard !others.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: others.map { "@" + $0 })
        return "\(list) \(others.count == 1 ? "doesn't" : "don't") follow you. \(line)"
    }
}

extension MessagesPeople {
    /// Followers matching what's typed, for a channel's invite field. Nothing when Social can't be asked.
    public func followerSuggestions(for token: String) async -> [ProfileSuggestion] {
        guard !token.isEmpty, let followers else { return [] }
        return (try? await followers.followers(matching: token, limit: 10)) ?? []
    }

    /// Which of these follow you, or nil when that couldn't be found out.
    public func whoFollowsMe(among names: [String]) async -> Set<String>? {
        guard let followers else { return nil }
        return try? await followers.followers(among: names)
    }

    /// Suggestions for what's typed. Nothing when the directory can't be asked, such as offline.
    public func suggestions(for token: String) async -> [ProfileSuggestion] {
        guard !token.isEmpty, let directory else { return [] }
        return (try? await directory.suggestions(matching: token, limit: 10)) ?? []
    }
}
