import Foundation


final class NewsXML: NSObject, XMLParserDelegate {
    private let source: NewsSource
    private var path: [String] = []
    private var fields: [String: String] = [:]
    private var imageURL: URL?
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
            imageURL = nil
            entryDepth = path.count
        }
        guard let depth = entryDepth, path.count > depth else { return }
        if path.count == depth + 1, name == "link",
           attributes["rel"] == nil || attributes["rel"] == "alternate", let href = attributes["href"] {
            fields["link"] = href
        }
        let qName = qualifiedName?.lowercased() ?? name.lowercased()
        if imageURL == nil {
            if qName == "media:content" || qName == "media:thumbnail" || name == "content" || name == "thumbnail",
               let raw = attributes["url"],
               let candidate = URL(string: raw, relativeTo: source.url)?.absoluteURL,
               NewsNetwork.allows(candidate) {
                let medium = attributes["medium"]?.lowercased()
                let mime = attributes["type"]?.lowercased() ?? ""
                if medium == nil || medium == "image" || mime.isEmpty || mime.hasPrefix("image/") {
                    imageURL = candidate
                }
            } else if name == "enclosure",
                      let raw = attributes["url"],
                      let mime = attributes["type"]?.lowercased(),
                      mime.hasPrefix("image/"),
                      let candidate = URL(string: raw, relativeTo: source.url)?.absoluteURL,
                      NewsNetwork.allows(candidate) {
                imageURL = candidate
            } else if qName == "itunes:image" || (name == "image" && attributes["href"] != nil),
                      let raw = attributes["href"],
                      let candidate = URL(string: raw, relativeTo: source.url)?.absoluteURL,
                      NewsNetwork.allows(candidate) {
                imageURL = candidate
            }
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
        guard ["link", "title", "summary", "description", "encoded", "content", "pubDate", "published", "updated", "date"].contains(name),
              fields[name, default: ""].count < 16_000 else { return }
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
        let resolvedImage = imageURL
            ?? Self.firstHTMLImage(in: fields["encoded"] ?? fields["content"] ?? fields["description"] ?? fields["summary"] ?? "", base: url)
        entries.append(NewsArticle(title: title, summary: summary, source: source.name, url: url, date: rawDate.flatMap(Self.date), feedURL: source.url, imageURL: resolvedImage))
    }

    private static func firstHTMLImage(in html: String, base: URL) -> URL? {
        guard !html.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"]"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, NewsNetwork.allows(url) else { return nil }
        return url
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
