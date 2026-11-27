import Foundation

struct NewsSource: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }

    static let defaults = [
        NewsSource(name: "NASA News Releases", url: URL(string: "https://www.nasa.gov/news-release/feed/")!),
        NewsSource(name: "USGS Earthquakes", url: URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_week.atom")!),
        NewsSource(name: "Idaho Weather Alerts", url: URL(string: "https://api.weather.gov/alerts/active?area=ID")!),
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
}

enum NewsError: Error {
    case invalidAddress, badResponse, invalidFeed
    case rateLimited
}

protocol NewsFetching: Sendable {
    func feed(_ source: NewsSource) async throws -> [NewsArticle]
    func discover(_ topic: String) async throws -> [NewsArticle]
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
        request.setValue("Totality News RSS Reader", forHTTPHeaderField: "User-Agent")
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
        let data = try await download(source.url, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml")
        return try NewsXML.read(data, source: source)
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
        let data = try await download(url.url!, accept: "application/json")
        return try Self.discoveryArticles(data)
    }

    static func discoveryArticles(_ data: Data) throws -> [NewsArticle] {
        struct Response: Decodable {
            struct Article: Decodable {
                let title: String
                let url: URL
                let domain: String?
                let seendate: String?
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
            return NewsArticle(title: String(item.title.prefix(500)), summary: "", source: item.domain ?? item.url.host ?? "GDELT",
                               url: item.url, date: item.seendate.flatMap(format.date(from:)))
        }
    }
}

private final class NewsRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(NewsNetwork.allowsFeed) == true ? request : nil)
    }
}
