import Foundation

/// One thing a search found. `itemID` means something only to the module that found it, which is
/// also the module that opens it.
public struct SearchHit: Identifiable, Sendable, Hashable {
    public let module: ModuleID
    public let itemID: String
    public let title: String
    /// The quiet line under the title, like a date.
    public let detail: String?
    /// The words around a match that isn't in the title.
    public let snippet: String?
    public let date: Date?

    public init(module: ModuleID, itemID: String, title: String, detail: String? = nil, snippet: String? = nil, date: Date? = nil) {
        self.module = module
        self.itemID = itemID
        self.title = title
        self.detail = detail
        self.snippet = snippet
        self.date = date
    }

    public var id: String { "\(module.rawValue)-\(itemID)" }
}

/// A module whose content can be searched. Searching happens on the device, because a server can't
/// read private content. Nothing a searcher is given may be stored or sent.
public protocol ModuleSearcher: ContentHandler {
    func search(_ query: String) async throws -> [SearchHit]
}

public struct SearchResults: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let module: ModuleID
        public let hits: [SearchHit]

        public var id: ModuleID { module }
    }

    public var groups: [Group] = []
    /// Modules that couldn't be searched, so the screen can say what's missing.
    public var failed: [ModuleID] = []

    public init(groups: [Group] = [], failed: [ModuleID] = []) {
        self.groups = groups
        self.failed = failed
    }
}

/// Asks every module at once. One that fails doesn't stop the others.
public struct UniversalSearch: Sendable {
    private let searchers: [any ModuleSearcher]

    public init(searchers: [any ModuleSearcher]) {
        self.searchers = searchers
    }

    /// Everything, once every module has answered.
    public func run(_ query: String) async -> SearchResults {
        var last = SearchResults()
        for await results in stream(query) { last = results }
        return last
    }

    /// The results so far, again each time a module answers, so a slow one, like Google Drive's search,
    /// doesn't hold up the rest. Two searchers for one module, like the Reader's library and its Drive
    /// folders, share one group, in the order they're listed, each result once.
    public func stream(_ query: String) -> AsyncStream<SearchResults> {
        AsyncStream { continuation in
            guard !SearchText.terms(in: query).isEmpty else {
                continuation.yield(SearchResults())
                continuation.finish()
                return
            }
            let searchers = searchers
            let work = Task {
                await withTaskGroup(of: (Int, [SearchHit]?).self) { group in
                    for (index, searcher) in searchers.enumerated() {
                        group.addTask { (index, try? await searcher.search(query)) }
                    }
                    var answers = [Int: [SearchHit]?]()
                    for await (index, hits) in group {
                        answers[index] = hits
                        continuation.yield(Self.assemble(answers, from: searchers))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func assemble(_ answers: [Int: [SearchHit]?], from searchers: [any ModuleSearcher]) -> SearchResults {
        var results = SearchResults()
        var seen = Set<String>()
        for (index, searcher) in searchers.enumerated() {
            guard let answer = answers[index] else { continue }
            guard let hits = answer else {
                if !results.failed.contains(searcher.module) { results.failed.append(searcher.module) }
                continue
            }
            let fresh = hits.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            if let at = results.groups.firstIndex(where: { $0.module == searcher.module }) {
                results.groups[at] = .init(module: searcher.module, hits: results.groups[at].hits + fresh)
            } else {
                results.groups.append(.init(module: searcher.module, hits: fresh))
            }
        }
        return results
    }
}

/// How every module matches words, so a search means the same thing everywhere: every word has to
/// appear, in any order, ignoring case and accents.
public enum SearchText {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let radius = 60

    public static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func find(_ term: String, in text: String) -> Range<String.Index>? {
        text.range(of: term, options: options)
    }

    /// Everywhere the terms appear, for highlighting.
    public static func matches(of terms: [String], in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms {
            var start = text.startIndex
            while start < text.endIndex, let match = text.range(of: term, options: options, range: start..<text.endIndex) {
                found.append(match)
                start = match.upperBound
            }
        }
        return found
    }

    /// The words around a match, on one line.
    public static func excerpt(of text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let words = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + words + (end < text.endIndex ? "…" : "")
    }
}
