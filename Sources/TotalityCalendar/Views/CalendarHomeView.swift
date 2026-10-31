import SwiftUI
import TotalityCore
import TotalityUI

/// The Calendar's front screen: the agenda and the month, with new events and device calendars.
public struct CalendarHomeView: View {
    @Bindable private var model: CalendarModel
    private let onClose: (() -> Void)?
    private let onOpen: (ContentRef) -> Void
    @State private var path: [CalendarEntry] = []
    @State private var creating = false
    @State private var showingSources = false

    public init(model: CalendarModel, onClose: (() -> Void)? = nil, onOpen: @escaping (ContentRef) -> Void = { _ in }) {
        self.model = model
        self.onClose = onClose
        self.onOpen = onOpen
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            content
                .background(theme.bg.color)
                .navigationTitle("Calendar")
                .navigationDestination(for: CalendarEntry.self) { entry in
                    EventDetailView(entry: entry, model: model, onOpen: onOpen) { path.removeAll() }
                }
                .toolbar { toolbar }
        }
        .tint(theme.accent.color)
        .sheet(isPresented: $creating) {
            NavigationStack {
                EventEditorView(model: model, draft: model.newDraft(), occurrence: nil) { creating = false }
            }
            .tint(theme.accent.color)
        }
        .sheet(isPresented: $showingSources) {
            NavigationStack {
                DeviceCalendarsView(model: model) { showingSources = false }
            }
            .tint(theme.accent.color)
        }
        .alert("Calendar", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task { await model.load() }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button("Home", systemImage: "circle.hexagongrid", action: onClose)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button("Calendars", systemImage: "calendar.badge.checkmark") { showingSources = true }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New event", systemImage: "plus") { creating = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening your calendar")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            CalendarMessage(
                systemImage: "exclamationmark.triangle",
                title: "Your calendar didn't open",
                detail: "This device's storage couldn't be read. Close the Calendar and try again."
            )
        case .ready:
            VStack(spacing: Space.s3) {
                Picker("View", selection: $model.mode) {
                    ForEach(CalendarModel.Mode.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Space.s4)
                switch model.mode {
                case .agenda: agenda
                case .month: MonthView(model: model)
                }
            }
        }
    }

    @ViewBuilder private var agenda: some View {
        let days = model.agenda
        if days.isEmpty && model.unreadable == 0 {
            CalendarMessage(
                systemImage: "calendar",
                title: "Nothing coming up",
                detail: model.isSynced
                    ? "Add an event, or show your Apple and Google calendars here. Events you add here are encrypted, and sync between your devices."
                    : "Add an event, or show your Apple and Google calendars here. Events you add here are encrypted and aren't synced between your devices yet."
            )
        } else {
            List {
                CalendarNotes(model: model)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            NavigationLink(value: entry) {
                                EntryRow(entry: entry)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(heading(for: day.day))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func heading(for day: CalendarDay) -> String {
        if day == model.today { return "Today" }
        if day == model.today.adding(days: 1, in: model.display) { return "Tomorrow" }
        return day.start(in: model.display).formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// The two things worth saying above the list: what's unreadable, and where events are kept.
struct CalendarNotes: View {
    let model: CalendarModel

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            if model.unreadable > 0 {
                Label(unreadableText, systemImage: "lock.slash")
                    .foregroundStyle(theme.danger.color)
            }
            Label(
                model.isSynced
                    ? "Events you add here are encrypted, and sync between your devices. Apple and Google calendars aren't encrypted by Totality."
                    : "Events you add here are encrypted and can't be recovered on a new device yet. Apple and Google calendars aren't encrypted by Totality.",
                systemImage: model.isSynced ? "lock" : "iphone"
            )
                .foregroundStyle(theme.textSecondary.color)
        }
        .font(Typeface.caption)
    }

    private var unreadableText: String {
        model.unreadable == 1
            ? "1 event can't be opened on this device."
            : "\(model.unreadable) events can't be opened on this device."
    }
}

struct EntryRow: View {
    let entry: CalendarEntry

    private var isOwn: Bool {
        if case .own = entry.source { true } else { false }
    }

    private var caption: String {
        var parts: [String] = []
        if case .device(let event) = entry.source, !event.calendarTitle.isEmpty { parts.append(event.calendarTitle) }
        if !entry.location.isEmpty { parts.append(entry.location) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(entry.isAllDay ? "All day" : entry.start.formatted(date: .omitted, time: .shortened))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(minWidth: Space.s8, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(entry.title)
                    .font(Typeface.headline)
                    .foregroundStyle(isOwn ? theme.textPrimary.color : theme.textSecondary.color)
                    .lineLimit(2)
                if !caption.isEmpty {
                    Text(caption)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
    }
}

struct CalendarMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceCalendarsView: View {
    let model: CalendarModel
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        Form {
            switch model.deviceAccess {
            case .notAsked:
                Section {
                    Text("Show the calendars already on this device, including any Google account you've added to it. They're read-only here, Totality doesn't copy or encrypt them, and Apple or Google keeps them in sync.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                    Button("Show my calendars") { Task { await model.allowDeviceCalendars() } }
                }
            case .denied:
                Section {
                    Text("Totality can't see this device's calendars. You can allow it in Settings, under Privacy & Security, then Calendars.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                }
            case .allowed:
                Section {
                    if model.deviceCalendars.isEmpty {
                        Text("There are no calendars on this device yet.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    ForEach(model.deviceCalendars) { calendar in
                        Toggle(isOn: visible(calendar)) {
                            VStack(alignment: .leading, spacing: Space.s1) {
                                Text(calendar.title).font(Typeface.body)
                                if !calendar.account.isEmpty {
                                    Text(calendar.account)
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Read-only here. Totality doesn't copy or encrypt these.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle("Calendars")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }

    private func visible(_ calendar: DeviceCalendar) -> Binding<Bool> {
        Binding(
            get: { !model.hiddenCalendars.contains(calendar.id) },
            set: { model.setVisible($0, calendar: calendar) }
        )
    }
}
