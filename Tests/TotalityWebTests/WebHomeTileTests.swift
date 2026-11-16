import Foundation
import Testing
import TotalityCore
@testable import TotalityWeb

/// What each size of Web's home tile shows (issue 127).
@MainActor
@Suite struct WebHomeTileTests {
    private func model() async throws -> WebModel {
        let model = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        await model.use(account: "user-1")
        return model
    }

    @Test("Large and square: open tabs show, the one in front first, and never a private one")
    func tabsShow() async throws {
        let model = try await model()
        #expect(model.homeTabs.isEmpty, "A new tab with nothing in it isn't shown")
        model.open(URL(string: "https://en.wikipedia.org/wiki/Lisbon")!)
        model.newTab()
        model.open(URL(string: "https://www.carris.pt/en/tram-28")!)
        model.newTab(isPrivate: true)
        model.open(URL(string: "https://example.org/private")!)
        model.newTab()
        model.open(URL(string: "https://news.ycombinator.com")!)
        defer { model.tabs.forEach { $0.page?.stop() } }
        #expect(model.homeTabs.map { $0.address?.host() } == ["news.ycombinator.com", "www.carris.pt", "en.wikipedia.org"])
        #expect(model.homeTabs.map(WebModel.shortAddress) == ["news.ycombinator.com", "carris.pt", "en.wikipedia.org"])
    }

    @Test("A tab card brings that tab to the front")
    func tabCardSelects() async throws {
        let model = try await model()
        model.open(URL(string: "https://en.wikipedia.org/wiki/Lisbon")!)
        let lisbon = model.current
        model.newTab()
        model.open(URL(string: "https://github.com")!)
        defer { model.tabs.forEach { $0.page?.stop() } }
        model.showFromHome(lisbon)
        #expect(model.current.id == lisbon.id)
        #expect(model.homeTabs.first?.id == lisbon.id)
    }

    @Test("The box searches only on Go, in a tab of its own")
    func searchOnGo() async throws {
        let model = try await model()
        model.open(URL(string: "https://en.wikipedia.org/wiki/Lisbon")!)
        defer { model.tabs.forEach { $0.page?.stop() } }
        let before = model.tabs.count
        model.homeQuery = "tram 28 timetable"
        #expect(model.tabs.count == before, "Typing does nothing by itself")
        #expect(model.submitFromHome())
        #expect(model.tabs.count == before + 1, "It doesn't replace the page that was open")
        #expect(model.current.showing == .results)
        #expect(model.current.search.query == "tram 28 timetable")
        #expect(model.homeQuery.isEmpty)
        // Nothing typed, nothing happens.
        model.homeQuery = "   "
        #expect(!model.submitFromHome())
    }

    @Test("Without visits, bookmarks keep the person's order")
    func bookmarksOrder() async throws {
        let model = try await model()
        for (title, address) in [("BBC News", "https://www.bbc.com/news"), ("GitHub", "https://github.com"), ("Weather", "https://weather.gov")].reversed() {
            await model.addBookmark(title: title, url: URL(string: address)!)
        }
        #expect(model.homeBookmarks.map(\.title) == model.bookmarks.map(\.title))
        #expect(model.homeDownload == nil)
    }
}
