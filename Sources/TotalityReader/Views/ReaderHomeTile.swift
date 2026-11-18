import SwiftUI
import TotalityUI

/// The Reader's home tile at each size, on the soft accent (redesign, 2026-11-17). Small is the front
/// item and a Listen button. Medium is what's being heard, where you are, and play or pause beside a
/// bar of how far along it is. Large adds the item's mark and, under it, the rest of the shelf as far
/// as fits. Linked Google Drive folders and files sit on the shelf too, by when they were last opened.
public struct ReaderHomeTile: View {
    private static let mostRows = 8

    private let model: ReaderModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings the Reader up after an item has been asked for.
    public init(model: ReaderModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ entry: ShelfEntry) {
        model.requestedItem = entry.id
        onOpen()
    }

    private var header: String {
        model.homeIsListening ? "Listening · Reader" : "Reader"
    }

    /// Where you are, or what it is.
    private func detail(_ entry: ShelfEntry) -> String {
        model.homePlace ?? entry.typeName
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
        .tileTint()
        .task(id: model.frontOfShelf?.id) { await model.loadHomePlace() }
    }

    // MARK: Small

    private var small: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            TileHeader(model.homeIsListening ? "Listening" : "Reader", systemImage: "book", isTinted: true)
            if let front = model.frontOfShelf {
                HStack(alignment: .top, spacing: Metric.tileItemGap) {
                    ShelfMark(entry: front, width: Space.s7 - Space.s1)
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(front.title)
                            .font(Typeface.caption.weight(.bold))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(3)
                        Text(detail(front))
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                .tileLink(front.title) { open(front) }
                Spacer(minLength: 0)
                if model.homeOffersListen {
                    ReaderTileListen(model: model, diameter: Space.s6, showsLabel: true, onOpen: onOpen)
                        .tileControl()
                }
            } else {
                empty
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            TileHeader(header, systemImage: "book", isTinted: true)
            if let front = model.frontOfShelf {
                VStack(alignment: .leading, spacing: 0) {
                    Text(front.title)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text(detail(front))
                        .font(Typeface.tileDetail)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                .padding(.top, Space.s1)
                .tileLink(front.title) { open(front) }
                Spacer(minLength: 0)
                listenRow(diameter: Space.s6 + Space.s1 + Space.s1 / 2)
            } else {
                empty
            }
        }
    }

    // MARK: Large

    private var large: some View {
        let theme = Theme.current
        let front = model.frontOfShelf
        let rest = Array(model.shelf.filter { $0.id != front?.id }.prefix(Self.mostRows))
        return VStack(alignment: .leading, spacing: Space.s3) {
            TileHeader(header, systemImage: "book", isTinted: true)
            if let front {
                HStack(alignment: .top, spacing: Space.s3) {
                    ShelfMark(entry: front, width: Space.s7 + Space.s5)
                        .tileLink(front.title) { open(front) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(front.title)
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(2)
                        Text(detail(front))
                            .font(Typeface.tileDetail)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                        listenRow(diameter: Space.s6 + Space.s1 / 2)
                            .padding(.top, Space.s3)
                    }
                }
                // As much of the shelf as fits, spread to the bottom edge.
                TileList(rest, spacing: Space.s2) { entry in
                    ShelfRow(entry: entry)
                        .tileLink(entry.title) { open(entry) }
                }
            } else {
                empty
            }
        }
    }

    @ViewBuilder private func listenRow(diameter: CGFloat) -> some View {
        if model.homeOffersListen {
            HStack(spacing: Space.s2) {
                ReaderTileListen(model: model, diameter: diameter, showsLabel: !model.homeIsListening, onOpen: onOpen)
                    .tileControl()
                if model.homeIsListening {
                    ListenBars(progress: model.listen.progress)
                }
            }
        }
    }

    private var empty: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            Spacer(minLength: 0)
            Text("Nothing here yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Add a file, a note or a Drive folder.")
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
        }
    }
}

/// An item's mark: its icon on a cover-shaped card in its own colour, since items carry no cover art.
private struct ShelfMark: View {
    let entry: ShelfEntry
    let width: CGFloat

    var body: some View {
        Image(systemName: entry.systemImage)
            .font(.system(size: width / 2.5))
            .foregroundStyle(Theme.current.accentOn.color)
            .frame(width: width, height: width * 4 / 3)
            .background(CoverTone.tone(for: entry.id.uuidString).color,
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One more item on the shelf: its mark, title and what it is.
private struct ShelfRow: View {
    let entry: ShelfEntry

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Metric.tileItemGap) {
            ShelfMark(entry: entry, width: Space.s5 + Space.s1)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                Text(entry.typeName)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How far along Listen is, as a row of bars: the heard part in the accent, the rest fainter.
private struct ListenBars: View {
    let progress: Double

    /// Bar heights in quarters of `Space.s1`, a fixed shape so the row reads as sound, not data.
    private static let heights: [CGFloat] = [6, 12, 18, 10, 22, 14, 8, 20, 16, 24, 12, 6, 18, 24, 12, 8, 14, 20, 10, 16]
    private static let unheard = 0.4

    var body: some View {
        let theme = Theme.current
        let heard = Int((min(max(progress, 0), 1) * Double(Self.heights.count)).rounded())
        HStack(spacing: Space.s1 - 1) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(theme.accent.color)
                    .opacity(index < heard ? 1 : Self.unheard)
                    .frame(width: Space.s1 - 1, height: height * Space.s1 / 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Listen progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Play or pause, working on the tile. Something that has to open first, like a Drive file, opens in
/// the Reader and starts there.
private struct ReaderTileListen: View {
    let model: ReaderModel
    let diameter: CGFloat
    let showsLabel: Bool
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let playing = model.homeIsListening && !model.listen.isPaused
        Button {
            if playing {
                model.listen.togglePause()
            } else if model.homeCanListen {
                Task { await model.playFromHome() }
            } else if let front = model.frontOfShelf {
                model.listenWhenOpened = true
                model.requestedItem = front.id
                onOpen()
            }
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(Typeface.caption.weight(.bold))
                    .foregroundStyle(theme.accentOn.color)
                    .frame(width: diameter, height: diameter)
                    .background(Circle().fill(theme.accent.color))
                if showsLabel {
                    Text("Listen")
                        .font(Typeface.tileLabel)
                        .foregroundStyle(theme.accent.color)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(playing ? "Pause" : "Listen")
    }
}
