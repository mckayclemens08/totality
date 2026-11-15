import SwiftUI
import TotalityUI

/// The Reader's big home tile: a shelf, with what's being read or heard at the front. Linked Google Drive
/// folders and files opened from them sit on it too, by when they were last opened.
public struct ReaderHomeTile: View {
    private static let shelfSize: [BigTileSize: Int] = [.medium: 0, .large: 3, .square: 3]

    private let model: ReaderModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings the Reader up after an item has been asked for.
    public init(model: ReaderModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ entry: ShelfEntry) {
        model.requestedItem = entry.id
        onOpen()
    }

    private var front: ShelfEntry? {
        model.frontOfShelf
    }

    private var shelf: [ShelfEntry] {
        Array(model.shelf.filter { $0.id != front?.id }.prefix(Self.shelfSize[size] ?? 0))
    }

    public var body: some View {
        VStack(spacing: Space.s6) {
            if let front { frontBook(front) }
            if !shelf.isEmpty {
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(shelf) { entry in
                        SmallBook(entry: entry)
                            .tileLink(entry.title) { open(entry) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconSize: CGFloat {
        switch size {
        case .medium: Space.s5
        case .large: Space.s6
        case .square: Space.s7
        }
    }

    private func frontBook(_ item: ShelfEntry) -> some View {
        let theme = Theme.current
        let isPlaying = model.listen.current?.id == item.id
        return VStack(spacing: Space.s2) {
            VStack(spacing: Space.s1) {
                BookIcon(systemImage: isPlaying ? "waveform" : item.systemImage, size: iconSize)
                    .padding(.bottom, Space.s1)
                if isPlaying {
                    Text("Listening")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                }
                Text(item.title)
                    .font(size == .medium ? Typeface.headline : Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(size == .medium ? 1 : 2)
                Text(item.typeName)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .multilineTextAlignment(.center)
            if isPlaying {
                ListenProgress(value: model.listen.progress)
            }
        }
        .frame(maxWidth: .infinity)
        .tileLink(item.title) { open(item) }
    }
}

private struct SmallBook: View {
    let entry: ShelfEntry

    var body: some View {
        VStack(spacing: Space.s1) {
            BookIcon(systemImage: entry.systemImage, size: Space.s5)
            Text(entry.title)
                .font(Typeface.micro)
                .foregroundStyle(Theme.current.textSecondary.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BookIcon: View {
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size))
            .foregroundStyle(Theme.current.textSecondary.color)
            .accessibilityHidden(true)
    }
}
