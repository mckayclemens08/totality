import Foundation


final class NewsXML: NSObject, XMLParserDelegate {
    private let source: NewsSource
    private var path: [String] = []
    private var fields: [String: String] = [:]
    private var entries: [NewsArticle] = []
    private var isFeed = false
    private var entryDepth: Int?

    private init(source: NewsSource) { self.source = source }

    static func read(_ data: Data, source: NewsSource) throws -> [NewsArticle] {
        let reader = NewsXML(source: source)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), reader.isFeed else { throw NewsError.invalidFeed }
        return reader.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard path.count < 64 else { parser.abortParsing(); return }
        path.append(name)
        if path.count == 1 { isFeed = ["rss", "feed", "RDF"].contains(name) }
        if entryDepth == nil, (name == "item" || name == "entry"), path.count <= 3 {
            fields = [:]
            entryDepth = path.count
        }
        if let depth = entryDepth, path.count == depth + 1, name == "link",
           attributes["rel"] == nil || attributes["rel"] == "alternate", let href = attributes["href"] {
            fields["link"] = href
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if let string = String(data: block, encoding: .utf8) { append(string) }
    }

    private func append(_ string: String) {
        guard let depth = entryDepth, path.count > depth else { return }
        let name = path[depth]
        guard ["link", "title", "summary", "description", "pubDate", "published", "updated", "date"].contains(name),
              fields[name, default: ""].count < 8_000 else { return }
        fields[name, default: ""].append(contentsOf: string.prefix(8_000))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = path.popLast() }
        guard entryDepth == path.count else { return }
        entryDepth = nil
        guard entries.count < 100, let link = fields["link"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty, let url = URL(string: link, relativeTo: source.url)?.absoluteURL, NewsNetwork.allows(url)
        else { return }
        let title = Self.text(fields["title"] ?? "", limit: 500)
        guard !title.isEmpty else { return }
        let summary = Self.text(fields["summary"] ?? fields["description"] ?? "", limit: 800)
        let rawDate = fields["published"] ?? fields["pubDate"] ?? fields["updated"] ?? fields["date"]
        entries.append(NewsArticle(title: title, summary: summary, source: source.name, url: url, date: rawDate.flatMap(Self.date), feedURL: source.url))
    }

    private static func text(_ input: String, limit: Int) -> String {
        let plain = input.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return String(plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    private static func date(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return format.date(from: value)
    }
}
