import Foundation

/// Links on a public profile: up to five, https only. Checked when someone saves them, and again before
/// each one is shown or opened, because what comes from the server is never trusted. The server has its
/// own check on `profiles.links`, written to the same rules.
public enum ProfileLinks {
    public static let maximumCount = 5
    public static let maximumLength = 200

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case notHTTPS
        case tooLong
        case malformed
        case tooMany
    }

    /// Turns what was typed into the link that is saved: "example.com/me" becomes
    /// "https://example.com/me", with the host in lowercase. Anything but https is refused (javascript:,
    /// data:, http:, mailto: and the rest), as is a link with a name or password in front of the host,
    /// which is how links pretend to be somewhere else.
    public static func normalize(_ typed: String) throws -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Problem.empty }
        guard text.unicodeScalars.count <= maximumLength else { throw Problem.tooLong }
        guard !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) else {
            throw Problem.malformed
        }
        let candidate: String
        if let range = text.range(of: "://") {
            guard text[..<range.lowerBound].lowercased() == "https" else { throw Problem.notHTTPS }
            candidate = "https://" + text[range.upperBound...]
        } else if text.hasPrefix("//") {
            candidate = "https:" + text
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("."), !text[..<colon].contains("/") {
            // "javascript:...", "data:...", "mailto:...". A host with a port has a dot before its colon.
            throw Problem.notHTTPS
        } else {
            candidate = "https://" + text
        }
        guard var parts = URLComponents(string: candidate), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(), isPlainHost(host)
        else { throw Problem.malformed }
        parts.scheme = "https"
        parts.host = host
        if parts.port == 443 { parts.port = nil }
        if parts.path == "/" && parts.query == nil && parts.fragment == nil { parts.path = "" }
        guard let result = parts.string, result.unicodeScalars.count <= maximumLength else { throw Problem.tooLong }
        let refused = "<>\"\\^`{|}".unicodeScalars
        guard result.unicodeScalars.allSatisfy({ $0.isASCII && !refused.contains($0) }) else { throw Problem.malformed }
        return result
    }

    /// Normalises a whole list, in order, dropping blanks and repeats.
    public static func normalize(all typed: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in typed where !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let link = try normalize(entry)
            if seen.insert(link).inserted { result.append(link) }
        }
        guard result.count <= maximumCount else { throw Problem.tooMany }
        return result
    }

    /// What to show for links that came from the server: only the ones that pass, at most five. Nothing
    /// that fails is shown or opened.
    public static func safe(_ stored: [String]?) -> [URL] {
        (stored ?? []).prefix(maximumCount).compactMap { link in
            guard let clean = try? normalize(link), clean == link else { return nil }
            return URL(string: clean)
        }
    }

    /// The name shown on a chip: the site, without "www." and without the rest of the address.
    public static func domain(of url: URL) -> String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func message(for problem: Problem) -> String {
        switch problem {
        case .empty: return "Type a link first."
        case .notHTTPS: return "Links have to start with https://."
        case .tooLong: return "Use \(maximumLength) characters or fewer for each link."
        case .malformed: return "That doesn't look like a web address."
        case .tooMany: return "You can add up to \(maximumCount) links."
        }
    }

    private static func isPlainHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last else { return false }
        return last.contains(where: \.isLetter) && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-" }
        }
    }
}
