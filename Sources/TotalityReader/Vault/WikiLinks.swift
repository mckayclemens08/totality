import Foundation

/// Links between docs, written `[[Title]]`, `[[Title|words]]`, `[[Title#Heading]]` or `[[#Heading]]`, the
/// form Pandoc reads with `wikilinks_title_after_pipe`. A link names a title, never an ID, so the text
/// stays plain. These rules match the writing page's (`web/reader-editor/src/wiki.js`).
public enum WikiLinks {
    public struct Link: Equatable, Sendable {
        /// Empty for a heading in the same doc.
        public let target: String
        public let heading: String
        public let alias: String

        /// What the link reads as.
        public var words: String {
            if !alias.isEmpty { return alias }
            return target.isEmpty ? heading : target
        }
    }

    /// Another doc's link to this one, with the words around the first such link.
    public struct Backlink: Equatable, Sendable, Identifiable {
        public let item: ReaderItem
        public let snippet: String
        public let count: Int

        public var id: UUID { item.id }
    }

    static let maxTitle = 200
    /// Each part is checked again after trimming, and a part longer than a title isn't a link.
    /// Made each time, because a regex can't be shared between threads.
    private static var pattern: Regex<(Substring, Substring, Substring?, Substring?)> {
        /\[\[([^\[\]|#\n]*)(?:#([^\[\]|\n]*))?(?:\|([^\[\]\n]*))?\]\]/
    }

    /// Titles match whatever their case or spacing.
    public static func titleKey(_ title: String) -> String {
        title.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    /// Whether a title can go inside `[[ ]]` as it is.
    public static func linkable(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && title.count <= maxTitle
            && !title.contains(where: { "[]|#\n".contains($0) })
    }

    private static func link(_ match: Regex<(Substring, Substring, Substring?, Substring?)>.Match) -> Link? {
        let target = match.1.trimmingCharacters(in: .whitespaces)
        let heading = (match.2 ?? "").trimmingCharacters(in: .whitespaces)
        let alias = (match.3 ?? "").trimmingCharacters(in: .whitespaces)
        guard !(target.isEmpty && heading.isEmpty), target.count <= maxTitle, heading.count <= maxTitle else { return nil }
        return Link(target: target, heading: heading, alias: alias)
    }

    /// Every link in a doc, in order, leaving out code blocks and code spans.
    public static func links(in markdown: String) -> [Link] {
        guard markdown.contains("[[") else { return [] }
        return lines(markdown).flatMap { line in line.matches(of: pattern).compactMap(link) }
    }

    /// The lines a link can be on, with code spans blanked out.
    private static func lines(_ markdown: String) -> [String] {
        var found: [String] = []
        var fence: String?
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if let marker = trimmed.firstMatch(of: /^(`{3,}|~{3,})/) {
                fence = String(marker.1)
                continue
            }
            guard line.contains("[[") else { continue }
            found.append(line.replacing(/`+[^`]*`+/, with: ""))
        }
        return found
    }

    /// The text with each link replaced by the words it reads as, for Listen and search.
    public static func readable(_ text: String) -> String {
        text.replacing(pattern) { match in link(match)?.words ?? String(match.0) }
    }

    /// The doc a link names. Two docs can share a title, so one in the same folder wins, then the newest.
    public static func resolve(_ target: String, in items: [ReaderItem], near folder: UUID?) -> ReaderItem? {
        let key = titleKey(target)
        guard !key.isEmpty else { return nil }
        return items
            .filter { $0.kind == .note && !$0.title.isEmpty && titleKey($0.title) == key }
            .max { a, b in
                let near = (a.folderID == folder, b.folderID == folder)
                if near.0 != near.1 { return !near.0 }
                return a.updatedAt < b.updatedAt
            }
    }

    /// The first line holding a link, as it reads, shortened around the link.
    static func snippet(_ markdown: String, where matches: (Link) -> Bool) -> String {
        for line in lines(markdown) where line.matches(of: pattern).compactMap(link).contains(where: matches) {
            let words = MarkdownText.inline(line.replacing(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)/, with: ""))
            return words.count > 160 ? String(words.prefix(157)) + "…" : words
        }
        return ""
    }
}
