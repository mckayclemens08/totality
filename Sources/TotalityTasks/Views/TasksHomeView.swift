import SwiftUI
import TotalityCore
import TotalityUI

/// Tasks' screen: Home, the list's big title, a pill for each list, and the list itself (redesign,
/// 2026-11-17). Today opens first, with its progress ring.
public struct TasksHomeView: View {
    /// Today first, as on the canvas, then the rest in their usual order.
    static let pillOrder: [TaskBucket] = [.today, .inbox, .upcoming, .anytime, .someday, .logbook]

    @Bindable private var model: TasksModel
    private let onClose: (() -> Void)?
    @State private var bucket: TaskBucket = .today
    @State private var expanded: UUID?
    @State private var addingTo: TaskBucket?
    @AppStorage("tasks.splitToday") private var splitToday = false

    public init(model: TasksModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            header
            front
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onClose)
        .tint(theme.accent.color)
        .overlay(alignment: .bottomTrailing) {
            if model.phase == .ready {
                AddButton("New task") { addingTo = bucket == .logbook ? .inbox : bucket }
                    .padding(Space.s4)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .overlay(alignment: .bottom) {
            if let last = model.lastCompleted {
                UndoBar(title: last.title, onUndo: { Task { await model.undoCompletion() } }, onDismiss: model.dismissUndo)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s5 + Metric.addButton)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(Motion.smooth, value: model.lastCompleted)
        .sensoryFeedback(.success, trigger: model.completions)
        .sheet(item: $addingTo) { bucket in
            QuickAddView(model: model, bucket: bucket) { addingTo = nil }
        }
        .alert("Tasks", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task {
            await model.load()
            takeRequests()
        }
        .onChange(of: model.requestedTask) { takeRequests() }
        .onChange(of: model.requestedQuickAdd) { takeRequests() }
        .onChange(of: bucket) { expanded = nil }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    /// Opens what home search or the tile asked for: a task, in its list and open, or quick add.
    private func takeRequests() {
        guard model.phase == .ready else { return }
        if let id = model.requestedTask, let task = model.tasks.first(where: { $0.id == id }) {
            model.requestedTask = nil
            bucket = TaskRules.bucket(of: task, today: model.today)
            expanded = id
        }
        if model.requestedQuickAdd {
            model.requestedQuickAdd = false
            addingTo = .inbox
        }
    }

    /// Home and Today's options, the list's big title, and the pills.
    private var header: some View {
        let ready = model.phase == .ready
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if let onClose {
                    HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                }
                Spacer(minLength: 0)
                if ready, bucket == .today {
                    HeaderMenu("Today options", systemImage: "ellipsis") {
                        Toggle("Split into morning, afternoon and evening", isOn: $splitToday)
                    }
                }
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle(ready ? bucket.name : "Tasks")
            if ready {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach(Self.pillOrder) { item in
                            FilterPill(pillTitle(item), isSelected: bucket == item) {
                                withMotion(Motion.snappy) { bucket = item }
                            }
                            .accessibilityLabel(pillLabel(item))
                        }
                    }
                    // Room for the shadow pair, which a scroll view would clip.
                    .padding(Space.s2)
                }
                .padding(.horizontal, -Space.s2)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    /// "Today · 4": Inbox and Today show what's in them, as the old list of lists did.
    private func pillTitle(_ item: TaskBucket) -> String {
        let count = item == .inbox || item == .today ? model.count(item) : 0
        return count > 0 ? "\(item.name) · \(count)" : item.name
    }

    private func pillLabel(_ item: TaskBucket) -> String {
        var parts = [item.name]
        if item == .inbox || item == .today, model.count(item) > 0 { parts.append("\(model.count(item)) tasks") }
        if item == .today, model.overdue > 0 { parts.append("\(model.overdue) overdue") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var front: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening your tasks")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            TasksMessage(
                systemImage: "exclamationmark.triangle",
                title: "Your tasks didn't open",
                detail: "This device's storage couldn't be read. Close Tasks and try again. Nothing has been changed."
            )
            .pullsToRefresh(with: model.refresher)
        case .ready:
            TaskListView(model: model, bucket: bucket, expanded: $expanded)
                .id(bucket)
        }
    }
}

/// "Completed …  Undo", for a few seconds after a tick.
struct UndoBar: View {
    let title: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Text("Completed “\(title)”")
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Spacer()
            Button("Undo", action: onUndo)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: Capsule())
        .onTapGesture(perform: onDismiss)
    }
}

/// A full-screen message, for when Tasks can't open.
struct TasksMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        ScrollView {
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
            .frame(maxWidth: .infinity)
            .padding(.top, Space.s8)
        }
    }
}
