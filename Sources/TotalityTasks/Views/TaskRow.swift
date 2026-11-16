import SwiftUI
import TotalityCore
import TotalityUI

/// One task on the surface: its title and one quiet line. Tapping opens the whole task in place.
struct TaskRow: View {
    let model: TasksModel
    let task: TaskItem
    let bucket: TaskBucket
    let isExpanded: Bool
    let onTap: () -> Void
    let onSchedule: (ScheduleTarget) -> Void

    var body: some View {
        let isDone = model.isDone(task.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.s2) {
                TickBox(isDone: isDone, title: task.displayTitle) {
                    Task { await model.toggle(task.id) }
                }
                if isExpanded {
                    TaskEditor(model: model, task: task, onSchedule: onSchedule)
                } else {
                    summary(isDone: isDone)
                }
            }
        }
        .padding(.vertical, isExpanded ? Space.s3 : 0)
        .padding(.trailing, isExpanded ? Space.s3 : 0)
        // Closed, a task is a row on the surface. Open, it rises into a card.
        .background {
            if isExpanded {
                Color.clear.neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
        .animation(Motion.standard, value: isExpanded)
    }

    private func summary(isDone: Bool) -> some View {
        let theme = Theme.current
        return HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(task.displayTitle)
                    .font(Typeface.body)
                    .foregroundStyle(isDone && bucket != .logbook ? theme.textSecondary.color : theme.textPrimary.color)
                    .lineLimit(2)
                if let line = quietLine {
                    line
                        .font(Typeface.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.s2)
            if task.hasNotes {
                Image(systemName: "note.text")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityLabel("Has notes")
            }
            if task.priority != .none {
                PriorityMarker(priority: task.priority)
            }
        }
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the task")
    }

    /// The quiet line, with a near deadline in muted red.
    private var quietLine: Text? {
        let theme = Theme.current
        guard let line = model.quietLine(for: task, in: bucket) else { return nil }
        let isNear = TaskRules.deadlineIsNear(task, today: model.today, in: model.calendar)
        let parts = line.components(separatedBy: " · ")
        var text = Text("")
        for (index, part) in parts.enumerated() {
            let isDeadline = part.hasPrefix("Due") || part.hasPrefix("Overdue")
            let piece = Text(part).foregroundColor(isDeadline && isNear ? theme.danger.color : theme.textSecondary.color)
            text = index == 0 ? piece : text + Text(" · ").foregroundColor(theme.textSecondary.color) + piece
        }
        return text
    }
}

/// Priority, shown quietly: one to three small marks.
struct PriorityMarker: View {
    let priority: TaskItem.Priority

    var body: some View {
        Text(String(repeating: "!", count: priority.rawValue))
            .font(Typeface.caption.weight(.bold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .accessibilityLabel("\(priority.name) priority")
    }
}

/// Which of a task's dates the scheduling sheet is setting.
struct ScheduleTarget: Identifiable, Equatable {
    enum Kind { case when, deadline }

    let id: UUID
    let kind: Kind
}

/// The whole task, opened in place: title, notes, checklist, dates, tags and priority. Changes save as
/// they're made, and only what changed here is sent, so a sync meanwhile isn't undone.
struct TaskEditor: View {
    let model: TasksModel
    let task: TaskItem
    let onSchedule: (ScheduleTarget) -> Void
    @State private var draft: TaskItem
    @State private var base: TaskItem
    @State private var newItem = ""
    @State private var newTag = ""
    @State private var confirmingDelete = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case title, notes, item(UUID), newItem, newTag }
    /// How long after typing stops a change is saved.
    static let saveDelay = Duration.milliseconds(500)

    init(model: TasksModel, task: TaskItem, onSchedule: @escaping (ScheduleTarget) -> Void) {
        self.model = model
        self.task = task
        self.onSchedule = onSchedule
        _draft = State(initialValue: task)
        _base = State(initialValue: task)
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            TextField("New task", text: $draft.title, axis: .vertical)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .focused($focus, equals: .title)
                .padding(.top, Space.s3 - Space.s1)
            notes
            checklist
            chips
            tags
            HStack {
                Spacer()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text saves a moment after typing stops; anything else saves at once.
        .task(id: draft) {
            guard draft != base else { return }
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
        .onChange(of: task) { _, new in
            // Something else changed it, like a tick on the tile or a sync: take it in, keeping what's typed.
            guard new != base else { return }
            let typed = draft
            let typedSince = base
            base = new
            draft = new.applying(typed, since: typedSince, at: new.updatedAt)
        }
        .onDisappear { Task { await save() } }
        .confirmationDialog("Delete this task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) { Task { await model.delete(task.id) } }
        } message: {
            Text("It's removed from all your devices.")
        }
    }

    private func save() async {
        guard draft != base else { return }
        if let saved = await model.commit(draft, since: base) {
            base = saved
            if draft != saved, focus == nil { draft = saved }
        }
    }

    @ViewBuilder private var notes: some View {
        let theme = Theme.current
        if focus == .notes || !draft.hasNotes {
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textPrimary.color)
                .focused($focus, equals: .notes)
                .lineLimit(1...12)
        } else {
            // Markdown, shown as it reads. Tapping goes back to the words as typed.
            Text(Self.markdown(draft.notes))
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textPrimary.color)
                .tint(theme.accent.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focus = .notes }
                .accessibilityHint("Edit notes")
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var checklist: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: 0) {
            ForEach($draft.checklist) { $item in
                HStack(spacing: Space.s1) {
                    TickBox(isDone: item.isDone, title: item.title, diameter: Space.s4) { item.isDone.toggle() }
                    TextField("Item", text: $item.title)
                        .font(Typeface.callout.weight(.regular))
                        .foregroundStyle(item.isDone ? theme.textSecondary.color : theme.textPrimary.color)
                        .focused($focus, equals: .item(item.id))
                    Button {
                        draft.checklist.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(width: Space.s6, height: Space.s6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.title)")
                }
            }
            HStack(spacing: Space.s1) {
                Image(systemName: "plus")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
                    .accessibilityHidden(true)
                TextField("Add to checklist", text: $newItem)
                    .font(Typeface.callout.weight(.regular))
                    .focused($focus, equals: .newItem)
                    .onSubmit {
                        let title = newItem.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        draft.checklist.append(.init(title: title))
                        newItem = ""
                        focus = .newItem
                    }
            }
        }
        .padding(.leading, -Space.s2)
    }

    private var chips: some View {
        let today = model.today
        let calendar = model.calendar
        return FlowRow {
            Chip(systemImage: "calendar", text: draft.when.map { TaskText.day($0, today: today, in: calendar) + (draft.isEvening ? " evening" : "") }
                ?? (draft.place == .someday ? "Someday" : "When")) {
                onSchedule(ScheduleTarget(id: task.id, kind: .when))
            }
            if draft.when != nil {
                TimeChip(time: $draft.time, calendar: calendar)
            }
            Chip(
                systemImage: "flag", text: draft.deadline.map { TaskText.deadline($0, today: today, in: calendar) } ?? "Deadline",
                isWarning: TaskRules.deadlineIsNear(draft, today: today, in: calendar)
            ) {
                onSchedule(ScheduleTarget(id: task.id, kind: .deadline))
            }
            Menu {
                Picker("Priority", selection: $draft.priority) {
                    ForEach(TaskItem.Priority.allCases, id: \.self) { Text($0.name).tag($0) }
                }
            } label: {
                ChipLabel(systemImage: "exclamationmark", text: draft.priority == .none ? "Priority" : draft.priority.name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private var tags: some View {
        let theme = Theme.current
        return FlowRow {
            ForEach(draft.tags, id: \.self) { tag in
                Button {
                    draft.tags.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: Space.s1) {
                        Text("#" + tag)
                        Image(systemName: "xmark").font(Typeface.micro)
                    }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1)
                    .neumorphic(.pressed, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
            TextField("Add tag", text: $newTag)
                .font(Typeface.caption)
                .focused($focus, equals: .newTag)
                .frame(minWidth: Space.s8)
                .fixedSize()
                .onSubmit {
                    let tag = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                    if !tag.isEmpty, !draft.tags.contains(tag) { draft.tags.append(tag) }
                    newTag = ""
                }
        }
    }
}

/// A small soft button in the editor.
struct Chip: View {
    let systemImage: String
    let text: String
    var isWarning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(systemImage: systemImage, text: text, isWarning: isWarning)
        }
        .buttonStyle(.plain)
    }
}

struct ChipLabel: View {
    let systemImage: String
    let text: String
    var isWarning = false

    var body: some View {
        let theme = Theme.current
        Label(text, systemImage: systemImage)
            .font(Typeface.caption)
            .foregroundStyle(isWarning ? theme.danger.color : theme.textSecondary.color)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .neumorphic(.subtle, in: Capsule())
    }
}

/// The optional time, added and cleared in place.
private struct TimeChip: View {
    @Binding var time: TaskTime?
    let calendar: Calendar

    var body: some View {
        if let time {
            HStack(spacing: Space.s1) {
                DatePicker("Time", selection: Binding(
                    get: { TaskDay(year: 2026, month: 1, day: 15).date(at: time, in: calendar) },
                    set: { self.time = TaskTime($0, in: calendar) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                Button {
                    self.time = nil
                } label: {
                    Image(systemName: "xmark").font(Typeface.micro)
                        .foregroundStyle(Theme.current.textSecondary.color)
                        .frame(width: Space.s5, height: Space.s5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove time")
            }
        } else {
            Chip(systemImage: "clock", text: "Time") { time = TaskTime(hour: 9) }
        }
    }
}

/// Lays chips out in rows, wrapping as they run out of room.
struct FlowRow: Layout {
    var spacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
