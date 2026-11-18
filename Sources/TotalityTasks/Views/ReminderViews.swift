@preconcurrency import MapKit
import SwiftUI
import TotalityUI
#if canImport(UIKit)
import UIKit
#endif

/// A task's reminders: what's set, nagging, and why one can't ring when it can't. Matches the "nagging"
/// and "reminders off" boards.
struct RemindersSheet: View {
    let model: TasksModel
    let taskID: UUID
    let onDone: () -> Void
    @State private var editing: Editing?

    enum Editing: Identifiable {
        case time(TaskReminder?)
        case place(TaskReminder?)

        var id: String {
            switch self {
            case .time(let r): "time" + (r?.id.uuidString ?? "")
            case .place(let r): "place" + (r?.id.uuidString ?? "")
            }
        }
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                if let task = model.tasks.first(where: { $0.id == taskID }) {
                    content(task)
                        .padding(Space.s4)
                }
            }
            .background(theme.bg.color)
            .navigationTitle("Reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .tint(theme.accent.color)
        .task { await model.refreshReminderAccess() }
        .sheet(item: $editing) { editing in
            switch editing {
            case .time(let reminder):
                TimeReminderSheet(model: model, taskID: taskID, reminder: reminder) { self.editing = nil }
            case .place(let reminder):
                PlaceReminderSheet(model: model, taskID: taskID, reminder: reminder) { self.editing = nil }
            }
        }
    }

    private func content(_ task: TaskItem) -> some View {
        let theme = Theme.current
        let access = model.reminderAccess
        let hasTime = task.reminders.contains { !$0.isPlace }
        let hasPlace = task.reminders.contains(where: \.isPlace)
        return VStack(alignment: .leading, spacing: Space.s3) {
            Text(task.displayTitle)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            badges(task)
            if !access.timeWorks, !task.reminders.isEmpty {
                OffNotice(
                    title: "Notifications are off for Totality",
                    text: "Your reminders are kept, but this iPhone won't show them. Turn on Allow Notifications in Settings.",
                    button: "Open Settings"
                )
            }
            if hasPlace, access.notifications != .denied, access.location == .whileUsing || access.location == .denied {
                OffNotice(
                    title: access.location == .denied ? "Location is off for Totality" : "Location is set to “While Using”",
                    text: "Place reminders need “Always”, so iOS can watch for the place while Totality is closed. Your location still never leaves the phone.",
                    button: "Change in Settings"
                )
            }
            if let until = task.snoozedUntil, until > model.now {
                HStack {
                    Label("Snoozed until " + until.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                    Spacer()
                    Button("Ring again now") { Task { await model.change(taskID) { $0.snoozedUntil = nil } } }
                        .font(Typeface.callout)
                }
            }
            GroupLabel("Reminder")
            if !task.reminders.isEmpty {
                VStack(spacing: 0) {
                    ForEach(task.reminders) { reminder in
                        reminderRow(reminder, task: task, paused: reminder.isPlace ? !access.placeWorks : !access.timeWorks)
                    }
                }
                .padding(.horizontal, Space.s3)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            HStack(spacing: Space.s2) {
                addButton("At a time", systemImage: "clock") { editing = .time(nil) }
                addButton("At a place", systemImage: "mappin.and.ellipse") { editing = .place(nil) }
            }
            if hasTime { NaggingCard(model: model, task: task) }
            if !task.reminders.isEmpty, !access.timeWorks || (hasPlace && !access.placeWorks) {
                Text("Tasks whose reminders can't ring show a small bell with a slash in your lists.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    private func badges(_ task: TaskItem) -> some View {
        FlowRow {
            if let deadline = task.deadline {
                let words = TaskText.deadline(deadline, today: model.today, in: model.calendar)
                    + (task.deadlineTime.map { " " + TaskText.time($0, in: model.calendar) } ?? "")
                Badge(text: words, isWarning: TaskRules.deadlineIsNear(task, today: model.today, in: model.calendar))
            }
            if let list = model.list(task.listID) { Badge(text: list.displayName) }
        }
    }

    private func reminderRow(_ reminder: TaskReminder, task: TaskItem, paused: Bool) -> some View {
        let theme = Theme.current
        let (icon, text, kind) = Self.describe(reminder, task: task, model: model)
        return HStack(spacing: Space.s3) {
            Button {
                editing = reminder.isPlace ? .place(reminder) : .time(reminder)
            } label: {
                HStack(spacing: Space.s3) {
                    IconTile(systemImage: paused ? "bell.slash" : icon)
                    Text(text)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                    Spacer(minLength: Space.s1)
                    Text(paused ? "Paused" : kind)
                        .font(Typeface.callout.weight(.regular))
                        .foregroundStyle(theme.textSecondary.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Task { await model.removeReminder(taskID, reminder.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove reminder")
        }
        .padding(.vertical, Space.s2)
    }

    /// The icon, the words and the kind of one reminder, as its row shows them.
    static func describe(_ reminder: TaskReminder, task: TaskItem, model: TasksModel) -> (String, String, String) {
        let calendar = model.calendar
        switch reminder.kind {
        case .at(let day, let time):
            return ("bell", TaskText.day(day, today: model.today, in: calendar) + ", " + TaskText.time(time, in: calendar), "At a time")
        case .beforeDeadline(let offset):
            let when = reminder.fireDate(for: task, in: calendar).map {
                TaskText.day(TaskDay($0, in: calendar), today: model.today, in: calendar) + ", " + TaskText.time(TaskTime($0, in: calendar), in: calendar)
            } ?? "Needs a deadline time"
            return ("bell", when, offset.name)
        case .place(let place):
            return ("mappin.and.ellipse", (place.onArrival ? "Arriving at " : "Leaving ") + place.name, "At a place")
        }
    }

    private func addButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small pale label, like "Due today 11:59 PM" or a list's name.
struct Badge: View {
    let text: String
    var isWarning = false

    var body: some View {
        let theme = Theme.current
        Text(text)
            .font(Typeface.micro.weight(.semibold))
            .foregroundStyle(isWarning ? theme.danger.color : theme.textSecondary.color)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .neumorphic(.flat, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// A rounded square holding a small accent icon.
struct IconTile: View {
    let systemImage: String

    var body: some View {
        let theme = Theme.current
        Image(systemName: systemImage)
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
            .frame(width: Space.s6, height: Space.s6)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.highlight.color))
            .accessibilityHidden(true)
    }
}

/// Why reminders can't ring here, with the way to Settings.
struct OffNotice: View {
    let title: String
    let text: String
    let button: String

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .top, spacing: Space.s3) {
                IconTile(systemImage: "bell.slash")
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text(text)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            #if os(iOS)
            Button(button) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(theme.accent.color)
            .padding(.leading, Space.s6 + Space.s3)
            #endif
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// "Keep reminding me until it's done": how often, and when to give up.
struct NaggingCard: View {
    let model: TasksModel
    let task: TaskItem

    var body: some View {
        let theme = Theme.current
        let nagging = task.nagging
        VStack(alignment: .leading, spacing: Space.s3) {
            Toggle(isOn: Binding(
                get: { nagging != nil },
                set: { on in Task { await model.setNagging(task.id, on ? Nagging() : nil) } }
            )) {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text("Keep reminding me until it's done")
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text("Stops the moment you tick it off")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .tint(theme.accent.color)
            if let nagging {
                GroupLabel("Remind again every")
                FlowRow {
                    ForEach(Nagging.intervals, id: \.self) { minutes in
                        OptionPill(title: minutes == 60 ? "1 hour" : "\(minutes) min", isOn: nagging.everyMinutes == minutes) {
                            var next = nagging
                            next.everyMinutes = minutes
                            Task { await model.setNagging(task.id, next) }
                        }
                    }
                }
                GroupLabel("Give up at")
                FlowRow {
                    giveUp("After 1 hour", .afterHours(1), nagging)
                    giveUp("After 3 hours", .afterHours(3), nagging)
                    giveUp("Midnight", .midnight, nagging)
                }
                preview(nagging)
            }
        }
        .padding(Space.s4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func giveUp(_ title: String, _ value: Nagging.GiveUp, _ nagging: Nagging) -> some View {
        OptionPill(title: title, isOn: nagging.giveUp == value) {
            var next = nagging
            next.giveUp = value
            Task { await model.setNagging(task.id, next) }
        }
    }

    /// The first run, as dots with times.
    @ViewBuilder
    private func preview(_ nagging: Nagging) -> some View {
        let theme = Theme.current
        let calendar = model.calendar
        let first = task.reminders.compactMap { $0.fireDate(for: task, in: calendar) }.filter { $0 > model.now }.min()
        if let first {
            let run = nagging.run(from: first, in: calendar)
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: 0) {
                    ForEach(0..<min(run.count, 5), id: \.self) { index in
                        VStack(spacing: Space.s1) {
                            Circle()
                                .fill(index == 0 ? theme.accent.color : theme.highlight.color)
                                .frame(width: Space.s3, height: Space.s3)
                            Text(TaskText.time(TaskTime(run[index], in: calendar), in: calendar))
                                .font(Typeface.micro)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if run.count > 5 {
                        Text("…").font(Typeface.micro).foregroundStyle(theme.textSecondary.color).frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
                Text("\(run.count) reminders at most, from \(TaskText.time(TaskTime(first, in: calendar), in: calendar)) to \(stopWords(nagging, first)).")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    private func stopWords(_ nagging: Nagging, _ first: Date) -> String {
        switch nagging.giveUp {
        case .midnight: return "midnight"
        case .afterHours(let hours):
            return TaskText.time(TaskTime(first.addingTimeInterval(Double(hours) * 3600), in: model.calendar), in: model.calendar)
        }
    }
}

/// Sets a time reminder: a day and a time, or a moment before the deadline. Matches the "time reminder" board.
struct TimeReminderSheet: View {
    let model: TasksModel
    let taskID: UUID
    let reminder: TaskReminder?
    let onDone: () -> Void
    @State private var day: TaskDay
    @State private var time: TaskTime
    @State private var offset: TaskReminder.DeadlineOffset?
    @State private var pickingDay = false
    @State private var pickingTime = false

    static let times = [TaskTime(hour: 9)!, TaskTime(hour: 12)!, TaskTime(hour: 17)!, TaskTime(hour: 21)!]

    init(model: TasksModel, taskID: UUID, reminder: TaskReminder?, onDone: @escaping () -> Void) {
        self.model = model
        self.taskID = taskID
        self.reminder = reminder
        self.onDone = onDone
        let task = model.tasks.first { $0.id == taskID }
        var day = task?.when ?? model.today.adding(days: 1, in: model.calendar)
        var time = task?.time ?? TaskReminder.morning
        var offset: TaskReminder.DeadlineOffset?
        switch reminder?.kind {
        case .at(let d, let t):
            day = d
            time = t
        case .beforeDeadline(let o):
            offset = o
        default:
            break
        }
        _day = State(initialValue: day)
        _time = State(initialValue: time)
        _offset = State(initialValue: offset)
    }

    private var calendar: Calendar { model.calendar }

    var body: some View {
        let theme = Theme.current
        let task = model.tasks.first { $0.id == taskID }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let task {
                        Text(task.displayTitle)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    bigTime(task)
                    GroupLabel("Day")
                    FlowRow {
                        let today = model.today
                        OptionPill(title: "Today", isOn: offset == nil && day == today) { pick(today) }
                        OptionPill(title: "Tomorrow", isOn: offset == nil && day == today.adding(days: 1, in: calendar)) {
                            pick(today.adding(days: 1, in: calendar))
                        }
                        let third = today.adding(days: 2, in: calendar)
                        OptionPill(title: short(third), isOn: offset == nil && day == third) { pick(third) }
                        OptionPill(title: "Pick a date", isOn: pickingDay) { pickingDay.toggle() }
                    }
                    if pickingDay {
                        DatePicker("Day", selection: dayBinding, in: model.today.start(in: calendar)..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.calendar, calendar)
                            .environment(\.timeZone, calendar.timeZone)
                            .padding(Space.s3)
                            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    GroupLabel("Time")
                    FlowRow {
                        ForEach(Self.times, id: \.self) { choice in
                            OptionPill(title: TaskText.time(choice, in: calendar), isOn: offset == nil && time == choice) {
                                time = choice
                                offset = nil
                            }
                        }
                    }
                    Button {
                        pickingTime.toggle()
                        offset = nil
                    } label: {
                        Label("Other time", systemImage: "clock")
                            .font(Typeface.body.weight(.semibold))
                            .foregroundStyle(theme.accent.color)
                            .padding(Space.s1)
                    }
                    .buttonStyle(.plain)
                    if pickingTime {
                        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                            #if os(iOS)
                            .datePickerStyle(.wheel)
                            #endif
                            .labelsHidden()
                            .environment(\.calendar, calendar)
                            .environment(\.timeZone, calendar.timeZone)
                            .frame(maxWidth: .infinity)
                    }
                    if let task, let deadline = task.deadline {
                        GroupLabel("Or before the deadline (" + TaskText.heading(deadline, today: model.today, in: calendar)
                            + (task.deadlineTime.map { ", " + TaskText.time($0, in: calendar) } ?? "") + ")")
                        FlowRow {
                            ForEach(TaskReminder.DeadlineOffset.allCases, id: \.self) { choice in
                                OptionPill(
                                    title: choice.name, isOn: offset == choice,
                                    isEnabled: choice != .hour || task.deadlineTime != nil
                                ) { offset = choice }
                            }
                        }
                        if task.deadlineTime == nil {
                            Text("“1 hour before” needs a time on the deadline.")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    if let task { alreadySet(task) }
                    Label("Set on this iPhone. It rings even with no signal.", systemImage: "lock")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.top, Space.s2)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Remind me")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let kind: TaskReminder.Kind = offset.map { .beforeDeadline($0) } ?? .at(day, time)
                        let saved = TaskReminder(id: reminder?.id ?? UUID(), kind: kind)
                        Task {
                            await model.replaceReminder(taskID, saved)
                            onDone()
                        }
                    }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private func bigTime(_ task: TaskItem?) -> some View {
        let theme = Theme.current
        let moment: Date? = if let offset, let task {
            TaskReminder(kind: .beforeDeadline(offset)).fireDate(for: task, in: calendar)
        } else {
            day.date(at: time, in: calendar)
        }
        return VStack(spacing: Space.s1) {
            if let moment {
                let fireDay = TaskDay(moment, in: calendar)
                Text(TaskText.day(fireDay, today: model.today, in: calendar))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Text(TaskText.time(TaskTime(moment, in: calendar), in: calendar))
                    .font(Typeface.display)
                    .foregroundStyle(theme.textPrimary.color)
                Text(TaskText.heading(fireDay, today: TaskDay(year: 1, month: 1, day: 1), in: calendar))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            } else {
                Text("Needs a deadline time").font(Typeface.body).foregroundStyle(theme.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Space.s4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    @ViewBuilder
    private func alreadySet(_ task: TaskItem) -> some View {
        let others = task.reminders.filter { !$0.isPlace && $0.id != reminder?.id }
        if !others.isEmpty {
            GroupLabel("Already set")
            VStack(spacing: 0) {
                ForEach(others) { other in
                    let (icon, text, kind) = RemindersSheet.describe(other, task: task, model: model)
                    HStack(spacing: Space.s3) {
                        IconTile(systemImage: icon)
                        Text(text).font(Typeface.body).foregroundStyle(Theme.current.textPrimary.color)
                        Spacer()
                        Text(kind).font(Typeface.callout.weight(.regular)).foregroundStyle(Theme.current.textSecondary.color)
                    }
                    .padding(.vertical, Space.s2)
                }
            }
            .padding(.horizontal, Space.s3)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private func pick(_ chosen: TaskDay) {
        day = chosen
        offset = nil
        pickingDay = false
    }

    private func short(_ day: TaskDay) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return day.start(in: calendar).addingTimeInterval(12 * 3600).formatted(style)
    }

    private var dayBinding: Binding<Date> {
        Binding(get: { day.start(in: calendar).addingTimeInterval(12 * 3600) }, set: {
            day = TaskDay($0, in: calendar)
            offset = nil
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: { TaskDay(year: 2026, month: 1, day: 15).date(at: time, in: calendar) }, set: {
            time = TaskTime($0, in: calendar)
            offset = nil
        })
    }
}

/// Sets a place reminder: where, arriving or leaving, and how near. Matches the "location reminder" board.
struct PlaceReminderSheet: View {
    let model: TasksModel
    let taskID: UUID
    let reminder: TaskReminder?
    let onDone: () -> Void
    @State private var place: ReminderPlace?
    @State private var searching = false

    init(model: TasksModel, taskID: UUID, reminder: TaskReminder?, onDone: @escaping () -> Void) {
        self.model = model
        self.taskID = taskID
        self.reminder = reminder
        self.onDone = onDone
        if case .place(let place) = reminder?.kind { _place = State(initialValue: place) }
    }

    var body: some View {
        let theme = Theme.current
        let task = model.tasks.first { $0.id == taskID }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let task {
                        Text(task.displayTitle)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    if let place { PlaceMap(place: place) }
                    Button {
                        searching = true
                    } label: {
                        HStack(spacing: Space.s3) {
                            IconTile(systemImage: "mappin.and.ellipse")
                            Text(place?.name ?? "Pick a place")
                                .font(Typeface.body)
                                .foregroundStyle(theme.textPrimary.color)
                            Spacer()
                            Text(place == nil ? "Search" : "Change")
                                .font(Typeface.callout.weight(.regular))
                                .foregroundStyle(theme.accent.color)
                            Image(systemName: "chevron.right")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textTertiary.color)
                        }
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    if let current = place {
                        GroupLabel("Remind me when I'm")
                        HStack(spacing: Space.s2) {
                            OptionPill(title: "Arriving", isOn: current.onArrival) { place?.onArrival = true }
                            OptionPill(title: "Leaving", isOn: !current.onArrival) { place?.onArrival = false }
                        }
                        GroupLabel("Within")
                        HStack(spacing: Space.s2) {
                            ForEach(ReminderPlace.radii, id: \.self) { radius in
                                OptionPill(title: "\(Int(radius)) m", isOn: current.radius == radius) { place?.radius = radius }
                            }
                        }
                    }
                    privacy
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Remind me at a place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let place else { return }
                        let saved = TaskReminder(id: reminder?.id ?? UUID(), kind: .place(place))
                        Task {
                            await model.replaceReminder(taskID, saved)
                            onDone()
                        }
                    }
                    .disabled(place == nil)
                }
            }
            .sheet(isPresented: $searching) {
                PlaceSearch { found in
                    var chosen = found
                    if let place {
                        chosen.radius = place.radius
                        chosen.onArrival = place.onArrival
                    }
                    place = chosen
                    searching = false
                }
            }
        }
        .tint(theme.accent.color)
        .task { await model.refreshReminderAccess() }
    }

    private var privacy: some View {
        let theme = Theme.current
        let location = model.reminderAccess.location
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s3) {
                IconTile(systemImage: "lock")
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Your location stays on this iPhone")
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text(
                        "The iPhone itself watches for this place. Totality never uploads where you are, and the place you picked is sealed before it syncs."
                            + (location == .always ? "" : " iOS will ask to allow location Always, so the reminder works while the app is closed.")
                    )
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                }
            }
            if location == .notAsked {
                Button {
                    Task { await model.askForAccess(place: true) }
                } label: {
                    Text("Allow location")
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.accentOn.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.s3)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.accent.color))
                }
                .buttonStyle(.plain)
                Text("Or tap Done: iOS asks then.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(Space.s4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .padding(.top, Space.s3)
    }
}

/// The picked place on a map, with its ring.
struct PlaceMap: View {
    let place: ReminderPlace

    var body: some View {
        let theme = Theme.current
        let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        Map(position: .constant(.region(MKCoordinateRegion(center: center, latitudinalMeters: place.radius * 5, longitudinalMeters: place.radius * 5)))) {
            MapCircle(center: center, radius: place.radius)
                .foregroundStyle(theme.accent.color.opacity(0.15))
                .stroke(theme.accent.color, lineWidth: Space.hairline * 2)
            Marker(place.name, coordinate: center)
                .tint(theme.accent.color)
        }
        .allowsHitTesting(false)
        .frame(height: Space.s8 * 3)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityLabel("Map of \(place.name)")
    }
}

/// Finds a place by name through Apple Maps. Only the words typed go to Apple; where the person is
/// doesn't.
struct PlaceSearch: View {
    let onPick: (ReminderPlace) -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    SearchBox("Search for a place", text: $query)
                    if failed {
                        Text("Places couldn't be searched just now. Check the connection and try again.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    } else if results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No places found yet.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button {
                            let c = item.placemark.coordinate
                            onPick(ReminderPlace(name: item.name ?? "Place", latitude: c.latitude, longitude: c.longitude))
                        } label: {
                            HStack(spacing: Space.s3) {
                                IconTile(systemImage: "mappin")
                                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                                    Text(item.name ?? "Place").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                    if let address = item.placemark.title {
                                        Text(address).font(Typeface.caption).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(Space.s3)
                            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(theme.accent.color)
        .task(id: query) {
            let words = query.trimmingCharacters(in: .whitespaces)
            guard words.count >= 2 else {
                results = []
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = words
            do {
                results = try await MKLocalSearch(request: request).start().mapItems
                failed = false
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                failed = (error as? MKError)?.code != .placemarkNotFound
            }
        }
    }
}
