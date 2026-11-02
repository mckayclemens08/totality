import SwiftUI
import TotalityUI

/// Web's big home tile: bookmarks on a wall, with a download or the open tabs underneath. Never history.
/// A bookmark's first letter stands in for the site's icon, because fetching one would tell the site.
/// Each of them opens what it shows.
public struct WebHomeTile: View {
    private static let perRow = 4
    private static let rows: [BigTileSize: Int] = [.medium: 1, .large: 2, .square: 3]

    private let model: WebModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Web up after a site or a panel has been asked for.
    public init(model: WebModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ panel: WebModel.Panel) {
        model.requestedPanel = panel
        onOpen()
    }

    private var rows: [[WebBookmark]] {
        let shown = Array(model.bookmarks.prefix(Self.perRow * (Self.rows[size] ?? 1)))
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
        VStack(spacing: Space.s4) {
            if rows.isEmpty { front } else { wall }
            if let progress = model.downloadProgress {
                VStack(spacing: Space.s1) {
                    Text("Downloading")
                        .font(Typeface.caption)
                        .foregroundStyle(Theme.current.accent.color)
                    ProgressView(value: progress)
                        .tint(Theme.current.accent.color)
                }
                .tileLink("Downloads") { open(.downloads) }
            } else if !rows.isEmpty, let tabsLine, size != .medium {
                Text(tabsLine)
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .tileLink(tabsLine) { open(.tabs) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wall: some View {
        VStack(spacing: size == .square ? Space.s6 : Space.s5) {
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
                .font(.system(size: size == .medium ? Space.s5 : Space.s6))
                .foregroundStyle(theme.textSecondary.color)
                .padding(.bottom, Space.s1)
                .accessibilityHidden(true)
            Text("Search the web")
                .font(size == .medium ? Typeface.headline : Typeface.title)
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
