import SwiftUI
import TotalityUI

/// The Reader's big home tile: a shelf, with what's being read or heard at the front.
public struct ReaderHomeTile: View {
    private static let shelfSize: [BigTileSize: Int] = [.medium: 0, .large: 3, .square: 3]

    private let model: ReaderModel
    private let size: BigTileSize

    public init(model: ReaderModel, size: BigTileSize) {
        self.model = model
        self.size = size
    }

    private var front: ReaderItem? {
        model.frontOfShelf
    }

    private var shelf: [ReaderItem] {
        Array(model.library.lastOpened.filter { $0.id != front?.id }.prefix(Self.shelfSize[size] ?? 0))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let front { frontBook(front) }
            if !shelf.isEmpty {
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(shelf) { item in
                        SmallBook(item: item)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func frontBook(_ item: ReaderItem) -> some View {
        let theme = Theme.current
        let isPlaying = model.listen.current?.id == item.id
        return HStack(alignment: .center, spacing: Space.s3) {
            BookCover(systemImage: isPlaying ? "waveform" : item.systemImage, width: Space.s7 + Space.s4)
            VStack(alignment: .leading, spacing: Space.s1) {
                if isPlaying {
                    Text("Listening")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                }
                Text(item.displayTitle)
                    .font(size == .medium ? Typeface.headline : Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Text(item.typeName)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if isPlaying {
                    ListenProgress(value: model.listen.progress)
                        .padding(.top, Space.s1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SmallBook: View {
    let item: ReaderItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            BookCover(systemImage: item.systemImage, width: Space.s7)
            Text(item.displayTitle)
                .font(Typeface.micro)
                .foregroundStyle(Theme.current.textSecondary.color)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shaped like a book, so the tile reads as a shelf even before anything on it does.
private struct BookCover: View {
    let systemImage: String
    let width: CGFloat

    var body: some View {
        let theme = Theme.current
        Image(systemName: systemImage)
            .font(Typeface.body)
            .foregroundStyle(theme.textSecondary.color)
            .frame(width: width, height: width * 4 / 3)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .accessibilityHidden(true)
    }
}
