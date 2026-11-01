import Foundation
import Observation
import TotalityCore
import WebKit

/// One tab's search.
public struct WebSearchState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case searching, done
        case failed(WebSearchError)
    }

    public var query = ""
    public var category = WebCategory.web
    public var phase = Phase.done
    public var results: [WebResult] = []
    public var partial = false
    public var page = 1
    public var canLoadMore = false
    public var isLoadingMore = false
}

@MainActor
@Observable
public final class WebTab: Identifiable {
    public enum Showing: Equatable, Sendable {
        case start, results, page
    }

    public let id: UUID
    public let isPrivate: Bool
    public var showing = Showing.start
    public var search = WebSearchState()
    public fileprivate(set) var page: WebPage?
    /// Where this tab is, for a tab that hasn't made its page yet.
    public var address: URL?
    public var savedTitle = ""

    public init(id: UUID = UUID(), isPrivate: Bool = false) {
        self.id = id
        self.isPrivate = isPrivate
    }

    public var title: String {
        switch showing {
        case .start: "New tab"
        case .results: search.query
        case .page:
            if let title = page?.title, !title.isEmpty { title } else if !savedTitle.isEmpty { savedTitle } else { address?.host() ?? "New tab" }
        }
    }
}

/// The browser's state. Nothing here is logged, and a search is only ever sent to the gateway.
@MainActor
@Observable
public final class WebModel {
    public private(set) var tabs: [WebTab]
    public private(set) var currentID: UUID
    public var safety = SafeSearch.moderate

    @ObservationIgnored private let client: WebSearchClient?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private let store: () -> WKWebsiteDataStore

    public init(client: WebSearchClient?, store: @escaping () -> WKWebsiteDataStore = { .default() }) {
        self.client = client
        self.store = store
        let first = WebTab()
        tabs = [first]
        currentID = first.id
    }

    public var current: WebTab {
        tabs.first { $0.id == currentID } ?? tabs[0]
    }

    /// The box at the top: an address opens, and anything else is a search.
    public func submit(_ text: String) {
        switch WebAddress.parse(text) {
        case .address(let url): open(url)
        case .search(let query): search(query)
        case nil: break
        }
    }

    public func open(_ url: URL, in tab: WebTab? = nil) {
        let tab = tab ?? current
        page(for: tab).load(url)
        tab.address = url
        tab.showing = .page
    }

    private func page(for tab: WebTab) -> WebPage {
        if let page = tab.page { return page }
        let page = WebPage(configuration: WebPage.configuration(isPrivate: tab.isPrivate, store: store()), isPrivate: tab.isPrivate)
        attach(page, to: tab)
        return page
    }

    private func attach(_ page: WebPage, to tab: WebTab) {
        tab.page = page
    }

    public func search(_ query: String, category: WebCategory? = nil) {
        let tab = current
        let category = category ?? tab.search.category
        var state = WebSearchState()
        state.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        state.category = category
        state.phase = .searching
        tab.search = state
        tab.showing = .results
        searching?.cancel()
        searching = Task { [weak self] in await self?.run(in: tab, page: 1) }
    }

    public func choose(_ category: WebCategory) {
        guard current.search.category != category else { return }
        search(current.search.query, category: category)
    }

    public func retry() {
        search(current.search.query)
    }

    public func loadMore() {
        let tab = current
        guard tab.search.canLoadMore, !tab.search.isLoadingMore, tab.search.phase == .done else { return }
        tab.search.isLoadingMore = true
        searching = Task { [weak self] in await self?.run(in: tab, page: tab.search.page + 1) }
    }

    private func run(in tab: WebTab, page: Int) async {
        let wanted = tab.search
        guard let client else {
            tab.search.phase = .failed(.signedOut)
            return
        }
        do {
            let answer = try await client.search(wanted.query, category: wanted.category, page: page, safety: safety)
            guard !Task.isCancelled, tab.search.query == wanted.query, tab.search.category == wanted.category else { return }
            let seen = Set(tab.search.results.map(\.url))
            let fresh = answer.results.filter { !seen.contains($0.url) }
            tab.search.results += fresh
            tab.search.partial = answer.partial
            tab.search.page = page
            tab.search.canLoadMore = !fresh.isEmpty && page < Self.lastPage
            tab.search.isLoadingMore = false
            tab.search.phase = .done
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, tab.search.query == wanted.query else { return }
            tab.search.isLoadingMore = false
            if tab.search.results.isEmpty {
                tab.search.phase = .failed(error as? WebSearchError ?? .unavailable)
            }
        }
    }

    /// The gateway refuses pages past this.
    private static let lastPage = 10

    /// Thumbnails come through the server, and never directly from the image's site.
    public func thumbnail(_ thumbnail: WebThumbnail) async -> Data? {
        try? await client?.image(thumbnail)
    }

    public func openOnPublicSearch() {
        if let url = WebAddress.publicSearch(current.search.query) { open(url) }
    }

    /// Back goes through the page's history, then to the results it came from, then to the start.
    public func goBack() {
        let tab = current
        if tab.showing == .page, let page = tab.page, page.canGoBack {
            page.goBack()
        } else if tab.showing == .page, !tab.search.query.isEmpty {
            tab.showing = .results
        } else {
            tab.showing = .start
        }
    }

    public func goForward() {
        let tab = current
        if tab.showing != .page, tab.page?.url != nil {
            tab.showing = .page
        } else {
            tab.page?.goForward()
        }
    }

    public var canGoBack: Bool {
        current.showing != .start
    }

    public var canGoForward: Bool {
        let tab = current
        return tab.showing == .page ? tab.page?.canGoForward == true : tab.page?.url != nil
    }
}
