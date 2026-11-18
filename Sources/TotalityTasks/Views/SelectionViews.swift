import SwiftUI
import TotalityCore
import TotalityUI

extension TaskList.Kind: Identifiable {
    public var id: String { rawValue }
}

/// What the selection bar opens.
enum SelectionSheet: String, Identifiable {
    case move, date, tag
    var id: String { rawValue }
}

/// The accent round +, as the label of a menu.
struct AddMark: View {
    var body: some View {
        let theme = Theme.current
        Image(systemName: "plus")
            .font(Typeface.title.weight(.semibold))
            .foregroundStyle(theme.accentOn.color)
            .frame(width: Metric.addButton, height: Metric.addButton)
            .background(Circle().fill(theme.accent.color))
            .neumorphic(.raised, in: Circle())
            .contentShape(Circle())
    }
}

/// Over the screen's header while several are picked: Cancel, Select all and how many.
struct SelectionHeader: View {
    let selection: TaskSelection
    let visible: [UUID]

    var body: some View {
        let theme = Theme.current
        let allPicked = !visible.isEmpty && Set(visible).isSubset(of: selection.ids)
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                HeaderPill("Cancel") { selection.end() }
                Spacer(minLength: 0)
                HeaderPill(allPicked ? "Select none" : "Select all") {
                    withMotion(Motion.snappy) { selection.selectAll(allPicked ? [] : visible) }
                }
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle(selection.ids.count == 1 ? "1 selected" : "\(selection.ids.count) selected")
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s3)
        .frame(maxWidth: .infinity)
        .background(theme.bg.color)
    }
}

/// Along the bottom while several are picked: Move, Date, Tag, Complete and Delete.
struct SelectionBar: View {
    let model: TasksModel
    let selection: TaskSelection
    @Binding var sheet: SelectionSheet?

    var body: some View {
        let theme = Theme.current
        let none = selection.ids.isEmpty
        HStack(spacing: 0) {
            action("Move", systemImage: "arrow.right.circle") { sheet = .move }
            action("Date", systemImage: "calendar") { sheet = .date }
            action("Tag", systemImage: "tag") { sheet = .tag }
            action("Complete", systemImage: "checkmark.circle") {
                let ids = selection.ids
                selection.end()
                Task { await model.complete(ids) }
            }
            // No question first: Undo stays for a few seconds, then it's for good (owner, 2026-11-18).
            action("Delete", systemImage: "trash", tint: theme.danger.color) {
                let ids = selection.ids
                selection.end()
                Task { await model.delete(tasks: ids) }
            }
        }
        .disabled(none)
        .opacity(none ? Motion.pressOpacity : 1)
        .padding(.horizontal, Space.s2)
        .padding(.top, Space.s3)
        .padding(.bottom, Space.s2)
        .background {
            Color.clear
                .neumorphic(.raised, in: UnevenRoundedRectangle(topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg, style: .continuous))
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func action(_ title: String, systemImage: String, tint: Color? = nil, _ run: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: run) {
            VStack(spacing: Space.s1) {
                Image(systemName: systemImage).font(Typeface.headline)
                Text(title).font(Typeface.micro)
            }
            .foregroundStyle(tint ?? theme.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
    }
}

/// Up from the bottom while a task is dragged: the lists to drop it on (owner, 2026-11-18).
struct DragTray: View {
    let model: TasksModel
    let selection: TaskSelection

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text("Drop on a list to move it")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                Spacer()
                Button {
                    selection.dragging = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: Space.s6, height: Space.s6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("Close the tray")
            }
            .padding(.horizontal, Space.s1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s3) {
                    ForEach(DestinationChoice.all(in: model)) { choice in
                        TrayTarget(model: model, selection: selection, choice: choice)
                    }
                }
                .padding(Space.s2)
            }
            .padding(.horizontal, -Space.s2)
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s3)
        .padding(.bottom, Space.s2)
        .background {
            Color.clear
                .neumorphic(.raised, in: UnevenRoundedRectangle(topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg, style: .continuous))
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// One list in the drag tray. It fills with the accent while a task hovers over it.
private struct TrayTarget: View {
    let model: TasksModel
    let selection: TaskSelection
    let choice: DestinationChoice
    @State private var isTargeted = false

    var body: some View {
        let theme = Theme.current
        Label(choice.name, systemImage: choice.systemImage)
            .font(Typeface.callout)
            .foregroundStyle(isTargeted ? theme.accentOn.color : theme.textPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2 + Space.s1 / 2)
            .background { if isTargeted { Capsule().fill(theme.accent.color) } }
            .neumorphic(isTargeted ? .flat : .subtle, in: Capsule())
            .scaleEffect(isTargeted ? 1.05 : 1)
            .motion(Motion.snappy, value: isTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                selection.dragging = nil
                Task { await model.move([id], to: choice.destination) }
                return true
            } isTargeted: { on in
                isTargeted = on
                if on { selection.tick() }
            }
            .accessibilityLabel("Move to \(choice.name)")
    }
}

/// "3 tasks deleted · Gone for good in 3 seconds · Undo", counting down.
struct DeleteUndoBar: View {
    let pending: PendingDelete
    let onUndo: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 0) {
                Text(pending.title)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(1, Int(pending.until.timeIntervalSince(context.date).rounded(.up)))
                    Text(left == 1 ? "Gone for good in 1 second" : "Gone for good in \(left) seconds")
                        .font(Typeface.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Spacer()
            Button("Undo", action: onUndo)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
