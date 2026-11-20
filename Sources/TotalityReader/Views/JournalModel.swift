import Foundation

/// The journal's side of the Reader's model (issue 128).
extension ReaderModel {
    /// Reads the journal again. A failure here leaves the library usable and says so on the journal row.
    func loadJournal() async {
        do {
            journal = try await vault.journal()
            let today = try await vault.journalToday()
            let text = (try? await vault.journalText(of: today.id)) ?? ""
            journalTodayWords = DocVersions.words(text)
            journalLoaded = true
        } catch {
            journalLoaded = false
        }
    }

    /// Today's entry, kept or not yet written.
    func journalToday() async throws -> ReaderItem {
        try await vault.journalToday()
    }

    func journalNote(under day: String) async throws -> ReaderItem {
        try await vault.journalNote(under: day)
    }

    func journalText(of id: UUID) async throws -> String {
        try await vault.journalText(of: id)
    }

    /// Saves from the journal's editor. A day that ended while the person was typing is refused, and
    /// what they typed is kept as a note under today, so nothing is lost.
    func saveJournal(_ draft: ReaderItem, text: String, basedOn: Date) async -> NoteSave? {
        do {
            let result = try await vault.saveJournal(draft, body: text, basedOn: basedOn)
            await loadJournal()
            return result
        } catch ReaderError.journalClosed {
            if !text.isEmpty, let today = try? await vault.journalToday(), let day = draft.journal?.about ?? draft.journal?.day,
               let note = try? await vault.journalNote(under: day, now: Date(), zone: TimeZone(identifier: today.journal?.zone ?? "") ?? .current),
               case .saved(let kept)? = try? await vault.saveJournal(note, body: text, basedOn: note.updatedAt) {
                notice = "That day ended, so what you'd just written was kept as a note under it."
                await loadJournal()
                return .keptAsCopy(kept)
            }
            notice = ReaderError.journalClosed.message
        } catch let error as ReaderError {
            notice = error.message
        } catch {
            notice = "Your journal wasn't saved. Try again."
        }
        return nil
    }

    func journalItem(_ id: UUID) -> ReaderItem? {
        journal.entries.first { $0.id == id } ?? journal.notes.values.joined().first { $0.id == id }
    }

    var journalStreak: Int {
        JournalClock.streak(days: journal.days, today: JournalClock.day(of: Date(), in: .current))
    }

    /// The journal, or the days from `first` to `last`, as one Markdown manuscript for export: each day
    /// under its date, its notes after it with when they were added.
    func journalManuscript(from first: String? = nil, to last: String? = nil) async -> String {
        var parts: [String] = []
        let days = journal.days.sorted().filter { day in
            (first.map { day >= $0 } ?? true) && (last.map { day <= $0 } ?? true)
        }
        for day in days {
            var section = ["# \(JournalClock.heading(day))"]
            if let entry = journal.entries.first(where: { $0.journal?.day == day }),
               let text = try? await vault.journalText(of: entry.id), !text.isEmpty {
                section.append(text)
            }
            for note in journal.notes[day] ?? [] {
                guard let text = try? await vault.journalText(of: note.id), !text.isEmpty, let added = note.journal?.day else { continue }
                let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
                section.append("> **Added \(JournalClock.short(added)):**\n>\n\(quoted)")
            }
            parts.append(section.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Where the journal is showing (issue 128, owner 2026-11-20): today's page, the search, or one earlier
/// day on its own, opened from the calendar or a search result. Earlier days never stack above today.
struct JournalPlace: Equatable {
    /// The search is open, or a day was opened from it and going back returns to the results.
    var searching = false
    /// An earlier day, opened on its own. Nil is today's page or the search.
    var day: String?

    var isToday: Bool { day == nil && !searching }

    /// Opens a day. Today's own day is today's page.
    mutating func open(_ day: String, today: String?) {
        self.day = day == today ? nil : day
        if self.day == nil { searching = false }
    }

    mutating func search() {
        day = nil
        searching = true
    }

    /// One step back: from a day to the search it came from, or to today.
    mutating func back() {
        if day != nil { day = nil } else { searching = false }
    }

    mutating func goToToday() {
        self = JournalPlace()
    }

    var backLabel: String {
        if day != nil { return searching ? "Back to search" : "Back to today" }
        return searching ? "Back to today" : "Back to the Reader"
    }
}

/// A day the journal's search found, with a few words around the first match.
struct JournalHit: Identifiable, Equatable {
    let day: String
    let snippet: String
    var id: String { day }
}

/// Searching the journal's own words, on this device, after they're opened.
enum JournalSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Each day with a match once, newest first: its entry's words first, then its notes'.
    static func hits(_ query: String, entries: [ReaderItem], notes: [String: [ReaderItem]], texts: [UUID: String]) -> [JournalHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var byDay: [String: [ReaderItem]] = notes
        for entry in entries {
            guard let day = entry.journal?.day else { continue }
            byDay[day, default: []].insert(entry, at: 0)
        }
        return byDay.keys.sorted(by: >).compactMap { day in
            for item in byDay[day] ?? [] {
                if let text = texts[item.id], let snippet = snippet(of: text, around: query) {
                    return JournalHit(day: day, snippet: snippet)
                }
            }
            return nil
        }
    }

    /// The words around the first match on one line, without Markdown's markers, cut at whole words.
    static func snippet(of text: String, around query: String, before: Int = 40, after: Int = 90) -> String? {
        let plain = text.split(separator: "\n").map { line in
            var line = Substring(line.trimmingCharacters(in: .whitespaces))
            while let first = line.first, "#>-*".contains(first) { line = line.dropFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = plain.range(of: query, options: options) else { return nil }
        var start = plain.index(match.lowerBound, offsetBy: -before, limitedBy: plain.startIndex) ?? plain.startIndex
        var end = plain.index(match.upperBound, offsetBy: after, limitedBy: plain.endIndex) ?? plain.endIndex
        if start > plain.startIndex, let space = plain[start..<match.lowerBound].firstIndex(of: " ") {
            start = plain.index(after: space)
        }
        if end < plain.endIndex, let space = plain[match.upperBound..<end].lastIndex(of: " ") {
            end = space
        }
        let words = String(plain[start..<end])
        return (start > plain.startIndex ? "…" : "") + words + (end < plain.endIndex ? "…" : "")
    }
}
