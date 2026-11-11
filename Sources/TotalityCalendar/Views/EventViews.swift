import SwiftUI
import TotalityCore
import TotalityUI

/// One event. The person's own events can be changed here. Device events are only shown.
struct EventDetailView: View {
    let entry: CalendarEntry
    let model: CalendarModel
    let onOpen: (ContentRef) -> Void
    let onChanged: () -> Void
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var editingGoogle = false
    @State private var confirmingGoogleDelete = false
    @State private var googleProblem: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private var google: GoogleEventKey? {
        if case .device(let event) = entry.source { event.google } else { nil }
    }

    private var occurrence: EventOccurrence? {
        if case .own(let occurrence) = entry.source { occurrence } else { nil }
    }

    private var when: String {
        let timing = Date.FormatStyle(date: .complete, time: .omitted)
        if let occurrence, occurrence.event.isAllDay {
            let own = occurrence.event.ownCalendar
            let first = CalendarDay(occurrence.start, in: own).start(in: model.display).formatted(timing)
            let last = CalendarDay(occurrence.end, in: own).start(in: model.display).formatted(timing)
            return first == last ? "\(first), all day" : "\(first) to \(last), all day"
        }
        if entry.isAllDay { return "\(entry.start.formatted(timing)), all day" }
        let start = entry.start.formatted(date: .complete, time: .shortened)
        let sameDay = model.display.isDate(entry.start, inSameDayAs: entry.end)
        return "\(start) to \(entry.end.formatted(date: sameDay ? .omitted : .complete, time: .shortened))"
    }

    private var notes: String {
        switch entry.source {
        case .own(let occurrence): occurrence.event.notes
        case .device(let event): event.notes
        }
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(entry.title)
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                Label(when, systemImage: "clock")
                if !entry.location.isEmpty { Label(entry.location, systemImage: "mappin.and.ellipse") }
                if let rule = occurrence?.event.repeatRule {
                    Label(rule.description(in: model.display), systemImage: "repeat")
                }
                if let minutes = occurrence?.event.reminderMinutes {
                    Label(ReminderText.name(minutes), systemImage: "bell")
                }
                if !notes.isEmpty {
                    Text(notes)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                        .padding(.top, Space.s2)
                }
                if let occurrence {
                    ForEach(occurrence.event.attachments, id: \.id) { ref in
                        AttachmentRow(ref: ref, model: model, onOpen: onOpen)
                    }
                } else if case .device(let event) = entry.source {
                    switch event.origin {
                    case .device:
                        Label("From your \(event.calendarTitle) calendar. It's read-only here, and Totality doesn't encrypt it.", systemImage: "calendar")
                            .padding(.top, Space.s2)
                    case .google(let account, let link):
                        Label(GoogleCalendarWording.origin(event.calendarTitle, canEdit: event.google?.canEdit == true), systemImage: "calendar")
                            .padding(.top, Space.s2)
                        if event.google?.canAllowEditing == true {
                            Text(GoogleCalendarWording.allowEditing)
                            Button("Allow editing for \(account)") {
                                let session = webAuthenticationSession
                                Task {
                                    await model.allowGoogleEditing(account) { page, scheme in
                                        try await session.authenticate(using: page, callbackURLScheme: scheme, preferredBrowserSession: .shared)
                                    }
                                }
                            }
                            .disabled(model.isConnectingGoogle)
                            .foregroundStyle(Theme.current.accent.color)
                        }
                        if let link {
                            Link(destination: link) {
                                Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                            }
                            .foregroundStyle(Theme.current.accent.color)
                        }
                    }
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.textSecondary.color)
            .padding(Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
            .padding(Space.s4)
        }
        .background(theme.bg.color)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if occurrence != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash") { confirmingDelete = true }
                }
            } else if google?.canEdit == true {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editingGoogle = true }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash") { confirmingGoogleDelete = true }
                        .disabled(model.isSendingToGoogle)
                }
            }
        }
        .sheet(isPresented: $editingGoogle) {
            if let google {
                NavigationStack {
                    EventEditorView(model: model, draft: model.draft(for: google), occurrence: nil, google: google) {
                        editingGoogle = false
                        onChanged()
                    } onCancel: {
                        editingGoogle = false
                    }
                }
                .tint(Theme.current.accent.color)
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(entry.title)\u{201D} from Google Calendar?", isPresented: $confirmingGoogleDelete, titleVisibility: .visible
        ) {
            if let google {
                if google.repeats {
                    Button("This event", role: .destructive) { deleteGoogle(google, .thisOccurrence) }
                    Button("All events", role: .destructive) { deleteGoogle(google, .allOccurrences) }
                } else {
                    Button("Delete", role: .destructive) { deleteGoogle(google, .thisOccurrence) }
                }
            }
        } message: {
            Text(GoogleCalendarWording.deleteDetail)
        }
        .alert("Google Calendar", isPresented: googleProblemShown) {
            Button("OK", role: .cancel) { googleProblem = nil }
        } message: {
            Text(googleProblem ?? "")
        }
        .sheet(isPresented: $editing) {
            if let occurrence {
                NavigationStack {
                    EventEditorView(model: model, draft: model.draft(for: occurrence), occurrence: occurrence) {
                        editing = false
                        onChanged()
                    } onCancel: {
                        editing = false
                    }
                }
                .tint(Theme.current.accent.color)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            if let occurrence {
                if occurrence.event.repeatRule != nil {
                    Button("This event only", role: .destructive) { delete(occurrence, .thisOccurrence) }
                    Button("All of them", role: .destructive) { delete(occurrence, .allOccurrences) }
                } else {
                    Button("Delete", role: .destructive) { delete(occurrence, .allOccurrences) }
                }
            }
        }
    }

    private func delete(_ occurrence: EventOccurrence, _ scope: EditScope) {
        Task {
            await model.delete(occurrence, scope: scope)
            onChanged()
        }
    }

    private func deleteGoogle(_ key: GoogleEventKey, _ scope: EditScope) {
        Task {
            if let problem = await model.deleteGoogle(key, scope: scope) {
                googleProblem = GoogleCalendarWording.notSaved(problem)
            } else {
                onChanged()
            }
        }
    }

    private var googleProblemShown: Binding<Bool> {
        Binding(get: { googleProblem != nil }, set: { if !$0 { googleProblem = nil } })
    }
}

private struct AttachmentRow: View {
    let ref: ContentRef
    let model: CalendarModel
    let onOpen: (ContentRef) -> Void
    @State private var current: ContentRef?
    @State private var checked = false

    var body: some View {
        let theme = Theme.current
        Group {
            if let current {
                Button {
                    onOpen(current)
                } label: {
                    Label(current.preview.title, systemImage: current.kind == .note ? "note.text" : "doc")
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            } else if checked {
                Label("\(ref.preview.title) is no longer here.", systemImage: "questionmark.folder")
            } else {
                Label(ref.preview.title, systemImage: "doc")
            }
        }
        .padding(.top, Space.s1)
        .task {
            current = await model.current(ref)
            checked = true
        }
    }
}

extension RepeatRule {
    func description(in display: Calendar) -> String {
        guard let until else { return frequency.name }
        return "\(frequency.name) until \(until.start(in: display).formatted(date: .abbreviated, time: .omitted))"
    }
}

enum ReminderText {
    static func name(_ minutes: Int?) -> String {
        switch minutes {
        case nil: "None"
        case 0: "At the start"
        case 60: "1 hour before"
        case 1_440: "1 day before"
        case let minutes?: "\(minutes) minutes before"
        }
    }
}

/// Creating an event and editing one are the same form. Saving a repeating event asks how far it goes.
/// A Google event, or a new one on a Google calendar, goes through a confirm sheet first, and only its
/// press sends anything (issue 88).
struct EventEditorView: View {
    let model: CalendarModel
    let occurrence: EventOccurrence?
    /// The Google event being edited, or nil.
    let google: GoogleEventKey?
    let onDone: () -> Void
    let onCancel: () -> Void
    @State private var draft: EventDraft
    /// Where a new event goes. Nil is Totality's own calendar, the default (issue 88, decision 9).
    @State private var target: GoogleTarget?
    @State private var pending: GoogleChange?
    @State private var choosingGoogleScope = false
    @State private var choosingScope = false
    @State private var attaching = false
    @State private var showingNotes = false
    @FocusState private var typingTitle: Bool

    init(
        model: CalendarModel, draft: EventDraft, occurrence: EventOccurrence?, google: GoogleEventKey? = nil,
        onDone: @escaping () -> Void, onCancel: (() -> Void)? = nil
    ) {
        self.model = model
        self.occurrence = occurrence
        self.google = google
        self.onDone = onDone
        self.onCancel = onCancel ?? onDone
        _draft = State(initialValue: draft)
    }

    private var dateParts: DatePickerComponents {
        draft.isAllDay ? [.date] : [.date, .hourAndMinute]
    }

    var body: some View {
        let theme = Theme.current
        Form {
            if occurrence == nil, google == nil, !model.googleTargets.isEmpty {
                Section {
                    Picker("Calendar", selection: $target) {
                        Text("Totality").tag(GoogleTarget?.none)
                        ForEach(model.googleTargets) { target in
                            Text("\(target.title) (\(target.account))").tag(Optional(target))
                        }
                    }
                } footer: {
                    Text(isGoogle ? GoogleCalendarWording.savedToGoogle : "Kept in Totality, encrypted with your key.")
                }
            }
            if let google {
                Section {
                    Label("\(google.calendarTitle) (\(google.account))", systemImage: "calendar")
                } footer: {
                    Text(GoogleCalendarWording.savedToGoogle)
                }
            }
            Section {
                TextField("Title", text: $draft.title)
                    .font(Typeface.title)
                    .focused($typingTitle)
                TextField("Location", text: $draft.location)
            }
            Section {
                Toggle("All day", isOn: $draft.isAllDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: dateParts)
                DatePicker("Ends", selection: $draft.end, displayedComponents: dateParts)
            }
            if google != nil {
                if google?.repeats == true {
                    Section {
                        Text(GoogleCalendarWording.repeatStaysGoogle)
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
            } else {
            Section {
                Picker("Repeat", selection: $draft.frequency) {
                    Text("Never").tag(RepeatRule.Frequency?.none)
                    ForEach(RepeatRule.Frequency.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                if draft.frequency != nil {
                    Toggle("Ends", isOn: repeatEnds)
                    if let until = draft.until {
                        DatePicker("Last day", selection: Binding(get: { until }, set: { draft.until = $0 }), displayedComponents: [.date])
                    }
                }
                if !isGoogle {
                    Picker("Reminder", selection: $draft.reminderMinutes) {
                        ForEach(CalendarModel.reminderChoices, id: \.self) { Text(ReminderText.name($0)).tag($0) }
                    }
                }
            } footer: {
                if draft.reminderMinutes != nil, !isGoogle {
                    Text("Reminders show the event's title and time, including on your lock screen. Your device keeps those outside Totality's encryption until the reminder fires.")
                }
            }
            }
            Section {
                if showingNotes || !draft.notes.isEmpty {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                } else {
                    Button("Add notes", systemImage: "text.alignleft") { showingNotes = true }
                }
                ForEach(draft.attachments, id: \.id) { ref in
                    HStack {
                        Text(ref.preview.title).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "xmark") { draft.attachments.removeAll { $0.id == ref.id } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                    }
                }
                if !isGoogle {
                    Button("Attach from Reader", systemImage: "paperclip") { attaching = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle(occurrence == nil && google == nil ? "New event" : "Edit event")
        .task { typingTitle = occurrence == nil }
        .onChange(of: draft.start) { old, new in
            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .sheet(isPresented: $attaching) {
            NavigationStack {
                AttachmentPicker(model: model, chosen: draft.attachments) { ref in
                    draft.attachments.append(ref)
                    attaching = false
                } onCancel: {
                    attaching = false
                }
            }
            .tint(theme.accent.color)
        }
        .confirmationDialog("Change which events?", isPresented: $choosingScope, titleVisibility: .visible) {
            Button("This event only") { finish(.thisOccurrence) }
            Button("All of them") { finish(.allOccurrences) }
        }
        .confirmationDialog("Change which events?", isPresented: $choosingGoogleScope, titleVisibility: .visible) {
            Button("This event") { askGoogle(.thisOccurrence) }
            Button("All events") { askGoogle(.allOccurrences) }
        }
        .sheet(item: $pending) { change in
            NavigationStack {
                GoogleConfirmSheet(model: model, change: change) {
                    pending = nil
                    onDone()
                } onCancel: {
                    pending = nil
                }
            }
            .tint(theme.accent.color)
        }
        .alert("Calendar", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var repeatEnds: Binding<Bool> {
        Binding(
            get: { draft.until != nil },
            set: { draft.until = $0 ? draft.start : nil }
        )
    }

    private var isGoogle: Bool { google != nil || target != nil }

    private func save() {
        if let google {
            if google.repeats { choosingGoogleScope = true } else { askGoogle(.thisOccurrence) }
            return
        }
        if let target {
            pending = model.googleChange(draft, to: target)
            return
        }
        if occurrence?.event.repeatRule != nil {
            choosingScope = true
        } else {
            finish(.allOccurrences)
        }
    }

    /// Shows the confirm sheet. Nothing is sent from here.
    private func askGoogle(_ scope: EditScope) {
        guard let google else { return }
        // After Google said the event changed, the newer version is the one to save over.
        pending = model.googleChange(draft, editing: model.latest(google), scope: scope)
    }

    private func finish(_ scope: EditScope) {
        Task {
            let saved = if let occurrence {
                await model.update(occurrence, with: draft, scope: scope)
            } else {
                await model.create(draft)
            }
            if saved { onDone() }
        }
    }
}

private struct AttachmentPicker: View {
    let model: CalendarModel
    let chosen: [ContentRef]
    let onPick: (ContentRef) -> Void
    let onCancel: () -> Void
    @State private var available: [ContentRef]?

    var body: some View {
        let theme = Theme.current
        Group {
            if let available {
                let options = available.filter { option in !chosen.contains { $0.id == option.id } }
                if options.isEmpty {
                    CalendarMessage(systemImage: "book", title: "Nothing to attach", detail: "Notes and files from your Reader show up here.")
                } else {
                    List(options, id: \.id) { ref in
                        Button {
                            onPick(ref)
                        } label: {
                            Label(ref.preview.title, systemImage: ref.kind == .note ? "note.text" : "doc")
                                .foregroundStyle(theme.textPrimary.color)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.bg.color)
        .navigationTitle("Attach")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
        .task { available = await model.attachableContent() }
    }
}

/// Exactly what goes to Google, and the one press that sends it (issue 88, decision 2). Cancelling sends
/// nothing, and a problem leaves the editor and what was typed as they were.
struct GoogleConfirmSheet: View {
    let model: CalendarModel
    let change: GoogleChange
    let onSent: () -> Void
    let onCancel: () -> Void
    @State private var problem: String?

    private var heading: String {
        switch change.action {
        case .create: "Add to Google Calendar?"
        case .update(_, .allOccurrences): "Change every occurrence in Google Calendar?"
        case .update: "Change this event in Google Calendar?"
        }
    }

    private var when: String {
        let body = change.body
        if body.isAllDay {
            let style = Date.FormatStyle(date: .complete, time: .omitted, timeZone: .gmt)
            let first = body.start.formatted(style), last = body.end.formatted(style)
            return first == last ? "\(first), all day" : "\(first) to \(last), all day"
        }
        return "\(body.start.formatted(date: .complete, time: .shortened)) to \(body.end.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        let theme = Theme.current
        Form {
            Section {
                Text(heading).font(Typeface.title)
                LabeledContent("Account", value: change.account)
                LabeledContent("Calendar", value: change.calendarTitle)
                LabeledContent("Title", value: change.body.title.isEmpty ? "Untitled event" : change.body.title)
                LabeledContent("When", value: when)
                if case .create = change.action {
                    LabeledContent("Repeats", value: change.body.repeatRule.map { $0.frequency.name } ?? "No")
                }
                if !change.body.location.isEmpty { LabeledContent("Location", value: change.body.location) }
                if !change.body.notes.isEmpty { LabeledContent("Notes", value: change.body.notes) }
            } footer: {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(GoogleCalendarWording.savedToGoogle)
                    if change.hasGuests { Text(GoogleCalendarWording.guestsUntouched) }
                }
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.danger.color)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle("Google Calendar")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isSendingToGoogle {
                    ProgressView()
                } else {
                    Button("Save to Google", action: send)
                }
            }
        }
        .interactiveDismissDisabled(model.isSendingToGoogle)
    }

    private func send() {
        Task {
            if let found = await model.send(change) {
                problem = GoogleCalendarWording.notSaved(found)
            } else {
                onSent()
            }
        }
    }
}
