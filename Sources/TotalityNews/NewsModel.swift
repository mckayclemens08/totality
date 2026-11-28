import CryptoKit
import Foundation
import Observation
import TotalityCore

@MainActor
@Observable
public final class NewsModel: ModuleSearcher, ModuleRefresher, ArticleLinkProvider {
    public nonisolated let module = ModuleID.news
    public nonisolated let kinds: Set<ContentKind> = [.newsArticle]
    private(set) var record = NewsRecord()
    private(set) var discovered: [NewsArticle] = []
    private(set) var topStories: [NewsArticle] = []
    private(set) var loadingTopStories = false
    private(set) var loading = false
    private(set) var discovering = false
    private(set) var discoveryLoaded = false
    private(set) var publisherResults: [NewsSource] = []
    private(set) var searchingPublishers = false
    private(set) var publisherNotice: String?
    private var publisherSearchID = UUID()
    private(set) var notice: String?
    private(set) var discoveryNotice: String?
    private let library: NewsLibrary
    private let network: any NewsFetching
    private var lastRefresh: Date?
    private var lastTopStoriesRequest: Date?
    private var active = true

    public convenience init(library: NewsLibrary) {
        self.init(library: library, network: NewsNetwork())
    }

    init(library: NewsLibrary, network: any NewsFetching) {
        self.library = library
        self.network = network
    }

    public func load() async {
        guard active else { return }
        do {
            let loaded = try await library.read()
            if active { record = loaded }
        } catch {
            if active { notice = "Your News library couldn’t be opened." }
        }
    }

    public func close() async {
        active = false
        record = NewsRecord(sources: [])
        discovered = []
        topStories = []
        publisherResults = []
        publisherNotice = nil
        await library.close()
    }

    public func refreshAhead() async { await refresh(force: false) }

    func refresh(force: Bool = true) async {
        guard active, !loading, force || lastRefresh.map({ Date().timeIntervalSince($0) > 900 }) != false else { return }
        loading = true
        defer { loading = false }
        await load()
        let sources = record.sources
        let completed = await fetch(sources)
        guard active, !Task.isCancelled else { return }
        let failed = sources.count - completed.count
        do {
            let result = try await library.update { record in
                let refreshed = Set(record.sources.filter { completed[$0] != nil }.map(\.url))
                let fresh = record.sources.flatMap { completed[$0] ?? [] }
                let cached = record.latest.filter { article in article.feedURL.map { !refreshed.contains($0) } ?? false }
                record.latest = Self.unique(fresh + cached)
            }
            guard active else { return }
            record = result
            lastRefresh = Date()
            notice = failed == 0 ? nil : "\(failed) news source\(failed == 1 ? "" : "s") couldn’t refresh."
        } catch {
            if active { notice = "News couldn’t update the local library." }
        }
    }

    private func fetch(_ sources: [NewsSource]) async -> [NewsSource: [NewsArticle]] {
        let network = network
        var updates: [NewsSource: [NewsArticle]] = [:]
        for start in stride(from: 0, to: sources.count, by: 4) {
            guard active, !Task.isCancelled else { break }
            let end = min(start + 4, sources.count)
            let batch = await withTaskGroup(of: (NewsSource, [NewsArticle]?).self) { group in
                for source in sources[start..<end] {
                    group.addTask { (source, try? await network.feed(source)) }
                }
                var results: [NewsSource: [NewsArticle]] = [:]
                for await (source, articles) in group { results[source] = articles }
                return results
            }
            updates.merge(batch) { _, fresh in fresh }
        }
        return updates
    }

    func refreshTopStories(force: Bool = false) async {
        guard active, !loadingTopStories, !discovering,
              force || lastTopStoriesRequest.map({ Date().timeIntervalSince($0) >= 900 }) != false else { return }
        lastTopStoriesRequest = Date()
        loadingTopStories = true
        defer { loadingTopStories = false }
        do {
            let stories = try await network.discover("")
            if active && !Task.isCancelled { topStories = Array(Self.unique(stories).prefix(4)) }
        } catch {
            // Publishers' feeds remain readable when the discovery service is unavailable.
        }
    }

    func discover(_ topic: String) async {
        guard active, !discovering else { return }
        let query = String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        discovering = true
        discoveryNotice = nil
        defer { discovering = false }
        let localMatches = matchingLocalArticles(for: query)
        do {
            let articles = try await network.discover(query)
            guard active, !Task.isCancelled else { return }
            discovered = Self.unique(articles + localMatches)
            discoveryLoaded = true
        } catch NewsError.rateLimited {
            if active {
                if !localMatches.isEmpty {
                    discovered = localMatches
                    discoveryLoaded = true
                    discoveryNotice = "Showing matching stories from your library — GDELT is busy right now."
                } else {
                    discoveryNotice = "GDELT is busy. Wait a moment, then search again."
                }
            }
        } catch {
            if active, !Task.isCancelled {
                if !localMatches.isEmpty {
                    discovered = localMatches
                    discoveryLoaded = true
                    discoveryNotice = "Showing matching stories from your library."
                } else {
                    discoveryNotice = "GDELT couldn’t load this topic. Try again."
                }
            }
        }
    }

    private func matchingLocalArticles(for query: String) -> [NewsArticle] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return [] }
        return Self.unique((record.latest + record.saved + topStories).filter { article in
            let haystack = "\(article.title) \(article.source) \(article.summary)"
            return terms.allSatisfy { SearchText.find($0, in: haystack) != nil }
        })
    }

    func clearPublisherSearch() {
        publisherSearchID = UUID()
        publisherNotice = nil
        publisherResults = []
        searchingPublishers = false
    }

    func searchPublishers(_ text: String) async {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        clearPublisherSearch()
        let requestID = publisherSearchID
        guard active, !query.isEmpty else { return }
        if let publisher = NewsSource.publisher(query) {
            publisherResults = [publisher]
            return
        }
        searchingPublishers = true
        defer { if publisherSearchID == requestID { searchingPublishers = false } }
        do {
            let matches = try await network.publishers(matching: query)
            if active, publisherSearchID == requestID, !Task.isCancelled { publisherResults = matches }
        } catch {
            if active, publisherSearchID == requestID, !Task.isCancelled {
                publisherNotice = "Publisher search is unavailable. Try the publisher’s website."
            }
        }
    }

    func follow(_ source: NewsSource) async {
        guard NewsSource.catalog.contains(source) || (source.indexedPublisher == true && NewsSource.publisher(source.url.absoluteString) != nil) else { return }
        await change { record in
            if !record.sources.contains(where: { $0.url == source.url }) {
                record.sources.append(source)
            }
        }
        guard active, record.sources.contains(where: { $0.url == source.url }) else { return }
        do {
            let headlines = try await network.feed(source)
            guard active, !Task.isCancelled else { return }
            await change { record in
                guard record.sources.contains(where: { $0.url == source.url }) else { return }
                record.latest = Self.unique(headlines + record.latest)
            }
        } catch {
            if active, !Task.isCancelled { notice = "You’re following " + source.name + ". Its headlines couldn’t load yet." }
        }
    }

    func source(for article: NewsArticle) -> NewsSource? {
        let publishers = record.sources + NewsSource.catalog
        if let feedURL = article.feedURL, let followed = publishers.first(where: { $0.url == feedURL }) {
            return followed
        }
        guard let publisher = NewsSource.publisher(article.url.absoluteString, name: article.source) else { return nil }
        return publishers.first { NewsSource.publisher($0.url.absoluteString)?.url == publisher.url } ?? publisher
    }

    func remove(_ source: NewsSource) async {
        await change { record in
            record.sources.removeAll { $0.url == source.url }
            record.latest.removeAll { $0.feedURL == source.url }
        }
    }

    func toggleSaved(_ article: NewsArticle) async {
        await change { record in
            if record.saved.contains(where: { $0.url == article.url }) {
                record.saved.removeAll { $0.url == article.url }
            } else {
                record.saved.insert(article, at: 0)
            }
        }
    }

    private func change(_ update: @Sendable (inout NewsRecord) -> Void) async {
        guard active else { return }
        do {
            let result = try await library.update(update)
            if active { record = result; notice = nil }
        } catch {
            if active { notice = "Your News changes couldn’t be saved." }
        }
    }

    private nonisolated static func unique(_ articles: [NewsArticle]) -> [NewsArticle] {
        var seen = Set<URL>()
        let ordered = articles.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Array(ordered.filter { seen.insert($0.url).inserted }.prefix(500))
    }

    func reference(_ article: NewsArticle) -> ContentRef {
        let hash = Array(SHA256.hash(data: Data(article.url.absoluteString.utf8)).prefix(16))
        let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                             hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        return ContentRef(module: .news, kind: .newsArticle, id: id, keyRef: .plain, preview: .init(title: article.title))
    }

    public func articleURL(for ref: ContentRef) async -> URL? {
        guard active, ref.module == module, ref.kind == .newsArticle else { return nil }
        return articles.first(where: { reference($0).id == ref.id })?.url
    }

    var todayStories: [NewsArticle] {
        var seen = Set<URL>()
        let unique = (topStories + record.latest).filter { seen.insert($0.url).inserted }
        var publishers = Set<String>()
        var first: [NewsArticle] = []
        var rest: [NewsArticle] = []
        for article in unique {
            if publishers.insert(article.source.lowercased()).inserted {
                first.append(article)
            } else {
                rest.append(article)
            }
        }
        return first + rest
    }

    private var articles: [NewsArticle] { record.saved + todayStories + discovered }

    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard active, !terms.isEmpty else { return [] }
        var seen = Set<URL>()
        return articles.filter { article in
            terms.allSatisfy { SearchText.find($0, in: article.title + " " + article.source) != nil }
                && seen.insert(article.url).inserted
        }.prefix(30).map { article in
            SearchHit(module: .news, itemID: reference(article).id.uuidString, title: article.title, detail: article.source)
        }
    }
}
