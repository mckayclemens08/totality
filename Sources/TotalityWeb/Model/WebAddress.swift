import Foundation

/// What the one box at the top was given.
public enum WebInput: Equatable, Sendable {
    case address(URL)
    case search(String)
}

public enum WebAddress {
    /// Only these open as pages. Anything else typed with a colon, like `javascript:`, is a search, so
    /// the box can never run something.
    private static let schemes: Set<String> = ["http", "https"]

    public static func parse(_ typed: String) -> WebInput? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !text.contains(where: \.isWhitespace) else { return .search(text) }
        if let scheme = text.firstRange(of: "://").map({ text[..<$0.lowerBound].lowercased() }) {
            guard schemes.contains(scheme), let url = URL(string: text), url.host() != nil else { return .search(text) }
            return .address(url)
        }
        guard looksLikeHost(text), let url = URL(string: "https://\(text)"), url.host() != nil else { return .search(text) }
        return .address(url)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let name = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard name.count == 1 || (name.count == 2 && Int(name[1]) != nil) else { return false }
        if name[0] == "localhost" { return true }
        let labels = name[0].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        guard let last = labels.last else { return false }
        return last.count >= 2 && last.allSatisfy(\.isLetter)
    }

    /// The same search on DuckDuckGo's own site, for when the server can't answer.
    public static func publicSearch(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://duckduckgo.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts?.url
    }
}
