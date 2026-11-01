import Foundation

/// Where in a sentence's audio a word starts, with its place in the text in UTF-16 units.
struct VoiceMark: Equatable, Sendable {
    let fraction: Double
    let offset: Int
}

/// A sentence's audio, and where its words fall. Without marks, the position is estimated from how
/// much of the audio has played.
struct VoiceSpeech: Sendable {
    var samples: [Float]
    var marks: [VoiceMark] = []
}

/// Finds each word in the audio from what the model planned: how long it gave each sound. That's what
/// the audio is built from, so the marks follow pauses and slow words, which a count of letters can't.
enum VoiceTiming {
    /// Kokoro makes this many samples for each frame it plans.
    private static let samplesPerFrame = 600

    private struct Word {
        let key: String
        let offset: Int
    }

    /// `said` is the text as the model read it, which spells out things like "$45". `kept` is the part
    /// of the audio that plays. Long sentences reach the model in pieces, and they return no marks.
    static func marks(text: String, said: String?, phonemes: String, durations: [Int], kept: Range<Int>) -> [VoiceMark] {
        let starts = wordStarts(phonemes: phonemes, durations: durations)
        let written = words(in: text)
        let spoken = words(in: said ?? text)
        guard !starts.isEmpty, !written.isEmpty, !spoken.isEmpty, !kept.isEmpty else { return [] }
        let places = places(of: spoken, in: written)
        var marks: [VoiceMark] = []
        for (index, frame) in starts.enumerated() {
            // The sounds and the words nearly always match one to one. When they don't, this stays close.
            let offset = written[places[index * spoken.count / starts.count]].offset
            guard offset > (marks.last?.offset ?? -1) else { continue }
            let played = frame * samplesPerFrame - kept.lowerBound
            marks.append(VoiceMark(fraction: min(max(Double(played) / Double(kept.count), 0), 1), offset: offset))
        }
        return marks
    }

    /// The frame each word starts on. There's one duration per sound, plus a start and an end.
    private static func wordStarts(phonemes: String, durations: [Int]) -> [Int] {
        let sounds = Array(phonemes.unicodeScalars)
        guard durations.count == sounds.count + 2 else { return [] }
        var frame = durations[0]
        var starts: [Int] = []
        var isNewWord = true
        for (sound, duration) in zip(sounds, durations.dropFirst()) {
            if sound == " " {
                isNewWord = true
            } else if isNewWord {
                starts.append(frame)
                isNewWord = false
            }
            frame += duration
        }
        return starts
    }

    /// The model reads a hyphenated word as separate words, so it's split the same way here.
    private static func words(in text: String) -> [Word] {
        text.split { $0.isWhitespace || "-–—".contains($0) }.map { word in
            Word(
                key: word.lowercased().filter { $0.isLetter || $0.isNumber },
                offset: word.startIndex.utf16Offset(in: text)
            )
        }
    }

    /// Which written word each spoken word belongs to. "$45" read as "forty five dollars" is one written
    /// word for all three, and a written word that wasn't read, like "[12]", is passed over.
    private static func places(of spoken: [Word], in written: [Word]) -> [Int] {
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in spoken.map(\.key).difference(from: written.map(\.key)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var place = 0
        var replaced: Int?
        return spoken.indices.map { index in
            if inserted.contains(index) {
                // Each new word takes the next written word it replaces. Any more share the last one.
                if removed.contains(place) {
                    replaced = place
                    place += 1
                }
                return replaced ?? min(place, written.count - 1)
            }
            while removed.contains(place) { place += 1 }
            replaced = nil
            place += 1
            return place - 1
        }
    }
}
