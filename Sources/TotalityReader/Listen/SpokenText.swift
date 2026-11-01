import Foundation
import NaturalLanguage

/// Rewrites a sentence for the natural voice, which reads what's written. The page keeps the original.
enum SpokenText {
    private static let swaps: [(pattern: String, spoken: String)] = [
        (#"https?://(?:www\.)?([^/\s]+)\S*"#, "$1"),
        (#"\s*\[\d+(?:\s*[,–-]\s*\d+)*\]"#, ""),
        (#"\bFig\."#, "Figure"),
        (#"\bFigs\."#, "Figures"),
        (#"\bpp\.(?=\s*\d)"#, "pages"),
        (#"\bp\.(?=\s*\d)"#, "page"),
        (#"(?<=\d)\s*×\s*"#, " times "),
        (#"^[•*·]\s*"#, ""),
    ]

    /// Words whose sound depends on how they're used. The model always says the common one, so the verb
    /// is respelled to sound right.
    private static let verbs = ["live": "liv", "tear": "tare", "present": "prezent", "object": "ubject"]
    private static let afterHaving: Set<String> = ["had", "has", "have", "having", "was", "were", "been", "being"]

    static func prepared(_ text: String) -> String {
        var result = text
        for swap in swaps {
            result = result.replacingOccurrences(of: swap.pattern, with: swap.spoken, options: .regularExpression)
        }
        return respelled(result)
    }

    private static func respelled(_ text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var result = ""
        var last = text.startIndex
        var previous = ""
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let word = text[range]
            let bare = word.lowercased()
            var swap: String?
            if bare == "read", afterHaving.contains(previous) {
                swap = "red"
            } else if tag == .verb {
                swap = verbs[bare]
            }
            if let swap {
                result += text[last..<range.lowerBound] + (word.first?.isUppercase == true ? swap.capitalized : swap)
                last = range.upperBound
            }
            previous = bare
            return true
        }
        return result + text[last...]
    }
}

enum SpokenAudio {
    private static let sampleRate = 24_000.0
    private static let quiet: Float = 0.01
    private static let keptBefore = 0.03
    private static let keptAfter = 0.18

    /// The model pads each sentence with about a second of silence, which makes reading drag.
    static func kept(_ samples: [Float]) -> Range<Int> {
        guard let first = samples.firstIndex(where: { abs($0) > quiet }),
              let last = samples.lastIndex(where: { abs($0) > quiet })
        else { return samples.indices }
        let start = max(0, first - Int(keptBefore * sampleRate))
        let end = min(samples.count, last + 1 + Int(keptAfter * sampleRate))
        return start..<end
    }
}
