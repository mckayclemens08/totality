import SwiftUI
import TotalityUI

/// The journal's row, pinned at the top of the Reader: today's words and how many days running.
struct JournalRow: View {
    let model: ReaderModel

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Journal")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(model.journalLoaded == false ? theme.danger.color : theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock")
                .font(Typeface.micro)
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityLabel("Private")
        }
        .padding(.vertical, Space.s1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch model.journalLoaded {
        case nil: return "Opening"
        case false?: return "Your journal didn't open. Pull down to try again."
        case true?:
            let words = model.journalTodayWords == 1 ? "1 word" : "\(model.journalTodayWords) words"
            let streak = model.journalStreak
            return streak > 1 ? "Today · \(words) · \(streak) days running" : "Today · \(words)"
        }
    }
}

/// The journal (issue 128). It opens on today alone, with the cursor ready, and only today can be written
/// in. Earlier days are reached only by the calendar or the journal's own search (owner, 2026-11-20), and
/// open one at a time: read-only, and can be listened to, copied, and take notes added under them.
struct JournalView: View {
    let model: ReaderModel
    /// A day to show first, as from a search. Today when nil.
    let showing: String?

    @State private var today: ReaderItem?
    @State private var failed = false
    @State private var editor = WritingEditorController()
    @State private var texts: [UUID: String] = [:]
    @State private var noteFor: NoteDraft?
    @State private var showsMonth = false
    @State private var showsExport = false
    @State private var place = JournalPlace()
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    struct NoteDraft: Identifiable {
        let item: ReaderItem
        var id: UUID { item.id }
    }

    private var todayDay: String? { today?.journal?.day }

    /// Days with something in them, other than today.
    private var pastDays: Set<String> {
        model.journal.days.union(model.journal.notes.keys).subtracting([todayDay].compactMap { $0 })
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if failed {
                ReaderMessage(
                    systemImage: "lock.slash", title: "Your journal didn't open",
                    detail: "This device's copy couldn't be read. Go back and try again."
                )
            } else if let today {
                ZStack {
                    // Today's page stays put underneath, so its writing page doesn't start over.
                    todayPage(today)
                        .opacity(place.isToday ? 1 : 0)
                        .allowsHitTesting(place.isToday)
                        .accessibilityHidden(!place.isToday)
                    if let day = place.day {
                        dayPage(day)
                    } else if place.searching {
                        searchPage
                    }
                }
            } else {
                ProgressView("Opening your journal")
                    .font(Typeface.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.bg.color)
        // Outside the scrolling page, so it rides above the keyboard instead of hiding under it.
        .safeAreaInset(edge: .bottom) {
            if today != nil, place.isToday {
                WritingFormatBar(controller: editor)
                    .background(theme.bg.color)
            }
        }
        .navigationTitle("Journal")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The Journal draws its own header (redesign, 2026-11-17).
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            JournalHeader(
                place: place, streak: model.journalStreak,
                onBack: back,
                onToday: { withMotion(Motion.smooth) { place.goToToday() } },
                onSearch: { withMotion(Motion.smooth) { place.search() } },
                onCalendar: { showsMonth = true },
                onExport: { showsExport = true }
            )
        }
        .edgeSwipeBack { back() }
        .sheet(isPresented: $showsMonth) {
            JournalMonthSheet(days: model.journal.days.union(model.journal.notes.keys), today: todayDay) { day in
                showsMonth = false
                withMotion(Motion.smooth) {
                    place.goToToday()
                    place.open(day, today: todayDay)
                }
            }
        }
        .sheet(isPresented: $showsExport) {
            if let today {
                ExportSheet(
                    item: today, model: model,
                    read: { text in
                        guard let reply = await editor.call("exportDoc", text) else { return nil }
                        return ExportDocument(page: reply, title: "Journal")
                    },
                    currentText: {
                        await editor.flush()
                        return await model.journalManuscript()
                    },
                    journalDays: model.journal.days.sorted()
                )
            }
        }
        .sheet(item: $noteFor) { draft in
            JournalNoteSheet(draft: draft.item, model: model)
        }
        .task { await open() }
        .onChange(of: model.journal) { Task { await loadTexts() } }
    }

    private func back() {
        if place.isToday {
            dismiss()
        } else {
            withMotion(Motion.smooth) { place.back() }
        }
    }

    private func todayPage(_ today: ReaderItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                if pastDays.isEmpty {
                    Text("Your journal starts today")
                        .font(Typeface.title)
                        .foregroundStyle(Theme.current.textPrimary.color)
                        .padding(.top, Space.s4)
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    JournalTodayHeading(day: todayDay, notes: model.journal.notes[todayDay ?? ""] ?? [], texts: texts) { note in
                        noteFor = NoteDraft(item: note)
                    }
                    JournalEditor(
                        draft: today, model: model, editor: editor, placeholder: "What happened today?", focusOnOpen: showing == nil,
                        onDayEnd: { Task { await nextDay() } }, showsBar: false
                    )
                        // The page's own gutter lines the writing up with the headings above it.
                        .padding(.horizontal, -Space.s4)
                        .containerRelativeFrame(.vertical) { height, _ in height * 0.85 }
                }
            }
            .padding(.horizontal, Space.s4)
        }
    }

    /// One earlier day on its own, read-only.
    private func dayPage(_ day: String) -> some View {
        ScrollView {
            JournalDayPage(
                day: day, entry: entry(on: day), notes: model.journal.notes[day] ?? [], texts: texts,
                onListen: { id in Task { await model.startListening(to: id) } },
                onAddNote: { addNote(under: day) },
                onEditNote: { note in noteFor = NoteDraft(item: note) },
                onToday: { withMotion(Motion.smooth) { place.goToToday() } }
            )
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s2)
        }
        .background(Theme.current.bg.color)
    }

    private var searchPage: some View {
        var all = texts
        if let today { all[today.id] = editor.text }
        let hits = JournalSearch.hits(query, entries: model.journal.entries, notes: model.journal.notes, texts: all)
        return JournalSearchPage(query: $query, hits: hits, today: todayDay) { day in
            withMotion(Motion.smooth) { place.open(day, today: todayDay) }
        }
        .background(Theme.current.bg.color)
    }

    private func entry(on day: String) -> ReaderItem? {
        model.journal.entries.first { $0.journal?.day == day }
    }

    private func open() async {
        do {
            await model.loadJournal()
            today = try await model.journalToday()
            if let showing { place.open(showing, today: todayDay) }
            await loadTexts()
        } catch {
            failed = true
        }
    }

    /// Earlier days' words, for opening a day and for the search. A closed day's can't change, so it's
    /// read once. Notes and open days are read again.
    private func loadTexts() async {
        for item in model.journal.entries + model.journal.notes.values.joined() where item.id != today?.id {
            let closed = item.journal?.isClosed(at: Date()) == true
            if closed, texts[item.id] != nil, item.journal?.about == nil { continue }
            texts[item.id] = (try? await model.journalText(of: item.id)) ?? ""
        }
    }

    /// At 4 a.m. today locks and a fresh entry opens.
    private func nextDay() async {
        await model.loadJournal()
        today = try? await model.journalToday()
        await loadTexts()
    }

    private func addNote(under day: String) {
        Task {
            do {
                noteFor = NoteDraft(item: try await model.journalNote(under: day))
            } catch {
                model.notice = "A note couldn't be added here."
            }
        }
    }
}

/// The journal's header: back, the streak or a way to today, Search, Calendar and Export, then the title.
struct JournalHeader: View {
    let place: JournalPlace
    let streak: Int
    let onBack: () -> Void
    let onToday: () -> Void
    let onSearch: () -> Void
    let onCalendar: () -> Void
    let onExport: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                HeaderButton(place.backLabel, systemImage: "chevron.left", action: onBack)
                Spacer(minLength: 0)
                if !place.isToday {
                    HeaderPill("Today", action: onToday)
                } else if streak > 1 {
                    Text("\(streak)-day streak")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .background(theme.highlight.color, in: Capsule())
                }
                if !place.searching || place.day != nil {
                    HeaderButton("Search your journal", systemImage: "magnifyingglass", action: onSearch)
                }
                HeaderButton("Calendar", systemImage: "calendar", action: onCalendar)
                HeaderButton("Export", systemImage: "square.and.arrow.up", action: onExport)
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle("Journal")
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
        .background(theme.bg.color)
    }
}

/// Today's date, the seal, and any notes added today, above today's writing page.
struct JournalTodayHeading: View {
    let day: String?
    let notes: [ReaderItem]
    let texts: [UUID: String]
    let onEditNote: (ReaderItem) -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(day.map { "Today · \(JournalClock.heading($0))" } ?? "Today")
                .font(Typeface.callout.weight(.semibold))
                .foregroundStyle(theme.accent.color)
            // Literally true: every journal entry is sealed with ContentCipher before it's written or synced.
            Label("Sealed on this device before it syncs", systemImage: "lock.fill")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            ForEach(notes) { note in
                JournalNoteBlock(note: note, text: texts[note.id] ?? "") { onEditNote(note) }
            }
        }
    }
}

/// An earlier day opened on its own: the day in a card, or word that nothing was written, and a way back.
struct JournalDayPage: View {
    let day: String
    let entry: ReaderItem?
    let notes: [ReaderItem]
    let texts: [UUID: String]
    let onListen: (UUID) -> Void
    let onAddNote: () -> Void
    let onEditNote: (ReaderItem) -> Void
    let onToday: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if entry == nil && notes.isEmpty {
                ReaderMessage(
                    systemImage: "calendar", title: "Nothing written that day",
                    detail: "\(JournalClock.heading(day)) has no entry."
                )
            } else {
                JournalPastDay(
                    day: day, entry: entry, notes: notes, texts: texts,
                    onListen: onListen, onAddNote: onAddNote, onEditNote: onEditNote
                )
                .itemCard()
            }
            Button(action: onToday) {
                Label("Back to today", systemImage: "arrow.uturn.backward")
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(Theme.current.accent.color)
            }
            .buttonStyle(SoftPress())
        }
    }
}

/// The journal's own search: a box, then each day that matches with its date and the words around it.
struct JournalSearchPage: View {
    @Binding var query: String
    let hits: [JournalHit]
    let today: String?
    let onOpen: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            SearchBox("Search your journal", text: $query)
                .focused($focused)
            ScrollView {
                JournalSearchResults(query: query, hits: hits, today: today, onOpen: onOpen)
                    .padding(.bottom, Space.s4)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .onAppear { focused = true }
    }
}

/// What the journal's search found, or why there's nothing to show.
struct JournalSearchResults: View {
    let query: String
    let hits: [JournalHit]
    let today: String?
    let onOpen: (String) -> Void

    var body: some View {
        let theme = Theme.current
        LazyVStack(alignment: .leading, spacing: Space.s3) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Find a day by something you wrote in it. To go to a date, use the calendar.")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
            } else if hits.isEmpty {
                ReaderMessage(
                    systemImage: "magnifyingglass", title: "Nothing matches",
                    detail: "No day in your journal has “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."
                )
            } else {
                ForEach(hits) { hit in
                    Button { onOpen(hit.day) } label: {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(hit.day == today ? "Today · \(JournalClock.heading(hit.day))" : JournalClock.heading(hit.day))
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text(hit.snippet)
                                .font(Typeface.callout)
                                .foregroundStyle(theme.textSecondary.color)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .itemCard()
                    }
                    .buttonStyle(SoftPress())
                }
            }
        }
    }
}

/// An earlier day: quieter, locked, and read-only. Listen and copy still work.
struct JournalPastDay: View {
    let day: String
    let entry: ReaderItem?
    let notes: [ReaderItem]
    let texts: [UUID: String]
    let onListen: (UUID) -> Void
    let onAddNote: () -> Void
    let onEditNote: (ReaderItem) -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Text(JournalClock.heading(day))
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textSecondary.color)
                Image(systemName: "lock")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
                    .accessibilityLabel("Locked")
                Spacer(minLength: 0)
                if let entry {
                    Button { onListen(entry.id) } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Listen to \(JournalClock.heading(day))")
                }
            }
            if let entry { JournalWords(text: texts[entry.id] ?? "") }
            ForEach(notes) { note in
                JournalNoteBlock(note: note, text: texts[note.id] ?? "") { onEditNote(note) }
            }
            Button("Add a note", action: onAddNote)
                .buttonStyle(.plain)
                .font(Typeface.caption)
                .foregroundStyle(theme.accent.color)
        }
    }
}

/// A note added under a day: indented, and labelled with the day it was added.
struct JournalNoteBlock: View {
    let note: ReaderItem
    let text: String
    let onEdit: () -> Void

    var body: some View {
        let theme = Theme.current
        let open = note.journal?.isClosed(at: Date()) == false
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Text(label)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textTertiary.color)
                if open {
                    Button("Edit", action: onEdit)
                        .buttonStyle(.plain)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.accent.color)
                } else {
                    Image(systemName: "lock")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textTertiary.color)
                        .accessibilityLabel("Locked")
                }
            }
            JournalWords(text: text)
        }
        .padding(.leading, Space.s5)
    }

    private var label: String {
        let added = note.journal.map { JournalClock.short($0.day) } ?? ""
        return note.title == "Conflict copy" ? "Kept from another device, \(added)" : "Added \(added)"
    }
}

/// A day's words, read-only, in the quieter colour. They can be selected and copied.
private struct JournalWords: View {
    let text: String

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(Array(MarkdownText.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(_, let words):
                    Text(words).font(Typeface.headline)
                case .paragraph(let words):
                    Text(words).font(Typeface.body)
                case .item(let words):
                    Text("• \(words)").font(Typeface.body)
                case .code(let words):
                    Text(words).font(Typeface.code)
                }
            }
        }
        .foregroundStyle(theme.textSecondary.color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The writing page for today's entry or a note. It saves after a pause and when it goes away, and a day
/// that ends while it's open is refused by the vault however the page feels about it.
struct JournalEditor: View {
    let draft: ReaderItem
    let model: ReaderModel
    let editor: WritingEditorController
    let placeholder: String
    let focusOnOpen: Bool
    /// The entry's day has ended. Anything typed before then is saved first.
    var onDayEnd: () -> Void = {}
    /// Today's page puts the format bar above the keyboard itself, so the editor leaves it out.
    var showsBar = true

    private static let savePause = Duration.milliseconds(600)

    @State private var current: ReaderItem?
    @State private var savedRevision: Int?
    @State private var isSaving = false
    @State private var failed = false

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            if failed {
                ReaderMessage(systemImage: "lock.slash", title: "Today's entry didn't open", detail: "Go back and try again.")
            } else if case .failed(let reason) = editor.phase {
                ReaderMessage(systemImage: "exclamationmark.triangle", title: "The writing page didn't start", detail: reason)
            } else {
                WritingEditorView(controller: editor, webView: editor.webView)
                    .overlay {
                        if savedRevision == nil || editor.phase == .starting {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.bg.color)
                        }
                    }
                if showsBar { WritingFormatBar(controller: editor) }
            }
        }
        .task(id: draft.id) { await open() }
        .task(id: current?.journal?.locksAt) { await waitForDayEnd() }
        .onChange(of: editor.phase) { if editor.phase == .ready, focusOnOpen { editor.focus() } }
        .task(id: editor.revision) {
            try? await Task.sleep(for: Self.savePause)
            guard !Task.isCancelled else { return }
            await save()
        }
        .onChange(of: model.journal) {
            // Another device wrote here. With nothing unsaved, the page catches up.
            guard savedRevision == editor.revision, let current, let latest = model.journalItem(current.id),
                  latest.updatedAt != current.updatedAt
            else { return }
            Task { await open() }
        }
        .onDisappear {
            Task {
                await editor.flush()
                await save()
            }
        }
    }

    private func open() async {
        await editor.start()
        do {
            let text = try await model.journalText(of: draft.id)
            current = model.journalItem(draft.id) ?? draft
            // The cursor waits at the end, where today's writing goes on.
            editor.startPlace = (cursor: text.utf16.count, scroll: 1)
            editor.load(text, placeholder: placeholder)
            savedRevision = editor.revision
        } catch {
            failed = true
        }
    }

    /// Saves what's there a moment before the day locks, then hands over.
    private func waitForDayEnd() async {
        guard let locksAt = current?.journal?.locksAt else { return }
        let wait = locksAt.timeIntervalSinceNow - 2
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
        }
        await editor.flush()
        await save()
        try? await Task.sleep(for: .seconds(max(0, locksAt.timeIntervalSinceNow) + 1))
        guard !Task.isCancelled else { return }
        await editor.flush()
        // Anything typed in the last moment is refused by the vault, and kept as a note under the day.
        await save()
        onDayEnd()
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        while let saved = savedRevision, let item = current, editor.revision != saved {
            let revision = editor.revision
            switch await model.saveJournal(item, text: editor.text, basedOn: item.updatedAt) {
            case .saved(let kept):
                current = kept
                savedRevision = revision
            case .keptAsCopy:
                // What was typed is safe in a note. The page reads the entry as it is now.
                savedRevision = revision
                await open()
                return
            case nil:
                return
            }
        }
    }
}

/// Writing a note under an earlier day, in its own sheet.
private struct JournalNoteSheet: View {
    let draft: ReaderItem
    let model: ReaderModel

    @State private var editor = WritingEditorController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            JournalEditor(
                draft: draft, model: model, editor: editor, placeholder: "Add to this day", focusOnOpen: true,
                onDayEnd: { dismiss() }
            )
                .padding(Space.s4)
                .background(Theme.current.bg.color)
                .navigationTitle(draft.journal?.about.map { "Note on \(JournalClock.short($0))" } ?? "Note")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        // The page saves as it goes away.
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// A month at a time, with a dot under each day that has writing. Choosing a day goes to it.
private struct JournalMonthSheet: View {
    let days: Set<String>
    let today: String?
    let onPick: (String) -> Void

    @State private var month: (year: Int, month: Int) = (0, 0)
    @Environment(\.dismiss) private var dismiss

    private static let calendar = JournalClock.calendar(.current)

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s4) {
                HStack {
                    ToolbarIcon("Earlier month", systemImage: "chevron.left") { step(-1) }
                    Spacer()
                    Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                    Spacer()
                    ToolbarIcon("Later month", systemImage: "chevron.right") { step(1) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s1), count: 7), spacing: Space.s2) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(Typeface.micro).foregroundStyle(theme.textTertiary.color)
                    }
                    ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: Space.s6) }
                    ForEach(1...dayCount, id: \.self) { number in
                        dayCell(number)
                    }
                }
                Spacer()
            }
            .padding(Space.s4)
            .background(theme.bg.color)
            .navigationTitle("Your journal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if let today, let parts = JournalClock.components(today) {
                month = (parts.year, parts.month)
            } else {
                let now = Self.calendar.dateComponents([.year, .month], from: Date())
                month = (now.year ?? 2026, now.month ?? 1)
            }
        }
    }

    private func dayCell(_ number: Int) -> some View {
        let theme = Theme.current
        let key = JournalClock.key(DateComponents(year: month.year, month: month.month, day: number))
        let written = days.contains(key)
        return Button { if written || key == today { onPick(key) } } label: {
            VStack(spacing: Space.s1) {
                Text("\(number)")
                    .font(Typeface.caption)
                    .foregroundStyle(key == today ? theme.accent.color : written ? theme.textPrimary.color : theme.textTertiary.color)
                Circle()
                    .fill(written ? theme.accent.color : Color.clear)
                    .frame(width: Space.s1, height: Space.s1)
            }
            .frame(maxWidth: .infinity, minHeight: Space.s6)
        }
        .buttonStyle(.plain)
        .disabled(!written && key != today)
        .accessibilityLabel(written ? "\(JournalClock.heading(key)), written" : JournalClock.heading(key))
    }

    /// The weekday letters, starting on the day the week starts on, as the blanks before the 1st do.
    private var weekdays: [String] {
        let symbols = Self.calendar.veryShortWeekdaySymbols
        let start = (Self.calendar.firstWeekday - 1) % symbols.count
        return Array(symbols[start...] + symbols[..<start])
    }

    private var first: Date {
        Self.calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1, hour: 12)) ?? Date()
    }

    private var dayCount: Int {
        Self.calendar.range(of: .day, in: .month, for: first)?.count ?? 30
    }

    private var leadingBlanks: Int {
        (Self.calendar.component(.weekday, from: first) - Self.calendar.firstWeekday + 7) % 7
    }

    private var title: String {
        first.formatted(.dateTime.month(.wide).year())
    }

    private func step(_ offset: Int) {
        guard let moved = Self.calendar.date(byAdding: .month, value: offset, to: first) else { return }
        let parts = Self.calendar.dateComponents([.year, .month], from: moved)
        month = (parts.year ?? month.year, parts.month ?? month.month)
    }
}
