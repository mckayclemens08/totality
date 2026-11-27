import Foundation
import Testing
import TotalityCore
@testable import TotalityNews

struct NewsTests {
    @Test func readsRSSAndAtom() throws {
        let source = NewsSource.defaults[0]
        let rss = #"<rss version="2.0"><channel><item><title>NASA’s Artemis II mission</title><description><![CDATA[<p>Four astronauts will fly around the Moon.</p>]]></description><link>https://www.nasa.gov/mission/artemis-ii/</link><pubDate>Fri, 27 Nov 2026 12:00:00 +0000</pubDate></item></channel></rss>"#
        let atom = #"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>NASA’s Artemis II mission</title><link rel="alternate" href="/mission/artemis-ii/"/><updated>2026-11-27T12:00:00Z</updated></entry></feed>"#
        let first = try #require(NewsXML.read(Data(rss.utf8), source: source).first)
        let second = try #require(NewsXML.read(Data(atom.utf8), source: source).first)
        #expect(first.url == second.url)
        #expect(first.date == second.date)
        #expect(first.summary == "Four astronauts will fly around the Moon.")
        #expect(first.feedURL == source.url)
    }

    @Test func discoveryShowsPublisherMetadataAndNoArticleBody() throws {
        let json = #"{"articles":[{"title":"NASA’s Artemis II mission","url":"https://www.nasa.gov/mission/artemis-ii/","domain":"nasa.gov","seendate":"20261127T120000Z","body":"Publisher article"}]}"#
        let story = try #require(NewsNetwork.discoveryArticles(Data(json.utf8)).first)
        #expect(story.source == "nasa.gov")
        #expect(story.summary.isEmpty)
        #expect(story.date != nil)
    }

    @Test func discardsUnsafeLinks() throws {
        #expect(!NewsNetwork.allowsFeed(URL(string: "https://news.google.com/rss")!))
        #expect(!NewsNetwork.allowsFeed(URL(string: "https://api.reddit.com/r/Boise/.rss")!))
        #expect(NewsNetwork.allowsFeed(URL(string: "https://www.nasa.gov/news-release/feed/")!))
        let feed = "<rss><channel><item><title>Idaho weather alerts</title><link>javascript:alert(1)</link></item></channel></rss>"
        #expect(try NewsXML.read(Data(feed.utf8), source: NewsSource.defaults[2]).isEmpty)
        #expect(throws: NewsError.self) {
            try NewsXML.read(Data("<html/>".utf8), source: NewsSource.defaults[2])
        }
    }
}

struct NewsTwoUserTests {
    @Test func readingListStaysSealedAndAccountScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try FileBlobStore(directory: directory.appendingPathComponent("first"))
        let secondStore = try FileBlobStore(directory: directory.appendingPathComponent("second"))
        let firstKey = try ContentRootKey.generate()
        let secondKey = try ContentRootKey.generate()
        let first = NewsLibrary(store: firstStore, rootKey: firstKey)
        let second = NewsLibrary(store: secondStore, rootKey: secondKey)
        let url = URL(string: "https://www.nasa.gov/mission/artemis-ii/")!
        let article = NewsArticle(title: "NASA’s Artemis II mission", summary: "A flight around the Moon.",
                                  source: "NASA", url: url, date: nil)
        _ = try await first.update { $0.saved = [article] }
        #expect(try await first.read().saved == [article])
        #expect(try await second.read().saved.isEmpty)
        let blob = try #require(try firstStore.names().first)
        let data = try #require(try firstStore.read(blob))
        #expect(data.range(of: Data(url.absoluteString.utf8)) == nil)
        let wrongKey = NewsLibrary(store: firstStore, rootKey: secondKey)
        await #expect(throws: (any Error).self) { try await wrongKey.read() }
        await first.close()
        await #expect(throws: CancellationError.self) { try await first.update { $0.saved = [] } }
    }
}

private actor TestNewsNetwork: NewsFetching {
    private var failed = false

    func fail() { failed = true }

    func publishers(matching query: String) async throws -> [NewsSource] {
        guard let source = NewsSource.publisher("propublica.org", name: query) else { return [] }
        return [source]
    }

    func feed(_ source: NewsSource) async throws -> [NewsArticle] {
        guard !failed, source == NewsSource.defaults[0] else { throw NewsError.badResponse }
        return [NewsArticle(title: "NASA’s Artemis II mission", summary: "Four astronauts fly around the Moon.",
                            source: source.name, url: URL(string: "https://www.nasa.gov/mission/artemis-ii/")!,
                            date: Date(timeIntervalSince1970: 1_750_000_000), feedURL: source.url)]
    }

    func discover(_ topic: String) async throws -> [NewsArticle] {
        if failed { throw NewsError.rateLimited }
        let headline = topic.isEmpty ? "Artemis II mission" : "Idaho weather alerts"
        let address = topic.isEmpty ? "https://www.nasa.gov/mission/artemis-ii/" : "https://www.weather.gov/boi/"
        return [NewsArticle(title: headline, summary: "", source: "GDELT", url: URL(string: address)!, date: nil)]
    }
}

extension NewsTests {
    @MainActor
    @Test func followsAndUnfollowsAPublisherByName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileBlobStore(directory: directory)
        let key = try ContentRootKey.generate()
        let library = NewsLibrary(store: store, rootKey: key)
        let model = NewsModel(library: library, network: TestNewsNetwork())
        let publisher = try #require(NewsSource.catalog.first { !NewsSource.defaults.contains($0) })
        await model.load()
        #expect(!model.record.sources.contains(publisher))
        await model.follow(publisher)
        #expect(try await library.read().sources.contains(publisher))
        await model.remove(publisher)
        #expect(try await !library.read().sources.contains(publisher))
    }

    @MainActor
    @Test func websiteLookupSupportsPublishersOutsideTheCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(store: try FileBlobStore(directory: directory), rootKey: try ContentRootKey.generate())
        let model = NewsModel(library: library, network: TestNewsNetwork())
        await model.searchPublishers("ProPublica")
        #expect(model.publisherResults.first?.name == "ProPublica")
        await model.searchPublishers("https://www.propublica.org/")
        let result = try #require(model.publisherResults.first)
        #expect(result.url.host == "propublica.org")
        #expect(!NewsSource.catalog.contains(result))
        await model.follow(result)
        #expect(try await library.read().sources.contains(result))
        await model.remove(result)
        #expect(try await library.read().sources.contains(result) == false)
        #expect(NewsSource.publisher("news.google.com") == nil)
    }

    @MainActor
    @Test func todayShowsDifferentPublishersBeforeRepeats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(store: try FileBlobStore(directory: directory), rootKey: try ContentRootKey.generate())
        let model = NewsModel(library: library, network: TestNewsNetwork())
        let local = NewsArticle(title: "Idaho weather alerts", summary: "", source: "National Weather Service",
                                url: URL(string: "https://www.weather.gov/boi/")!, date: nil)
        let secondAlert = NewsArticle(title: "Idaho mountain forecast", summary: "", source: "National Weather Service",
                                      url: URL(string: "https://www.weather.gov/boi/forecast")!, date: nil)
        let space = NewsArticle(title: "Artemis II mission", summary: "", source: "NASA",
                                url: URL(string: "https://www.nasa.gov/mission/artemis-ii/")!, date: nil)
        _ = try await library.update { $0.latest = [local, secondAlert, space] }
        await model.load()
        #expect(model.todayStories.map(\.title) == [local.title, space.title, secondAlert.title])
    }

    @MainActor
    @Test func topStoriesStaySeparateFromTopicSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileBlobStore(directory: directory)
        let key = try ContentRootKey.generate()
        let network = TestNewsNetwork()
        let model = NewsModel(library: NewsLibrary(store: store, rootKey: key), network: network)
        await model.refreshAhead()
        await model.refreshTopStories()
        #expect(model.todayStories.map(\.title) == ["Artemis II mission"])
        await model.discover("Idaho weather")
        #expect(model.discovered.map(\.title) == ["Idaho weather alerts"])
        #expect(model.todayStories.map(\.title) == ["Artemis II mission"])
        await network.fail()
        await model.refreshTopStories(force: true)
        #expect(model.todayStories.map(\.title) == ["Artemis II mission"])
    }

    @MainActor
    @Test func refreshKeepsUsableHeadlinesAndRoutesSearchResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileBlobStore(directory: directory)
        let key = try ContentRootKey.generate()
        let network = TestNewsNetwork()
        let model = NewsModel(library: NewsLibrary(store: store, rootKey: key), network: network)
        let registry = try ModuleRegistry(handlers: [model])
        await model.refreshAhead()
        let hit = try #require(try await model.search("Artemis").first)
        let id = try #require(UUID(uuidString: hit.itemID))
        let ref = ContentRef(module: .news, kind: .newsArticle, id: id, keyRef: .plain, preview: .init(title: hit.title))
        let handler = try #require(registry.handler(for: ref) as? any ArticleLinkProvider)
        #expect(await handler.articleURL(for: ref)?.absoluteString == "https://www.nasa.gov/mission/artemis-ii/")
        #expect(model.notice != nil)
        await network.fail()
        await model.refresh()
        #expect(try await model.search("Artemis").count == 1)
        await model.close()
        #expect(await handler.articleURL(for: ref) == nil)
    }
}
