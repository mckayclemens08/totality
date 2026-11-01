import Foundation

/// What Listen has reached on the page, in UTF-16 offsets into the document.
public struct ReadAlongHighlight: Equatable, Sendable {
    public let sentence: Int
    public let range: Range<Int>
    public let word: Range<Int>?
}

public extension ListenScript {
    /// Nil when there's nothing to mark.
    func highlight(sentence index: Int, spoken: Int) -> ReadAlongHighlight? {
        range(ofSentence: index).map {
            ReadAlongHighlight(sentence: index, range: $0, word: range(ofWordIn: index, spoken: spoken))
        }
    }
}

/// Where a PDF's pages sit in its text, which is what Listen reads.
public struct PDFPageMap: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public let index: Int
        public let start: Int
        public let length: Int
    }

    /// Only the pages with text that was found.
    public let pages: [Page]

    /// A page is looked for from where the last one ended, so a repeated page can't land on the wrong one.
    public init(whole: String, pages: [String]) {
        let text = whole as NSString
        var cursor = 0
        var found: [Page] = []
        for (index, page) in pages.enumerated() where !page.isEmpty {
            let place = text.range(of: page, options: .literal, range: NSRange(location: cursor, length: text.length - cursor))
            guard place.location != NSNotFound else { continue }
            found.append(Page(index: index, start: place.location, length: place.length))
            cursor = place.location + place.length
        }
        self.pages = found
    }

    /// Each page a stretch of the text touches, with the part on that page.
    public func pieces(of range: Range<Int>) -> [(page: Int, range: NSRange)] {
        pages.compactMap { page in
            let start = max(range.lowerBound, page.start)
            let end = min(range.upperBound, page.start + page.length)
            guard start < end else { return nil }
            return (page.index, NSRange(location: start - page.start, length: end - start))
        }
    }

    /// The place in the text of a character on a page. Nil for a page whose text wasn't found.
    public func offset(page index: Int, character: Int) -> Int? {
        pages.first { $0.index == index }.map { $0.start + character }
    }
}

/// A document's text set out to follow along with: the words Listen reads, in paragraphs that know
/// where they are, so a place in the audio can be found on the page and a tap on the page in the audio.
public struct ReadAlongPage: Equatable, Sendable {
    public struct Paragraph: Equatable, Sendable, Identifiable {
        public let id: Int
        public let text: String
        public let offset: Int
        public let isHeading: Bool

        public var length: Int {
            text.utf16.count
        }

        fileprivate var range: Range<Int> {
            offset..<(offset + length)
        }
    }

    public enum Mark: Equatable, Sendable {
        case none, sentence, word
    }

    /// A stretch of a paragraph that looks and acts the same throughout.
    public struct Piece: Equatable, Sendable {
        public let text: String
        public let sentence: Int?
        public let mark: Mark
    }

    public let script: ListenScript
    public let paragraphs: [Paragraph]

    /// `text` must be what Listen reads, so empty lines stay in the count and only leave the page.
    public init(text: String, headings: Set<String> = []) {
        script = ListenScript(text: text)
        var offset = 0
        var paragraphs: [Paragraph] = []
        for line in text.components(separatedBy: "\n") {
            if line.contains(where: { !$0.isWhitespace }) {
                paragraphs.append(Paragraph(id: paragraphs.count, text: line, offset: offset, isHeading: headings.contains(line)))
            }
            offset += line.utf16.count + 1
        }
        self.paragraphs = paragraphs
    }

    public func paragraph(holding offset: Int) -> Paragraph? {
        paragraphs.last { $0.offset <= offset }
    }

    public func paragraph(titled title: String) -> Paragraph? {
        paragraphs.first { $0.isHeading && $0.text == title }
    }

    public func touches(_ paragraph: Paragraph, _ highlight: ReadAlongHighlight?) -> Bool {
        highlight?.range.overlaps(paragraph.range) ?? false
    }

    /// Cuts a paragraph wherever a sentence or the highlight starts or ends.
    public func pieces(of paragraph: Paragraph, highlight: ReadAlongHighlight?) -> [Piece] {
        let span = paragraph.range
        let sentences = sentences(in: span)
        var cuts: Set<Int> = [span.lowerBound, span.upperBound]
        for bound in sentences.flatMap({ [$0.span.lowerBound, $0.span.upperBound] }) + highlightBounds(highlight) {
            cuts.insert(min(max(bound, span.lowerBound), span.upperBound))
        }
        let ordered = cuts.sorted()
        let text = paragraph.text as NSString
        return zip(ordered, ordered.dropFirst()).map { start, end in
            Piece(
                text: text.substring(with: NSRange(location: start - span.lowerBound, length: end - start)),
                sentence: sentences.first { $0.span.contains(start) }?.index,
                mark: mark(at: start, highlight)
            )
        }
    }

    private func highlightBounds(_ highlight: ReadAlongHighlight?) -> [Int] {
        guard let highlight else { return [] }
        return [highlight.range.lowerBound, highlight.range.upperBound]
            + (highlight.word.map { [$0.lowerBound, $0.upperBound] } ?? [])
    }

    private func mark(at offset: Int, _ highlight: ReadAlongHighlight?) -> Mark {
        guard let highlight else { return .none }
        if highlight.word?.contains(offset) == true { return .word }
        return highlight.range.contains(offset) ? .sentence : .none
    }

    private func sentences(in span: Range<Int>) -> [(index: Int, span: Range<Int>)] {
        var found: [(index: Int, span: Range<Int>)] = []
        var index = script.index(at: span.lowerBound)
        while script.sentences.indices.contains(index), script.sentences[index].offset < span.upperBound {
            let sentence = script.sentences[index]
            let whole = sentence.offset..<(sentence.offset + sentence.rawLength)
            if whole.overlaps(span) { found.append((index, whole)) }
            index += 1
        }
        return found
    }
}

/// A tap on a sentence arrives as a link, because that's the one way a run of text can be tapped in
/// SwiftUI on both platforms. It never leaves the app.
enum ReadAlongLink {
    private static let scheme = "totality-read-along"

    static func url(forSentence index: Int) -> URL? {
        URL(string: "\(scheme)://sentence/\(index)")
    }

    static func sentence(in url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.lastPathComponent)
    }
}
