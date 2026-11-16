import SwiftUI
import TotalityUI

/// The Reader's big home tiles: a shelf, with what's being read or heard at the front. Linked Google Drive
/// folders and files opened from them sit on it too, by when they were last opened. The square is a
/// workspace (issue 127): the front item large, where you are in it, Listen's sentence and its controls.
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
        if size == .square {
            ReaderDeskTile(model: model, onOpen: onOpen)
        } else {
            shelfTile
        }
    }

    private var shelfTile: some View {
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

/// The square: what's being read or heard now, with Listen working on the tile, and two more under it.
private struct ReaderDeskTile: View {
    let model: ReaderModel
    let onOpen: @MainActor () -> Void

    private func open(_ entry: ShelfEntry) {
        model.requestedItem = entry.id
        onOpen()
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            if let front = model.frontOfShelf {
                VStack(alignment: .leading, spacing: Space.s1) {
                    if model.homeIsListening {
                        Text("Listening")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.accent.color)
                    }
                    Text(front.title)
                        .font(Typeface.title)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                    if let place = model.homePlace {
                        Text(place)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                .tileLink(front.title) { open(front) }
                if model.homeIsListening {
                    ListenProgress(value: model.listen.progress)
                }
                if let line = model.homeListenLine {
                    Text(Self.marked(line))
                        .font(Typeface.body)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(line.text)
                }
                if !model.homeIsListening {
                    more.padding(.top, Space.s3)
                }
                Spacer(minLength: 0)
                if model.homeCanListen {
                    ReaderTileListen(model: model)
                        .tileControl()
                        .layoutPriority(1)
                }
                if model.homeIsListening {
                    more.layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.frontOfShelf?.id) { await model.loadHomePlace() }
    }

    /// The most recent items: two across under Listen, or a list filling the square when nothing plays.
    @ViewBuilder private var more: some View {
        let theme = Theme.current
        let across = model.homeIsListening
        let layout = across
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.s3))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s4))
        layout {
            ForEach(model.homeMore) { entry in
                HStack(spacing: Space.s3) {
                    BookIcon(systemImage: entry.systemImage, size: Space.s5)
                        .frame(width: Space.s6)
                    Text(entry.title)
                        .font(across ? Typeface.caption : Typeface.body)
                        .foregroundStyle(across ? theme.textSecondary.color : theme.textPrimary.color)
                        .lineLimit(across ? 2 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tileLink(entry.title) { open(entry) }
            }
        }
    }

    /// The sentence on the soft highlight and the word being said on the strong one, as Read along has them.
    static func marked(_ line: ListenLine) -> AttributedString {
        let theme = Theme.current
        var text = AttributedString(line.text)
        text.foregroundColor = theme.textPrimary.color
        text.backgroundColor = theme.highlight.color
        let units = line.text.utf16
        if let word = line.word, word.upperBound <= units.count,
           let lower = String.Index(units.index(units.startIndex, offsetBy: word.lowerBound), within: line.text),
           let upper = String.Index(units.index(units.startIndex, offsetBy: word.upperBound), within: line.text),
           let low = AttributedString.Index(lower, within: text), let up = AttributedString.Index(upper, within: text) {
            text[low..<up].backgroundColor = theme.highlightStrong.color
        }
        return text
    }
}

/// Play or pause, and the next sentence, working on the tile.
private struct ReaderTileListen: View {
    let model: ReaderModel

    var body: some View {
        let playing = model.homeIsListening && !model.listen.isPaused
        HStack(spacing: Space.s2) {
            TileButton(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill", isProminent: true) {
                if playing { model.listen.togglePause() } else { Task { await model.playFromHome() } }
            }
            if model.homeIsListening {
                TileButton("Next sentence", systemImage: "forward.fill") { model.listen.skip(by: 1) }
            }
            Spacer(minLength: 0)
        }
    }
}
