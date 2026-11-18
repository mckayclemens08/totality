import SwiftUI
import TotalityCore
import TotalityUI

/// Tasks' home tile at each size (redesign, 2026-11-17). Small is today's ring, centred, and the next
/// task. Medium puts the ring beside today's first few tasks. Large has a smaller ring with how many are
/// left, as many tasks as fit, and an Add a task button that opens quick add over the home page. The
/// ticks work on the tile.
public struct TasksHomeTile: View {
    private static let mostRows = 8

    private let model: TasksModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void
    private let onQuickAdd: @MainActor () -> Void

    /// `onOpen` brings Tasks up after a task has been asked for. `onQuickAdd` shows quick add over the home page.
    public init(
        model: TasksModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {},
        onQuickAdd: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
        self.onQuickAdd = onQuickAdd
    }

    public var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
        .tilePadding()
        .animation(Motion.standard, value: model.progress)
        .sensoryFeedback(.success, trigger: model.completions)
    }

    private var todays: [TaskItem] {
        model.tasks(in: .today)
    }

    /// Today's first task not done yet.
    private var next: TaskItem? {
        todays.first { !model.isDone($0.id) }
    }

    private func openToday() {
        if let first = todays.first { model.requestedTask = first.id }
        onOpen()
    }

    private func ring(diameter: CGFloat, caption: String?) -> some View {
        let theme = Theme.current
        let progress = model.progress
        return TotalityUI.ProgressRing(progress: progress.fraction, diameter: diameter) {
            VStack(spacing: 0) {
                Text("\(progress.done)/\(progress.planned)")
                    .font(size == .large ? Typeface.headline : Typeface.title)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .tileLink(progress.spoken) { openToday() }
    }

    // MARK: Small

    private var small: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s1) {
            TileHeader("Tasks", systemImage: "checklist")
            if model.progress.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing planned today")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else {
                ring(diameter: Space.s8 + Space.s5, caption: "done")
                    .frame(maxHeight: .infinity)
                Text(next.map { "Next: \($0.displayTitle)" } ?? "All done today")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                    .tileLink(next?.displayTitle ?? "") {
                        if let next { model.requestedTask = next.id }
                        onOpen()
                    }
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: Space.s4) {
            if !model.progress.isEmpty {
                ring(diameter: Space.s8 + Space.s6, caption: "done today")
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                TileHeader("Tasks · Today", systemImage: "checklist")
                lines(3)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Large

    private var large: some View {
        let theme = Theme.current
        let left = todays.filter { !model.isDone($0.id) }
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if !model.progress.isEmpty {
                    ring(diameter: Space.s8 + Space.s3, caption: nil)
                }
                VStack(alignment: .leading, spacing: 0) {
                    TileHeader("Tasks · Today", systemImage: "checklist")
                    Text(left.isEmpty ? "All done today" : "\(left.count) left today")
                        .font(Typeface.title)
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(.top, Space.s1)
                    if let footnote {
                        Text(footnote.text)
                            .font(Typeface.caption)
                            .foregroundStyle(footnote.isUrgent ? theme.danger.color : theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
            }
            lines(Self.mostRows)
                .frame(maxHeight: .infinity, alignment: .top)
            addButton
        }
    }

    /// Overdue first, then when the next one is due.
    private var footnote: (text: String, isUrgent: Bool)? {
        let overdue = model.overdue
        if overdue > 0 { return (overdue == 1 ? "1 overdue" : "\(overdue) overdue", true) }
        if let time = next?.time { return ("Next at \(TaskText.time(time, in: model.calendar))", false) }
        if let deadline = model.nextDeadline, let date = deadline.deadline {
            return ("\(deadline.displayTitle) · \(TaskText.deadlinePhrase(date, today: model.today, in: model.calendar))",
                    TaskRules.deadlineIsNear(deadline, today: model.today, in: model.calendar))
        }
        return nil
    }

    /// A plain raised button, never a field or a "type here" prompt: a tile holds no text input.
    private var addButton: some View {
        let theme = Theme.current
        return Label("Add a task", systemImage: "plus")
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(theme.accent.color)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2 + Space.s1 / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .tileLink("Add a task") { onQuickAdd() }
    }

    /// Today's tasks, as many as fit up to `limit`.
    @ViewBuilder private func lines(_ limit: Int) -> some View {
        let shown = Array(todays.prefix(limit))
        if shown.isEmpty {
            Text("Nothing planned today")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
        } else {
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: shown.count, to: 0, by: -1)), id: \.self) { count in
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ForEach(shown.prefix(count)) { task in
                            TileTaskLine(model: model, task: task, onOpen: onOpen)
                        }
                    }
                }
            }
            .animation(Motion.standard, value: shown.map(\.id))
        }
    }
}

/// One of today's tasks on the tile: the tick works right there, and the title opens it in Tasks.
private struct TileTaskLine: View {
    let model: TasksModel
    let task: TaskItem
    let onOpen: @MainActor () -> Void

    var body: some View {
        let theme = Theme.current
        let isDone = model.isDone(task.id)
        HStack(spacing: Space.s2) {
            TickMark(isDone: isDone, diameter: Space.s4 + Space.s1 / 2)
                .contentShape(Rectangle())
                .tileLink(isDone ? "Mark \(task.displayTitle) as not done" : "Complete \(task.displayTitle)") {
                    Task { await model.toggle(task.id) }
                }
            Text(task.displayTitle)
                .font(Typeface.callout.weight(.regular))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? theme.textSecondary.color : theme.textPrimary.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tileLink(task.displayTitle) {
                    model.requestedTask = task.id
                    onOpen()
                }
            if let time = task.time, !isDone {
                Text(TaskText.time(time, in: model.calendar))
                    .font(Typeface.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1 / 2)
                    .background(theme.highlight.color, in: RoundedRectangle(cornerRadius: Radius.sm / 2, style: .continuous))
            }
        }
    }
}
