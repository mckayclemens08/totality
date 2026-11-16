import SwiftUI
import TotalityUI

/// Web's big home tiles, one job for each size (issue 127). Medium is a glance at the bookmarks. Large
/// is a Search button and the open tabs, or with none, the bookmarks used most. The square has the button,
/// eight bookmarks, open tabs and the newest download. Never history, and never a private tab. A site's
/// first letter stands in for its icon, because fetching one would tell the site. Search opens Web's own
/// field, because tiles never hold a text box.
public struct WebHomeTile: View {
    private static let perRow = 4

    private let model: WebModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Web up after a site, a tab or a panel has been asked for.
    public init(model: WebModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ panel: WebModel.Panel) {
        model.requestedPanel = panel
        onOpen()
    }

    private func rows(_ count: Int, of bookmarks: [WebBookmark]) -> [[WebBookmark]] {
        let shown = Array(bookmarks.prefix(Self.perRow * count))
        return stride(from: 0, to: shown.count, by: Self.perRow).map { Array(shown[$0..<min($0 + Self.perRow, shown.count)]) }
    }

    private var tabsLine: String? {
        switch model.openTabCount {
        case 0: nil
        case 1: "1 tab open"
        case let count: "\(count) tabs open"
        }
    }

    public var body: some View {
        Group {
            switch size {
            case .medium: medium
            case .large: large
            case .square: square
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Medium: a glance at the bookmarks

    private var medium: some View {
        let shown = rows(1, of: model.bookmarks)
        return VStack(spacing: Space.s4) {
            if shown.isEmpty { front } else { wall(shown) }
            if let progress = model.downloadProgress {
                downloading(progress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Large: search, and the open tabs

    private var large: some View {
        let tabs = Array(model.homeTabs.prefix(WebModel.homeTabCards))
        return VStack(alignment: .leading, spacing: Space.s3) {
            WebTileSearch(model: model, onOpen: onOpen)
                .tileControl()
            ForEach(tabs) { tab in
                TabCard(tab: tab)
                    .tileLink("\(tab.title), open tab") {
                        model.showFromHome(tab)
                        onOpen()
                    }
            }
            if tabs.isEmpty && model.bookmarks.isEmpty {
                emptyNote
            } else if tabs.count < WebModel.homeTabCards, !model.bookmarks.isEmpty {
                // Room the tabs don't fill goes to the bookmarks people use most, right under the button.
                wall(rows(tabs.isEmpty ? 2 : 1, of: model.homeBookmarks))
                    .padding(.top, Space.s3)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Square: search, bookmarks, tabs and the latest download

    private var square: some View {
        let grid = rows(WebModel.homeGrid / Self.perRow, of: model.homeBookmarks)
        let tabs = Array(model.homeTabs.prefix(WebModel.homeSquareTabs))
        return VStack(alignment: .leading, spacing: Space.s3) {
            WebTileSearch(model: model, onOpen: onOpen)
                .tileControl()
            if grid.isEmpty && tabs.isEmpty && model.homeDownload == nil {
                emptyNote
            }
            if !grid.isEmpty {
                wall(grid)
                    .padding(.top, Space.s3)
            }
            Spacer(minLength: 0)
            ForEach(tabs) { tab in
                TabCard(tab: tab)
                    .tileLink("\(tab.title), open tab") {
                        model.showFromHome(tab)
                        onOpen()
                    }
            }
            if let download = model.homeDownload {
                DownloadLine(download: download)
                    .tileLink("Downloads, \(download.filename)") { open(.downloads) }
            }
        }
    }

    private var emptyNote: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            Text("No tabs or bookmarks yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Bookmark a page in Web to keep it here.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    private func downloading(_ progress: Double) -> some View {
        VStack(spacing: Space.s1) {
            Text("Downloading")
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.accent.color)
            ProgressView(value: progress)
                .tint(Theme.current.accent.color)
        }
        .tileLink("Downloads") { open(.downloads) }
    }

    private func wall(_ rows: [[WebBookmark]]) -> some View {
        VStack(spacing: Space.s4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(row) { bookmark in
                        SiteMark(bookmark: bookmark, size: size)
                            .tileLink(bookmark.displayTitle) {
                                model.openFromHome(bookmark)
                                onOpen()
                            }
                    }
                    ForEach(row.count..<Self.perRow, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    /// With nothing saved yet, the tile says what it's for and how much is open.
    private var front: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Space.s5))
                .foregroundStyle(theme.textSecondary.color)
                .padding(.bottom, Space.s1)
                .accessibilityHidden(true)
            Text("Search the web")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(tabsLine ?? "No bookmarks yet")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .tileLink(tabsLine ?? "", action: tabsLine.map { _ in { open(.tabs) } })
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// A plain Search button. Web opens with its own search field ready: tiles never hold a text box.
private struct WebTileSearch: View {
    let model: WebModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        TileButton("Search", systemImage: "magnifyingglass", isProminent: true) {
            model.openSearchFromHome()
            onOpen()
        }
    }
}

/// An open tab: its site's letter, title and address.
private struct TabCard: View {
    let tab: WebTab

    var body: some View {
        let theme = Theme.current
        let address = WebModel.shortAddress(of: tab)
        HStack(spacing: Space.s3) {
            Text((address.isEmpty ? tab.title : address).prefix(1).uppercased())
                .font(Typeface.headline)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s6, height: Space.s6)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                // A page with no title of its own goes by its address, which then needn't show twice.
                if address != tab.title {
                    Text(address)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The newest download: its name and how it's going.
private struct DownloadLine: View {
    let download: WebDownload

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Image(systemName: download.state == .failed ? "exclamationmark.circle" : "arrow.down.circle")
                .foregroundStyle(download.state == .running ? theme.accent.color : theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(download.filename)
                .font(Typeface.caption)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Spacer(minLength: Space.s1)
            Text(download.state == .failed ? "Didn't finish" : download.state == .running ? "\(Int(download.progress * 100))%" : download.sizeText)
                .font(Typeface.micro)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
        }
    }
}

private struct SiteMark: View {
    let bookmark: WebBookmark
    let size: BigTileSize

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            Text(bookmark.displayTitle.prefix(1).uppercased())
                .font(size == .large ? Typeface.display : Typeface.title)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(bookmark.displayTitle)
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(size == .large ? 2 : 1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
