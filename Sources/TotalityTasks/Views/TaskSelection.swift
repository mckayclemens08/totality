import SwiftUI
import TotalityCore
import TotalityUI

/// What's chosen while several tasks are picked at once, and what's being dragged. One per Tasks screen,
/// shared with every list in it.
@MainActor
@Observable
final class TaskSelection {
    /// Picking several: a long press on a task starts it.
    private(set) var isOn = false
    private(set) var ids: Set<UUID> = []
    /// The task picked up to drag. iOS asks for it as soon as a long press lifts the row, even when the
    /// press only opens the menu, so the tray waits for `isDragMoving`.
    var dragging: UUID? {
        didSet { if dragging == nil { isDragMoving = false } }
    }
    /// The drag has come over the screen, so it really is a drag.
    var isDragMoving = false

    /// Whether the tray of lists to drop on is up.
    var showsTray: Bool { dragging != nil && isDragMoving && !isOn }
    /// Bumps as a drag passes over a new place, for the haptic tick.
    private(set) var ticks = 0

    func start(with id: UUID) {
        dragging = nil
        isOn = true
        ids = [id]
    }

    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func selectAll(_ all: [UUID]) {
        ids = Set(all)
    }

    func end() {
        dragging = nil
        isOn = false
        ids = []
    }

    func tick() {
        ticks += 1
    }
}

extension EnvironmentValues {
    @Entry var taskSelection: TaskSelection?
}

extension View {
    /// Lets a dragged task be dropped here, just above `task`, with a haptic tick as it arrives.
    func dropsTask(above task: TaskItem, in shown: [TaskItem], model: TasksModel, selection: TaskSelection?) -> some View {
        modifier(TaskDropTarget(task: task, shown: shown, model: model, selection: selection))
    }
}

/// A row a dragged task can land above. While one hovers, a soft accent slot opens where it would go.
private struct TaskDropTarget: ViewModifier {
    let task: TaskItem
    let shown: [TaskItem]
    let model: TasksModel
    let selection: TaskSelection?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        VStack(spacing: Space.s2) {
            if isTargeted {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Theme.current.highlight.color)
                    .frame(height: Space.s7)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            content
        }
        .motion(Motion.snappy, value: isTargeted)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != task.id else { return false }
            selection?.dragging = nil
            Task { await model.place(id, before: task.id, in: shown) }
            return true
        } isTargeted: { on in
            isTargeted = on
            if on { selection?.tick() }
        }
    }
}

/// Under the whole Tasks screen: notices a drag moving over it, so the tray comes up only for a real
/// drag. It takes no drops itself.
struct DragWatcher: DropDelegate {
    let selection: TaskSelection

    func validateDrop(info: DropInfo) -> Bool { selection.dragging != nil }

    func dropEntered(info: DropInfo) {
        if selection.dragging != nil { selection.isDragMoving = true }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if selection.dragging != nil, !selection.isDragMoving { selection.isDragMoving = true }
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        selection.dragging = nil
        return false
    }
}
