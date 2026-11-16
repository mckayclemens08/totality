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
            case .large, .square: startPage
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

    // MARK: Large and square: a start page (owner, 2026-11-16)

    /// A full-width Search button, the bookmarks as raised squares (four across, up to eight), and the open
    /// tabs as one button at the bottom. The square adds the newest download under them.
    private var startPage: some View {
        let marks = Array(model.homeBookmarks.prefix(size == .square ? 6 : 3))
        return VStack(alignment: .leading, spacing: Space.s5) {
            WebTileSearch(model: model, onOpen: onOpen)
                .tileControl()
                .padding(.top, Space.s3)
            if marks.isEmpty {
                emptyNote
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4), count: 3),
                          alignment: .leading, spacing: Space.s4) {
                    ForEach(marks) { bookmark in
                        SiteSquare(bookmark: bookmark)
                            .tileLink(bookmark.displayTitle) {
                                model.openFromHome(bookmark)
                                onOpen()
                            }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.s3) {
                if size == .square, let download = model.homeDownload {
                    DownloadLine(download: download)
                        .tileLink("Downloads, \(download.filename)") { open(.downloads) }
                }
                Spacer(minLength: 0)
                if let tabsLine {
                    TileButton(tabsLine, systemImage: "square.on.square") { open(.tabs) }
                        .tileControl()
                }
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

    /// A raised button across the tile. It opens Web's own field, because a tile holds no text box.
    var body: some View {
        let theme = Theme.current
        Button {
            model.openSearchFromHome()
            onOpen()
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.accent.color)
                Text("Search or type address")
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
            }
            .font(Typeface.callout)
            .lineLimit(1)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .frame(maxWidth: .infinity)
            .neumorphic(.subtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .accessibilityLabel("Search the web")
    }
}

/// A bookmark as a raised square with its site's letter, and its name under it.
private struct SiteSquare: View {
    let bookmark: WebBookmark

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            Text(bookmark.displayTitle.prefix(1).uppercased())
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .accessibilityHidden(true)
            Text(bookmark.displayTitle)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
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
                .font(size == .medium ? Typeface.title : Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(bookmark.displayTitle)
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(size == .medium ? 1 : 2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
