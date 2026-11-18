import SwiftUI
import TotalityUI

/// Web's home tile at each size (redesign, 2026-11-17). Every size has the search box, a raised button
/// that opens Web's own field, because tiles never hold a text box. Small adds three bookmarks, medium
/// a row of five with names, and large eight in two rows with the open tabs under them. Never history,
/// and never a private tab. A site's first letter stands in for its icon, because fetching one would tell
/// the site.
public struct WebHomeTile: View {
    private let model: WebModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Web up after a site, a tab or a panel has been asked for.
    public init(model: WebModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ panel: WebModel.Panel) {
        model.requestedPanel = panel
        onOpen()
    }

    public var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
        .tilePadding()
    }

    private func mark(_ bookmark: WebBookmark, side: CGFloat, named: Bool) -> some View {
        SiteSquare(bookmark: bookmark, side: side, named: named)
            .tileLink(bookmark.displayTitle) {
                model.openFromHome(bookmark)
                onOpen()
            }
    }

    // MARK: Small

    private var small: some View {
        let marks = Array(model.homeBookmarks.prefix(3))
        return VStack(alignment: .leading, spacing: Space.s3) {
            TileHeader("Web", systemImage: "globe")
            WebTileSearch(title: "Search", model: model, onOpen: onOpen)
                .tileControl()
            Spacer(minLength: 0)
            if !marks.isEmpty {
                HStack {
                    ForEach(marks) { mark($0, side: Space.s6 + Space.s1 + Space.s1 / 2, named: false) }
                    if marks.count < 3 { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        let marks = Array(model.homeBookmarks.prefix(5))
        return VStack(spacing: Space.s4) {
            WebTileSearch(title: "Search or type address", model: model, onOpen: onOpen)
                .tileControl()
            if marks.isEmpty {
                emptyNote
            } else {
                grid(marks, side: Space.s7 - Space.s1, columns: 5)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Large

    private var large: some View {
        let marks = Array(model.homeBookmarks.prefix(8))
        let tabs = model.homeTabs
        return VStack(alignment: .leading, spacing: Space.s4) {
            WebTileSearch(title: "Search or type address", model: model, onOpen: onOpen)
                .tileControl()
            if marks.isEmpty && tabs.isEmpty {
                emptyNote
            } else if !marks.isEmpty {
                grid(marks, side: Space.s7, columns: 4)
            }
            Spacer(minLength: 0)
            // The open tabs, as many as fit, so the tile has no empty bottom.
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: min(tabs.count, 4), through: 0, by: -1)), id: \.self) { count in
                    VStack(spacing: Space.s2) {
                        ForEach(tabs.prefix(count)) { tab in
                            TabLine(tab: tab)
                                .tileLink(tab.title) {
                                    model.showFromHome(tab)
                                    onOpen()
                                }
                        }
                    }
                }
            }
        }
    }

    private func grid(_ marks: [WebBookmark], side: CGFloat, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: columns),
                  alignment: .center, spacing: Metric.tileGap) {
            ForEach(marks) { mark($0, side: side, named: true) }
        }
    }

    private var emptyNote: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            Text("No bookmarks yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Bookmark a page in Web to keep it here.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The search box: a raised button that opens Web's own field, because a tile holds no text box.
private struct WebTileSearch: View {
    let title: String
    let model: WebModel
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        Button {
            model.openSearchFromHome()
            onOpen()
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.accent.color)
                Text(title)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
            }
            .font(Typeface.callout)
            .lineLimit(1)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2 + Space.s1 / 2)
            .frame(maxWidth: .infinity)
            .neumorphic(.subtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(TilePress())
        .accessibilityLabel("Search the web")
    }
}

/// A bookmark as a raised square with its site's letter in the accent, and its name under it.
private struct SiteSquare: View {
    let bookmark: WebBookmark
    let side: CGFloat
    let named: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            Text(bookmark.displayTitle.prefix(1).uppercased())
                .font(Typeface.headline)
                .foregroundStyle(theme.accent.color)
                .frame(width: side, height: side)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm + Space.s1, style: .continuous))
                .accessibilityHidden(true)
            if named {
                Text(bookmark.displayTitle)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
    }
}

/// An open tab: its site's letter and its title, on a raised strip.
private struct TabLine: View {
    let tab: WebTab

    var body: some View {
        let theme = Theme.current
        let address = WebModel.shortAddress(of: tab)
        HStack(spacing: Space.s3) {
            Text((address.isEmpty ? tab.title : address).prefix(1).uppercased())
                .font(Typeface.callout.weight(.bold))
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            Text(tab.title.isEmpty ? address : tab.title)
                .font(Typeface.caption)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}
