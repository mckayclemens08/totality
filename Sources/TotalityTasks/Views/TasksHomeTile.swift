import SwiftUI
import TotalityCore
import TotalityUI

/// Tasks' big home tile. Each size has its own job (issue 127): medium is a glance at today's count and
/// the next deadline, large is today's list with tick boxes that work on the tile, and the big square is a
/// workspace, today's list plus quick add over the home page, without opening Tasks.
public struct TasksHomeTile: View {
    private let model: TasksModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void
    private let onQuickAdd: @MainActor () -> Void

    /// `onOpen` brings Tasks up after a task has been asked for. `onQuickAdd` shows quick add over the home page.
    public init(
        model: TasksModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {},
        onQuickAdd: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
        self.onQuickAdd = onQuickAdd
    }

    public var body: some View {
        switch size {
        case .medium: glance
        case .large: list(limit: 5)
        case .square: workspace
        }
    }

    // MARK: Medium: is there anything for me?

    private var glance: some View {
        let theme = Theme.current
        let count = model.count(.today)
        return VStack(alignment: .leading, spacing: Space.s1) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text("\(count)")
                    .font(Typeface.display)
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? theme.accent.color : theme.textSecondary.color)
                Text(count == 0 ? "Nothing planned today" : count == 1 ? "task today" : "tasks today")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .tileLink(count == 1 ? "1 task today" : "\(count) tasks today", action: count > 0 ? { onOpenToday() } : nil)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onOpenToday() {
        if let first = model.tasks(in: .today).first { model.requestedTask = first.id }
        onOpen()
    }

    // MARK: Large: what are the things?

    private func list(limit: Int) -> some View {
        let theme = Theme.current
        let todays = model.tasks(in: .today)
        return VStack(alignment: .leading, spacing: Space.s1) {
            if todays.isEmpty {
                Text("Nothing planned today")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textSecondary.color)
            } else {
                Text(todays.count == 1 ? "1 today" : "\(todays.count) today")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.accent.color)
            }
            ForEach(todays.prefix(limit)) { task in
                TileTaskLine(model: model, task: task, onOpen: onOpen)
                    .transition(.opacity)
            }
            if todays.count > limit {
                Text("\(todays.count - limit) more")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .tileLink("\(todays.count - limit) more today") { onOpenToday() }
            }
            Spacer(minLength: 0)
            footer
        }
        .animation(Motion.standard, value: todays.map(\.id))
        .sensoryFeedback(.success, trigger: model.completions)
    }

    // MARK: Big square: do the next thing here.

    private var workspace: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Image(systemName: "plus")
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.accentOn.color)
                    .frame(width: Space.s5, height: Space.s5)
                    .background(Circle().fill(theme.accent.color))
                Text("Add a task, like “Call Gran tomorrow 5pm”")
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .neumorphic(.pressed, in: Capsule())
            .tileLink("New task") { onQuickAdd() }
            list(limit: 7)
        }
    }

    @ViewBuilder private var footer: some View {
        let theme = Theme.current
        let overdue = model.overdue
        VStack(alignment: .leading, spacing: Space.s1 / 2) {
            if overdue > 0 {
                Text(overdue == 1 ? "1 overdue" : "\(overdue) overdue")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.danger.color)
            }
            if let next = model.nextDeadline, let deadline = next.deadline {
                Text("\(next.displayTitle) · \(TaskText.deadlinePhrase(deadline, today: model.today, in: model.calendar))")
                    .font(Typeface.caption)
                    .foregroundStyle(TaskRules.deadlineIsNear(next, today: model.today, in: model.calendar) ? theme.danger.color : theme.textSecondary.color)
                    .lineLimit(1)
                    .tileLink(next.displayTitle) {
                        model.requestedTask = next.id
                        onOpen()
                    }
            }
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
            TickMark(isDone: isDone, diameter: Space.s4 + Space.s1)
                .frame(width: Space.s6, height: Space.s6)
                .contentShape(Rectangle())
                .tileLink(isDone ? "Mark \(task.displayTitle) as not done" : "Complete \(task.displayTitle)") {
                    Task { await model.toggle(task.id) }
                }
            Text(task.displayTitle)
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(isDone ? theme.textSecondary.color : theme.textPrimary.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tileLink(task.displayTitle) {
                    model.requestedTask = task.id
                    onOpen()
                }
            if let time = task.time {
                Text(TaskText.time(time, in: model.calendar))
                    .font(Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }
}
