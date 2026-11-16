import SwiftUI
import TotalityUI

/// Photos' big home tile: the newest photos, a row of four for each size step. Each opens in the viewer.
/// The thumbnails are opened on this device the same way the library opens them, so the server sees
/// nothing it wouldn't see when Photos opens. Recently Deleted never shows here.
public struct PhotosHomeTile: View {
    private static let perRow = 4
    private static let rows: [BigTileSize: Int] = [.medium: 1, .large: 2, .square: 3]

    private let model: PhotosModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings Photos up after a photo has been asked for.
    public init(model: PhotosModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private var rows: [[PhotoItem]] {
        let shown = model.newest(Self.perRow * (Self.rows[size] ?? 1))
        return stride(from: 0, to: shown.count, by: Self.perRow).map { Array(shown[$0..<min($0 + Self.perRow, shown.count)]) }
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .ready:
                if rows.isEmpty { front } else { wall }
            case .loading:
                status(systemImage: nil, title: "Opening your photos")
            case .unavailable(let title, _):
                status(systemImage: model.fix == .tryAgain ? "exclamationmark.triangle" : "lock.slash", title: title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// While the library opens, or when it can't, the tile says so rather than sitting blank. No photo
    /// shows until the library is ready, so nothing of another account's can linger here.
    private func status(systemImage: String?, title: String) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: Space.s5))
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var wall: some View {
        VStack(spacing: Space.s2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Space.s2) {
                    ForEach(row) { item in
                        PhotoCell(model: model, item: item)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .tileLink(PhotoCell.label(of: item)) {
                                model.requestedItem = item.id
                                onOpen()
                            }
                    }
                    ForEach(row.count..<Self.perRow, id: \.self) { _ in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }

    /// With nothing added yet, the tile says what it's for.
    private var front: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s1) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: size == .medium ? Space.s5 : Space.s6))
                .foregroundStyle(theme.textSecondary.color)
                .padding(.bottom, Space.s1)
                .accessibilityHidden(true)
            Text("Photos")
                .font(size == .medium ? Typeface.headline : Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text("No photos yet")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
