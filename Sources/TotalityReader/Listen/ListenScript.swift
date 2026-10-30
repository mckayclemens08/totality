import Foundation
import NaturalLanguage

/// Text cut into sentences to speak. Offsets are UTF-16, so they survive storage as plain integers.
public struct ListenScript: Sendable, Equatable {
    public struct Sentence: Sendable, Equatable {
        public let text: String
        public let offset: Int
    }

    /// Long unpunctuated runs, common in PDFs, are cut so one utterance never runs for minutes.
    static let maxSentenceLength = 600

    public let sentences: [Sentence]
    public let length: Int

    public init(text: String) {
        var sentences: [Sentence] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences += Self.pieces(of: text, in: range)
            return true
        }
        self.sentences = sentences
        self.length = text.utf16.count
    }

    private static func pieces(of text: String, in range: Range<String.Index>) -> [Sentence] {
        var pieces: [Sentence] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = text.index(start, offsetBy: maxSentenceLength, limitedBy: range.upperBound) ?? range.upperBound
            if end < range.upperBound, let space = text[start..<end].lastIndex(where: \.isWhitespace), space > start {
                end = space
            }
            let piece = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append(Sentence(text: piece, offset: start.utf16Offset(in: text)))
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

    public func progress(at index: Int) -> Double {
        guard length > 0, sentences.indices.contains(index) else { return 0 }
        return Double(sentences[index].offset) / Double(length)
    }
}
