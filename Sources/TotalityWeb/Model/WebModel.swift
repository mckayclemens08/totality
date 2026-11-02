import Foundation
import Observation
import TotalityCore
import WebKit

/// Something already on this device that matches what's being typed.
public struct WebSuggestion: Equatable, Identifiable, Sendable {
    public let title: String
    public let url: URL
    public let isBookmark: Bool

    public var id: URL { url }
}

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

/// How far back Clear History reaches.
public enum WebClearing: CaseIterable, Sendable, Identifiable {
    case lastHour, lastDay, everything

    public var id: Self { self }

    public var label: String {
        switch self {
        case .lastHour: "The last hour"
        case .lastDay: "The last day"
        case .everything: "Everything"
        }
    }

    var reach: TimeInterval? {
        switch self {
        case .lastHour: 60 * 60
        case .lastDay: 24 * 60 * 60
        case .everything: nil
        }
    }
}

/// The browser's state. Nothing here is logged, and a search is only ever sent to the gateway.
@MainActor
@Observable
public final class WebModel {
    /// The most kept on the device. The oldest go first.
    static let historyLimit = 2_000
    /// Lets a burst of pages settle, so the sealed file isn't rewritten for each one.
    private static let savePause = Duration.milliseconds(800)

    public private(set) var tabs: [WebTab]
    public private(set) var currentID: UUID
    public var safety = SafeSearch.moderate
    public private(set) var bookmarks: [WebBookmark] = []
    public private(set) var history: [WebVisit] = []
    public private(set) var isLoaded = false
    public private(set) var downloads: [WebDownload] = []
    public var notice: String?
    /// Something reached the Reader, so its library has to look again.
    @ObservationIgnored public var onSentToReader: (() -> Void)?
    /// A download is in the Reader and the person asked to go there.
    @ObservationIgnored public var onOpenInReader: ((ContentRef) -> Void)?

    @ObservationIgnored private let client: WebSearchClient?
    @ObservationIgnored private let vault: WebVault?
    @ObservationIgnored private let blocker: WebBlocker?
    @ObservationIgnored private let downloadsRoot: URL?
    @ObservationIgnored private let receiver: (any ContentReceiver)?
    @ObservationIgnored private var folder: WebDownloadFolder?
    @ObservationIgnored private var blockingStarted = false
    @ObservationIgnored private var searching: Task<Void, Never>?
    private var settings = WebSettings()
    /// Who things are kept for. Nil for anyone else, and then nothing is.
    private var account: String?
    @ObservationIgnored private var dataStore: WKWebsiteDataStore?
    @ObservationIgnored private var savingHistory: Task<Void, Never>?
    @ObservationIgnored private var savingTabs: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        client: WebSearchClient?, vault: WebVault? = nil, blocker: WebBlocker? = nil, downloads: URL? = nil,
        receiver: (any ContentReceiver)? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.vault = vault
        self.blocker = blocker
        self.downloadsRoot = downloads
        self.receiver = receiver
        self.now = now
        let first = WebTab()
        tabs = [first]
        currentID = first.id
    }

    /// Says who's here. Only the account that owns this device's key has things kept, because its
    /// bookmarks sync under that key. Signed out or anyone else, the browser works and keeps nothing.
    /// Nothing is written until there's something to keep, so an unused browser leaves a device empty
    /// and a new account can still take it over.
    public func use(account: String?) async {
        if account != self.account {
            reset()
            self.account = account
        }
        await load()
    }

    /// What's open belongs to whoever is leaving, so none of it carries over. What they kept stays
    /// sealed on the device for when they're back.
    private func reset() {
        savingHistory?.cancel()
        savingTabs?.cancel()
        searching?.cancel()
        for tab in tabs { tab.page?.stop() }
        for download in downloads where download.state == .running { remove(download) }
        let first = WebTab()
        tabs = [first]
        currentID = first.id
        bookmarks = []
        history = []
        downloads = []
        settings = WebSettings()
        folder = nil
        dataStore = nil
        notice = nil
        isLoaded = false
    }

    /// Reads what's sealed on this device. Open tabs come back without loading, and each one loads when
    /// it's next looked at, so reopening the app doesn't fetch every site.
    public func load() async {
        startBlocking()
        guard let vault, let account else {
            isLoaded = true
            return
        }
        do {
            let bookmarks = try await vault.bookmarks()
            // Sync reloads too, and the rest is already in memory, with changes still on their way to disk.
            guard !isLoaded else {
                if account == self.account { self.bookmarks = bookmarks }
                return
            }
            let history = try await vault.history(for: account)
            let settings = try await vault.settings(for: account)
            let tabs = try await vault.savedTabs(for: account)
            guard account == self.account, !isLoaded else { return }
            self.bookmarks = bookmarks
            self.history = history
            self.settings = settings
            let directory = WebVault.siteID(for: account).uuidString
            folder = downloadsRoot.map { WebDownloadFolder(directory: $0.appendingPathComponent(directory, isDirectory: true)) }
            downloads = folder?.existing().map(WebDownload.init(finished:)) ?? []
            restoreTabs(tabs)
            isLoaded = true
        } catch {
            notice = "Your bookmarks and history couldn't be opened."
        }
    }

    /// True once it's settled that this person gets a browser that keeps nothing.
    public var keepsNothing: Bool { vault != nil && isLoaded && account == nil }

    private func startBlocking() {
        guard let blocker, !blockingStarted else { return }
        blockingStarted = true
        Task { [weak self] in
            await blocker.prepare()
            for tab in self?.tabs ?? [] { tab.page?.rules = blocker.rules }
        }
    }

    private func restoreTabs(_ saved: WebSavedTabs) {
        guard !saved.tabs.isEmpty, tabs.count == 1, tabs[0].showing == .start else { return }
        tabs = saved.tabs.map { tab in
            let restored = WebTab(id: tab.id)
            restored.address = tab.url
            restored.savedTitle = tab.title
            restored.showing = .page
            return restored
        }
        currentID = saved.tabs.first { $0.id == saved.current }?.id ?? tabs[0].id
        wakeCurrent()
    }

    /// Stops writing under a key that's about to change.
    public func stopForKeyChange() async {
        savingHistory?.cancel()
        savingTabs?.cancel()
        await vault?.close()
    }

    private func wakeCurrent() {
        let tab = current
        guard tab.showing == .page, tab.page == nil, let address = tab.address else { return }
        page(for: tab).load(address)
    }

    /// The account's own store of cookies and site data, so one person's sign-ins can't reach another's.
    private func store() -> WKWebsiteDataStore {
        if let dataStore { return dataStore }
        let store = account.map { WKWebsiteDataStore(forIdentifier: WebVault.siteID(for: $0)) } ?? .nonPersistent()
        dataStore = store
        return store
    }

    // MARK: Tabs

    public func newTab(isPrivate: Bool = false) {
        let tab = WebTab(isPrivate: isPrivate)
        tabs.append(tab)
        currentID = tab.id
        tabsChanged()
    }

    public func select(_ tab: WebTab) {
        currentID = tab.id
        wakeCurrent()
        tabsChanged()
    }

    public func close(_ tab: WebTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.page?.stop()
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = WebTab()
            tabs = [fresh]
            currentID = fresh.id
        } else if tab.id == currentID {
            currentID = tabs[min(index, tabs.count - 1)].id
            wakeCurrent()
        }
        tabsChanged()
    }

    /// Private tabs are never saved, so they can't come back after the app closes.
    private func tabsChanged() {
        guard let vault, let account, isLoaded else { return }
        savingTabs?.cancel()
        savingTabs = Task { [weak self] in
            try? await Task.sleep(for: Self.savePause)
            guard !Task.isCancelled, let self else { return }
            try? await vault.saveTabs(self.savedTabs, for: account)
        }
    }

    var savedTabs: WebSavedTabs {
        let kept = tabs.filter { !$0.isPrivate && $0.showing == .page }.compactMap { tab -> WebSavedTabs.Tab? in
            guard let url = tab.page?.url ?? tab.address else { return nil }
            return WebSavedTabs.Tab(id: tab.id, url: url, title: tab.title)
        }
        return WebSavedTabs(tabs: kept, current: kept.contains { $0.id == currentID } ? currentID : nil)
    }

    // MARK: History

    private func visited(_ url: URL, title: String, in tab: WebTab) {
        tab.address = url
        if !title.isEmpty { tab.savedTitle = title }
        tabsChanged()
        guard account != nil, isLoaded, !tab.isPrivate, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        if let latest = history.first, latest.url == url {
            history[0].title = title
            history[0].date = now()
        } else {
            history.insert(WebVisit(title: title, url: url, date: now()), at: 0)
            history.removeLast(max(0, history.count - Self.historyLimit))
        }
        saveHistory()
    }

    private func saveHistory() {
        guard let vault, let account, isLoaded else { return }
        savingHistory?.cancel()
        savingHistory = Task { [weak self] in
            try? await Task.sleep(for: Self.savePause)
            guard !Task.isCancelled, let self else { return }
            try? await vault.saveHistory(self.history, for: account)
        }
    }

    public func clearHistory(_ reach: WebClearing) {
        if let seconds = reach.reach {
            let cutoff = now().addingTimeInterval(-seconds)
            history.removeAll { $0.date >= cutoff }
        } else {
            history = []
        }
        savingHistory?.cancel()
        guard let account, isLoaded else { return }
        Task { [vault, history] in try? await vault?.saveHistory(history, for: account) }
    }

    public func forget(_ visit: WebVisit) {
        history.removeAll { $0.id == visit.id }
        saveHistory()
    }

    /// Signs every site out on this device, for this account. False when it isn't known yet whose store
    /// to clear, so the screen can't say it's done.
    public func clearSiteData() async -> Bool {
        guard isLoaded else { return false }
        await store().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        return true
    }

    /// Bookmarks and pages already visited, matched here. Nothing typed leaves the device until Go.
    public func suggestions(for typed: String) -> [WebSuggestion] {
        let terms = SearchText.terms(in: typed)
        guard !terms.isEmpty else { return [] }
        func matches(_ title: String, _ url: URL) -> Bool {
            terms.allSatisfy { SearchText.find($0, in: title) != nil || SearchText.find($0, in: url.absoluteString) != nil }
        }
        var seen = Set<URL>()
        var found: [WebSuggestion] = []
        for bookmark in bookmarks where matches(bookmark.title, bookmark.url) && seen.insert(bookmark.url).inserted {
            found.append(WebSuggestion(title: bookmark.displayTitle, url: bookmark.url, isBookmark: true))
        }
        for visit in history where matches(visit.title, visit.url) && seen.insert(visit.url).inserted {
            found.append(WebSuggestion(title: visit.displayTitle, url: visit.url, isBookmark: false))
        }
        return Array(found.prefix(Self.suggestionLimit))
    }

    private static let suggestionLimit = 6

    // MARK: Blocking

    public var unblockedSites: [String] { settings.unblockedSites.sorted() }

    public func isBlocking(_ url: URL?) -> Bool {
        WebSite.key(url).map { !settings.unblockedSites.contains($0) } ?? true
    }

    public func setBlocking(_ isOn: Bool, for site: String) {
        if isOn { settings.unblockedSites.remove(site) } else { settings.unblockedSites.insert(site) }
        if let account, isLoaded {
            Task { [vault, settings] in try? await vault?.saveSettings(settings, for: account) }
        }
        for tab in tabs where WebSite.key(tab.page?.url) == site {
            tab.page?.applyRules(for: tab.page?.url)
            tab.page?.reload()
        }
    }

    // MARK: Downloads and the Reader

    public func remove(_ download: WebDownload) {
        download.cancel()
        try? FileManager.default.removeItem(at: download.file)
        downloads.removeAll { $0.id == download.id }
    }

    /// Goes through the registry, so Web hands over a note and never learns how the Reader keeps it.
    public func saveToReader() async {
        guard let page = current.page, let receiver else { return }
        do {
            let text = try await page.readableText()
            guard !text.body.isEmpty else {
                notice = "This page has no text to save."
                return
            }
            _ = try await receiver.receive(noteTitled: text.title, body: text.body)
            onSentToReader?()
            notice = "Saved to Reader."
        } catch {
            notice = "This page wasn't saved."
        }
    }

    /// Hands the file over the first time, then opens it there. A file that's already in the Reader
    /// goes back to the same document, unless it's been deleted there.
    public func openInReader(_ download: WebDownload) async {
        guard let receiver else { return }
        do {
            let kept = if let sent = download.inReader { try await receiver.current(sent) } else { nil as ContentRef? }
            let ref = if let kept { kept } else { try await receiver.receive(file: Data(contentsOf: download.file), named: download.filename) }
            download.inReader = ref
            onOpenInReader?(ref)
        } catch {
            notice = "The Reader couldn't take this file."
        }
    }

    /// Every running download as one number, or nil when none is running.
    public var downloadProgress: Double? {
        let running = downloads.filter { $0.state == .running }
        return running.isEmpty ? nil : running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    /// True while there's a download to show, running or ended and not looked at yet.
    public var showsDownloadStatus: Bool {
        downloads.contains { $0.state == .running || !$0.wasSeen }
    }

    /// Anything still running keeps its marker, so its ending gets seen too.
    public func downloadsSeen() {
        for download in downloads where download.state != .running { download.wasSeen = true }
    }

    // MARK: Bookmarks

    public var folders: [String] {
        Array(Set(bookmarks.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    public func bookmark(for url: URL?) -> WebBookmark? {
        guard let url else { return nil }
        return bookmarks.first { $0.url == url }
    }

    public func addBookmark(title: String, url: URL, folder: String = "") async {
        await changeBookmarks("The bookmark wasn't saved.") { vault in
            try await vault.save(WebBookmark(title: title, url: url, folder: folder, updatedAt: self.now()))
        }
    }

    public func save(_ bookmark: WebBookmark) async {
        var changed = bookmark
        changed.updatedAt = now()
        await changeBookmarks("The bookmark wasn't saved.") { try await $0.save(changed) }
    }

    public func remove(_ bookmark: WebBookmark) async {
        await changeBookmarks("The bookmark wasn't removed.") { try await $0.delete(bookmark.id) }
    }

    private func changeBookmarks(_ failure: String, _ change: (WebVault) async throws -> Void) async {
        guard let vault, account != nil, isLoaded else {
            notice = failure
            return
        }
        do {
            try await change(vault)
            bookmarks = try await vault.bookmarks()
        } catch {
            notice = failure
        }
    }

    /// The home tile: the newest bookmarks, and never history.
    public var glance: ModuleGlance? {
        guard isLoaded else { return nil }
        guard !bookmarks.isEmpty else { return ModuleGlance(lines: ["No bookmarks yet"], isQuiet: true) }
        return ModuleGlance(lines: bookmarks.map(\.displayTitle))
    }

    /// Normal tabs with something in them. Only the number reaches the home page.
    public var openTabCount: Int {
        tabs.filter { !$0.isPrivate && $0.showing != .start }.count
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
        page.isUnblocked = { [weak self] site in self?.settings.unblockedSites.contains(site) ?? false }
        page.rules = blocker?.rules
        page.onDownload = { [weak self] task, name in
            guard let self else { return nil }
            guard let file = try? self.folder?.destination(for: name) else {
                self.notice = "This file wasn't saved. Downloads are kept only for the account that owns this device."
                return nil
            }
            self.downloads.insert(WebDownload(file: file, task: task), at: 0)
            return file
        }
        page.onVisit = { [weak self, weak tab] url, title in
            guard let self, let tab else { return }
            self.visited(url, title: title, in: tab)
        }
        page.onNewTab = { [weak self, weak tab] configuration, _ in
            guard let self, let tab else { return nil }
            let opened = WebTab(isPrivate: tab.isPrivate)
            let page = WebPage(configuration: configuration, isPrivate: tab.isPrivate)
            self.attach(page, to: opened)
            opened.showing = .page
            self.tabs.append(opened)
            self.currentID = opened.id
            return page.webView
        }
        page.onOpenInTab = { [weak self, weak tab] url, isPrivate in
            guard let self, let tab else { return }
            let opened = WebTab(isPrivate: isPrivate || tab.isPrivate)
            self.tabs.append(opened)
            self.open(url, in: opened)
            self.currentID = opened.id
            self.tabsChanged()
        }
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
