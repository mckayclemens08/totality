import Foundation

/// What each size of Web's home tile shows (issue 127). Never history: visits only put the bookmarks
/// people use most first, on the device, and no visit is ever shown. Private tabs never reach the home
/// page at all.
extension WebModel {
    static let homeTabCards = 3
    static let homeSquareTabs = 2
    static let homeGrid = 8

    /// Normal tabs with something in them, the one in front first, then the newest.
    public var homeTabs: [WebTab] {
        let open = tabs.filter { !$0.isPrivate && $0.showing != .start }
        let front = open.filter { $0.id == currentID }
        return front + open.filter { $0.id != currentID }.reversed()
    }

    /// Bookmarks, the ones visited most first. Ties keep the person's own order.
    public var homeBookmarks: [WebBookmark] {
        var visits: [String: Int] = [:]
        for visit in history {
            if let host = visit.url.host()?.lowercased() { visits[host, default: 0] += 1 }
        }
        return bookmarks.enumerated().sorted { a, b in
            let one = a.element.url.host()?.lowercased().flatMap { visits[$0] } ?? 0
            let other = b.element.url.host()?.lowercased().flatMap { visits[$0] } ?? 0
            return one != other ? one > other : a.offset < b.offset
        }.map(\.element)
    }

    /// The newest download, running or done.
    public var homeDownload: WebDownload? { downloads.first }

    /// Search pressed on the home tile: Web comes up with its search field ready, in a normal tab of
    /// its own, the way a bookmark opens from the home page. Tiles never hold a text box (issue 127).
    public func openSearchFromHome() {
        if current.isPrivate || current.showing != .start { newTab() }
        requestedPanel = .search
    }

    /// A tab card tapped on the home page: Web comes up on that tab.
    public func showFromHome(_ tab: WebTab) {
        guard tabs.contains(where: { $0.id == tab.id }), !tab.isPrivate else { return }
        select(tab)
    }

    /// The address a tab card shows: the site, without the scheme.
    public static func shortAddress(of tab: WebTab) -> String {
        switch tab.showing {
        case .results: "Search"
        default: (tab.page?.url ?? tab.address)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        }
    }
}
