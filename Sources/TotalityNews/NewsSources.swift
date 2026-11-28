import Foundation

struct NewsSource: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }
    var indexedPublisher: Bool? = nil

    static func publisher(_ input: String, name: String? = nil) -> NewsSource? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace),
              let website = URL(string: text.contains("://") ? text : "https://" + text),
              NewsNetwork.allowsFeed(website),
              let host = website.host?.lowercased(),
              host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
        else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let localSuffixes = [".local", ".internal", ".localhost", ".test", ".invalid", ".example", ".onion"]
        guard !localSuffixes.contains(where: domain.hasSuffix), let url = URL(string: "https://" + domain) else { return nil }
        return NewsSource(name: name ?? domain, url: url, indexedPublisher: true)
    }

    static let defaults = [
        NewsSource(name: "NASA News Releases", url: URL(string: "https://www.nasa.gov/news-release/feed/")!),
        NewsSource(name: "USGS Earthquakes", url: URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_week.atom")!),
        NewsSource(name: "Idaho Weather Alerts", url: URL(string: "https://api.weather.gov/alerts/active?area=ID")!),
    ]

    static let catalog = defaults + [
        NewsSource(name: "Federal Reserve", url: URL(string: "https://www.federalreserve.gov/feeds/press_all.xml")!),
        NewsSource(name: "U.S. Census Bureau", url: URL(string: "https://www.census.gov/content/census/en/newsroom/press-releases.xml")!),
    ]
}

struct NewsArticle: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let summary: String
    let source: String
    let url: URL
    let date: Date?
    var id: URL { url }
    var feedURL: URL? = nil
    var throughGDELT: Bool? = nil
    var imageURL: URL? = nil
}

enum NewsError: Error {
    case invalidAddress, badResponse, invalidFeed
    case rateLimited
}

protocol NewsFetching: Sendable {
    func feed(_ source: NewsSource) async throws -> [NewsArticle]
    func discover(_ topic: String) async throws -> [NewsArticle]
    func publishers(matching query: String) async throws -> [NewsSource]
}

extension NewsFetching {
    func publishers(matching query: String) async throws -> [NewsSource] { [] }
}

struct NewsNetwork: NewsFetching {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NewsRedirects(), delegateQueue: nil)
    }()

    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    static func allowsFeed(_ url: URL) -> Bool {
        guard allows(url), let host = url.host?.lowercased() else { return false }
        let excluded = ["newsapi.org", "gnews.io", "news.google.com", "reddit.com", "api.nytimes.com", "content.guardianapis.com"]
        let canonicalHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        return !excluded.contains { canonicalHost == $0 || canonicalHost.hasSuffix("." + $0) }
    }

    private func download(_ url: URL, accept: String) async throws -> Data {
        guard Self.allowsFeed(url) else { throw NewsError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("TotalityNews/1.0 (https://usetotality.com/)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await Self.session.bytes(for: request)
        let limit = 2 * 1024 * 1024
        guard let http = response as? HTTPURLResponse else { throw NewsError.badResponse }
        if http.statusCode == 429 { throw NewsError.rateLimited }
        guard 200..<300 ~= http.statusCode, http.expectedContentLength <= limit else { throw NewsError.badResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw NewsError.badResponse }
            data.append(byte)
        }
        return data
    }

    func feed(_ source: NewsSource) async throws -> [NewsArticle] {
        if source.indexedPublisher == true {
            guard let publisher = NewsSource.publisher(source.url.absoluteString), let domain = publisher.url.host
            else { throw NewsError.invalidAddress }
            if let articles = try? await publicPublisherFeed(source) { return articles }
            let stories = try await discover("(domainis:" + domain + " OR domainis:www." + domain + ")")
            return stories.filter { NewsSource.publisher($0.url.absoluteString)?.url == publisher.url }.map {
                NewsArticle(title: $0.title, summary: "", source: source.name, url: $0.url, date: $0.date, feedURL: source.url, throughGDELT: true, imageURL: $0.imageURL)
            }
        }
        let data = try await download(source.url, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml")
        return try NewsXML.read(data, source: source)
    }

    private static let knownRSSFeeds: [String: URL] = [
        "nytimes.com": URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")!,
        "bbc.com": URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!,
        "bbc.co.uk": URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!,
        "npr.org": URL(string: "https://feeds.npr.org/1001/rss.xml")!,
        "theguardian.com": URL(string: "https://www.theguardian.com/world/rss")!,
        "arstechnica.com": URL(string: "https://feeds.arstechnica.com/arstechnica/index")!,
        "theverge.com": URL(string: "https://www.theverge.com/rss/index.xml")!,
        "propublica.org": URL(string: "https://www.propublica.org/feeds/propublica/main")!,
        "reuters.com": URL(string: "https://www.reuters.com/rssFeed/worldNews")!,
        "apnews.com": URL(string: "https://apnews.com/index.rss")!,
    ]

    static func isSamePublisherSite(_ candidate: URL, as publisher: NewsSource) -> Bool {
        guard let candidateHost = candidate.host?.lowercased(),
              let baseHost = publisher.url.host?.lowercased() else { return false }
        let normalizedCandidate = candidateHost.hasPrefix("www.") ? String(candidateHost.dropFirst(4)) : candidateHost
        let normalizedBase = baseHost.hasPrefix("www.") ? String(baseHost.dropFirst(4)) : baseHost
        return normalizedCandidate == normalizedBase || normalizedCandidate.hasSuffix("." + normalizedBase)
            || (normalizedBase == "bbc.com" && normalizedCandidate.hasSuffix(".bbci.co.uk"))
    }

    private func publicPublisherFeed(_ publisher: NewsSource) async throws -> [NewsArticle] {
        let baseHost = publisher.url.host?.lowercased() ?? ""
        if let known = Self.knownRSSFeeds[baseHost],
           let data = try? await download(known, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml"),
           let articles = try? NewsXML.read(data, source: NewsSource(name: publisher.name, url: known)),
           !articles.isEmpty {
            return articles.map {
                NewsArticle(title: $0.title, summary: "", source: publisher.name, url: $0.url, date: $0.date, feedURL: publisher.url, imageURL: $0.imageURL)
            }
        }
        if let page = try? await download(publisher.url, accept: "text/html") {
            let html = String(decoding: page, as: UTF8.self)
            let pattern = try NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive)
            let links = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for link in links {
                guard let range = Range(link.range, in: html) else { continue }
                let tag = String(html[range])
                guard tag.range(of: #"application/(rss|atom)\+xml"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      let href = tag.range(of: #"(?i)\bhref\s*=\s*['"][^'"]+['"]"#, options: .regularExpression),
                      let quote = tag[href].firstIndex(where: { $0.asciiValue == 34 || $0.asciiValue == 39 })
                else { continue }
                let relative = String(tag[tag.index(after: quote)..<tag.index(before: href.upperBound)])
                    .replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: relative, relativeTo: publisher.url)?.absoluteURL,
                      Self.isSamePublisherSite(url, as: publisher) else { continue }
                if let data = try? await download(url, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml"),
                   let articles = try? NewsXML.read(data, source: NewsSource(name: publisher.name, url: url)),
                   !articles.isEmpty {
                    // Keep the publisher as the stable follow identifier and show links, titles, and thumbnails.
                    return articles.map {
                        NewsArticle(title: $0.title, summary: "", source: publisher.name, url: $0.url, date: $0.date, feedURL: publisher.url, imageURL: $0.imageURL)
                    }
                }
            }
        }
        for path in ["/rss", "/rss.xml", "/feed", "/feed.xml", "/atom.xml"] {
            if let fallbackURL = URL(string: path, relativeTo: publisher.url)?.absoluteURL,
               let data = try? await download(fallbackURL, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml"),
               let articles = try? NewsXML.read(data, source: NewsSource(name: publisher.name, url: fallbackURL)),
               !articles.isEmpty {
                return articles.map {
                    NewsArticle(title: $0.title, summary: "", source: publisher.name, url: $0.url, date: $0.date, feedURL: publisher.url, imageURL: $0.imageURL)
                }
            }
        }
        throw NewsError.invalidFeed
    }

    func discover(_ topic: String) async throws -> [NewsArticle] {
        var url = URLComponents(string: "https://api.gdeltproject.org/api/v2/doc/doc")!
        url.queryItems = [
            URLQueryItem(name: "query", value: topic.isEmpty ? "sourcelang:english (world OR government OR economy)" : topic),
            URLQueryItem(name: "mode", value: "artlist"),
            URLQueryItem(name: "maxrecords", value: "30"),
            URLQueryItem(name: "timespan", value: "3d"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let endpoint = url.url!
        do {
            let data = try await download(endpoint, accept: "application/json")
            return try Self.discoveryArticles(data)
        } catch NewsError.rateLimited {
            try await Task.sleep(for: .milliseconds(1200))
            let data = try await download(endpoint, accept: "application/json")
            return try Self.discoveryArticles(data)
        }
    }

    func publishers(matching query: String) async throws -> [NewsSource] {
        struct Matches: Decodable {
            struct Item: Decodable { let id: String; let label: String }
            let search: [Item]
        }
        struct Entities: Decodable {
            struct Entity: Decodable {
                struct Claim: Decodable {
                    struct Snak: Decodable {
                        struct Value: Decodable { let value: String }
                        let datavalue: Value?
                    }
                    let mainsnak: Snak
                }
                struct Claims: Decodable {
                    let websites: [Claim]?
                    enum CodingKeys: String, CodingKey { case websites = "P856" }
                }
                let claims: Claims?
            }
            let entities: [String: Entity]
        }
        func request(_ parameters: [String: String]) async throws -> Data {
            var endpoint = URLComponents(string: "https://www.wikidata.org/w/api.php")!
            endpoint.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
                + [URLQueryItem(name: "format", value: "json")]
            return try await download(endpoint.url!, accept: "application/json")
        }
        let data = try await request(["action": "wbsearchentities", "language": "en", "search": query, "limit": "8"])
        let matches = try JSONDecoder().decode(Matches.self, from: data).search
        guard !matches.isEmpty else { return [] }
        let details = try await request(["action": "wbgetentities", "ids": matches.map(\.id).joined(separator: "|"),
                                         "props": "claims", "languages": "en"])
        let entries = try JSONDecoder().decode(Entities.self, from: details).entities
        var seen = Set<URL>()
        return matches.compactMap { match in
            let websites = entries[match.id]?.claims?.websites ?? []
            return websites.lazy.compactMap { claim in
                claim.mainsnak.datavalue.flatMap { NewsSource.publisher($0.value, name: match.label) }
            }.first
        }.filter { seen.insert($0.url).inserted }
    }

    static func discoveryArticles(_ data: Data) throws -> [NewsArticle] {
        struct Response: Decodable {
            struct Article: Decodable {
                let title: String
                let url: URL
                let domain: String?
                let seendate: String?
                let socialimage: String?
            }
            let articles: [Article]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return (response.articles ?? []).compactMap { item in
            guard Self.allows(item.url), !item.title.isEmpty else { return nil }
            let imageURL = item.socialimage.flatMap(URL.init(string:)).flatMap { Self.allows($0) ? $0 : nil }
            return NewsArticle(title: String(item.title.prefix(500)), summary: "", source: item.domain ?? item.url.host ?? "GDELT",
                               url: item.url, date: item.seendate.flatMap(format.date(from:)), throughGDELT: true, imageURL: imageURL)
        }
    }
}

private final class NewsRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(NewsNetwork.allowsFeed) == true ? request : nil)
    }
}
