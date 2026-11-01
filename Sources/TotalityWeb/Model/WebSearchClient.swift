import Foundation

public enum WebCategory: String, CaseIterable, Sendable, Identifiable {
    case web, images, news, videos

    public var id: Self { self }

    public var label: String {
        switch self {
        case .web: "Web"
        case .images: "Images"
        case .news: "News"
        case .videos: "Videos"
        }
    }
}

public enum SafeSearch: Int, CaseIterable, Sendable, Identifiable {
    case off, moderate, strict

    public static let key = "web.safeSearch"

    public var id: Self { self }

    public var label: String {
        switch self {
        case .off: "Off"
        case .moderate: "Moderate"
        case .strict: "Strict"
        }
    }
}

/// A thumbnail the gateway handed out. It comes through the server, so image sites don't see this device.
public struct WebThumbnail: Codable, Equatable, Hashable, Sendable {
    public let url: String
    public let signature: String

    public init(url: String, signature: String) {
        self.url = url
        self.signature = signature
    }
}

public struct WebResult: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let title: String
    public let url: URL
    public let site: String
    public let snippet: String
    public let thumbnail: WebThumbnail?

    public var id: URL { url }

    public init(title: String, url: URL, site: String, snippet: String, thumbnail: WebThumbnail? = nil) {
        self.title = title
        self.url = url
        self.site = site
        self.snippet = snippet
        self.thumbnail = thumbnail
    }
}

public struct WebResults: Codable, Equatable, Sendable {
    public let results: [WebResult]
    /// An engine stopped answering, so there may be less here than usual.
    public let partial: Bool

    public init(results: [WebResult], partial: Bool = false) {
        self.results = results
        self.partial = partial
    }
}

public enum WebSearchError: Error, Equatable, Sendable {
    case signedOut, limitReached, offline, unavailable
}

/// Talks to the gateway on your server. Searches go in the body of a POST, so they're never part of an
/// address, and nothing is cached or kept here.
public struct WebSearchClient: Sendable {
    public static let server = URL(string: "https://usetotality.com")!

    private let server: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(server: URL = WebSearchClient.server, session: URLSession? = nil, token: @escaping @Sendable () async throws -> String) {
        self.server = server
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    public func search(_ query: String, category: WebCategory, page: Int, safety: SafeSearch) async throws -> WebResults {
        struct Body: Encodable {
            let query: String
            let category: String
            let page: Int
            let safety: Int
        }
        let body = Body(query: query, category: category.rawValue, page: page, safety: safety.rawValue)
        let data = try await post("web/search", body: try JSONEncoder().encode(body))
        do {
            return try JSONDecoder().decode(WebResults.self, from: data)
        } catch {
            throw WebSearchError.unavailable
        }
    }

    public func image(_ thumbnail: WebThumbnail) async throws -> Data {
        try await post("web/image", body: try JSONEncoder().encode(thumbnail))
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        let bearer: String
        do {
            bearer = try await token()
        } catch {
            throw WebSearchError.signedOut
        }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offline.contains(error.code) {
            throw WebSearchError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw WebSearchError.unavailable
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 401: throw WebSearchError.signedOut
        case 429: throw WebSearchError.limitReached
        default: throw WebSearchError.unavailable
        }
    }

    private static let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]
}
