import Foundation
import NaturalLanguage

/// Text cut into sentences to speak. Offsets are UTF-16, so they survive storage as plain integers.
public struct ListenScript: Sendable, Equatable {
    public struct Sentence: Sendable, Equatable {
        public let text: String
        public let offset: Int
        /// The sentence as the document has it. `text` tidies this up to be spoken.
        let raw: String

        var rawLength: Int {
            raw.utf16.count
        }

        /// Where each unit of `text` sits in `raw`. Tidying only drops characters, so each is found in order.
        fileprivate var rawOffsets: [Int] {
            let units = Array(raw.utf16)
            var place = 0
            return text.utf16.map { unit in
                guard unit != Self.space else { return place }
                while place < units.count, units[place] != unit { place += 1 }
                place += 1
                return place - 1
            }
        }

        fileprivate static let space = " ".utf16.first!
    }

    /// Long unpunctuated runs, common in PDFs, are cut so one utterance never runs for minutes.
    static let maxSentenceLength = 600

    public let sentences: [Sentence]
    public let length: Int
    /// Tells two scripts of a long document apart without comparing every sentence. It only means
    /// something while the app runs, so it's never stored.
    public let fingerprint: Int

    /// Stands in for a hyphen and line break that came out of a word, so offsets stay the same.
    private static let joined: Character = "\u{2060}"
    /// A line this long ran out of page. A shorter one is more likely a heading or a table row.
    private static let wrappedLine = 40
    /// These end with a full stop but don't end a sentence, though the tokenizer often thinks they do.
    private static let abbreviations: Set<String> = [
        "st", "dr", "mr", "mrs", "ms", "prof", "fig", "figs", "vol", "vols", "pp", "p", "ed", "eds", "vs", "mt",
        "gen", "col", "capt", "sgt", "rev", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct",
        "nov", "dec",
    ]

    public init(text: String) {
        let flowing = Self.unwrapped(text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = flowing
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: flowing.startIndex..<flowing.endIndex) { range, _ in
            if let last = ranges.last, Self.carriesOn(String(flowing[last])) {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
            return true
        }
        self.sentences = ranges.flatMap { Self.pieces(of: flowing, in: $0) }
        self.length = text.utf16.count
        self.fingerprint = text.hashValue
    }

    /// PDFs break lines wherever the page ran out, and the tokenizer takes each break for the end of a
    /// sentence. The result is the same length as the text, so offsets still point into the original.
    static func unwrapped(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r", with: " ").components(separatedBy: "\n")
        var result = ""
        for (index, line) in lines.enumerated() {
            guard index + 1 < lines.count else {
                result += line
                break
            }
            let next = lines[index + 1]
            if splitsWord(line, next) {
                result += line.dropLast(hyphenAndSpaces(line)) + String(repeating: joined, count: hyphenAndSpaces(line) + 1)
            } else {
                result += line + (continues(line, next) ? " " : "\n")
            }
        }
        return result
    }

    private static func trimmed(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hyphenAndSpaces(_ line: String) -> Int {
        line.reversed().prefix(while: \.isWhitespace).count + 1
    }

    private static func splitsWord(_ line: String, _ next: String) -> Bool {
        let end = trimmed(line)
        guard end.hasSuffix("-"), end.dropLast().last?.isLetter == true else { return false }
        return trimmed(next).first?.isLowercase == true
    }

    private static func continues(_ line: String, _ next: String) -> Bool {
        let end = trimmed(line)
        let start = trimmed(next)
        guard let last = end.last, let first = start.first else { return false }
        if ".!?:".contains(last), !carriesOn(end) { return false }
        if first == "•" || first == "-" || first == "*" || startsList(start) { return false }
        return first.isLowercase || end.count >= wrappedLine
    }

    private static func startsList(_ line: String) -> Bool {
        guard let word = line.split(separator: " ").first, let last = word.last, ".)".contains(last) else { return false }
        return word.dropLast().allSatisfy(\.isNumber)
    }

    /// True when text ends mid-sentence: on an abbreviation, an initial, or a list number.
    private static func carriesOn(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let word = words.last, word.hasSuffix(".") else { return false }
        let bare = word.dropLast().drop { !$0.isLetter && !$0.isNumber }
        if bare.count == 1, bare.first?.isUppercase == true { return true }
        if words.count == 1, !bare.isEmpty, bare.allSatisfy(\.isNumber) { return true }
        return abbreviations.contains(bare.lowercased())
    }

    private static func pieces(of text: String, in range: Range<String.Index>) -> [Sentence] {
        var pieces: [Sentence] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = text.index(start, offsetBy: maxSentenceLength, limitedBy: range.upperBound) ?? range.upperBound
            if end < range.upperBound, let space = text[start..<end].lastIndex(where: \.isWhitespace), space > start {
                end = space
            }
            let piece = trimmed(text[start..<end].filter { $0 != joined })
            // Bullets, rules, page numbers, and table figures have nothing to read.
            if piece.contains(where: \.isLetter) {
                pieces.append(Sentence(text: piece, offset: start.utf16Offset(in: text), raw: String(text[start..<end])))
            }
            start = end
        }
        return pieces
    }

    /// The sentence holding `offset`. An offset past the end, from a note since cut short, lands on
    /// the last sentence.
    public func index(at offset: Int) -> Int {
        sentences.lastIndex { $0.offset <= offset } ?? 0
    }

    /// Where a sentence sits in the document, without the spaces around it.
    public func range(ofSentence index: Int) -> Range<Int>? {
        guard sentences.indices.contains(index) else { return nil }
        let sentence = sentences[index]
        guard let first = sentence.rawOffsets.first, let last = sentence.rawOffsets.last else { return nil }
        return (sentence.offset + first)..<(sentence.offset + min(last + 1, sentence.rawLength))
    }

    /// Where the word `spoken` has reached sits in the document.
    public func range(ofWordIn index: Int, spoken: Int) -> Range<Int>? {
        guard sentences.indices.contains(index) else { return nil }
        let sentence = sentences[index]
        let units = Array(sentence.text.utf16)
        guard !units.isEmpty else { return nil }
        var start = min(max(spoken, 0), units.count - 1)
        // A pause can land between words, so the highlight stays on the word before it.
        while start > 0, units[start] == Sentence.space { start -= 1 }
        var end = start
        while start > 0, units[start - 1] != Sentence.space { start -= 1 }
        while end + 1 < units.count, units[end + 1] != Sentence.space { end += 1 }
        let offsets = sentence.rawOffsets
        return (sentence.offset + offsets[start])..<(sentence.offset + min(offsets[end] + 1, sentence.rawLength))
    }

    /// `spoken` is how far into the sentence speech has reached, so the bar moves between sentences too.
    public func progress(at index: Int, spoken: Int = 0) -> Double {
        guard length > 0, sentences.indices.contains(index) else { return 0 }
        let sentence = sentences[index]
        return Double(sentence.offset + min(max(spoken, 0), sentence.text.utf16.count)) / Double(length)
    }
}
