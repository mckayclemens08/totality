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
    @Environment(\.colorScheme) private var scheme

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
        let theme = Theme.current(scheme)
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
                    Label("From your \(event.calendarTitle) calendar. It's read-only here, and Totality doesn't encrypt it.", systemImage: "calendar")
                        .padding(.top, Space.s2)
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.textSecondary.color)
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg.color)
        .navigationTitle("Event")
        .toolbar {
            if occurrence != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash") { confirmingDelete = true }
                }
            }
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
                .tint(Theme.current(scheme).accent.color)
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
}

private struct AttachmentRow: View {
    let ref: ContentRef
    let model: CalendarModel
    let onOpen: (ContentRef) -> Void
    @State private var current: ContentRef?
    @State private var checked = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
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
struct EventEditorView: View {
    let model: CalendarModel
    let occurrence: EventOccurrence?
    let onDone: () -> Void
    let onCancel: () -> Void
    @State private var draft: EventDraft
    @State private var choosingScope = false
    @State private var attaching = false
    @Environment(\.colorScheme) private var scheme

    init(model: CalendarModel, draft: EventDraft, occurrence: EventOccurrence?, onDone: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        self.model = model
        self.occurrence = occurrence
        self.onDone = onDone
        self.onCancel = onCancel ?? onDone
        _draft = State(initialValue: draft)
    }

    private var dateParts: DatePickerComponents {
        draft.isAllDay ? [.date] : [.date, .hourAndMinute]
    }

    var body: some View {
        let theme = Theme.current(scheme)
        Form {
            Section {
                TextField("Title", text: $draft.title)
                TextField("Location", text: $draft.location)
            }
            Section {
                Toggle("All day", isOn: $draft.isAllDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: dateParts)
                DatePicker("Ends", selection: $draft.end, displayedComponents: dateParts)
            }
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
            }
            Section {
                Picker("Reminder", selection: $draft.reminderMinutes) {
                    ForEach(CalendarModel.reminderChoices, id: \.self) { Text(ReminderText.name($0)).tag($0) }
                }
            } footer: {
                Text("Reminders show the event's title and time, including on your lock screen. Your device keeps those outside Totality's encryption until the reminder fires.")
            }
            Section("Attached") {
                ForEach(draft.attachments, id: \.id) { ref in
                    HStack {
                        Text(ref.preview.title).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "xmark") { draft.attachments.removeAll { $0.id == ref.id } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                    }
                }
                Button("Attach from Reader") { attaching = true }
            }
            Section("Notes") {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle(occurrence == nil ? "New event" : "Edit event")
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

    private func save() {
        if occurrence?.event.repeatRule != nil {
            choosingScope = true
        } else {
            finish(.allOccurrences)
        }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
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
