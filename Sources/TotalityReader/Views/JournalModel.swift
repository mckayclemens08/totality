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
