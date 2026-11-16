import Foundation

/// The current Listen sentence, with the word being spoken, for the home square.
public struct ListenLine: Equatable, Sendable {
    public let text: String
    /// The word Listen has reached, in `text`'s UTF-16 units.
    public let word: Range<Int>?
}

/// What the Reader's home square shows (issue 127): what's being read or heard now, where the person
/// is in it, the sentence Listen is saying, and two more recent items.
extension ReaderModel {
    static let homeMore = 2

    /// The front item is what Listen is playing.
    public var homeIsListening: Bool {
        guard let front = frontOfShelf, let current = listen.current else { return false }
        return current.id == front.id
    }

    /// Listen can start from the tile only on an item in the library. A Drive file opens first.
    public var homeCanListen: Bool {
        if homeIsListening { return true }
        guard case .item? = frontOfShelf else { return false }
        return true
    }

    /// The two most recent after the front one.
    public var homeMore: [ShelfEntry] {
        let front = frontOfShelf?.id
        return Array(shelf.filter { $0.id != front }.prefix(Self.homeMore))
    }

    /// The sentence Listen is saying, as Read along marks it.
    public var homeListenLine: ListenLine? {
        guard homeIsListening, let track = listen.current, track.script.sentences.indices.contains(listen.sentence) else { return nil }
        let text = track.script.sentences[listen.sentence].text
        return ListenLine(text: text, word: Self.word(in: text, at: listen.spoken))
    }

    /// The word around `spoken`, counted in UTF-16 units.
    static func word(in text: String, at spoken: Int) -> Range<Int>? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        let space = UInt16(UInt8(ascii: " "))
        var start = min(max(spoken, 0), units.count - 1)
        while start > 0, units[start] == space { start -= 1 }
        var end = start
        while start > 0, units[start - 1] != space { start -= 1 }
        while end + 1 < units.count, units[end + 1] != space { end += 1 }
        return start..<(end + 1)
    }

    /// Where a place is, in words. Nil when there's nothing worth saying.
    public static func whereYouAre(_ place: ReadingPlace?) -> String? {
        switch place?.spot {
        case .pdf(let page)?: "Page \(page + 1)"
        case .book(_, let progress)?: progress > 0 ? "\(percent(progress)) through the chapter" : nil
        case .doc(let scroll, _)?: scroll > 0 ? "\(percent(scroll)) of the way down" : nil
        case nil: nil
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    /// Looks up where the person is in the front item. The tile calls it as the front changes.
    public func loadHomePlace() async {
        guard case .item(let item)? = frontOfShelf, let places else {
            homePlace = nil
            return
        }
        let place = await places.place(of: item.id)
        guard frontOfShelf?.id == item.id else { return }
        homePlace = Self.whereYouAre(place)
    }

    /// Play on the tile: carries on, or starts Listen on the front item.
    public func playFromHome() async {
        if homeIsListening {
            if listen.isPaused { listen.togglePause() }
            return
        }
        guard case .item(let item)? = frontOfShelf else { return }
        await startListening(to: item.id)
    }
}
