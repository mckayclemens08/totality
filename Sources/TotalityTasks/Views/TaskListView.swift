import SwiftUI
import TotalityCore
import TotalityUI

/// One of the person's lists: Inbox, Today, Upcoming, Anytime, Someday or the Logbook.
struct TaskListView: View {
    @Bindable var model: TasksModel
    let bucket: TaskBucket
    @Binding var expanded: UUID?
    // Set from the Today options menu in the header.
    @AppStorage("tasks.splitToday") private var splitToday = false
    @State private var scheduling: ScheduleTarget?
    @State private var query = ""

    var body: some View {
        let theme = Theme.current
        List {
            RefreshStatusLine(model.refresher)
                .plainRow()
            if model.unreadable > 0 {
                Label(
                    model.unreadable == 1 ? "1 task can't be opened with this device's key." : "\(model.unreadable) tasks can't be opened with this device's key.",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .plainRow()
            }
            content
            // Room for the + button under the last task.
            Color.clear
                .frame(height: Metric.addButton + Space.s5)
                .plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .environment(\.defaultMinListRowHeight, 0)
        .motion(Motion.smooth, value: model.tasks(in: bucket).map(\.id))
        .motion(Motion.smooth, value: expanded)
        .pullsToRefresh(with: model.refresher)
        .sheet(item: $scheduling) { target in
            ScheduleSheet(model: model, target: target) { scheduling = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch bucket {
        case .today: today
        case .upcoming: upcoming
        case .logbook: logbook
        default:
            let tasks = model.tasks(in: bucket)
            if tasks.isEmpty { EmptyList(bucket: bucket).plainRow() }
            rows(tasks)
        }
    }

    @ViewBuilder private var today: some View {
        let tasks = model.tasks(in: .today)
        let progress = model.progress
        if !progress.isEmpty {
            TodayProgressView(progress: progress)
                .padding(.bottom, Space.s4)
                .plainRow()
        }
        if tasks.isEmpty, !progress.isEmpty {
            Text("Everything for today is done.")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
                .frame(maxWidth: .infinity)
                .plainRow()
        } else if tasks.isEmpty {
            EmptyList(bucket: .today).plainRow()
        } else if splitToday {
            ForEach(TodayPart.allCases) { part in
                let inPart = tasks.filter { TaskRules.part(of: $0) == part }
                if !inPart.isEmpty {
                    if let name = part.name { SectionHeading(text: name).plainRow() }
                    rows(inPart)
                }
            }
        } else {
            rows(tasks)
        }
    }

    @ViewBuilder private var upcoming: some View {
        let days = model.upcoming
        let later = model.later
        if days.allSatisfy(\.isEmpty), later.isEmpty {
            EmptyList(bucket: .upcoming).plainRow()
        }
        ForEach(days) { day in
            SectionHeading(text: TaskText.heading(day.day, today: model.today, in: model.calendar), isQuiet: day.isEmpty)
                .plainRow()
            ForEach(day.events) { event in
                EventLine(event: event, calendar: model.calendar).plainRow()
            }
            rows(day.tasks)
            rows(day.deadlines)
        }
        if !later.isEmpty {
            SectionHeading(text: "Later").plainRow()
            rows(later)
        }
    }

    @ViewBuilder private var logbook: some View {
        let days = model.logbook(matching: query)
        SearchBox("Search the Logbook", text: $query)
            .padding(.bottom, Space.s2)
            .plainRow()
        if days.isEmpty {
            if query.isEmpty {
                EmptyList(bucket: .logbook).plainRow()
            } else {
                Text("Nothing done matches “\(query)”.")
                    .font(Typeface.callout)
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .padding(.vertical, Space.s5)
                    .plainRow()
            }
        }
        ForEach(days) { day in
            SectionHeading(text: TaskText.heading(day.day, today: model.today, in: model.calendar)).plainRow()
            rows(day.tasks)
        }
    }

    private func rows(_ tasks: [TaskItem]) -> some View {
        TaskRows(model: model, tasks: tasks, bucket: bucket, expanded: $expanded, scheduling: $scheduling)
    }
}

/// Tasks as raised cards in a list: tap to open in place, swipe right to complete or left to schedule,
/// long press to pick several, and drag by the handle onto a list or above another task.
struct TaskRows: View {
    let model: TasksModel
    let tasks: [TaskItem]
    /// The list they're shown in. Nil works it out for each task, as in a project.
    var bucket: TaskBucket?
    @Binding var expanded: UUID?
    @Binding var scheduling: ScheduleTarget?
    var showsList = true
    @Environment(\.taskSelection) private var selection

    var body: some View {
        ForEach(tasks) { task in
            TaskRow(
                model: model, task: task, bucket: bucket ?? TaskRules.bucket(of: task, today: model.today),
                isExpanded: expanded == task.id,
                onTap: { expanded = expanded == task.id ? nil : task.id },
                onSchedule: { scheduling = $0 },
                showsList: showsList
            )
            .dropsTask(above: task, in: tasks, model: model, selection: selection)
            // A long press opens this menu, and holding and moving drags instead, as everywhere on iOS.
            .contextMenu {
                if let selection, !selection.isOn {
                    Button("Select several", systemImage: "checkmark.circle") {
                        withMotion(Motion.snappy) { selection.start(with: task.id) }
                    }
                    Button(model.isDone(task.id) ? "Not done" : "Complete", systemImage: "checkmark") {
                        Task { await model.toggle(task.id) }
                    }
                    Button("Schedule", systemImage: "calendar") { scheduling = ScheduleTarget(id: task.id, kind: .when) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(tasks: [task.id]) }
                    }
                }
            }
            .id(task.id)
            // Every task is a raised card, with room between them for the shadows.
            .plainRow(vertical: Space.s1 + Space.s1 / 2)
            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await model.toggle(task.id) }
                } label: {
                    Label(model.isDone(task.id) ? "Not done" : "Complete", systemImage: "checkmark")
                }
                .tint(Theme.current.success.color)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    scheduling = ScheduleTarget(id: task.id, kind: .when)
                } label: {
                    Label("Schedule", systemImage: "calendar")
                }
                .tint(Theme.current.textSecondary.color)
            }
        }
    }
}

/// A day or part of the day, above its tasks.
struct SectionHeading: View {
    let text: String
    var isQuiet = false

    var body: some View {
        let theme = Theme.current
        Text(text)
            .font(Typeface.callout)
            .foregroundStyle(isQuiet ? theme.textSecondary.color : theme.textPrimary.color)
            .padding(.top, Space.s4)
            .padding(.bottom, Space.s1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A calendar event, shown faintly above the day's tasks. It can't be ticked: it's the calendar's.
struct EventLine: View {
    let event: AgendaItem
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Capsule()
                .fill(theme.highlightStrong.color)
                .frame(width: Space.s1 - Space.s1 / 4, height: Space.s4)
                .accessibilityHidden(true)
            Text(when)
                .font(Typeface.caption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
            Text(event.title)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.vertical, Space.s1 / 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calendar: \(event.title), \(when)")
    }

    private var when: String {
        guard !event.isAllDay else { return "All day" }
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = calendar.timeZone
        return event.start.formatted(style)
    }
}

/// What a list says when it's empty.
struct EmptyList: View {
    let bucket: TaskBucket

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Image(systemName: bucket.systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s8, height: Space.s8)
                .neumorphic(.subtle, in: Circle())
                .padding(.bottom, Space.s2)
                .accessibilityHidden(true)
            Text(bucket.emptyTitle)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(bucket.emptyDetail)
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s7)
        .padding(.horizontal, Space.s4)
    }
}

extension View {
    /// A list row with no separator or background of its own, so it sits on the surface.
    func plainRow(vertical: CGFloat = 0) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: vertical, leading: Space.s4, bottom: vertical, trailing: Space.s4))
    }
}
