import SwiftUI
import TotalityUI

/// Photos' home tile, full bleed (redesign, 2026-11-17). Small is the newest photo edge to edge. Medium
/// is the newest large on the left with two more stacked beside it. Large is the newest across the top
/// with three more under it. Each opens in the viewer. The thumbnails are opened on this device the same
/// way the library opens them, so the server sees nothing it wouldn't see when Photos opens. Recently
/// Deleted never shows here.
public struct PhotosHomeTile: View {
    private let model: PhotosModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Photos up after a photo has been asked for.
    public init(model: PhotosModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .ready:
                let newest = model.newest(4)
                if newest.isEmpty { front } else { wall(newest) }
            case .loading:
                status(title: "Opening your photos")
            case .unavailable:
                // Opening Photos says why, as the home page's other modules do.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func wall(_ items: [PhotoItem]) -> some View {
        let lead = items[0]
        let rest = Array(items.dropFirst())
        switch size {
        case .small:
            photo(lead, caption: true, corner: 0)
        case .medium:
            HStack(spacing: Metric.tileBleed) {
                photo(lead, caption: true)
                if !rest.isEmpty {
                    VStack(spacing: Metric.tileBleed) {
                        ForEach(rest.prefix(2)) { photo($0) }
                    }
                }
            }
            .padding(Metric.tileBleed)
        case .large:
            // The newest takes three fifths of the height, and the rest share the strip under it.
            GeometryReader { proxy in
                VStack(spacing: Metric.tileBleed) {
                    photo(lead, caption: true)
                        .frame(height: rest.isEmpty ? proxy.size.height : proxy.size.height * 3 / 5)
                    if !rest.isEmpty {
                        HStack(spacing: Metric.tileBleed) {
                            ForEach(rest.prefix(3)) { photo($0) }
                        }
                    }
                }
            }
            .padding(Metric.tileBleed)
        }
    }

    private func photo(_ item: PhotoItem, caption: Bool = false, corner: CGFloat = Radius.tile - Metric.tileBleed) -> some View {
        PhotoCell(model: model, item: item, fills: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if caption { PhotoCaption(text: Self.caption(of: item)) }
            }
            .tileLink(PhotoCell.label(of: item)) {
                model.requestedItem = item.id
                onOpen()
            }
    }

    /// The photo's own caption, or the day it's from.
    static func caption(of item: PhotoItem, now: Date = Date()) -> String {
        if let caption = item.details.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            return caption
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(item.date) { return "Today" }
        if calendar.isDateInYesterday(item.date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: item.date, to: now).day, days < 7 {
            return item.date.formatted(.dateTime.weekday(.wide))
        }
        return item.date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// While the library opens, the tile says so. No photo shows until the library is ready, so nothing
    /// of another account's can linger here.
    private func status(title: String) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            ProgressView()
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .tilePadding()
    }

    /// With nothing added yet, the tile says what it's for.
    private var front: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            TileHeader("Photos", systemImage: "photo.on.rectangle")
            Spacer(minLength: 0)
            Text("No photos yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Photos you add are sealed before they upload.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .tilePadding()
    }
}

/// A few words on a photo, on a dark wash so they read on any picture.
private struct PhotoCaption: View {
    private static let wash = 0.55

    let text: String

    var body: some View {
        let theme = Theme.current
        Text(text)
            .font(Typeface.micro.weight(.semibold))
            .foregroundStyle(theme.accentOn.color)
            .lineLimit(1)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1 / 2 + 1)
            .background(theme.textPrimary.color.opacity(Self.wash), in: RoundedRectangle(cornerRadius: Radius.sm / 1.25, style: .continuous))
            .padding(Space.s2)
            .accessibilityHidden(true)
    }
}
